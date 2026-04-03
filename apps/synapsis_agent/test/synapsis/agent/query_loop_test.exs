defmodule Synapsis.Agent.QueryLoopTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.QueryLoop.State
  alias Synapsis.Agent.QueryLoop.Context

  describe "State.new/1" do
    test "creates state with defaults" do
      state = State.new()
      assert state.messages == []
      assert state.turn_count == 0
      assert state.max_turns == 50
    end

    test "creates state with custom max_turns" do
      state = State.new(max_turns: 10)
      assert state.max_turns == 10
    end

    test "creates state with initial messages" do
      msgs = [%{role: "user", content: "hello"}]
      state = State.new(messages: msgs)
      assert state.messages == msgs
    end
  end

  describe "State.increment_turn/1" do
    test "increments turn_count" do
      state = State.new() |> State.increment_turn()
      assert state.turn_count == 1
    end
  end

  describe "State.append_messages/2" do
    test "appends messages to state" do
      state = State.new(messages: [%{role: "user", content: "hi"}])
      new_msgs = [%{role: "assistant", content: [%{type: "text", text: "hello"}]}]
      state = State.append_messages(state, new_msgs)
      assert length(state.messages) == 2
    end
  end

  describe "State.max_turns_reached?/1" do
    test "returns false when under limit" do
      assert State.new(max_turns: 50) |> State.max_turns_reached?() == false
    end

    test "returns true when at limit" do
      state = %{State.new(max_turns: 1) | turn_count: 1}
      assert State.max_turns_reached?(state) == true
    end
  end

  describe "Context.new/1" do
    test "creates context with required fields" do
      ctx = Context.new(
        session_id: "sess_1",
        system_prompt: "You are helpful.",
        tools: [],
        model: "claude-sonnet-4-5-20250514",
        provider_config: %{type: "anthropic", api_key: "test"},
        subscriber: self()
      )

      assert ctx.session_id == "sess_1"
      assert ctx.model == "claude-sonnet-4-5-20250514"
      assert ctx.subscriber == self()
      assert ctx.depth == 0
      assert ctx.streaming_tools_enabled == true
    end

    test "raises on missing required field" do
      assert_raise ArgumentError, fn ->
        Context.new(session_id: "sess_1")
      end
    end
  end
end
