defmodule Synapsis.Tool.Context do
  @moduledoc """
  Structured context passed to tool `execute/2` callbacks.

  Provides session metadata, project paths, permissions, and agent
  orchestration info needed during tool execution.
  """

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          project_path: String.t() | nil,
          working_dir: String.t() | nil,
          permissions: map(),
          session_pid: pid() | nil,
          agent_mode: :build | :plan,
          parent_agent: pid() | nil
        }

  defstruct session_id: nil,
            project_path: nil,
            working_dir: nil,
            permissions: %{},
            session_pid: nil,
            agent_mode: :build,
            parent_agent: nil

  @doc "Create a new context from a keyword list or map."
  @spec new(keyword() | map()) :: t()
  def new(attrs \\ [])

  def new(attrs) when is_list(attrs) do
    struct(__MODULE__, attrs)
  end

  def new(attrs) when is_map(attrs) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Derive a sub-agent context from a parent context.

  Sets `parent_agent` to the given pid and inherits project/session info.
  """
  @spec sub_agent_context(t(), pid()) :: t()
  def sub_agent_context(%__MODULE__{} = ctx, parent_pid) when is_pid(parent_pid) do
    %{ctx | parent_agent: parent_pid}
  end

  @doc "Convert to a plain map for backward compatibility with map-based contexts."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = ctx) do
    ctx
    |> Map.from_struct()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
