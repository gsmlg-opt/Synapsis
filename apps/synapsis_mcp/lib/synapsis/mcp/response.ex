defmodule Synapsis.MCP.Response do
  @moduledoc "Normalizes MCP result maps into Synapsis tool shapes."

  @doc "Map a tools/list result map to Synapsis.Tool.Registry tool definitions."
  def tools(result, server_name, opts \\ []) when is_map(result) and is_list(opts) do
    trust_annotations? = Keyword.get(opts, :trust_annotations, false) == true

    (result["tools"] || [])
    |> Enum.map(fn t ->
      annotations = t["annotations"]

      %{
        name: "mcp:#{server_name}:#{t["name"]}",
        description: t["description"] || "",
        parameters: t["inputSchema"] || %{},
        annotations: annotations,
        trust_annotations: trust_annotations?,
        permission_level: permission_level(annotations, trust_annotations?)
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

  defp permission_level(%{"readOnlyHint" => true} = annotations, true) do
    if annotations["destructiveHint"] == true, do: :write, else: :read
  end

  defp permission_level(_annotations, _trust_annotations?), do: :write
end
