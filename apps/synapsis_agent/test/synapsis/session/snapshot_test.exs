defmodule Synapsis.Session.SnapshotTest do
  @moduledoc "ADR-006 B1: per-turn snapshot encoding + rehydrate roundtrip."
  use ExUnit.Case, async: false

  alias Synapsis.Session.{Snapshot, Store}

  setup do
    assert Store.ensure_started() == :ok
    {:ok, id: "snap-" <> Integer.to_string(System.unique_integer([:positive]))}
  end

  describe "rehydrate/1" do
    test "returns meta + ordered turns from the store", %{id: id} do
      meta = %{status: "idle", turn_count: 2}
      assert Store.commit_turn(id, 0, %{role: "user", parts: []}, meta) == :ok
      assert Store.commit_turn(id, 1, %{role: "assistant", parts: []}, meta) == :ok

      assert {:ok, %{meta: ^meta, turns: [%{role: "user"}, %{role: "assistant"}]}} =
               Snapshot.rehydrate(id)
    end

    test "is :no_snapshot for an unknown session", %{id: id} do
      assert {:error, :no_snapshot} = Snapshot.rehydrate(id)
    end
  end

  describe "encode_message/1" do
    test "encodes parts to JSON-friendly maps" do
      message = %Synapsis.Message{
        role: "assistant",
        token_count: 5,
        parts: [
          %Synapsis.Part.Text{content: "hi"},
          %Synapsis.Part.ToolUse{tool: "bash", tool_use_id: "t1", input: %{"cmd" => "ls"}},
          %Synapsis.Part.ToolResult{tool_use_id: "t1", content: "out", is_error: false}
        ]
      }

      assert %{
               role: "assistant",
               token_count: 5,
               parts: [
                 %{type: "text", text: "hi"},
                 %{type: "tool_use", id: "t1", name: "bash", input: %{"cmd" => "ls"}},
                 %{type: "tool_result", tool_use_id: "t1", content: "out", is_error: false}
               ]
             } = Snapshot.encode_message(message)
    end
  end

  describe "build_meta/2" do
    test "captures the durable session fields" do
      session = %Synapsis.Session{
        status: "idle",
        agent: "main",
        provider: "anthropic",
        model: "claude-sonnet-4-5",
        title: "demo"
      }

      assert %{
               status: "idle",
               agent: "main",
               provider: "anthropic",
               model: "claude-sonnet-4-5",
               title: "demo",
               turn_count: 3
             } = Snapshot.build_meta(session, 3)
    end
  end
end
