defmodule Synapsis.PartTest do
  use ExUnit.Case, async: true

  alias Synapsis.Part

  describe "round-trip serialization" do
    test "TextPart" do
      part = %Part.Text{content: "hello world"}
      assert {:ok, dumped} = Part.dump(part)
      assert %{"type" => "text", "content" => "hello world"} = dumped
      assert {:ok, loaded} = Part.load(dumped)
      assert %Part.Text{content: "hello world"} = loaded
    end

    test "ToolUsePart" do
      part = %Part.ToolUse{
        tool: "file_read",
        tool_use_id: "toolu_123",
        input: %{"path" => "/tmp/test.txt"},
        status: :approved
      }

      assert {:ok, dumped} = Part.dump(part)
      assert %{"type" => "tool_use", "tool" => "file_read", "status" => "approved"} = dumped
      assert {:ok, loaded} = Part.load(dumped)
      assert %Part.ToolUse{tool: "file_read", status: :approved} = loaded
    end

    test "ToolResultPart" do
      part = %Part.ToolResult{
        tool_use_id: "toolu_123",
        content: "file contents here",
        is_error: false
      }

      assert {:ok, dumped} = Part.dump(part)
      assert {:ok, loaded} = Part.load(dumped)
      assert %Part.ToolResult{tool_use_id: "toolu_123", content: "file contents here"} = loaded
    end

    test "ReasoningPart" do
      part = %Part.Reasoning{content: "thinking..."}
      assert {:ok, dumped} = Part.dump(part)
      assert {:ok, loaded} = Part.load(dumped)
      assert %Part.Reasoning{content: "thinking..."} = loaded
    end

    test "FilePart" do
      part = %Part.File{path: "/tmp/test.ex", content: "defmodule Test do\nend"}
      assert {:ok, dumped} = Part.dump(part)
      assert {:ok, loaded} = Part.load(dumped)
      assert %Part.File{path: "/tmp/test.ex"} = loaded
    end

    test "SnapshotPart" do
      part = %Part.Snapshot{files: [%{"path" => "/tmp/a.ex", "hash" => "abc123"}]}
      assert {:ok, dumped} = Part.dump(part)
      assert {:ok, loaded} = Part.load(dumped)
      assert %Part.Snapshot{files: [%{"path" => "/tmp/a.ex"}]} = loaded
    end

    test "AgentPart" do
      part = %Part.Agent{agent: "build", message: "Switching to build mode"}
      assert {:ok, dumped} = Part.dump(part)
      assert {:ok, loaded} = Part.load(dumped)
      assert %Part.Agent{agent: "build"} = loaded
    end
  end

  describe "cast" do
    test "casts from string-keyed map" do
      assert {:ok, %Part.Text{content: "hi"}} =
               Part.cast(%{"type" => "text", "content" => "hi"})
    end

    test "casts from atom-keyed map" do
      assert {:ok, %Part.Text{content: "hi"}} =
               Part.cast(%{type: "text", content: "hi"})
    end

    test "casts from struct" do
      part = %Part.Text{content: "hi"}
      assert {:ok, ^part} = Part.cast(part)
    end
  end
end
