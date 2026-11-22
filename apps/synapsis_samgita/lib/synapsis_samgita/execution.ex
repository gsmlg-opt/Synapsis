defmodule SynapsisSamgita.Execution do
  @moduledoc """
  Routes assigned Tasks to their selected execution identity, journaling before
  dispatch. Restart observes interrupted executions; it never repeats them.
  """
  use GenServer
  require Logger
  alias Synapsis.Samgita.{Devices, Executions}
  alias SynapsisSamgita.{API, Events, Inbound}
  alias SynapsisSamgita.Execution.Worker

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def enqueue(device_id, %{"type" => "task.assigned"} = event) do
    with {:ok, _tag, entry} <- Executions.enqueue(device_id, event) do
      GenServer.cast(__MODULE__, {:queued, entry})
      :ok
    end
  end

  def enqueue(_, _), do: :ok

  def list(device_id) do
    case Executions.list(device_id) do
      list when is_list(list) -> Enum.map(list, &Executions.public/1)
      {:error, _} = error -> error
    end
  end

  def active?(device_id), do: Executions.active?(device_id)

  @doc "Read current server Task and durable local operation identities without retrying effects."
  def reconcile(device_id, project_id, task_id) do
    id = device_id <> "/" <> project_id <> "/" <> task_id

    with {:ok, entry} <- Executions.get(id),
         {:ok, conn} <- Inbound.api_conn(device_id),
         {:ok, task} <- API.get_task(conn, project_id, task_id) do
      {:ok, %{execution: Executions.public(entry), task: task}}
    end
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    Events.subscribe_devices()
    {:ok, %{}, {:continue, :restore}}
  end

  @impl true
  def handle_continue(:restore, state) do
    for entry <- entries(nil),
        entry["phase"] not in ~w(queued completed failed ignored recovery_required) do
      Executions.revoke(entry["id"], "execution_interrupted")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:queued, entry}, state), do: {:noreply, launch(entry, state)}

  @impl true
  def handle_info({:samgita_device_status, %{state: :connected, device_id: id}}, state) do
    next = Enum.reduce(entries(id), state, &launch/2)
    {:noreply, next}
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, Map.delete(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    if active = state[ref],
      do: Executions.revoke(active.entry["id"], "execution_process_lost")

    {:noreply, Map.delete(state, ref)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp launch(%{"phase" => "queued"} = entry, state) do
    device_id = entry["device_id"]

    cond do
      Enum.any?(state, fn {_ref, active} -> active.entry["id"] == entry["id"] end) ->
        state

      not match?(%{state: :connected}, Inbound.status(device_id)) ->
        state

      true ->
        owner = self()

        task =
          Task.Supervisor.async_nolink(SynapsisSamgita.TaskSupervisor, fn ->
            with {:ok, device} <- Devices.get(device_id),
                 do: Worker.run(entry, device, owner: owner)
          end)

        Map.put(state, task.ref, %{entry: entry, pid: task.pid})
    end
  end

  defp launch(_, state), do: state

  defp entries(device_id) do
    case Executions.list(device_id) do
      list when is_list(list) ->
        list

      {:error, reason} ->
        Logger.warning("samgita_execution_journal_unavailable", reason: inspect(reason))
        []
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state, fn {ref, active} ->
      Executions.revoke(active.entry["id"], "execution_interrupted")
      Task.Supervisor.terminate_child(SynapsisSamgita.TaskSupervisor, active.pid)
      Process.demonitor(ref, [:flush])
    end)

    :ok
  end
end
