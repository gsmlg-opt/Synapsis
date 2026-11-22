defmodule SynapsisSamgita.Coordinator do
  @moduledoc """
  Coordinates explicit manual project requests for a responsible manager device.
  Only queued requests may decompose. Durable commands are reconciled after
  interruption; unknown effects never authorize another task tree or execution.
  """
  use GenServer
  require Logger
  alias Synapsis.Samgita.{Coordination, Inbox}
  alias SynapsisSamgita.{Events, Inbound}
  alias SynapsisSamgita.Coordinator.Worker

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def enqueue(device_id, %{"type" => type} = event)
      when is_binary(device_id) and type in ["manual.triggered", "attempt.reported"] do
    with {:ok, _tag, entry} <- Coordination.enqueue(device_id, event) do
      GenServer.cast(__MODULE__, {:queued, entry})
      :ok
    end
  end

  def enqueue(_, _), do: :ok

  def list(device_id \\ nil) do
    case Coordination.list(device_id) do
      entries when is_list(entries) ->
        Enum.filter(entries, &(&1["event"]["type"] == "manual.triggered"))
        |> Enum.map(&Coordination.public/1)

      error ->
        error
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Events.subscribe_devices()
    {:ok, %{tasks: %{}, opts: opts}, {:continue, :restore}}
  end

  @impl true
  def handle_continue(:restore, state) do
    # Inbox acceptance and enqueue are independent commits. Recover the small
    # gap before acknowledgement, as well as journaled interrupted work.
    for entry <- Inbox.list(1_000),
        is_binary(entry["device_id"]),
        entry["event"]["type"] in ["manual.triggered", "attempt.reported"] do
      Coordination.enqueue(entry["device_id"], entry["event"])
    end

    {:noreply, Enum.reduce(entries(nil), state, &launch/2)}
  end

  @impl true
  def handle_cast({:queued, entry}, state), do: {:noreply, launch(entry, state)}

  @impl true
  def handle_info({:samgita_device_status, %{state: :connected, device_id: id}}, state),
    do: {:noreply, Enum.reduce(entries(id), state, &launch/2)}

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {entry, tasks} = Map.pop(state.tasks, ref)
    if entry, do: Events.broadcast_inbox_changed(entry.entry["event_id"])
    {:noreply, %{state | tasks: tasks}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {active, tasks} = Map.pop(state.tasks, ref)

    if active,
      do: Logger.warning("samgita_coordination_interrupted", event_id: active.entry["event_id"])

    {:noreply, %{state | tasks: tasks}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp launch(entry, state) do
    active = Enum.any?(state.tasks, fn {_, value} -> value.entry["id"] == entry["id"] end)
    phase = entry["phase"]

    if !active and phase in ~w(queued planning planned dispatching recovering) and
         match?(%{state: :connected}, Inbound.status(entry["device_id"])) do
      owner = self()

      task =
        Task.Supervisor.async_nolink(SynapsisSamgita.TaskSupervisor, fn ->
          Worker.run(entry, Keyword.put(state.opts, :owner, owner))
        end)

      %{state | tasks: Map.put(state.tasks, task.ref, %{entry: entry, pid: task.pid})}
    else
      state
    end
  end

  defp entries(device_id) do
    case Coordination.list(device_id) do
      entries when is_list(entries) ->
        entries

      {:error, reason} ->
        Logger.warning("samgita_coordination_unavailable", reason: inspect(reason))
        []
    end
  end

  @impl true
  def terminate(_reason, state) do
    for {ref, active} <- state.tasks do
      Task.Supervisor.terminate_child(SynapsisSamgita.TaskSupervisor, active.pid)
      Process.demonitor(ref, [:flush])
    end

    :ok
  end
end
