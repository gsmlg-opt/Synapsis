defmodule SynapsisLocalAgents.Event do
  @moduledoc """
  A local agent domain event, independent of any agent's wire format.

  Types: `:status` (`data: %{state, last_error}`), `:thread_started`,
  `:turn_started`, `:turn_completed` (`data.status` ∈ "completed" | "interrupted" | "failed",
  optional `data.error` message),
  `:item_started` / `:item_completed` (`data.item: %{type, text}`),
  `:item_delta` (`data.delta`), `:interaction` (`data: %{method, decision}`).
  """
  @enforce_keys [:type]
  defstruct [:agent_id, :type, :thread_id, :turn_id, :item_id, data: %{}]

  @type type ::
          :status | :thread_started | :turn_started | :turn_completed | :item_started
          | :item_delta | :item_completed | :interaction

  @type t :: %__MODULE__{
          agent_id: String.t() | nil,
          type: type,
          thread_id: String.t() | nil,
          turn_id: String.t() | nil,
          item_id: String.t() | nil,
          data: map()
        }
end
