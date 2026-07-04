defmodule Synapsis.MCP.Response do
  @moduledoc "Normalizes MCP result maps into Synapsis tool shapes."

  @doc "Map a tools/list result map to Synapsis.Tool.Registry tool definitions."
  def tools(result, server_name) when is_map(result) do
    (result["tools"] || [])
    |> Enum.map(fn t ->
      %{
        name: "mcp:#{server_name}:#{t["name"]}",
        description: t["description"] || "",
        parameters: t["inputSchema"] || %{}
      }
    end)
  end

  @doc "Extract text content from a tools/call result map."
  def content(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      %{"type" => type} -> "[unsupported content type: #{type}]"
      _ -> "[unsupported content format]"
    end)
    |> Enum.join("\n")
  end

  def content(%{"content" => content}) when is_binary(content), do: content
  def content(_), do: "[no content in MCP response]"

  @doc "Strip the `mcp:<server>:` prefix to recover the raw MCP tool name."
  def raw_tool_name(full_name) do
    case String.split(full_name, ":", parts: 3) do
      [_mcp, _server, name] -> name
      _ -> full_name
    end
  end
end
