defmodule Synapsis.Memory.WorkingMemory do
  @moduledoc """
  Layer A: In-process working memory for the current session.

  Accumulates context during an agent loop iteration — recent messages,
  tool results, temporary notes, and the current plan. This struct lives
  in the Session.Worker process and is never persisted directly. It is
  the raw material from which checkpoints and semantic memory are derived.
  """

  @type t :: %__MODULE__{
          run_id: String.t() | nil,
          session_id: String.t(),
          agent_id: String.t(),
          current_goal: String.t() | nil,
          recent_messages: [map()],
          tool_results: [map()],
          temporary_notes: [String.t()],
          current_plan: String.t() | nil,
          iteration: non_neg_integer(),
          token_estimate: non_neg_integer()
        }

  defstruct run_id: nil,
            session_id: "",
            agent_id: "default",
            current_goal: nil,
            recent_messages: [],
            tool_results: [],
            temporary_notes: [],
            current_plan: nil,
            iteration: 0,
            token_estimate: 0

  @doc """
  Creates a new WorkingMemory for a session.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end

  @doc """
  Records a user message as the current goal.
  """
  @spec set_goal(t(), String.t()) :: t()
  def set_goal(%__MODULE__{} = wm, goal) do
    %{wm | current_goal: goal}
  end

  @doc """
  Appends a message to recent history, keeping the last `limit` messages.
  """
  @spec push_message(t(), map(), non_neg_integer()) :: t()
  def push_message(%__MODULE__{} = wm, message, limit \\ 50) do
    messages = Enum.take([message | wm.recent_messages], limit)
    %{wm | recent_messages: messages}
  end

  @doc """
  Records a tool result from the current iteration.
  """
  @max_tool_results 100

  @spec push_tool_result(t(), map()) :: t()
  def push_tool_result(%__MODULE__{} = wm, result) do
    results = Enum.take([result | wm.tool_results], @max_tool_results)
    %{wm | tool_results: results}
  end

  @doc """
  Adds a temporary note (ephemeral insight for current iteration).
  """
  @max_notes 50

  @spec add_note(t(), String.t()) :: t()
  def add_note(%__MODULE__{} = wm, note) do
    notes = Enum.take([note | wm.temporary_notes], @max_notes)
    %{wm | temporary_notes: notes}
  end

  @doc """
  Increments the iteration counter.
  """
  @spec next_iteration(t()) :: t()
  def next_iteration(%__MODULE__{} = wm) do
    %{wm | iteration: wm.iteration + 1, tool_results: []}
  end

  @doc """
  Resets working memory for a new run while preserving session identity.
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = wm) do
    %{
      wm
      | current_goal: nil,
        recent_messages: [],
        tool_results: [],
        temporary_notes: [],
        current_plan: nil,
        iteration: 0,
        token_estimate: 0
    }
  end

  @doc """
  Estimates token count for the current working memory contents.
  Rough heuristic: ~4 chars per token.
  """
  @spec estimate_tokens(t()) :: t()
  def estimate_tokens(%__MODULE__{} = wm) do
    text_size =
      (wm.current_goal || "") <>
        Enum.join(Enum.map(wm.recent_messages, &inspect/1), " ") <>
        Enum.join(Enum.map(wm.tool_results, &inspect/1), " ") <>
        Enum.join(wm.temporary_notes, " ") <>
        (wm.current_plan || "")

    %{wm | token_estimate: div(byte_size(text_size), 4)}
  end

  @doc """
  Serializes working memory state for checkpoint persistence.
  """
  @spec to_checkpoint_state(t()) :: map()
  def to_checkpoint_state(%__MODULE__{} = wm) do
    %{
      run_id: wm.run_id,
      session_id: wm.session_id,
      agent_id: wm.agent_id,
      current_goal: wm.current_goal,
      current_plan: wm.current_plan,
      iteration: wm.iteration,
      token_estimate: wm.token_estimate,
      note_count: length(wm.temporary_notes),
      message_count: length(wm.recent_messages)
    }
  end
end
