defmodule Synapsis.Agent.Graphs.ConversationalLoop do
  @moduledoc """
  Graph definition for the conversational assistant loop.

  Runs the persistent assistant conversation:

      receive_message → compact_context → build_prompt → reason → act → respond
                ↑                                                        │
                └────────────────────────── loop ───────────────────────┘

  Key differences from CodingLoop:
  - `act` is an intent router, not a tool dispatcher.
  - The loop is persistent — `respond` returns to `receive_message` rather
    than terminating the graph.
  - `reason` streams the full conversational LLM response (like `llm_stream`),
    and `act` decides whether to respond directly, delegate, or spawn a
    Code Agent (Phase 3+).

  Error path from `reason` routes to `respond` so the loop continues even
  when the LLM call fails — the error is already logged upstream.
  """

  alias Synapsis.Agent.Runtime.Graph
  alias Synapsis.Agent.Nodes

  @spec build() :: {:ok, Graph.t()} | {:error, term()}
  def build do
    Graph.new(%{
      nodes: %{
        receive: Nodes.ReceiveMessage,
        compact_context: Nodes.CompactContext,
        build_prompt: Nodes.BuildPrompt,
        reason: Nodes.Reason,
        act: Nodes.Act,
        respond: Nodes.Respond
      },
      edges: %{
        receive: :compact_context,
        compact_context: :build_prompt,
        build_prompt: :reason,
        reason: %{default: :act, error: :respond},
        act: %{respond: :respond},
        respond: %{loop: :receive}
      },
      start: :receive
    })
  end

  @doc "Returns a fresh workflow state for a new conversational loop run."
  @spec initial_state(map()) :: map()
  def initial_state(opts) do
    %{
      session_id: opts[:session_id],
      messages: [],
      pending_text: "",
      pending_tool_use: nil,
      pending_tool_input: "",
      pending_reasoning: "",
      tool_uses: [],
      monitor: Synapsis.Session.Monitor.new(),
      iteration_count: 0,
      provider_config: opts[:provider_config] || %{},
      agent_config: opts[:agent_config] || %{},
      worktree_path: opts[:worktree_path],
      decision: nil,
      tool_call_hashes: MapSet.new(),
      user_input: nil,
      approval_decisions: %{}
    }
  end
end
