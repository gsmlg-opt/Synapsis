defmodule Synapsis.Agent.Daemon.StatusPublisher do
  @moduledoc false

  use GenServer

  alias Synapsis.Agent.Daemon.Execution
  alias Synapsis.Agent.RunEvents

  @task_supervisor Synapsis.Agent.Daemon.RunTaskSupervisor
  @event_timeout 1_000
  @retry_ms 50

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def publish(server \\ __MODULE__, status), do: GenServer.cast(server, {:publish, status})

  @impl true
  def init(opts) do
    {:ok,
     %{
       task_supervisor: Keyword.get(opts, :task_supervisor, @task_supervisor),
       run_events: Keyword.get(opts, :run_events, RunEvents),
       event_timeout: Keyword.get(opts, :event_timeout, @event_timeout),
       retry_ms: Keyword.get(opts, :retry_ms, @retry_ms),
       sequence: 0,
       current: nil,
       dirty: nil,
       last_error: nil
     }}
  end

  @impl true
  def handle_cast({:publish, status}, state) do
    sequence = state.sequence + 1
    snapshot = {sequence, status}
    state = %{state | sequence: sequence}

    case state.current do
      nil -> {:noreply, start_publish(state, snapshot)}
      _current -> {:noreply, %{state | dirty: snapshot}}
    end
  end

  @impl true
  def handle_info({:publish_result, pid, sequence, result}, state) do
    case state.current do
      %{pid: ^pid, ref: ref, timer_ref: timer_ref, sequence: ^sequence} = current ->
        Process.demonitor(ref, [:flush])
        cancel_timer(timer_ref)
        state = %{state | current: nil}

        case result do
          :ok -> {:noreply, start_dirty(state)}
          {:ok, _value} -> {:noreply, start_dirty(state)}
          error -> {:noreply, retry_later(state, state.dirty || current.snapshot, error)}
        end

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:publish_timeout, ref, pid}, state) do
    case state.current do
      %{ref: ^ref, pid: ^pid} ->
        Process.exit(pid, :kill)
        {:noreply, put_error(state, :status_publish_timeout)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:retry, {sequence, _status}}, %{sequence: latest} = state)
      when sequence < latest,
      do: {:noreply, state}

  def handle_info({:retry, snapshot}, %{current: nil} = state),
    do: {:noreply, start_publish(state, state.dirty || snapshot)}

  def handle_info({:retry, snapshot}, state),
    do: {:noreply, %{state | dirty: state.dirty || snapshot}}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case state.current do
      %{ref: ^ref, timer_ref: timer_ref} = current ->
        cancel_timer(timer_ref)
        state = %{state | current: nil}
        {:noreply, retry_later(state, state.dirty || current.snapshot, reason)}

      _other ->
        {:noreply, state}
    end
  end

  defp start_publish(state, nil), do: state

  defp start_publish(state, {sequence, status} = snapshot) do
    owner = self()

    case Execution.start_monitored_task(state.task_supervisor, fn ->
           result =
             Execution.protect(fn ->
               RunEvents.publish_status(state.run_events, status, sequence)
             end)

           send(owner, {:publish_result, self(), sequence, result})
         end) do
      {:ok, pid, ref} ->
        timer_ref =
          Process.send_after(self(), {:publish_timeout, ref, pid}, state.event_timeout)

        current = %{
          pid: pid,
          ref: ref,
          timer_ref: timer_ref,
          sequence: sequence,
          snapshot: snapshot
        }

        %{state | current: current, dirty: nil}

      {:error, reason} ->
        retry_later(state, snapshot, {:status_publish_start_failed, reason})
    end
  end

  defp start_dirty(%{dirty: nil} = state), do: state
  defp start_dirty(state), do: start_publish(state, state.dirty)

  defp retry_later(state, snapshot, reason) do
    Process.send_after(self(), {:retry, snapshot}, state.retry_ms)
    state |> Map.put(:dirty, nil) |> put_error(reason)
  end

  defp put_error(state, reason), do: %{state | last_error: Execution.bounded_error(reason)}

  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_timer(_ref), do: :ok
end
