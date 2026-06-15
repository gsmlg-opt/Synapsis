defmodule Synapsis.MCP.ResponseTest do
  use ExUnit.Case, async: true

  alias Synapsis.MCP.Response

  test "tools/2 maps a tools result to registry tool maps" do
    result = %{
      "tools" => [
        %{"name" => "search", "description" => "find", "inputSchema" => %{"type" => "object"}}
      ]
    }

    assert [tool] = Response.tools(result, "ctx7")
    assert tool.name == "mcp:ctx7:search"
    assert tool.description == "find"
    assert tool.parameters == %{"type" => "object"}
  end

  test "content/1 joins text content blocks" do
    result = %{
      "content" => [%{"type" => "text", "text" => "a"}, %{"type" => "text", "text" => "b"}]
    }

    assert Response.content(result) == "a\nb"
  end

  test "content/1 handles missing content" do
    assert Response.content(%{}) == "[no content in MCP response]"
  end

  test "raw_tool_name/1 strips the mcp:<server>: prefix" do
    assert Response.raw_tool_name("mcp:ctx7:search") == "search"
    assert Response.raw_tool_name("plain") == "plain"
  end
end
