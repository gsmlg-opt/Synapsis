defmodule Synapsis.Harness.Loop.ADTTest do
  use ExUnit.Case, async: true

  alias Synapsis.Harness.ProviderEvent
  alias Synapsis.Harness.Loop
  alias Synapsis.Harness.Loop.{Broadcast, Effect, Input}

  describe "input structs" do
    test "model reducer boundaries with explicit variants" do
      assert %Input.UserPrompt{message_id: "m1", parts: []}
      assert %Input.ProviderEvent{event: %ProviderEvent.Done{}}
      assert %Input.ToolCompleted{part_id: "tool-1", result: %{ok: true}}
      assert %Input.PermissionDenied{request_id: "perm-1"}
      assert %Input.BudgetTick{wall_clock_now: ~U[2026-05-12 00:00:00Z]}
    end
  end

  describe "effect and broadcast structs" do
    test "separate durable events from external side effects and UI broadcasts" do
      assert %Effect.StartProviderStream{request: %{model: "test"}}
      assert %Effect.CancelProviderStream{}
      assert %Effect.StartTool{part_id: "tool-1", tool_name: "read_file", args: %{}}

      assert %Effect.RequestPermission{
        request_id: "perm-1",
        tool_call: %{name: "write_file"},
        effect_class: :write
      }

      assert %Broadcast.TextDelta{part_id: "p1", fragment: "hello"}
      assert %Broadcast.ReasoningDelta{part_id: "p2", fragment: "because"}
      assert %Broadcast.ToolArgsDelta{part_id: "tool-1", fragment: "{\"path\""}
      assert %Broadcast.StatusChanged{status: :generating}
    end
  end

  test "next actions are plain command decisions" do
    assert Loop.NextAction.await_user() == :await_user
    assert Loop.NextAction.await_provider() == :await_provider
    assert Loop.NextAction.await_tools() == :await_tools
    assert Loop.NextAction.await_permission() == :await_permission
    assert Loop.NextAction.halt(:aborted) == {:halt, :aborted}
  end
end
