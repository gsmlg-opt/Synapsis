defmodule SynapsisLocalAgents.Adapter do
  @moduledoc """
  Contract between the local agent runtime and one kind of agent (Codex today).

  An adapter is a process started by `SynapsisLocalAgents.Runner` with the Runner
  as `owner`. It sends `{:local_agent_event, %SynapsisLocalAgents.Event{}}` to the
  owner — including `type: :status, data: %{state: :running}` once ready — and
  exits non-normally if the agent dies. Vocabulary follows samgita_protocol
  `sessions.v1` / `streaming.v1` (thread, turn, item).
  """

  alias Synapsis.LocalAgentConfig

  @type thread_summary :: %{id: String.t(), title: String.t() | nil, updated_at: String.t() | nil}
  @type item :: %{id: String.t(), role: :user | :agent, text: String.t()}
  @type thread :: %{id: String.t(), turns: [%{id: String.t(), status: String.t(), items: [item]}]}

  @callback start_link(LocalAgentConfig.t(), owner :: pid()) :: GenServer.on_start()
  @callback list_threads(pid()) :: {:ok, [thread_summary]} | {:error, term()}
  @callback start_thread(pid()) :: {:ok, %{id: String.t()}} | {:error, term()}
  @callback read_thread(pid(), String.t()) :: {:ok, thread} | {:error, term()}
  @callback resume_thread(pid(), String.t()) :: {:ok, %{id: String.t()}} | {:error, term()}
  @callback start_turn(pid(), String.t(), String.t()) :: {:ok, %{turn_id: String.t()}} | {:error, term()}
  @callback steer_turn(pid(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback interrupt_turn(pid(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback stop(pid()) :: :ok

  @doc "Adapter module for a config kind."
  def module_for(kind) do
    :synapsis_local_agents
    |> Application.get_env(:adapters, %{"codex" => SynapsisLocalAgents.Codex})
    |> Map.fetch(kind)
  end
end
