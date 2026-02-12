defmodule Synapsis.Tool.Permission do
  @moduledoc "Tool permission checking - auto-approve vs require user approval."

  @auto_approve ~w(file_read grep glob diagnostics)
  @always_ask ~w(bash file_edit file_write fetch)

  def check(tool_name, _session) when tool_name in @auto_approve, do: :approved
  def check(tool_name, _session) when tool_name in @always_ask, do: :requires_approval

  def check(tool_name, _session) do
    if String.starts_with?(to_string(tool_name), "mcp:") do
      :requires_approval
    else
      :requires_approval
    end
  end
end
