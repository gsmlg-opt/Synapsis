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

  test "tools/3 trusts explicit non-destructive read annotations only when locally authorized" do
    tools = [
      %{
        "name" => "read_notes",
        "annotations" => %{
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "openWorldHint" => true
        }
      },
      %{
        "name" => "delete_note",
        "annotations" => %{"readOnlyHint" => true, "destructiveHint" => true}
      },
      %{"name" => "unannotated"}
    ]

    assert [untrusted_read, _destructive, _unannotated] =
             Response.tools(%{"tools" => tools}, "notes")

    assert untrusted_read.annotations == hd(tools)["annotations"]
    assert untrusted_read.permission_level == :write

    assert [read, destructive, unannotated] =
             Response.tools(%{"tools" => tools}, "notes", trust_annotations: true)

    assert read.annotations == hd(tools)["annotations"]
    assert read.permission_level == :read
    assert destructive.annotations == Enum.at(tools, 1)["annotations"]
    assert destructive.permission_level == :write
    assert unannotated.annotations == nil
    assert unannotated.permission_level == :write
  end

  test "tools/2 preserves JSON Schema type arrays" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "label" => %{"type" => ["string", "null"], "description" => "optional label"}
      }
    }

    result = %{
      "tools" => [
        %{"name" => "list_notes", "description" => "List notes", "inputSchema" => schema}
      ]
    }

    assert [tool] = Response.tools(result, "agent-note")
    assert tool.parameters["properties"]["label"]["type"] == ["string", "null"]
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
