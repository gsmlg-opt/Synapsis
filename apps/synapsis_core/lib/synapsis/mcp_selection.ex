defmodule Synapsis.MCPSelection do
  @moduledoc "MCP display, refresh and legacy saved-selection compatibility helpers for the UI."

  @doc "Read source-owned metadata for display; never use it to resolve executable tools."
  def display_catalog do
    case Application.get_env(:synapsis_core, :mcp_source_catalog) do
      {module, function, args} -> Kernel.apply(module, function, args)
      nil -> []
    end
  catch
    _kind, _reason -> []
  end

  def from_legacy(tool_names, sources) do
    selections =
      Map.new(sources, fn source ->
        prefix = "mcp:" <> source.name <> ":"

        tools =
          tool_names
          |> Enum.filter(&String.starts_with?(&1, prefix))
          |> Enum.map(&String.replace_prefix(&1, prefix, ""))
          |> Enum.uniq()
          |> Enum.sort()

        {source.id, %{"mode" => "selected", "tools" => tools}}
      end)
      |> Map.reject(fn {_id, rule} -> rule["tools"] == [] end)

    %{"default" => "selected", "sources" => selections}
  end

  @doc "Run only from supervised turn preparation or an asynchronous UI action."
  def refresh do
    case Application.get_env(:synapsis_core, :mcp_refresh) do
      {module, function, args} -> Kernel.apply(module, function, args)
      nil -> %{}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  def mcp_name?("mcp:" <> _name), do: true
  def mcp_name?(_name), do: false
end
