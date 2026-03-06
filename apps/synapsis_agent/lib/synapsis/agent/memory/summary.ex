defmodule Synapsis.Agent.Memory.Summary do
  @moduledoc """
  Compressed memory entry for task/project/global summaries.
  """

  @enforce_keys [:scope, :scope_id, :kind, :content, :updated_at]
  defstruct [:scope, :scope_id, :kind, :content, :metadata, :updated_at]

  @type scope :: :global | :project | :task

  @type t :: %__MODULE__{
          scope: scope(),
          scope_id: String.t(),
          kind: atom(),
          content: String.t(),
          metadata: map(),
          updated_at: DateTime.t()
        }
end
