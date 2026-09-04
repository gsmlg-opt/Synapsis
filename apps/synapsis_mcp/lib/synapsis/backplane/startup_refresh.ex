defmodule Synapsis.Backplane.StartupRefresh do
  @moduledoc "Refresh enabled Backplane capability sources asynchronously at startup."

  use GenServer

  require Logger

  alias Synapsis.Backplane
  alias Synapsis.Backplane.Connection

  @timeout_ms 30_000

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      connections: Keyword.get(opts, :connections, &Connection.list/0),
      refresh: Keyword.get(opts, :refresh, &Backplane.refresh/1),
      task_supervisor: Keyword.get(opts, :task_supervisor, Synapsis.Tool.TaskSupervisor),
      timeout: Keyword.get(opts, :timeout, @timeout_ms),
      tasks: %{}
    }

    {:ok, state, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    tasks = schedule_enabled_connections(state)
    {:noreply, %{state | tasks: tasks}}
  end

  @impl true
  def handle_info({:task_timeout, ref}, state) do
    case Map.pop(state.tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {task, tasks} ->
        Task.Supervisor.terminate_child(state.task_supervisor, task.pid)
        Process.demonitor(ref, [:flush])

        Logger.warning("backplane_startup_refresh_timeout", connection_id: task.connection_id)

        {:noreply, %{state | tasks: tasks}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {task, tasks} ->
        Process.cancel_timer(task.timer)
        log_failure(task.connection_id, reason)
        {:noreply, %{state | tasks: tasks}}
    end
  end

  defp schedule_enabled_connections(state) do
    state.connections.()
    |> Enum.filter(&(&1.enabled and &1.sync_on_start))
    |> Enum.reduce(state.tasks, fn connection, tasks ->
      case start_refresh_task(state, connection.id) do
        {:ok, ref, task} ->
          Map.put(tasks, ref, task)

        {:error, reason} ->
          Logger.warning("backplane_startup_refresh_start_failed",
            connection_id: connection.id,
            reason: inspect(reason)
          )

          tasks
      end
    end)
  rescue
    error ->
      Logger.warning("backplane_startup_refresh_schedule_failed",
        reason: Exception.message(error)
      )

      state.tasks
  catch
    kind, reason ->
      Logger.warning("backplane_startup_refresh_schedule_failed",
        reason: inspect({kind, reason})
      )

      state.tasks
  end

  defp start_refresh_task(state, connection_id) do
    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           run_refresh(state.refresh, connection_id)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        timer = Process.send_after(self(), {:task_timeout, ref}, state.timeout)
        {:ok, ref, %{pid: pid, timer: timer, connection_id: connection_id}}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp run_refresh(refresh, connection_id) do
    case refresh.(connection_id) do
      {:error, _reason} ->
        Logger.warning("backplane_startup_refresh_failed", connection_id: connection_id)

      _result ->
        :ok
    end
  rescue
    error ->
      Logger.warning("backplane_startup_refresh_failed",
        connection_id: connection_id,
        error: inspect(error.__struct__)
      )
  catch
    kind, _reason ->
      Logger.warning("backplane_startup_refresh_failed",
        connection_id: connection_id,
        failure_kind: inspect(kind)
      )
  end

  defp log_failure(_connection_id, reason) when reason in [:normal, :shutdown, :noproc], do: :ok

  defp log_failure(connection_id, _reason),
    do: Logger.warning("backplane_startup_refresh_failed", connection_id: connection_id)
end
