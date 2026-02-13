defmodule Synapsis.Tool.Permissions do
  @moduledoc """
  Enhanced permission model with risk levels.

  Risk levels:
  - `:read` — read-only operations, auto-approved
  - `:write` — file modifications, requires approval by default
  - `:execute` — shell execution, requires approval by default
  - `:destructive` — irreversible operations, always requires approval
  """

  @type risk_level :: :read | :write | :execute | :destructive

  @read_tools ~w(file_read grep glob list_dir diagnostics)
  @write_tools ~w(file_write file_edit file_move fetch)
  @execute_tools ~w(bash)
  @destructive_tools ~w(file_delete)

  @doc "Returns the risk level for a tool."
  @spec level(String.t()) :: risk_level()
  def level(tool_name) when tool_name in @read_tools, do: :read
  def level(tool_name) when tool_name in @write_tools, do: :write
  def level(tool_name) when tool_name in @execute_tools, do: :execute
  def level(tool_name) when tool_name in @destructive_tools, do: :destructive

  def level(tool_name) do
    cond do
      String.starts_with?(to_string(tool_name), "mcp:") -> :write
      String.starts_with?(to_string(tool_name), "lsp_") -> :read
      true -> :write
    end
  end

  @doc "Check if a tool is allowed given a permission config."
  @spec allowed?(String.t(), map()) :: boolean()
  def allowed?(tool_name, %{auto_approve: levels}) do
    level(tool_name) in levels
  end

  def allowed?(_tool_name, _config), do: false

  @doc "Check permission, returning :approved or :requires_approval."
  @spec check(String.t(), term()) :: :approved | :requires_approval
  def check(tool_name, _session) do
    case level(tool_name) do
      :read -> :approved
      _ -> :requires_approval
    end
  end
end
