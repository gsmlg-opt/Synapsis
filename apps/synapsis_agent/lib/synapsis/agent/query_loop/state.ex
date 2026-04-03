defmodule Synapsis.Agent.QueryLoop.State do
  @moduledoc """
  Mutable state for the query loop, carried across iterations.
  Messages are in Anthropic canonical format.
  """

  @type t :: %__MODULE__{
          messages: [map()],
          turn_count: non_neg_integer(),
          max_turns: non_neg_integer()
        }

  defstruct messages: [],
            turn_count: 0,
            max_turns: 50

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct!(__MODULE__, opts)
  end

  @spec increment_turn(t()) :: t()
  def increment_turn(%__MODULE__{} = state) do
    %{state | turn_count: state.turn_count + 1}
  end

  @spec append_messages(t(), [map()]) :: t()
  def append_messages(%__MODULE__{} = state, msgs) when is_list(msgs) do
    %{state | messages: state.messages ++ msgs}
  end

  @spec max_turns_reached?(t()) :: boolean()
  def max_turns_reached?(%__MODULE__{turn_count: tc, max_turns: mt}), do: tc >= mt
end
