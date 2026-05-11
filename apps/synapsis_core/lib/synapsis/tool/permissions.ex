defmodule Synapsis.Tool.Permissions do
  @moduledoc "Backward-compatible permission helpers for legacy callers."

  @default_auto_approve [:read]

  @read_tools ~w(
    diagnostics file_read glob grep list_dir lsp_definition lsp_diagnostics
    memory_search notebook_read session_summarize web_search
  )

  @write_tools ~w(
    fetch file_edit file_move file_write memory_save memory_update multi_edit notebook_edit
    workspace_delete workspace_write
  )

  @execute_tools ~w(bash computer)
  @destructive_tools ~w(file_delete)

  @doc "Return the legacy permission level for a tool name."
  @spec level(String.t()) :: :none | :read | :write | :execute | :destructive
  def level(tool_name) when is_binary(tool_name) do
    cond do
      tool_name in @read_tools -> :read
      tool_name in @write_tools -> :write
      tool_name in @execute_tools -> :execute
      tool_name in @destructive_tools -> :destructive
      String.starts_with?(tool_name, "lsp_") -> :read
      String.starts_with?(tool_name, "mcp:") -> :write
      registry_started?() -> Synapsis.Tool.Permission.tool_permission_level(tool_name)
      true -> :write
    end
  rescue
    _error -> fallback_level(tool_name)
  catch
    :exit, _reason -> fallback_level(tool_name)
  end

  @doc "Return whether the configured auto-approved levels allow a tool."
  @spec allowed?(String.t(), map()) :: boolean()
  def allowed?(tool_name, config) when is_map(config) do
    config
    |> Map.get(:auto_approve, Map.get(config, "auto_approve", []))
    |> normalize_levels()
    |> MapSet.member?(level(tool_name))
  end

  def allowed?(_tool_name, _config), do: false

  @doc "Legacy 2-arity permission check returning `:approved` when auto-approved."
  @spec check(String.t(), map() | nil) :: :approved | :requires_approval
  def check(tool_name, session) do
    levels =
      @default_auto_approve
      |> MapSet.new()
      |> MapSet.union(session_auto_approve(session))

    if MapSet.member?(levels, level(tool_name)) do
      :approved
    else
      :requires_approval
    end
  end

  defp registry_started? do
    Process.whereis(Synapsis.Tool.Registry) != nil
  end

  defp fallback_level(tool_name) when tool_name in @read_tools, do: :read
  defp fallback_level(tool_name) when tool_name in @write_tools, do: :write
  defp fallback_level(tool_name) when tool_name in @execute_tools, do: :execute
  defp fallback_level(tool_name) when tool_name in @destructive_tools, do: :destructive

  defp fallback_level("lsp_" <> _rest), do: :read
  defp fallback_level("mcp:" <> _rest), do: :write
  defp fallback_level(_tool_name), do: :write

  defp session_auto_approve(%{config: config}) when is_map(config) do
    config
    |> get_in(["permissions", "autoApprove"])
    |> normalize_levels()
  end

  defp session_auto_approve(_session), do: MapSet.new()

  defp normalize_levels(levels) when is_list(levels) do
    levels
    |> Enum.map(&normalize_level/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp normalize_levels(_levels), do: MapSet.new()

  defp normalize_level(level) when is_atom(level), do: level

  defp normalize_level(level) when is_binary(level) do
    case level do
      "none" -> :none
      "read" -> :read
      "write" -> :write
      "execute" -> :execute
      "destructive" -> :destructive
      _ -> nil
    end
  end

  defp normalize_level(_level), do: nil
end
