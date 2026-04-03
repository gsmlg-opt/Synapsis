defmodule Synapsis.Agent.QueryLoopForkTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.QueryLoop
  alias Synapsis.Agent.QueryLoop.Context

  setup do
    parent =
      Context.new(
        session_id: "parent_sess",
        system_prompt: "parent prompt",
        tools: [
          %{name: "file_read", description: "read", parameters: %{}, permission_level: :read},
          %{name: "file_write", description: "write", parameters: %{}, permission_level: :write},
          %{name: "bash", description: "exec", parameters: %{}, permission_level: :execute},
          %{name: "grep", description: "search", parameters: %{}, permission_level: :none}
        ],
        model: "claude-sonnet-4-5-20250514",
        provider_config: %{type: "anthropic", api_key: "test"},
        subscriber: self(),
        project_path: "/tmp/test",
        working_dir: "/tmp/test"
      )

    {:ok, parent: parent}
  end

  describe "fork/2" do
    test "creates context with custom system prompt", %{parent: parent} do
      child = QueryLoop.fork(parent, system_prompt: "Do this task", subscriber: self())
      assert child.system_prompt == "Do this task"
    end

    test "defaults to read-only tools", %{parent: parent} do
      child = QueryLoop.fork(parent, system_prompt: "task", subscriber: self())
      tool_names = Enum.map(child.tools, & &1.name)
      assert "file_read" in tool_names
      assert "grep" in tool_names
      refute "file_write" in tool_names
      refute "bash" in tool_names
    end

    test "uses explicit tool allowlist", %{parent: parent} do
      child =
        QueryLoop.fork(parent,
          system_prompt: "task",
          subscriber: self(),
          tool_names: ["file_read", "file_write"]
        )

      tool_names = Enum.map(child.tools, & &1.name)
      assert "file_read" in tool_names
      assert "file_write" in tool_names
      refute "bash" in tool_names
      refute "grep" in tool_names
    end

    test "inherits project_path and working_dir", %{parent: parent} do
      child = QueryLoop.fork(parent, system_prompt: "task", subscriber: self())
      assert child.project_path == "/tmp/test"
      assert child.working_dir == "/tmp/test"
    end

    test "increments depth", %{parent: parent} do
      assert parent.depth == 0
      child = QueryLoop.fork(parent, system_prompt: "task", subscriber: self())
      assert child.depth == 1

      grandchild = QueryLoop.fork(child, system_prompt: "subtask", subscriber: self())
      assert grandchild.depth == 2
    end

    test "allows model override", %{parent: parent} do
      child =
        QueryLoop.fork(parent,
          system_prompt: "task",
          subscriber: self(),
          model: "claude-haiku-4-5-20251001"
        )

      assert child.model == "claude-haiku-4-5-20251001"
    end

    test "inherits provider_config", %{parent: parent} do
      child = QueryLoop.fork(parent, system_prompt: "task", subscriber: self())
      assert child.provider_config == parent.provider_config
    end

    test "gets own abort_ref", %{parent: parent} do
      child = QueryLoop.fork(parent, system_prompt: "task", subscriber: self())
      assert is_reference(child.abort_ref)
      assert child.abort_ref != parent.abort_ref
    end
  end

  describe "subagent integration" do
    defmodule SubagentEchoTool do
      use Synapsis.Tool

      def name, do: "echo"
      def description, do: "echoes"

      def parameters,
        do: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}

      def permission_level, do: :read

      def execute(%{"text" => t}, _ctx), do: {:ok, t}
      def execute(_, _), do: {:ok, "no text"}
    end

    defmodule SubagentTaskTool do
      @moduledoc "Mock task tool that uses QueryLoop.fork internally"
      use Synapsis.Tool

      def name, do: "task"
      def description, do: "spawn subagent"

      def parameters,
        do: %{
          "type" => "object",
          "properties" => %{"prompt" => %{"type" => "string"}},
          "required" => ["prompt"]
        }

      def permission_level, do: :none

      def execute(%{"prompt" => prompt}, context) do
        query_ctx = context[:query_context]

        unless QueryLoop.can_fork?(query_ctx) do
          {:error, "Max depth reached"}
        else
          child_ctx =
            QueryLoop.fork(query_ctx,
              system_prompt: "You are a helper subagent. Complete the task: #{prompt}",
              subscriber: self()
            )

          child_state =
            Synapsis.Agent.QueryLoop.State.new(messages: [%{role: "user", content: prompt}])

          case QueryLoop.run(child_state, child_ctx) do
            {:ok, :completed, final} ->
              last_assistant =
                final.messages |> Enum.reverse() |> Enum.find(&(&1.role == "assistant"))

              text =
                case last_assistant do
                  %{content: blocks} when is_list(blocks) ->
                    blocks
                    |> Enum.filter(&(is_map(&1) and &1[:type] == "text"))
                    |> Enum.map_join("", & &1[:text])

                  _ ->
                    "done"
                end

              {:ok, text}

            {:ok, reason, _} ->
              {:error, "Subagent: #{reason}"}
          end
        end
      end
    end

    test "task tool spawns subagent via QueryLoop.fork and returns result" do
      turn = :counters.new(1, [:atomics])

      mock_stream = fn _request, _config ->
        caller = self()
        count = :counters.get(turn, 1)
        :counters.add(turn, 1, 1)

        case count do
          0 ->
            # Parent turn 1: LLM calls task tool
            send(caller, {:provider_chunk, {:tool_use_start, "task", "tu_task"}})

            send(
              caller,
              {:provider_chunk, {:tool_use_complete, "task", %{"prompt" => "say hello"}}}
            )

            send(caller, {:provider_chunk, :content_block_stop})
            send(caller, {:provider_chunk, :done})

          _ ->
            # All other turns (parent turn 2, subagent turn): complete with text
            send(caller, {:provider_chunk, {:text_delta, "Hello from subagent!"}})
            send(caller, {:provider_chunk, :content_block_stop})
            send(caller, {:provider_chunk, :done})
        end

        :ok
      end

      tool_defs = [
        %{name: "task", description: "spawn", parameters: %{}, permission_level: :none},
        %{name: "echo", description: "echoes", parameters: %{}, permission_level: :read}
      ]

      ctx =
        Context.new(
          session_id: "test",
          system_prompt: "test",
          tools: tool_defs,
          model: "test",
          provider_config: %{type: "test"},
          subscriber: self(),
          agent_config: %{
            stream_fn: mock_stream,
            tool_modules: %{"task" => SubagentTaskTool, "echo" => SubagentEchoTool}
          }
        )

      state =
        Synapsis.Agent.QueryLoop.State.new(
          messages: [%{role: "user", content: "spawn a subagent to say hello"}]
        )

      assert {:ok, :completed, final} = QueryLoop.run(state, ctx)
      assert final.turn_count >= 2
    end

    test "refuses when depth >= 3" do
      parent =
        Context.new(
          session_id: "test",
          system_prompt: "test",
          tools: [],
          model: "test",
          provider_config: %{type: "test"},
          subscriber: self(),
          depth: 3
        )

      refute QueryLoop.can_fork?(parent)
    end
  end

  describe "can_fork?/1" do
    test "allows forking at depth 0", %{parent: parent} do
      assert QueryLoop.can_fork?(parent) == true
    end

    test "allows forking at depth 2", %{parent: parent} do
      child = QueryLoop.fork(parent, system_prompt: "t", subscriber: self())
      grandchild = QueryLoop.fork(child, system_prompt: "t", subscriber: self())
      assert QueryLoop.can_fork?(grandchild) == true
    end

    test "refuses forking at depth 3", %{parent: parent} do
      c1 = QueryLoop.fork(parent, system_prompt: "t", subscriber: self())
      c2 = QueryLoop.fork(c1, system_prompt: "t", subscriber: self())
      c3 = QueryLoop.fork(c2, system_prompt: "t", subscriber: self())
      assert QueryLoop.can_fork?(c3) == false
    end
  end
end
