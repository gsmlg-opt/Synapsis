defmodule SynapsisLocalAgents.Runner do
  @moduledoc """
  Supervises one local agent's adapter process and owns its status
  (`:stopped | :starting | :running | :crashed`). Rebroadcasts adapter events on
  `"local_agent:<id>"`; status changes also go to `"local_agents"`.
  Requests are made by callers directly against the adapter pid.
  """
  use GenServer, restart: :temporary

  require Logger
  alias SynapsisLocalAgents.{Adapter, Event}

  @call_timeout 10_000
  # Stopping a running adapter waits for it to close its agent (Codex: up to 35 s).
  @stop_timeout 45_000
  @query_timeout 1_000

  def start_link(agent_id), do: GenServer.start_link(__MODULE__, agent_id, name: via(agent_id))

  def via(agent_id), do: {:via, Registry, {SynapsisLocalAgents.Registry, agent_id}}

  def whereis(agent_id) do
    case Registry.lookup(SynapsisLocalAgents.Registry, agent_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def start(pid), do: GenServer.call(pid, :start, @call_timeout)
  def stop(pid), do: GenServer.call(pid, :stop, @stop_timeout)
  def status(pid), do: GenServer.call(pid, :status, @query_timeout)

  @doc "The adapter `{module, pid}` while running, else nil."
  def adapter_ref(pid), do: GenServer.call(pid, :adapter, @query_timeout)

  @doc "Adapter pid for `agent_id` while running (used by tests and the facade)."
  def adapter(agent_id) do
    with pid when is_pid(pid) <- whereis(agent_id),
         {_mod, adapter} <- adapter_ref(pid) do
      adapter
    end
  end

  @impl true
  def init(agent_id) do
    Process.flag(:trap_exit, true)
    {:ok, %{id: agent_id, state: :stopped, last_error: nil, module: nil, adapter: nil}}
  end

  @impl true
  def handle_call(:status, _from, s), do: {:reply, status_of(s), s}

  def handle_call(:adapter, _from, %{state: :running} = s), do: {:reply, {s.module, s.adapter}, s}
  def handle_call(:adapter, _from, s), do: {:reply, nil, s}

  def handle_call(:start, _from, %{adapter: pid} = s) when is_pid(pid), do: {:reply, :ok, s}

  def handle_call(:start, _from, s) do
    with %{} = config <- Synapsis.LocalAgentConfigs.get(s.id),
         {:ok, module} <- Adapter.module_for(config.kind),
         {:ok, pid} <- module.start_link(config, self()) do
      Logger.info("local_agent_starting", agent_id: s.id, kind: config.kind)

      {:reply, :ok,
       publish(%{s | state: :starting, last_error: nil, module: module, adapter: pid})}
    else
      nil -> {:reply, {:error, :not_found}, s}
      :error -> {:reply, {:error, :unsupported_kind}, s}
      {:error, reason} -> {:reply, {:error, reason}, publish(crashed(s, reason))}
    end
  end

  # Still booting (e.g. Codex initializing): nothing to close gracefully yet.
  def handle_call(:stop, _from, %{adapter: pid, state: :starting} = s) when is_pid(pid) do
    Process.exit(pid, :kill)
    receive_exit(pid)
    {:reply, :ok, publish(%{s | state: :stopped, adapter: nil, module: nil})}
  end

  def handle_call(:stop, _from, %{adapter: pid, module: module} = s) when is_pid(pid) do
    # The adapter may already be dying (or die while stopping); stopping is
    # still the outcome the operator asked for.
    try do
      module.stop(pid)
    catch
      :exit, _ -> :ok
    end

    receive_exit(pid)
    {:reply, :ok, publish(%{s | state: :stopped, adapter: nil, module: nil})}
  end

  def handle_call(:stop, _from, s), do: {:reply, :ok, publish(%{s | state: :stopped})}

  @impl true
  def handle_info({:local_agent_event, %Event{type: :status, data: %{state: :running}}}, s) do
    {:noreply, publish(%{s | state: :running})}
  end

  def handle_info({:local_agent_event, %Event{} = event}, s) do
    broadcast(s.id, %{event | agent_id: s.id})
    {:noreply, s}
  end

  def handle_info({:EXIT, pid, reason}, %{adapter: pid} = s) do
    s = %{s | adapter: nil, module: nil}

    if reason in [:normal, :shutdown] do
      {:noreply, publish(%{s | state: :stopped})}
    else
      Logger.warning("local_agent_crashed", agent_id: s.id, reason: short(reason))
      {:noreply, publish(crashed(s, reason))}
    end
  end

  def handle_info(_message, s), do: {:noreply, s}

  defp receive_exit(pid) do
    receive do
      {:EXIT, ^pid, _} -> :ok
    after
      5_000 -> Process.exit(pid, :kill)
    end
  end

  defp crashed(s, reason),
    do: %{s | state: :crashed, last_error: short(reason), adapter: nil, module: nil}

  defp short(reason),
    do: reason |> inspect(limit: 5, printable_limit: 200) |> String.slice(0, 200)

  defp status_of(s), do: %{state: s.state, last_error: s.last_error}

  defp publish(s) do
    event = %Event{agent_id: s.id, type: :status, data: status_of(s)}
    broadcast(s.id, event)
    Phoenix.PubSub.broadcast(Synapsis.PubSub, "local_agents", {:local_agent_event, event})
    s
  end

  defp broadcast(id, event),
    do:
      Phoenix.PubSub.broadcast(Synapsis.PubSub, "local_agent:#{id}", {:local_agent_event, event})
end
