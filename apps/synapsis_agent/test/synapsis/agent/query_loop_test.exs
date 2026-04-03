defmodule Synapsis.Agent.QueryLoopTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.QueryLoop
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
      ctx =
        Context.new(
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

  # -------------------------------------------------------------------------
  # run/2 tests — completion path (no tool execution)
  # -------------------------------------------------------------------------

  defp make_ctx(opts) do
    defaults = [
      session_id: "test_sess",
      system_prompt: "You are helpful.",
      tools: [],
      model: "test-model",
      provider_config: %{type: "test"},
      subscriber: self(),
      agent_config: %{}
    ]

    Context.new(Keyword.merge(defaults, opts))
  end

  describe "run/2 -- completion (no tools)" do
    test "completes when LLM returns no tool_use blocks" do
      test_pid = self()

      mock_stream = fn _request, _config ->
        send(test_pid, {:provider_chunk, :text_start})
        send(test_pid, {:provider_chunk, {:text_delta, "Hi there!"}})
        send(test_pid, {:provider_chunk, :content_block_stop})
        send(test_pid, {:provider_chunk, :done})
        :ok
      end

      ctx = make_ctx(agent_config: %{stream_fn: mock_stream})
      state = State.new(messages: [%{role: "user", content: "hello"}])

      assert {:ok, :completed, final_state} = QueryLoop.run(state, ctx)
      assert final_state.turn_count == 1
      assert length(final_state.messages) == 2
      last_msg = List.last(final_state.messages)
      assert last_msg.role == "assistant"
    end

    test "sends stream events to subscriber" do
      test_pid = self()

      mock_stream = fn _request, _config ->
        send(test_pid, {:provider_chunk, :text_start})
        send(test_pid, {:provider_chunk, {:text_delta, "Hello"}})
        send(test_pid, {:provider_chunk, :content_block_stop})
        send(test_pid, {:provider_chunk, :done})
        :ok
      end

      ctx = make_ctx(agent_config: %{stream_fn: mock_stream})
      state = State.new(messages: [%{role: "user", content: "hi"}])
      {:ok, :completed, _} = QueryLoop.run(state, ctx)

      assert_received {:query_event, {:stream_start}}
      assert_received {:query_event, {:stream_chunk, {:text_delta, "Hello"}}}
      assert_received {:query_event, {:stream_end, _}}
      assert_received {:query_event, {:terminal, :completed, _}}
    end

    test "handles model error gracefully" do
      test_pid = self()

      mock_stream = fn _request, _config ->
        send(test_pid, {:provider_chunk, {:error, "rate_limited"}})
        :ok
      end

      ctx = make_ctx(agent_config: %{stream_fn: mock_stream})
      state = State.new(messages: [%{role: "user", content: "hi"}])
      assert {:ok, :model_error, _} = QueryLoop.run(state, ctx)
    end

    test "respects max_turns limit with zero turns" do
      ctx = make_ctx(agent_config: %{})
      state = State.new(max_turns: 0)
      assert {:ok, :max_turns, _} = QueryLoop.run(state, ctx)
    end

    test "assembles assistant message with text content" do
      test_pid = self()

      mock_stream = fn _request, _config ->
        send(test_pid, {:provider_chunk, {:text_delta, "Part 1. "}})
        send(test_pid, {:provider_chunk, {:text_delta, "Part 2."}})
        send(test_pid, {:provider_chunk, :content_block_stop})
        send(test_pid, {:provider_chunk, :done})
        :ok
      end

      ctx = make_ctx(agent_config: %{stream_fn: mock_stream})
      state = State.new(messages: [%{role: "user", content: "hi"}])
      {:ok, :completed, final} = QueryLoop.run(state, ctx)

      assistant = List.last(final.messages)
      assert [%{type: "text", text: "Part 1. Part 2."}] = assistant.content
    end

    test "handles stream function returning {:ok, ref}" do
      test_pid = self()

      mock_stream = fn _request, _config ->
        send(test_pid, {:provider_chunk, {:text_delta, "ok"}})
        send(test_pid, {:provider_chunk, :done})
        {:ok, make_ref()}
      end

      ctx = make_ctx(agent_config: %{stream_fn: mock_stream})
      state = State.new(messages: [%{role: "user", content: "hi"}])
      assert {:ok, :completed, _} = QueryLoop.run(state, ctx)
    end

    test "handles :provider_done message directly" do
      test_pid = self()

      mock_stream = fn _request, _config ->
        send(test_pid, {:provider_chunk, {:text_delta, "hi"}})
        send(test_pid, :provider_done)
        :ok
      end

      ctx = make_ctx(agent_config: %{stream_fn: mock_stream})
      state = State.new(messages: [%{role: "user", content: "hi"}])
      assert {:ok, :completed, final} = QueryLoop.run(state, ctx)
      assert List.last(final.messages).role == "assistant"
    end

    test "builds request with tools formatted correctly" do
      test_pid = self()
      captured = :ets.new(:captured_req, [:set, :public])

      mock_stream = fn request, _config ->
        :ets.insert(captured, {:request, request})
        send(test_pid, {:provider_chunk, {:text_delta, "done"}})
        send(test_pid, {:provider_chunk, :done})
        :ok
      end

      tools = [%{name: "file_read", description: "Read a file", parameters: %{type: "object"}}]
      ctx = make_ctx(agent_config: %{stream_fn: mock_stream}, tools: tools)
      state = State.new(messages: [%{role: "user", content: "hi"}])
      {:ok, :completed, _} = QueryLoop.run(state, ctx)

      [{:request, req}] = :ets.lookup(captured, :request)
      assert req.model == "test-model"
      assert req.stream == true
      assert [%{name: "file_read", input_schema: %{type: "object"}}] = req.tools
      :ets.delete(captured)
    end

    test "stream function error propagates as model_error" do
      mock_stream = fn _request, _config ->
        {:error, :connection_refused}
      end

      ctx = make_ctx(agent_config: %{stream_fn: mock_stream})
      state = State.new(messages: [%{role: "user", content: "hi"}])
      assert {:ok, :model_error, _} = QueryLoop.run(state, ctx)
    end
  end

  describe "run/2 — tool execution loop" do
    defmodule EchoTool do
      use Synapsis.Tool
      def name, do: "echo"
      def description, do: "echoes input"
      def parameters, do: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}
      def permission_level, do: :read
      def execute(%{"text" => t}, _ctx), do: {:ok, t}
      def execute(_input, _ctx), do: {:ok, "no text"}
    end

    test "loops when LLM returns tool_use, executes tool, sends result back" do
      test_pid = self()
      turn = :counters.new(1, [:atomics])

      mock_stream = fn _request, _config ->
        count = :counters.get(turn, 1)
        :counters.add(turn, 1, 1)

        if count == 0 do
          # First turn: LLM calls a tool
          send(test_pid, {:provider_chunk, {:text_delta, "Let me check."}})
          send(test_pid, {:provider_chunk, :content_block_stop})
          send(test_pid, {:provider_chunk, {:tool_use_start, "echo", "tu_1"}})
          send(test_pid, {:provider_chunk, {:tool_use_complete, "echo", %{"text" => "hello"}}})
          send(test_pid, {:provider_chunk, :content_block_stop})
          send(test_pid, {:provider_chunk, :done})
        else
          # Second turn: LLM completes with text only
          send(test_pid, {:provider_chunk, {:text_delta, "The echo says hello."}})
          send(test_pid, {:provider_chunk, :content_block_stop})
          send(test_pid, {:provider_chunk, :done})
        end

        :ok
      end

      tool_defs = [%{name: "echo", description: "echoes", parameters: %{}}]

      ctx = Context.new(
        session_id: "test",
        system_prompt: "test",
        tools: tool_defs,
        model: "test",
        provider_config: %{type: "test"},
        subscriber: test_pid,
        agent_config: %{
          stream_fn: mock_stream,
          tool_modules: %{"echo" => EchoTool}
        }
      )

      state = State.new(messages: [%{role: "user", content: "echo hello"}])

      assert {:ok, :completed, final_state} = QueryLoop.run(state, ctx)
      assert final_state.turn_count == 2

      # Messages: user, assistant (tool_use), user (tool_result), assistant (text)
      assert length(final_state.messages) == 4

      # Verify tool events were sent
      assert_received {:query_event, {:tool_start, "tu_1", "echo", _}}
      assert_received {:query_event, {:tool_result, "tu_1", _}}
    end

    test "respects max_turns limit during tool loop" do
      test_pid = self()

      # Always return tool_use to force infinite loop
      mock_stream = fn _request, _config ->
        id = "tu_#{System.unique_integer([:positive])}"
        send(test_pid, {:provider_chunk, {:tool_use_start, "echo", id}})
        send(test_pid, {:provider_chunk, {:tool_use_complete, "echo", %{"text" => "x"}}})
        send(test_pid, {:provider_chunk, :content_block_stop})
        send(test_pid, {:provider_chunk, :done})
        :ok
      end

      ctx = Context.new(
        session_id: "test",
        system_prompt: "test",
        tools: [%{name: "echo", description: "echoes", parameters: %{}}],
        model: "test",
        provider_config: %{type: "test"},
        subscriber: test_pid,
        agent_config: %{stream_fn: mock_stream, tool_modules: %{"echo" => EchoTool}}
      )

      state = State.new(messages: [%{role: "user", content: "loop forever"}], max_turns: 3)

      assert {:ok, :max_turns, final_state} = QueryLoop.run(state, ctx)
      assert final_state.turn_count >= 3
    end

    test "tool error is formatted as is_error and loop continues" do
      test_pid = self()
      turn = :counters.new(1, [:atomics])

      defmodule FailTool do
        use Synapsis.Tool
        def name, do: "fail"
        def description, do: "fails"
        def parameters, do: %{}
        def permission_level, do: :read
        def execute(_input, _ctx), do: {:error, "boom"}
      end

      mock_stream = fn _request, _config ->
        count = :counters.get(turn, 1)
        :counters.add(turn, 1, 1)

        if count == 0 do
          send(test_pid, {:provider_chunk, {:tool_use_start, "fail", "tu_f1"}})
          send(test_pid, {:provider_chunk, {:tool_use_complete, "fail", %{}}})
          send(test_pid, {:provider_chunk, :content_block_stop})
          send(test_pid, {:provider_chunk, :done})
        else
          send(test_pid, {:provider_chunk, {:text_delta, "Sorry, the tool failed."}})
          send(test_pid, {:provider_chunk, :content_block_stop})
          send(test_pid, {:provider_chunk, :done})
        end
        :ok
      end

      ctx = Context.new(
        session_id: "test",
        system_prompt: "test",
        tools: [%{name: "fail", description: "fails", parameters: %{}}],
        model: "test",
        provider_config: %{type: "test"},
        subscriber: test_pid,
        agent_config: %{stream_fn: mock_stream, tool_modules: %{"fail" => FailTool}}
      )

      state = State.new(messages: [%{role: "user", content: "try fail"}])
      assert {:ok, :completed, final} = QueryLoop.run(state, ctx)
      assert final.turn_count == 2

      # tool_result message should have is_error: true
      tool_result_msg = Enum.find(final.messages, fn m ->
        m.role == "user" and is_list(m.content) and
          Enum.any?(m.content, &(Map.get(&1, :type) == "tool_result"))
      end)
      assert tool_result_msg
      [result_block] = tool_result_msg.content
      assert result_block.is_error == true
      assert result_block.content == "boom"
    end
  end
end
