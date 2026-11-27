defmodule Synapsis.Voice.DeviceCallRestorer do
  @moduledoc "Restores the owner of an active Device Voice call after process or application loss."
  use GenServer
  require Logger

  alias Synapsis.Voice.DeviceCallIntent
  alias Synapsis.{AgentConfigs, VoiceSession}

  @repair_interval 1_000
  @idle_interval 30_000

  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))

  def watch(session_id, owner), do: GenServer.cast(__MODULE__, {:watch, session_id, owner})

  @impl true
  def init(options) do
    send(self(), :repair)

    {:ok,
     %{
       owner: nil,
       task: nil,
       timer: nil,
       repair: Keyword.get(options, :repair, &restore_owner/0),
       interval: Keyword.get(options, :interval, @repair_interval),
       idle_interval: Keyword.get(options, :idle_interval, @idle_interval)
     }}
  end

  @impl true
  def handle_cast({:watch, id, owner}, state) do
    # An explicit start supersedes a boot lookup already in flight. Its late
    # result must not replace the monitor of this newer owner.
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    {:noreply, state |> Map.put(:task, nil) |> cancel_timer() |> monitor_owner({id, owner})}
  end

  @impl true
  def handle_info(:repair, state), do: {:noreply, repair(state)}

  def handle_info({:repair, token}, %{timer: {_, token}} = state),
    do: {:noreply, repair(%{state | timer: nil})}

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil}

    case result do
      {:ok, id, owner} ->
        {:noreply, monitor_owner(state, {id, owner})}

      :inactive ->
        {:noreply, state |> monitor_owner(nil) |> schedule(state.idle_interval)}

      {:error, reason} ->
        Logger.warning("device_voice_restore_failed", reason: inspect(reason))
        {:noreply, schedule(state, state.interval)}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner: {_, _, ref}} = state),
    do: {:noreply, repair(%{state | owner: nil})}

  def handle_info({:DOWN, ref, :process, _, reason}, %{task: %{ref: ref}} = state) do
    Logger.warning("device_voice_restore_failed", reason: inspect(reason))
    {:noreply, schedule(%{state | task: nil}, state.interval)}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{task: %Task{} = task}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_, _), do: :ok

  defp schedule(state, delay) do
    state = cancel_timer(state)
    token = make_ref()
    timer = Process.send_after(self(), {:repair, token}, delay)
    %{state | timer: {timer, token}}
  end

  defp cancel_timer(state) do
    if state.timer, do: Process.cancel_timer(elem(state.timer, 0))
    %{state | timer: nil}
  end

  defp repair(%{owner: {_, owner, _}} = state) when is_pid(owner), do: state

  defp repair(%{task: nil} = state) do
    %{state | task: Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, state.repair)}
  end

  defp repair(state), do: state

  defp monitor_owner(%{owner: {id, owner, _}} = state, {id, owner}), do: state

  defp monitor_owner(state, replacement) do
    if state.owner do
      {_, _, ref} = state.owner
      Process.demonitor(ref, [:flush])
    end

    owner =
      case replacement do
        {id, pid} -> {id, pid, Process.monitor(pid)}
        nil -> nil
      end

    %{state | owner: owner}
  end

  defp restore_owner do
    case Enum.find(AgentConfigs.list_enabled(), &(&1.kind == :host_voice)) do
      nil ->
        :inactive

      agent ->
        case DeviceCallIntent.load(agent.id) do
          {:ok, %{active: true}} ->
            # The owner reads the latest intent in init before opening media.
            # A delayed repair cannot override a user stop already persisted.
            with {:ok, owner} <- VoiceSession.ensure_device_call_owner(agent.id),
                 do: {:ok, agent.id, owner}

          {:ok, %{active: false}} ->
            :inactive

          :not_found ->
            :inactive

          error ->
            error
        end
    end
  end
end
