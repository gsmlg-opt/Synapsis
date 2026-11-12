defmodule SynapsisLocalAgents do
  @moduledoc """
  Facade for managing local agents (Codex today, more later): process lifecycle,
  threads and turns. `agent_id` is the `Synapsis.LocalAgentConfig` id.
  """

  alias Synapsis.LocalAgentConfigs
  alias SynapsisLocalAgents.Runner

  def list, do: Enum.map(LocalAgentConfigs.list(), &%{config: &1, status: status(&1.id)})

  def status(agent_id) do
    case Runner.whereis(agent_id) do
      nil -> %{state: :stopped, last_error: nil}
      pid -> Runner.status(pid)
    end
  end

  def start(agent_id) do
    case LocalAgentConfigs.get(agent_id) do
      nil -> {:error, :not_found}
      _config -> agent_id |> ensure_runner() |> Runner.start()
    end
  end

  def stop(agent_id) do
    case Runner.whereis(agent_id) do
      nil -> :ok
      pid -> Runner.stop(pid)
    end
  end

  def subscribe(agent_id), do: Phoenix.PubSub.subscribe(Synapsis.PubSub, "local_agent:#{agent_id}")
  def subscribe_all, do: Phoenix.PubSub.subscribe(Synapsis.PubSub, "local_agents")

  def list_threads(agent_id), do: request(agent_id, :list_threads, [])
  def start_thread(agent_id), do: request(agent_id, :start_thread, [])
  def read_thread(agent_id, thread_id), do: request(agent_id, :read_thread, [thread_id])
  def resume_thread(agent_id, thread_id), do: request(agent_id, :resume_thread, [thread_id])
  def start_turn(agent_id, thread_id, text), do: request(agent_id, :start_turn, [thread_id, text])

  def steer_turn(agent_id, thread_id, turn_id, text),
    do: request(agent_id, :steer_turn, [thread_id, turn_id, text])

  def interrupt_turn(agent_id, thread_id, turn_id),
    do: request(agent_id, :interrupt_turn, [thread_id, turn_id])

  defp request(agent_id, fun, args) do
    with pid when is_pid(pid) <- Runner.whereis(agent_id),
         {module, adapter} <- Runner.adapter_ref(pid) do
      # Adapters bound every call with their own timeout; an adapter that dies
      # mid-call must not take the caller (e.g. a LiveView) down with it.
      try do
        apply(module, fun, [adapter | args])
      catch
        :exit, reason -> {:error, {:adapter_exit, reason}}
      end
    else
      _ -> {:error, :not_running}
    end
  end

  defp ensure_runner(agent_id) do
    case DynamicSupervisor.start_child(SynapsisLocalAgents.RunnerSupervisor, {Runner, agent_id}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end
end
