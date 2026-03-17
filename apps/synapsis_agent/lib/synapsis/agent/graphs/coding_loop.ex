defmodule Synapsis.Agent.Graphs.CodingLoop do
  @moduledoc """
  Graph definition for the main coding agent loop.
  Replaces Session.Worker's internal state machine with a graph-based execution model.
  """

  alias Synapsis.Agent.Runtime.Graph
  alias Synapsis.Agent.Nodes

  @spec build() :: {:ok, Graph.t()} | {:error, term()}
  def build do
    Graph.new(%{
      nodes: %{
        receive: Nodes.ReceiveMessage,
        build_prompt: Nodes.BuildPrompt,
        llm_stream: Nodes.LLMStream,
        process_response: Nodes.ProcessResponse,
        tool_dispatch: Nodes.ToolDispatch,
        approval_gate: Nodes.ApprovalGate,
        tool_execute: Nodes.ToolExecute,
        orchestrate: Nodes.Orchestrate,
        escalate: Nodes.Escalate,
        complete: Nodes.Complete
      },
      edges: %{
        receive: :build_prompt,
        build_prompt: :llm_stream,
        llm_stream: :process_response,
        process_response: %{has_tools: :tool_dispatch, no_tools: :complete},
        tool_dispatch: %{all_approved: :tool_execute, needs_approval: :approval_gate},
        approval_gate: %{approved: :tool_execute, denied: :build_prompt},
        tool_execute: :orchestrate,
        orchestrate: %{
          continue: :build_prompt,
          pause: :receive,
          escalate: :escalate,
          terminate: :complete
        },
        escalate: :build_prompt,
        complete: :end
      },
      start: :receive
    })
  end

  @doc "Returns a fresh workflow state for a new coding loop run."
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
