defmodule Synapsis.Tool.Permission do
  @moduledoc """
  Tool permission checking - delegates to Synapsis.Tool.Permissions for risk-level-based checks.
  """

  @doc "Check if a tool requires approval."
  def check(tool_name, session) do
    Synapsis.Tool.Permissions.check(tool_name, session)
  end
end
