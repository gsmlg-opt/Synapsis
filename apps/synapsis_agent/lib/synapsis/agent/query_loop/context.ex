defmodule Synapsis.Agent.QueryLoop.Context do
  @moduledoc """
  Immutable context for a single query loop invocation.
  Equivalent to CCB's ToolUseContext + QueryParams.
  """

  @type t :: %__MODULE__{
          session_id: String.t(),
          system_prompt: String.t() | :dynamic,
          tools: [map()],
          model: String.t(),
          provider_config: map(),
          subscriber: pid(),
          abort_ref: reference() | nil,
          project_path: String.t() | nil,
          working_dir: String.t() | nil,
          depth: non_neg_integer(),
          streaming_tools_enabled: boolean(),
          agent_config: map()
        }

  @enforce_keys [:session_id, :system_prompt, :tools, :model, :provider_config, :subscriber]
  defstruct [
    :session_id,
    :system_prompt,
    :tools,
    :model,
    :provider_config,
    :subscriber,
    abort_ref: nil,
    project_path: nil,
    working_dir: nil,
    depth: 0,
    streaming_tools_enabled: true,
    agent_config: %{}
  ]

  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)
end
