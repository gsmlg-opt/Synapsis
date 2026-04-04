defmodule Synapsis.Agent.ResponseFlusherTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.Agent.{StreamAccumulator, ResponseFlusher}
  alias Synapsis.{Session, Message, Repo}

  setup do
    project =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{path: "/tmp/rf-test", slug: "rf-test", name: "rf-test"})
      |> Repo.insert!()

    session =
      %Session{}
      |> Session.changeset(%{
        project_id: project.id,
        provider: "anthropic",
        model: "claude-sonnet-4-20250514"
      })
      |> Repo.insert!()

    {:ok, session: session}
  end

  describe "build_parts/1" do
    test "builds parts from accumulated text" do
      acc = %{StreamAccumulator.new() | pending_text: "Hello world"}
      parts = ResponseFlusher.build_parts(acc)
      assert [%Synapsis.Part.Text{content: "Hello world"}] = parts
    end

    test "builds parts from accumulated reasoning + text" do
      acc = %{StreamAccumulator.new() | pending_reasoning: "thinking...", pending_text: "answer"}
      parts = ResponseFlusher.build_parts(acc)

      assert [
               %Synapsis.Part.Reasoning{content: "thinking..."},
               %Synapsis.Part.Text{content: "answer"}
             ] = parts
    end

    test "includes tool_uses" do
      tool_use = %Synapsis.Part.ToolUse{
        tool: "file_read",
        tool_use_id: "tu_1",
        input: %{"path" => "/foo"},
        status: :pending
      }

      acc = %{StreamAccumulator.new() | pending_text: "Let me read", tool_uses: [tool_use]}
      parts = ResponseFlusher.build_parts(acc)

      assert [%Synapsis.Part.Text{content: "Let me read"}, ^tool_use] = parts
    end

    test "handles empty text (no-op)" do
      acc = StreamAccumulator.new()
      assert ResponseFlusher.build_parts(acc) == []
    end
  end

  describe "flush/2" do
    test "creates assistant message with text part", %{session: session} do
      acc = %{StreamAccumulator.new() | pending_text: "Hello"}
      flushed = ResponseFlusher.flush(session.id, acc)

      # Verify message persisted
      messages = Repo.all(Message)
      assert [msg] = Enum.filter(messages, &(&1.role == "assistant"))
      assert [%Synapsis.Part.Text{content: "Hello"}] = msg.parts

      # Verify accumulator reset
      assert flushed.pending_text == ""
      assert flushed.pending_reasoning == ""
      assert flushed.pending_tool_use == nil
      assert flushed.pending_tool_input == ""
    end

    test "creates assistant message with reasoning part", %{session: session} do
      acc = %{StreamAccumulator.new() | pending_reasoning: "deep thought", pending_text: "42"}
      ResponseFlusher.flush(session.id, acc)

      messages = Repo.all(Message)
      msg = Enum.find(messages, &(&1.role == "assistant"))

      assert [
               %Synapsis.Part.Reasoning{content: "deep thought"},
               %Synapsis.Part.Text{content: "42"}
             ] = msg.parts
    end

    test "handles empty text (no-op)", %{session: session} do
      acc = StreamAccumulator.new()
      flushed = ResponseFlusher.flush(session.id, acc)

      messages = Repo.all(Message)
      assert Enum.filter(messages, &(&1.role == "assistant")) == []
      assert flushed == acc
    end
  end

  describe "flush_tool_result/4" do
    test "persists tool_result to DB", %{session: session} do
      ResponseFlusher.flush_tool_result(session.id, "tu_1", "file contents here", false)

      messages = Repo.all(Message)
      msg = Enum.find(messages, &(&1.role == "user"))

      assert [
               %Synapsis.Part.ToolResult{
                 tool_use_id: "tu_1",
                 content: "file contents here",
                 is_error: false
               }
             ] = msg.parts
    end

    test "persists error tool_result to DB", %{session: session} do
      ResponseFlusher.flush_tool_result(session.id, "tu_2", "File not found", true)

      messages = Repo.all(Message)
      msg = Enum.find(messages, &(&1.role == "user"))
      assert [%Synapsis.Part.ToolResult{tool_use_id: "tu_2", is_error: true}] = msg.parts
    end
  end
end
