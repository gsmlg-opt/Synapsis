defmodule Synapsis.Agent.QueryLoopContextTest do
  use Synapsis.Agent.DataCase

  alias Synapsis.Agent.QueryLoop
  alias Synapsis.Agent.QueryLoop.{State, Context}

  describe "context assembly integration" do
    test "assembled prompt includes base prompt section" do
      test_pid = self()

      mock_stream = fn request, _config ->
        send(test_pid, {:captured_request, request})
        send(test_pid, {:provider_chunk, {:text_delta, "done"}})
        send(test_pid, {:provider_chunk, :content_block_stop})
        send(test_pid, {:provider_chunk, :done})
        :ok
      end

      ctx =
        Context.new(
          session_id: "test",
          system_prompt: :dynamic,
          tools: [%{name: "file_read", description: "Reads a file", parameters: %{}}],
          model: "test",
          provider_config: %{type: "test"},
          subscriber: test_pid,
          agent_config: %{stream_fn: mock_stream, agent_type: :conversational}
        )

      state = State.new(messages: [%{role: "user", content: "read a file for me"}])
      {:ok, :completed, _} = QueryLoop.run(state, ctx)

      assert_received {:captured_request, request}
      assert is_binary(request.system)
      # The assembled prompt should be non-trivial (ContextBuilder adds layers)
      assert String.length(request.system) > 50
    end

    test "static system_prompt passes through unchanged" do
      test_pid = self()

      mock_stream = fn request, _config ->
        send(test_pid, {:captured_system, request.system})
        send(test_pid, {:provider_chunk, {:text_delta, "ok"}})
        send(test_pid, {:provider_chunk, :content_block_stop})
        send(test_pid, {:provider_chunk, :done})
        :ok
      end

      ctx =
        Context.new(
          session_id: "test",
          system_prompt: "You are a static test prompt.",
          tools: [],
          model: "test",
          provider_config: %{type: "test"},
          subscriber: test_pid,
          agent_config: %{stream_fn: mock_stream}
        )

      state = State.new(messages: [%{role: "user", content: "hi"}])
      {:ok, :completed, _} = QueryLoop.run(state, ctx)

      assert_received {:captured_system, "You are a static test prompt."}
    end
  end
end
