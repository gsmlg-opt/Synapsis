defmodule Synapsis.Agent.ResponseFlusherTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.ResponseFlusher
  alias Synapsis.Message
  alias Synapsis.Part.{Text, ToolResult, ToolUse}

  @placeholder "Tool use did not complete before the next turn."

  defp new_session_id, do: Ecto.UUID.generate()

  defp tool_use(id) do
    %ToolUse{tool: "web_fetch", tool_use_id: id, input: %{"url" => id}, status: :pending}
  end

  defp tool_result(id, content, is_error \\ false) do
    %ToolResult{tool_use_id: id, content: content, is_error: is_error}
  end

  defp persist(session_id, messages) do
    messages =
      Enum.map(messages, fn {role, parts} ->
        %Message{
          id: Ecto.UUID.generate(),
          session_id: session_id,
          role: role,
          parts: parts,
          token_count: 0,
          inserted_at: DateTime.utc_now()
        }
      end)

    :ok = Message.persist_list(session_id, messages)
  end

  defp results_by_id(session_id) do
    session_id
    |> Message.list_by_session()
    |> Enum.flat_map(& &1.parts)
    |> Enum.filter(&match?(%ToolResult{}, &1))
    |> Enum.group_by(& &1.tool_use_id)
  end

  describe "ensure_tool_results/3 with results scattered across user messages" do
    test "does not inject a placeholder when the result lives in a later message" do
      session_id = new_session_id()

      persist(session_id, [
        {"user", [%Text{content: "go"}]},
        {"assistant", [tool_use("call_A"), tool_use("call_B")]},
        {"user", [tool_result("call_B", "result B")]},
        {"user", [tool_result("call_A", "result A")]}
      ])

      assert {:ok, 0} = ResponseFlusher.ensure_tool_results(session_id, @placeholder, true)

      results = results_by_id(session_id)
      assert [%ToolResult{content: "result A", is_error: false}] = results["call_A"]
      assert [%ToolResult{content: "result B", is_error: false}] = results["call_B"]
    end

    test "consolidates scattered results into the message adjacent to the assistant" do
      session_id = new_session_id()

      persist(session_id, [
        {"assistant", [tool_use("call_A"), tool_use("call_B")]},
        {"user", [tool_result("call_B", "result B")]},
        {"user", [tool_result("call_A", "result A")]}
      ])

      {:ok, _} = ResponseFlusher.ensure_tool_results(session_id, @placeholder, true)

      [assistant | rest] = Message.list_by_session(session_id)
      assert assistant.role == "assistant"

      # The adjacent user message answers both calls in assistant order.
      adjacent = hd(rest)
      assert adjacent.role == "user"

      adjacent_ids =
        adjacent.parts |> Enum.filter(&match?(%ToolResult{}, &1)) |> Enum.map(& &1.tool_use_id)

      assert adjacent_ids == ["call_A", "call_B"]

      # No duplicate answers anywhere else.
      assert map_size(results_by_id(session_id)) == 2
      assert Enum.all?(results_by_id(session_id), fn {_id, rs} -> length(rs) == 1 end)
    end

    test "heals an already-poisoned transcript (placeholder + late real result)" do
      session_id = new_session_id()

      # The exact arrangement produced by the bug in production.
      persist(session_id, [
        {"assistant", [tool_use("call_A"), tool_use("call_B")]},
        {"user", [tool_result("call_A", @placeholder, true), tool_result("call_B", "result B")]},
        {"user", [tool_result("call_A", "real result A")]}
      ])

      {:ok, _} = ResponseFlusher.ensure_tool_results(session_id, @placeholder, true)

      results = results_by_id(session_id)
      # One result per id; the real (later) result wins over the placeholder.
      assert [%ToolResult{content: "real result A"}] = results["call_A"]
      assert [%ToolResult{content: "result B"}] = results["call_B"]
    end

    test "still backfills placeholders for genuinely unanswered tool uses" do
      session_id = new_session_id()

      persist(session_id, [
        {"assistant", [tool_use("call_A"), tool_use("call_B")]},
        {"user", [tool_result("call_B", "result B")]}
      ])

      assert {:ok, 1} = ResponseFlusher.ensure_tool_results(session_id, @placeholder, true)

      results = results_by_id(session_id)
      assert [%ToolResult{content: @placeholder, is_error: true}] = results["call_A"]
      assert [%ToolResult{content: "result B"}] = results["call_B"]
    end

    test "keeps user text following the tool results" do
      session_id = new_session_id()

      persist(session_id, [
        {"assistant", [tool_use("call_A")]},
        {"user", [tool_result("call_A", "result A"), %Text{content: "and also..."}]}
      ])

      assert {:ok, 0} = ResponseFlusher.ensure_tool_results(session_id, @placeholder, true)

      [_, user] = Message.list_by_session(session_id)
      assert [%ToolResult{}, %Text{content: "and also..."}] = user.parts
    end
  end

  describe "flush_tool_result/4 adjacency" do
    test "appends staggered results into one user message after the assistant" do
      session_id = new_session_id()

      persist(session_id, [
        {"assistant", [tool_use("call_A"), tool_use("call_B")]}
      ])

      :ok = ResponseFlusher.flush_tool_result(session_id, "call_B", "result B", false)
      :ok = ResponseFlusher.flush_tool_result(session_id, "call_A", "result A", false)

      messages = Message.list_by_session(session_id)
      assert length(messages) == 2, "both results must land in one adjacent user message"

      [_assistant, user] = messages
      ids = user.parts |> Enum.filter(&match?(%ToolResult{}, &1)) |> Enum.map(& &1.tool_use_id)
      assert Enum.sort(ids) == ["call_A", "call_B"]
    end

    test "second flush for the same id is a no-op (dedupe guard)" do
      session_id = new_session_id()

      persist(session_id, [{"assistant", [tool_use("call_A")]}])

      :ok = ResponseFlusher.flush_tool_result(session_id, "call_A", "first", false)
      :ok = ResponseFlusher.flush_tool_result(session_id, "call_A", "second", false)

      assert [%ToolResult{content: "first"}] = results_by_id(session_id)["call_A"]
    end
  end
end
