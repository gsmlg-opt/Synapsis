# Query Loop Port — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port CCB's `query.ts` agentic loop to Elixir as a simpler tail-recursive execution mode alongside the existing graph-based Runner, adding concurrency-partitioned tool execution and streaming tool dispatch.

**Architecture:** `QueryLoop` is a new, self-contained tail-recursive function that runs in a `Task` spawned by `Session.Worker`. It calls the existing `Provider.Adapter.stream/2` for LLM streaming, dispatches tools via a new `ToolExecutor` with read/write concurrency partitioning, and sends events to a subscriber pid. The existing `ContextBuilder`, `Tool.Registry`, `StreamAccumulator`, and `PubSub` infrastructure are reused as-is.

**Tech Stack:** Elixir 1.18+, OTP 28+, existing umbrella deps (Ecto, Phoenix.PubSub, Req/Finch via Provider.Adapter)

---

## Codebase Reconciliation

The PRD assumes a simpler codebase than what exists. Key existing infrastructure to reuse:

| PRD Assumption | Reality | Plan |
|---|---|---|
| No context builder | `Synapsis.Agent.ContextBuilder` exists with full 7-layer assembly | Reuse directly in Week 2 |
| No tool executor | `Synapsis.Tool.Executor` exists with file-path serialization | Add concurrency partitioning as new module |
| No task tool | `Synapsis.Tool.Task` exists via `SessionBridge` | Add `QueryLoop.fork` path alongside existing |
| No streaming | `Provider.Adapter.stream/2` + `StreamAccumulator` exist | Reuse, add `StreamingExecutor` on top |
| No identity system | `Synapsis.Workspace.Identity` exists | Reuse via ContextBuilder |
| No memory search | `Synapsis.Memory.ContextBuilder` exists | Reuse via ContextBuilder |

**New code lives in `apps/synapsis_agent/lib/synapsis/agent/`** — all new modules are pure functions or simple stateful structs, no new GenServers.

---

## File Inventory

### New Files

```
apps/synapsis_agent/lib/synapsis/agent/query_loop.ex          # Week 1 — core loop + state + types
apps/synapsis_agent/lib/synapsis/agent/query_loop/state.ex     # Week 1 — loop state struct
apps/synapsis_agent/lib/synapsis/agent/query_loop/context.ex   # Week 1 — immutable context struct
apps/synapsis_agent/lib/synapsis/agent/query_loop/executor.ex  # Week 1 — concurrency-partitioned tool dispatch
apps/synapsis_agent/lib/synapsis/agent/streaming_executor.ex   # Week 4 — eager tool dispatch during stream

test/synapsis/agent/query_loop_test.exs                        # Week 1
test/synapsis/agent/query_loop/executor_test.exs               # Week 1
test/synapsis/agent/query_loop_context_test.exs                # Week 2
test/synapsis/agent/query_loop_fork_test.exs                   # Week 3
test/synapsis/agent/streaming_executor_test.exs                # Week 4
```

### Modified Files

```
apps/synapsis_agent/lib/synapsis/session/worker.ex             # Week 1 — add QueryLoop execution path
apps/synapsis_agent/lib/synapsis/session/worker/io_handler.ex  # Week 1 — handle QueryLoop events
apps/synapsis_core/lib/synapsis/tool/task.ex                   # Week 3 — add QueryLoop.fork path
```

### Existing Files Reused (read-only references)

```
apps/synapsis_agent/lib/synapsis/agent/context_builder.ex      # Week 2 — called from QueryLoop.prepare
apps/synapsis_core/lib/synapsis/agent/stream_accumulator.ex    # Week 1+4 — event accumulation
apps/synapsis_provider/lib/synapsis/provider/adapter.ex        # Week 1 — Provider.Adapter.stream/2
apps/synapsis_provider/lib/synapsis/provider/event_mapper.ex   # Week 1 — canonical event protocol
apps/synapsis_core/lib/synapsis/tool/registry.ex               # Week 1 — tool lookup
apps/synapsis_core/lib/synapsis/tool/executor.ex               # Week 1 — reference for dispatch pattern
apps/synapsis_workspace/lib/synapsis/workspace/identity.ex     # Week 2 — identity file loading
```

---

## Week 1: QueryLoop + Executor (Tasks 1–10)

### Task 1: QueryLoop.State struct

**Files:**
- Create: `apps/synapsis_agent/lib/synapsis/agent/query_loop/state.ex`
- Test: `apps/synapsis_agent/test/synapsis/agent/query_loop_test.exs`

- [ ] **Step 1: Write failing test for State struct**

```elixir
# apps/synapsis_agent/test/synapsis/agent/query_loop_test.exs
defmodule Synapsis.Agent.QueryLoopTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.QueryLoop.State

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
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop_test.exs -v'`
Expected: compilation errors — `State` module not found

- [ ] **Step 3: Implement State struct**

```elixir
# apps/synapsis_agent/lib/synapsis/agent/query_loop/state.ex
defmodule Synapsis.Agent.QueryLoop.State do
  @moduledoc """
  Mutable state for the query loop, carried across iterations.
  Messages are in Anthropic canonical format.
  """

  @type t :: %__MODULE__{
          messages: [map()],
          turn_count: non_neg_integer(),
          max_turns: non_neg_integer()
        }

  defstruct messages: [],
            turn_count: 0,
            max_turns: 50

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct!(__MODULE__, opts)
  end

  @spec increment_turn(t()) :: t()
  def increment_turn(%__MODULE__{} = state) do
    %{state | turn_count: state.turn_count + 1}
  end

  @spec append_messages(t(), [map()]) :: t()
  def append_messages(%__MODULE__{} = state, msgs) when is_list(msgs) do
    %{state | messages: state.messages ++ msgs}
  end

  @spec max_turns_reached?(t()) :: boolean()
  def max_turns_reached?(%__MODULE__{turn_count: tc, max_turns: mt}), do: tc >= mt
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop_test.exs -v'`
Expected: all 6 tests pass

- [ ] **Step 5: Commit**

```bash
git add apps/synapsis_agent/lib/synapsis/agent/query_loop/state.ex apps/synapsis_agent/test/synapsis/agent/query_loop_test.exs
git commit -m "feat(agent): add QueryLoop.State struct"
```

---

### Task 2: QueryLoop.Context struct

**Files:**
- Create: `apps/synapsis_agent/lib/synapsis/agent/query_loop/context.ex`
- Modify: `apps/synapsis_agent/test/synapsis/agent/query_loop_test.exs`

- [ ] **Step 1: Write failing test for Context struct**

Append to `query_loop_test.exs`:

```elixir
  alias Synapsis.Agent.QueryLoop.Context

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
      assert_raise KeyError, fn ->
        Context.new(session_id: "sess_1")
      end
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop_test.exs -v'`
Expected: FAIL — `Context` not defined

- [ ] **Step 3: Implement Context struct**

```elixir
# apps/synapsis_agent/lib/synapsis/agent/query_loop/context.ex
defmodule Synapsis.Agent.QueryLoop.Context do
  @moduledoc """
  Immutable context for a single query loop invocation.
  Equivalent to CCB's ToolUseContext + QueryParams.
  """

  @type t :: %__MODULE__{
          session_id: String.t(),
          system_prompt: String.t(),
          tools: [map()],
          model: String.t(),
          provider_config: map(),
          subscriber: pid(),
          abort_ref: reference() | nil,
          project_path: String.t() | nil,
          working_dir: String.t() | nil,
          depth: non_neg_integer(),
          streaming_tools_enabled: boolean(),
          agent_config: map()
        }

  @enforce_keys [:session_id, :system_prompt, :tools, :model, :provider_config, :subscriber]
  defstruct [
    :session_id,
    :system_prompt,
    :tools,
    :model,
    :provider_config,
    :subscriber,
    abort_ref: nil,
    project_path: nil,
    working_dir: nil,
    depth: 0,
    streaming_tools_enabled: true,
    agent_config: %{}
  ]

  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop_test.exs -v'`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add apps/synapsis_agent/lib/synapsis/agent/query_loop/context.ex apps/synapsis_agent/test/synapsis/agent/query_loop_test.exs
git commit -m "feat(agent): add QueryLoop.Context struct"
```

---

### Task 3: QueryLoop.Executor — concurrency partitioning

**Files:**
- Create: `apps/synapsis_agent/lib/synapsis/agent/query_loop/executor.ex`
- Create: `apps/synapsis_agent/test/synapsis/agent/query_loop/executor_test.exs`

This is the novel piece from the PRD: partition tool calls into concurrent (read-only) and serial (write+) batches, then execute them in order.

- [ ] **Step 1: Write failing test for partition/2**

```elixir
# apps/synapsis_agent/test/synapsis/agent/query_loop/executor_test.exs
defmodule Synapsis.Agent.QueryLoop.ExecutorTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.QueryLoop.Executor

  defmodule ReadTool do
    use Synapsis.Tool
    def name, do: "read_tool"
    def description, do: "reads"
    def parameters, do: %{}
    def permission_level, do: :read
    def execute(_input, _ctx), do: {:ok, "read_result"}
  end

  defmodule WriteTool do
    use Synapsis.Tool
    def name, do: "write_tool"
    def description, do: "writes"
    def parameters, do: %{}
    def permission_level, do: :write
    def execute(_input, _ctx), do: {:ok, "write_result"}
  end

  @read_block %{id: "r1", name: "read_tool", input: %{}}
  @write_block %{id: "w1", name: "write_tool", input: %{}}

  describe "partition/2" do
    test "groups consecutive read-only tools into concurrent batch" do
      blocks = [
        %{@read_block | id: "r1"},
        %{@read_block | id: "r2"},
        %{@read_block | id: "r3"}
      ]
      tool_map = %{"read_tool" => ReadTool}

      assert [{:concurrent, ids}] = Executor.partition(blocks, tool_map)
      assert Enum.map(ids, & &1.id) == ["r1", "r2", "r3"]
    end

    test "isolates write tools into serial batches" do
      blocks = [
        %{@write_block | id: "w1"},
        %{@write_block | id: "w2"}
      ]
      tool_map = %{"write_tool" => WriteTool}

      result = Executor.partition(blocks, tool_map)
      assert [{:serial, [%{id: "w1"}]}, {:serial, [%{id: "w2"}]}] = result
    end

    test "handles mixed interleaved sequence" do
      blocks = [
        %{@read_block | id: "r1"},
        %{@read_block | id: "r2"},
        %{@write_block | id: "w1"},
        %{@read_block | id: "r3"},
        %{@write_block | id: "w2"}
      ]
      tool_map = %{"read_tool" => ReadTool, "write_tool" => WriteTool}

      result = Executor.partition(blocks, tool_map)

      assert [
               {:concurrent, [%{id: "r1"}, %{id: "r2"}]},
               {:serial, [%{id: "w1"}]},
               {:concurrent, [%{id: "r3"}]},
               {:serial, [%{id: "w2"}]}
             ] = result
    end

    test "handles single tool call" do
      result = Executor.partition([@read_block], %{"read_tool" => ReadTool})
      assert [{:concurrent, [%{id: "r1"}]}] = result
    end

    test "handles empty list" do
      assert [] = Executor.partition([], %{})
    end

    test "treats unknown tools as serial" do
      blocks = [%{id: "u1", name: "unknown", input: %{}}]
      assert [{:serial, [%{id: "u1"}]}] = Executor.partition(blocks, %{})
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop/executor_test.exs -v'`
Expected: FAIL — `Executor` module not defined

- [ ] **Step 3: Implement partition/2**

```elixir
# apps/synapsis_agent/lib/synapsis/agent/query_loop/executor.ex
defmodule Synapsis.Agent.QueryLoop.Executor do
  @moduledoc """
  Concurrency-partitioned tool executor for the query loop.
  
  Partitions tool calls into batches: consecutive read-only tools run in parallel,
  everything else runs serially. Executes batches in order.
  """

  require Logger

  @type tool_block :: %{id: String.t(), name: String.t(), input: map()}
  @type batch :: {:concurrent, [tool_block()]} | {:serial, [tool_block()]}

  @concurrent_permission_levels [:none, :read]

  @doc """
  Partition tool blocks into concurrent and serial batches.
  
  Consecutive concurrency-safe tools (permission_level :none or :read) are grouped.
  Non-safe tools each get their own serial batch.
  """
  @spec partition([tool_block()], map()) :: [batch()]
  def partition([], _tool_map), do: []

  def partition(blocks, tool_map) do
    blocks
    |> Enum.reduce([], fn block, acc ->
      safe? = concurrent_safe?(block.name, tool_map)
      append_to_batches(acc, block, safe?)
    end)
    |> Enum.reverse()
  end

  defp concurrent_safe?(name, tool_map) do
    case Map.get(tool_map, name) do
      nil -> false
      mod ->
        level = if function_exported?(mod, :permission_level, 0), do: mod.permission_level(), else: :write
        level in @concurrent_permission_levels
    end
  end

  defp append_to_batches([{:concurrent, items} | rest], block, true) do
    [{:concurrent, items ++ [block]} | rest]
  end

  defp append_to_batches(acc, block, true) do
    [{:concurrent, [block]} | acc]
  end

  defp append_to_batches(acc, block, false) do
    [{:serial, [block]} | acc]
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop/executor_test.exs -v'`
Expected: all 6 partition tests pass

- [ ] **Step 5: Commit**

```bash
git add apps/synapsis_agent/lib/synapsis/agent/query_loop/executor.ex apps/synapsis_agent/test/synapsis/agent/query_loop/executor_test.exs
git commit -m "feat(agent): add QueryLoop.Executor with concurrency partitioning"
```

---

### Task 4: QueryLoop.Executor.run/3 — batch execution

**Files:**
- Modify: `apps/synapsis_agent/lib/synapsis/agent/query_loop/executor.ex`
- Modify: `apps/synapsis_agent/test/synapsis/agent/query_loop/executor_test.exs`

- [ ] **Step 1: Write failing tests for run/3**

Append to `executor_test.exs`:

```elixir
  describe "run/3" do
    test "executes concurrent batch in parallel and returns results in order" do
      blocks = [
        %{id: "r1", name: "read_tool", input: %{"delay" => 0}},
        %{id: "r2", name: "read_tool", input: %{"delay" => 0}}
      ]
      tool_map = %{"read_tool" => ReadTool}
      ctx = %{session_id: "test", project_path: nil}

      results = Executor.run(blocks, tool_map, ctx)

      assert [
               %{tool_use_id: "r1", content: "read_result", is_error: false},
               %{tool_use_id: "r2", content: "read_result", is_error: false}
             ] = results
    end

    test "executes serial batch sequentially" do
      blocks = [
        %{id: "w1", name: "write_tool", input: %{}},
        %{id: "w2", name: "write_tool", input: %{}}
      ]
      tool_map = %{"write_tool" => WriteTool}
      ctx = %{session_id: "test", project_path: nil}

      results = Executor.run(blocks, tool_map, ctx)
      assert length(results) == 2
      assert Enum.all?(results, &(&1.is_error == false))
    end

    test "formats tool error as is_error result" do
      defmodule ErrorTool do
        use Synapsis.Tool
        def name, do: "error_tool"
        def description, do: "errors"
        def parameters, do: %{}
        def permission_level, do: :read
        def execute(_input, _ctx), do: {:error, "something broke"}
      end

      blocks = [%{id: "e1", name: "error_tool", input: %{}}]
      tool_map = %{"error_tool" => ErrorTool}
      ctx = %{session_id: "test", project_path: nil}

      results = Executor.run(blocks, tool_map, ctx)
      assert [%{tool_use_id: "e1", is_error: true, content: "something broke"}] = results
    end

    test "handles unknown tool with error result" do
      blocks = [%{id: "u1", name: "nonexistent", input: %{}}]
      results = Executor.run(blocks, %{}, %{session_id: "test"})
      assert [%{tool_use_id: "u1", is_error: true}] = results
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop/executor_test.exs -v'`
Expected: FAIL — `run/3` not defined

- [ ] **Step 3: Implement run/3**

Add to `executor.ex`:

```elixir
  @type tool_result :: %{
          tool_use_id: String.t(),
          content: String.t(),
          is_error: boolean()
        }

  @doc """
  Execute tool blocks with concurrency partitioning.
  Returns tool_result maps in the original block order.
  """
  @spec run([tool_block()], map(), map()) :: [tool_result()]
  def run(blocks, tool_map, context) do
    batches = partition(blocks, tool_map)

    Enum.flat_map(batches, fn
      {:concurrent, items} ->
        items
        |> Task.async_stream(
          fn block -> {block.id, run_one(block, tool_map, context)} end,
          max_concurrency: System.schedulers_online(),
          ordered: true,
          timeout: 60_000,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, {id, result}} -> format_result(id, result)
          {:exit, {id, _reason}} -> %{tool_use_id: id, content: "Tool execution timed out", is_error: true}
        end)

      {:serial, items} ->
        Enum.map(items, fn block ->
          result = run_one(block, tool_map, context)
          format_result(block.id, result)
        end)
    end)
  end

  @doc "Execute a single tool call."
  @spec run_one(tool_block(), map(), map()) :: {:ok, term()} | {:error, term()}
  def run_one(%{name: name, input: input}, tool_map, context) do
    case Map.get(tool_map, name) do
      nil ->
        {:error, "Unknown tool: #{name}"}

      mod ->
        try do
          mod.execute(input, context)
        rescue
          e -> {:error, Exception.message(e)}
        catch
          :exit, reason -> {:error, "Tool exited: #{inspect(reason)}"}
        end
    end
  end

  defp format_result(id, {:ok, result}) when is_binary(result) do
    %{tool_use_id: id, content: result, is_error: false}
  end

  defp format_result(id, {:ok, result}) do
    %{tool_use_id: id, content: inspect(result), is_error: false}
  end

  defp format_result(id, {:error, reason}) when is_binary(reason) do
    %{tool_use_id: id, content: reason, is_error: true}
  end

  defp format_result(id, {:error, reason}) do
    %{tool_use_id: id, content: inspect(reason), is_error: true}
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop/executor_test.exs -v'`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add apps/synapsis_agent/lib/synapsis/agent/query_loop/executor.ex apps/synapsis_agent/test/synapsis/agent/query_loop/executor_test.exs
git commit -m "feat(agent): add QueryLoop.Executor.run/3 with batch execution"
```

---

### Task 5: QueryLoop.run/2 — core loop (no-tool-use path)

**Files:**
- Create: `apps/synapsis_agent/lib/synapsis/agent/query_loop.ex`
- Modify: `apps/synapsis_agent/test/synapsis/agent/query_loop_test.exs`

Start with the simplest path: user message → LLM response with no tool calls → terminal :completed.

- [ ] **Step 1: Write failing test for run/2 completion path**

Add to `query_loop_test.exs`:

```elixir
  alias Synapsis.Agent.QueryLoop

  describe "run/2 — completion (no tools)" do
    test "completes when LLM returns no tool_use blocks" do
      # Mock provider that returns a text-only response
      test_pid = self()

      # We use a mock module that the test provides via context
      ctx = Context.new(
        session_id: "test_sess",
        system_prompt: "You are helpful.",
        tools: [],
        model: "test-model",
        provider_config: %{type: "test"},
        subscriber: test_pid
      )

      state = State.new(messages: [%{role: "user", content: "hello"}])

      # Inject a mock stream function via context
      mock_stream = fn _request, _config ->
        send(test_pid, {:provider_chunk, :message_start})
        send(test_pid, {:provider_chunk, :text_start})
        send(test_pid, {:provider_chunk, {:text_delta, "Hi there!"}})
        send(test_pid, {:provider_chunk, :content_block_stop})
        send(test_pid, {:provider_chunk, {:message_delta, %{"stop_reason" => "end_turn"}}})
        send(test_pid, {:provider_chunk, :done})
        :ok
      end

      ctx = %{ctx | agent_config: %{stream_fn: mock_stream}}

      assert {:ok, :completed, final_state} = QueryLoop.run(state, ctx)
      assert final_state.turn_count == 1
      # assistant message was appended
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

      ctx = Context.new(
        session_id: "test",
        system_prompt: "test",
        tools: [],
        model: "test",
        provider_config: %{type: "test"},
        subscriber: test_pid,
        agent_config: %{stream_fn: mock_stream}
      )

      state = State.new(messages: [%{role: "user", content: "hi"}])

      {:ok, :completed, _} = QueryLoop.run(state, ctx)

      assert_received {:query_event, {:stream_start}}
      assert_received {:query_event, {:stream_chunk, {:text_delta, "Hello"}}}
      assert_received {:query_event, {:stream_end, _}}
      assert_received {:query_event, {:terminal, :completed, _}}
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop_test.exs --only "describe:run/2" -v'`
Expected: FAIL — `QueryLoop.run/2` not defined

- [ ] **Step 3: Implement QueryLoop.run/2 (completion path only)**

```elixir
# apps/synapsis_agent/lib/synapsis/agent/query_loop.ex
defmodule Synapsis.Agent.QueryLoop do
  @moduledoc """
  CCB-style tail-recursive agentic loop.
  
  Runs: user message → LLM stream → tool dispatch → tool results → LLM again → ... → completion.
  
  Events are sent to `context.subscriber` as `{:query_event, event}`.
  """

  require Logger

  alias __MODULE__.{State, Context, Executor}

  @type terminal_reason :: :completed | :max_turns | :aborted | :model_error
  @type event ::
          {:stream_start}
          | {:stream_chunk, term()}
          | {:stream_end, map()}
          | {:tool_start, String.t(), String.t(), map()}
          | {:tool_result, String.t(), map()}
          | {:turn_complete, non_neg_integer()}
          | {:terminal, terminal_reason(), State.t()}

  @doc """
  Run the query loop. Tail-recursive: loops until terminal condition.
  Returns `{:ok, reason, final_state}`.
  """
  @spec run(State.t(), Context.t()) :: {:ok, terminal_reason(), State.t()}
  def run(%State{} = state, %Context{} = ctx) do
    cond do
      State.max_turns_reached?(state) ->
        notify(ctx, {:terminal, :max_turns, state})
        {:ok, :max_turns, state}

      not Process.alive?(ctx.subscriber) ->
        {:ok, :aborted, state}

      true ->
        case do_turn(state, ctx) do
          {:continue, next_state} ->
            next_state = State.increment_turn(next_state)
            notify(ctx, {:turn_complete, next_state.turn_count})
            run(next_state, ctx)

          {:terminal, reason, final_state} ->
            final_state = State.increment_turn(final_state)
            notify(ctx, {:terminal, reason, final_state})
            {:ok, reason, final_state}
        end
    end
  end

  # -- Turn execution --

  defp do_turn(state, ctx) do
    notify(ctx, {:stream_start})

    case stream_model(state, ctx) do
      {:ok, assistant_msg, tool_blocks} ->
        new_state = State.append_messages(state, [assistant_msg])
        notify(ctx, {:stream_end, assistant_msg})

        if tool_blocks == [] do
          {:terminal, :completed, new_state}
        else
          # Tool execution path (Task 6)
          execute_and_continue(new_state, tool_blocks, ctx)
        end

      {:error, reason} ->
        Logger.warning("query_loop_model_error", reason: inspect(reason))
        {:terminal, :model_error, state}
    end
  end

  # Placeholder — Task 6 implements this
  defp execute_and_continue(state, _tool_blocks, _ctx) do
    {:terminal, :completed, state}
  end

  # -- Streaming --

  defp stream_model(state, ctx) do
    request = build_request(state, ctx)

    # Use injected stream function for testing, or real provider
    stream_fn = get_in(ctx.agent_config, [:stream_fn]) || (&default_stream/2)

    case stream_fn.(request, ctx.provider_config) do
      :ok ->
        # Collect events from mailbox (sent by provider task)
        collect_stream_events(ctx)

      {:ok, _ref} ->
        collect_stream_events(ctx)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_stream(request, config) do
    Synapsis.Provider.Adapter.stream(request, config)
  end

  defp collect_stream_events(ctx) do
    collect_stream_events(ctx, "", [], [])
  end

  defp collect_stream_events(ctx, text_acc, tool_acc, content_blocks) do
    receive do
      {:provider_chunk, :done} ->
        assistant_msg = %{
          role: "assistant",
          content: build_content_blocks(text_acc, tool_acc)
        }
        {:ok, assistant_msg, tool_acc}

      {:provider_chunk, {:text_delta, text}} ->
        notify(ctx, {:stream_chunk, {:text_delta, text}})
        collect_stream_events(ctx, text_acc <> text, tool_acc, content_blocks)

      {:provider_chunk, {:tool_use_start, name, id}} ->
        notify(ctx, {:stream_chunk, {:tool_use_start, name, id}})
        collect_stream_events(ctx, text_acc, tool_acc, [{:tool, name, id, ""} | content_blocks])

      {:provider_chunk, {:tool_input_delta, json}} ->
        case content_blocks do
          [{:tool, name, id, acc_json} | rest] ->
            collect_stream_events(ctx, text_acc, tool_acc, [{:tool, name, id, acc_json <> json} | rest])
          _ ->
            collect_stream_events(ctx, text_acc, tool_acc, content_blocks)
        end

      {:provider_chunk, {:tool_use_complete, name, args}} ->
        block = %{id: find_tool_id(content_blocks, name), name: name, input: args}
        collect_stream_events(ctx, text_acc, tool_acc ++ [block], content_blocks)

      {:provider_chunk, :content_block_stop} ->
        case content_blocks do
          [{:tool, name, id, json} | rest] ->
            args = case Jason.decode(json) do
              {:ok, parsed} -> parsed
              _ -> %{}
            end
            # Only add if not already added via tool_use_complete
            if Enum.any?(tool_acc, &(&1.id == id)) do
              collect_stream_events(ctx, text_acc, tool_acc, rest)
            else
              block = %{id: id, name: name, input: args}
              collect_stream_events(ctx, text_acc, tool_acc ++ [block], rest)
            end
          _ ->
            collect_stream_events(ctx, text_acc, tool_acc, content_blocks)
        end

      {:provider_chunk, {:error, reason}} ->
        {:error, reason}

      {:provider_chunk, _other} ->
        # Ignore other events (message_start, message_delta, etc.)
        collect_stream_events(ctx, text_acc, tool_acc, content_blocks)
    after
      300_000 -> {:error, :stream_timeout}
    end
  end

  defp find_tool_id(content_blocks, name) do
    case Enum.find(content_blocks, fn
      {:tool, ^name, _id, _json} -> true
      _ -> false
    end) do
      {:tool, _, id, _} -> id
      nil -> "tu_#{System.unique_integer([:positive])}"
    end
  end

  defp build_content_blocks("", []), do: []
  defp build_content_blocks(text, []) when text != "", do: [%{type: "text", text: text}]
  defp build_content_blocks("", tools), do: Enum.map(tools, &tool_to_content_block/1)
  defp build_content_blocks(text, tools) do
    [%{type: "text", text: text} | Enum.map(tools, &tool_to_content_block/1)]
  end

  defp tool_to_content_block(%{id: id, name: name, input: input}) do
    %{type: "tool_use", id: id, name: name, input: input}
  end

  defp build_request(state, ctx) do
    tool_defs = Enum.map(ctx.tools, fn
      %{name: n, description: d, parameters: p} -> %{name: n, description: d, input_schema: p}
      tool_map -> tool_map
    end)

    %{
      model: ctx.model,
      system: ctx.system_prompt,
      messages: state.messages,
      tools: tool_defs,
      max_tokens: 8192,
      stream: true
    }
  end

  # -- Notifications --

  defp notify(%Context{subscriber: pid}, event) do
    if Process.alive?(pid), do: send(pid, {:query_event, event})
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop_test.exs -v'`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add apps/synapsis_agent/lib/synapsis/agent/query_loop.ex apps/synapsis_agent/test/synapsis/agent/query_loop_test.exs
git commit -m "feat(agent): add QueryLoop.run/2 core loop (completion path)"
```

---

### Task 6: QueryLoop — tool execution path

**Files:**
- Modify: `apps/synapsis_agent/lib/synapsis/agent/query_loop.ex`
- Modify: `apps/synapsis_agent/test/synapsis/agent/query_loop_test.exs`

Wire the tool dispatch into the loop: LLM returns tool_use → executor runs tools → tool results appended → loop continues.

- [ ] **Step 1: Write failing test for tool execution loop**

Add to `query_loop_test.exs`:

```elixir
  describe "run/2 — tool execution loop" do
    defmodule EchoTool do
      use Synapsis.Tool
      def name, do: "echo"
      def description, do: "echoes input"
      def parameters, do: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}
      def permission_level, do: :read
      def execute(%{"text" => t}, _ctx), do: {:ok, t}
    end

    test "loops when LLM returns tool_use, executes tool, sends result back" do
      test_pid = self()
      turn = :counters.new(1, [:atomics])

      mock_stream = fn _request, _config ->
        count = :counters.get(turn, 1)
        :counters.add(turn, 1, 1)

        if count == 0 do
          # First turn: LLM calls a tool
          send(test_pid, {:provider_chunk, :text_start})
          send(test_pid, {:provider_chunk, {:text_delta, "Let me check."}})
          send(test_pid, {:provider_chunk, :content_block_stop})
          send(test_pid, {:provider_chunk, {:tool_use_start, "echo", "tu_1"}})
          send(test_pid, {:provider_chunk, {:tool_input_delta, ~s({"text":"hello"})}})
          send(test_pid, {:provider_chunk, :content_block_stop})
          send(test_pid, {:provider_chunk, :done})
        else
          # Second turn: LLM completes
          send(test_pid, {:provider_chunk, :text_start})
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

    test "respects max_turns limit" do
      test_pid = self()

      # Always return tool_use to force infinite loop
      mock_stream = fn _request, _config ->
        send(test_pid, {:provider_chunk, {:tool_use_start, "echo", "tu_#{System.unique_integer([:positive])}"}})
        send(test_pid, {:provider_chunk, {:tool_input_delta, ~s({"text":"x"})}})
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
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop_test.exs --only "describe:run/2 — tool execution" -v'`
Expected: FAIL — tool execution path returns :completed without actually running tools

- [ ] **Step 3: Implement execute_and_continue/3**

Replace the placeholder in `query_loop.ex`:

```elixir
  defp execute_and_continue(state, tool_blocks, ctx) do
    tool_modules = get_in(ctx.agent_config, [:tool_modules]) || build_tool_map(ctx.tools)

    # Notify tool starts
    Enum.each(tool_blocks, fn %{id: id, name: name, input: input} ->
      notify(ctx, {:tool_start, id, name, input})
    end)

    # Execute with concurrency partitioning
    results = Executor.run(tool_blocks, tool_modules, %{
      session_id: ctx.session_id,
      project_path: ctx.project_path,
      working_dir: ctx.working_dir
    })

    # Notify tool results
    Enum.each(results, fn result ->
      notify(ctx, {:tool_result, result.tool_use_id, result})
    end)

    # Build tool_result user message
    tool_result_msg = %{
      role: "user",
      content: Enum.map(results, fn r ->
        %{
          type: "tool_result",
          tool_use_id: r.tool_use_id,
          content: r.content,
          is_error: r.is_error
        }
      end)
    }

    new_state = State.append_messages(state, [tool_result_msg])
    {:continue, new_state}
  end

  defp build_tool_map(tools) do
    # For real execution, look up tool modules from registry
    tools
    |> Enum.reduce(%{}, fn tool, acc ->
      case Synapsis.Tool.Registry.lookup(tool[:name] || tool.name) do
        {:ok, {_type, mod, _opts}} -> Map.put(acc, tool[:name] || tool.name, mod)
        _ -> acc
      end
    end)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop_test.exs -v'`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add apps/synapsis_agent/lib/synapsis/agent/query_loop.ex apps/synapsis_agent/test/synapsis/agent/query_loop_test.exs
git commit -m "feat(agent): wire tool execution into QueryLoop with concurrency partitioning"
```

---

### Task 7: QueryLoop — abort handling

**Files:**
- Modify: `apps/synapsis_agent/lib/synapsis/agent/query_loop.ex`
- Modify: `apps/synapsis_agent/test/synapsis/agent/query_loop_test.exs`

- [ ] **Step 1: Write failing test for abort**

```elixir
  describe "run/2 — abort handling" do
    test "aborts when subscriber process dies" do
      # Start a temporary process as subscriber
      {:ok, subscriber} = Agent.start(fn -> :ok end)

      mock_stream = fn _request, _config ->
        # Kill subscriber during stream
        Agent.stop(subscriber)
        Process.sleep(10)
        send(self(), {:provider_chunk, :done})
        :ok
      end

      ctx = Context.new(
        session_id: "test",
        system_prompt: "test",
        tools: [],
        model: "test",
        provider_config: %{type: "test"},
        subscriber: subscriber,
        agent_config: %{stream_fn: mock_stream}
      )

      state = State.new(messages: [%{role: "user", content: "hi"}])

      # Should detect dead subscriber and abort
      assert {:ok, :aborted, _} = QueryLoop.run(state, ctx)
    end
  end
```

- [ ] **Step 2: Run test to verify behavior**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop_test.exs --only "describe:run/2 — abort" -v'`

- [ ] **Step 3: Fix if needed — the abort check in run/2 already checks `Process.alive?(ctx.subscriber)`**

The existing code should handle this. If the test reveals a gap (e.g., the subscriber dies mid-stream), add an abort check between turns in `do_turn/2`.

- [ ] **Step 4: Run full test suite**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop_test.exs -v'`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add apps/synapsis_agent/lib/synapsis/agent/query_loop.ex apps/synapsis_agent/test/synapsis/agent/query_loop_test.exs
git commit -m "test(agent): add QueryLoop abort handling tests"
```

---

### Task 8: Wire QueryLoop into Session.Worker

**Files:**
- Modify: `apps/synapsis_agent/lib/synapsis/session/worker.ex`
- Modify: `apps/synapsis_agent/lib/synapsis/session/worker/io_handler.ex`

This adds a new code path to Worker: when `session.execution_mode == :query_loop`, use `QueryLoop.run/2` instead of the graph-based Runner.

- [ ] **Step 1: Read current worker.ex handle_cast for :send_message**

Read the full worker to understand the current `send_message` handling, then add the QueryLoop path.

- [ ] **Step 2: Add QueryLoop execution mode to Worker**

In `worker.ex`, add to the struct:

```elixir
# In defstruct, add:
query_loop_task: nil,
execution_mode: :graph,  # :graph | :query_loop
```

Add a new clause in `handle_cast({:send_message, ...})`:

```elixir
# After the existing send_message handling, add query_loop path
defp maybe_start_query_loop(content, _image_parts, state) do
  loop_state = %Synapsis.Agent.QueryLoop.State{
    messages: build_message_history(state) ++ [%{role: "user", content: content}],
    max_turns: Map.get(state.agent, :max_turns, 50)
  }

  loop_ctx = %Synapsis.Agent.QueryLoop.Context{
    session_id: state.session_id,
    system_prompt: build_system_prompt(state),
    tools: Synapsis.Tool.Registry.list_for_llm(),
    model: state.agent[:model] || "claude-sonnet-4-5-20250514",
    provider_config: state.provider_config,
    subscriber: self(),
    project_path: state.project_path,
    working_dir: state.worktree_path || state.project_path
  }

  task = Task.async(fn -> Synapsis.Agent.QueryLoop.run(loop_state, loop_ctx) end)
  %{state | query_loop_task: task}
end
```

Add `handle_info` for QueryLoop events:

```elixir
def handle_info({:query_event, event}, state) when state.execution_mode == :query_loop do
  handle_query_loop_event(event, state)
end

def handle_info({ref, {:ok, reason, final_state}}, state)
    when is_reference(ref) and state.query_loop_task != nil and ref == state.query_loop_task.ref do
  # QueryLoop completed
  Process.demonitor(ref, [:flush])
  persist_query_loop_result(final_state, state)
  {:noreply, %{state | query_loop_task: nil}}
end
```

- [ ] **Step 3: Add event relay in IOHandler**

In `io_handler.ex`, add:

```elixir
def handle_query_loop_event({:stream_chunk, chunk}, state) do
  # Reuse existing PubSub broadcast
  case chunk do
    {:text_delta, text} ->
      Persistence.broadcast(state.session_id, "text_delta", %{text: text})
    {:tool_use_start, name, id} ->
      Persistence.broadcast(state.session_id, "tool_use", %{tool: name, tool_use_id: id})
    _ -> :ok
  end
  {:noreply, state}
end

def handle_query_loop_event({:tool_start, id, name, input}, state) do
  Persistence.broadcast(state.session_id, "tool_start", %{tool_use_id: id, tool: name, input: input})
  {:noreply, state}
end

def handle_query_loop_event({:tool_result, id, result}, state) do
  Persistence.broadcast(state.session_id, "tool_result", %{tool_use_id: id, content: result.content, is_error: result.is_error})
  {:noreply, state}
end

def handle_query_loop_event({:terminal, reason, _final_state}, state) do
  Persistence.update_session_status(state.session_id, "idle")
  Persistence.broadcast(state.session_id, "session_status", %{status: "idle", reason: reason})
  {:noreply, state}
end

def handle_query_loop_event(_event, state), do: {:noreply, state}
```

- [ ] **Step 4: Run compile check**

Run: `devenv shell -- bash -c 'mix compile --warnings-as-errors'`
Expected: compiles cleanly

- [ ] **Step 5: Commit**

```bash
git add apps/synapsis_agent/lib/synapsis/session/worker.ex apps/synapsis_agent/lib/synapsis/session/worker/io_handler.ex
git commit -m "feat(agent): wire QueryLoop execution mode into Session.Worker"
```

---

## Week 2: Context Assembly (Tasks 9–10)

### Task 9: Wire ContextBuilder into QueryLoop.prepare

**Files:**
- Modify: `apps/synapsis_agent/lib/synapsis/agent/query_loop.ex`
- Modify: `apps/synapsis_agent/test/synapsis/agent/query_loop_test.exs`

The existing `ContextBuilder.build_system_prompt/2` already does all 7 layers. We just need to call it from the loop's prepare step instead of using `ctx.system_prompt` as a static value.

- [ ] **Step 1: Write failing test for dynamic system prompt assembly**

Add to `query_loop_test.exs`:

```elixir
  describe "run/2 — context assembly" do
    test "calls ContextBuilder when system_prompt is :dynamic" do
      test_pid = self()
      
      mock_stream = fn request, _config ->
        # Verify system prompt was assembled (not the literal :dynamic atom)
        send(test_pid, {:captured_system, request.system})
        send(test_pid, {:provider_chunk, {:text_delta, "ok"}})
        send(test_pid, {:provider_chunk, :content_block_stop})
        send(test_pid, {:provider_chunk, :done})
        :ok
      end

      ctx = Context.new(
        session_id: "test",
        system_prompt: :dynamic,
        tools: [],
        model: "test",
        provider_config: %{type: "test"},
        subscriber: test_pid,
        agent_config: %{
          stream_fn: mock_stream,
          agent_type: :conversational
        }
      )

      state = State.new(messages: [%{role: "user", content: "hello"}])

      {:ok, :completed, _} = QueryLoop.run(state, ctx)

      assert_received {:captured_system, system_prompt}
      assert is_binary(system_prompt)
      assert system_prompt != ":dynamic"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `:dynamic` atom passed through as-is

- [ ] **Step 3: Add prepare step to do_turn**

In `query_loop.ex`, modify `do_turn/2`:

```elixir
  defp do_turn(state, ctx) do
    ctx = prepare_context(state, ctx)
    notify(ctx, {:stream_start})
    # ... rest unchanged
  end

  defp prepare_context(state, %Context{system_prompt: :dynamic} = ctx) do
    user_message = state.messages |> Enum.reverse() |> Enum.find(& &1.role == "user")
    user_text = if user_message, do: extract_text(user_message.content), else: ""

    prompt = Synapsis.Agent.ContextBuilder.build_system_prompt(
      ctx.agent_config[:agent_type] || :conversational,
      project_id: ctx.agent_config[:project_id],
      session_id: ctx.session_id,
      user_message: user_text,
      agent_config: ctx.agent_config
    )

    %{ctx | system_prompt: prompt}
  end

  defp prepare_context(_state, ctx), do: ctx

  defp extract_text(content) when is_binary(content), do: content
  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1[:type] == "text"))
    |> Enum.map_join(" ", & &1[:text])
  end
  defp extract_text(_), do: ""
```

- [ ] **Step 4: Run test to verify it passes**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop_test.exs -v'`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add apps/synapsis_agent/lib/synapsis/agent/query_loop.ex apps/synapsis_agent/test/synapsis/agent/query_loop_test.exs
git commit -m "feat(agent): wire ContextBuilder into QueryLoop prepare step"
```

---

### Task 10: Week 2 integration test

**Files:**
- Create: `apps/synapsis_agent/test/synapsis/agent/query_loop_context_test.exs`

- [ ] **Step 1: Write integration test that verifies ContextBuilder output flows through**

```elixir
defmodule Synapsis.Agent.QueryLoopContextTest do
  use Synapsis.Agent.DataCase

  alias Synapsis.Agent.QueryLoop
  alias Synapsis.Agent.QueryLoop.{State, Context}

  describe "context assembly integration" do
    test "assembled prompt includes skills section when tools provided" do
      test_pid = self()

      mock_stream = fn request, _config ->
        send(test_pid, {:captured_request, request})
        send(test_pid, {:provider_chunk, {:text_delta, "done"}})
        send(test_pid, {:provider_chunk, :content_block_stop})
        send(test_pid, {:provider_chunk, :done})
        :ok
      end

      ctx = Context.new(
        session_id: "test",
        system_prompt: :dynamic,
        tools: [%{name: "file_read", description: "Reads a file", parameters: %{}}],
        model: "test",
        provider_config: %{type: "test"},
        subscriber: test_pid,
        agent_config: %{stream_fn: mock_stream, agent_type: :conversational}
      )

      state = State.new(messages: [%{role: "user", content: "read a file"}])
      {:ok, :completed, _} = QueryLoop.run(state, ctx)

      assert_received {:captured_request, request}
      assert is_binary(request.system)
      # The assembled prompt should be non-trivial
      assert String.length(request.system) > 50
    end
  end
end
```

- [ ] **Step 2: Run test**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop_context_test.exs -v'`

- [ ] **Step 3: Fix any issues, commit**

```bash
git add apps/synapsis_agent/test/synapsis/agent/query_loop_context_test.exs
git commit -m "test(agent): add QueryLoop context assembly integration test"
```

---

## Week 3: Subagent Spawning (Tasks 11–13)

### Task 11: QueryLoop.fork/2

**Files:**
- Modify: `apps/synapsis_agent/lib/synapsis/agent/query_loop.ex`
- Create: `apps/synapsis_agent/test/synapsis/agent/query_loop_fork_test.exs`

- [ ] **Step 1: Write failing tests for fork/2**

```elixir
# apps/synapsis_agent/test/synapsis/agent/query_loop_fork_test.exs
defmodule Synapsis.Agent.QueryLoopForkTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.QueryLoop
  alias Synapsis.Agent.QueryLoop.Context

  setup do
    parent = Context.new(
      session_id: "parent_sess",
      system_prompt: "parent prompt",
      tools: [
        %{name: "file_read", description: "read", parameters: %{}, permission_level: :read},
        %{name: "file_write", description: "write", parameters: %{}, permission_level: :write},
        %{name: "bash", description: "exec", parameters: %{}, permission_level: :execute}
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
      refute "file_write" in tool_names
      refute "bash" in tool_names
    end

    test "uses explicit tool allowlist", %{parent: parent} do
      child = QueryLoop.fork(parent,
        system_prompt: "task",
        subscriber: self(),
        tool_names: ["file_read", "file_write"]
      )
      tool_names = Enum.map(child.tools, & &1.name)
      assert "file_read" in tool_names
      assert "file_write" in tool_names
      refute "bash" in tool_names
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
    end

    test "allows model override", %{parent: parent} do
      child = QueryLoop.fork(parent,
        system_prompt: "task",
        subscriber: self(),
        model: "claude-haiku-4-5-20251001"
      )
      assert child.model == "claude-haiku-4-5-20251001"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop_fork_test.exs -v'`
Expected: FAIL — `fork/2` not defined

- [ ] **Step 3: Implement fork/2**

Add to `query_loop.ex`:

```elixir
  @max_depth 3
  @read_only_levels [:none, :read]

  @doc """
  Creates a scoped child context for subagent execution.
  Inherits project/working dir, gets restricted tools, custom prompt.
  """
  @spec fork(Context.t(), keyword()) :: Context.t()
  def fork(%Context{} = parent, opts) do
    subscriber = Keyword.fetch!(opts, :subscriber)
    system_prompt = Keyword.fetch!(opts, :system_prompt)
    tools = filter_fork_tools(parent.tools, Keyword.get(opts, :tool_names, :read_only))

    %Context{
      session_id: parent.session_id,
      system_prompt: system_prompt,
      tools: tools,
      model: Keyword.get(opts, :model, parent.model),
      provider_config: parent.provider_config,
      subscriber: subscriber,
      abort_ref: make_ref(),
      project_path: parent.project_path,
      working_dir: parent.working_dir,
      depth: parent.depth + 1,
      streaming_tools_enabled: parent.streaming_tools_enabled,
      agent_config: parent.agent_config
    }
  end

  @doc "Returns true if depth allows spawning subagents."
  @spec can_fork?(Context.t()) :: boolean()
  def can_fork?(%Context{depth: d}), do: d < @max_depth

  defp filter_fork_tools(tools, :read_only) do
    Enum.filter(tools, fn tool ->
      level = Map.get(tool, :permission_level, :write)
      level in @read_only_levels
    end)
  end

  defp filter_fork_tools(tools, names) when is_list(names) do
    name_set = MapSet.new(names)
    Enum.filter(tools, fn tool -> tool.name in name_set end)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop_fork_test.exs -v'`
Expected: all 6 tests pass

- [ ] **Step 5: Commit**

```bash
git add apps/synapsis_agent/lib/synapsis/agent/query_loop.ex apps/synapsis_agent/test/synapsis/agent/query_loop_fork_test.exs
git commit -m "feat(agent): add QueryLoop.fork/2 for subagent context creation"
```

---

### Task 12: Enhance Task tool with QueryLoop.fork path

**Files:**
- Modify: `apps/synapsis_core/lib/synapsis/tool/task.ex`

- [ ] **Step 1: Add query_loop execution mode to Task tool**

Add a new clause to `execute/2` that uses `QueryLoop` directly when `context[:query_context]` is present:

```elixir
  # In execute/2, add before the existing cond block:
  defp execute_via_query_loop(prompt, input, context) do
    query_ctx = context[:query_context]

    unless Synapsis.Agent.QueryLoop.can_fork?(query_ctx) do
      {:error, "Maximum subagent depth (#{query_ctx.depth}) reached"}
    else
      child_ctx = Synapsis.Agent.QueryLoop.fork(query_ctx,
        system_prompt: build_subagent_prompt(prompt),
        subscriber: self(),
        tool_names: input["tools"] || :read_only,
        model: input["model"]
      )

      child_state = %Synapsis.Agent.QueryLoop.State{
        messages: [%{role: "user", content: prompt}],
        max_turns: 50
      }

      case Synapsis.Agent.QueryLoop.run(child_state, child_ctx) do
        {:ok, :completed, final_state} ->
          summary = extract_final_response(final_state.messages)
          {:ok, summary}

        {:ok, reason, _state} ->
          {:error, "Subagent terminated: #{reason}"}
      end
    end
  end

  defp build_subagent_prompt(task) do
    """
    You are a subagent for Synapsis. Given the task below, use available tools to complete it.
    Complete the task fully. When done, respond with a concise report.

    Your strengths:
    - Searching for code, configurations, and patterns across codebases
    - Analyzing multiple files to understand system architecture
    - Performing multi-step research tasks

    Guidelines:
    - Search broadly when you don't know where something lives
    - Be thorough: check multiple locations, consider different naming conventions
    - NEVER create files unless absolutely necessary

    Task: #{task}
    """
  end

  defp extract_final_response(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(& &1.role == "assistant")
    |> case do
      %{content: content} when is_binary(content) -> content
      %{content: blocks} when is_list(blocks) ->
        blocks
        |> Enum.filter(&(is_map(&1) and &1[:type] == "text"))
        |> Enum.map_join("\n", & &1[:text])
      _ -> "Subagent completed without response."
    end
  end
```

- [ ] **Step 2: Modify execute/2 to check for query_context**

```elixir
  def execute(input, context) do
    prompt = input["prompt"]

    if context[:query_context] do
      execute_via_query_loop(prompt, input, context)
    else
      # Existing SessionBridge path (unchanged)
      mode = input["mode"] || "foreground"
      # ... rest of existing code
    end
  end
```

- [ ] **Step 3: Run compile check**

Run: `devenv shell -- bash -c 'mix compile --warnings-as-errors'`

- [ ] **Step 4: Commit**

```bash
git add apps/synapsis_core/lib/synapsis/tool/task.ex
git commit -m "feat(tool): add QueryLoop.fork path to task tool for subagent spawning"
```

---

### Task 13: Subagent integration test

**Files:**
- Modify: `apps/synapsis_agent/test/synapsis/agent/query_loop_fork_test.exs`

- [ ] **Step 1: Write integration test for subagent via task tool**

```elixir
  describe "subagent integration" do
    test "task tool spawns subagent via QueryLoop.fork" do
      test_pid = self()
      turn = :counters.new(1, [:atomics])

      mock_stream = fn request, _config ->
        count = :counters.get(turn, 1)
        :counters.add(turn, 1, 1)

        if count == 0 do
          # Parent turn 1: calls task tool
          send(test_pid, {:provider_chunk, {:tool_use_start, "task", "tu_task"}})
          send(test_pid, {:provider_chunk, {:tool_input_delta, ~s({"prompt":"count to 3"})}})
          send(test_pid, {:provider_chunk, :content_block_stop})
          send(test_pid, {:provider_chunk, :done})
        else
          # Parent turn 2 or subagent: simple completion
          send(test_pid, {:provider_chunk, {:text_delta, "Done: 1, 2, 3"}})
          send(test_pid, {:provider_chunk, :content_block_stop})
          send(test_pid, {:provider_chunk, :done})
        end
        :ok
      end

      # TaskTool mock that uses QueryLoop.fork internally
      defmodule MockTaskTool do
        use Synapsis.Tool
        def name, do: "task"
        def description, do: "spawn subagent"
        def parameters, do: %{"type" => "object", "properties" => %{"prompt" => %{"type" => "string"}}, "required" => ["prompt"]}
        def permission_level, do: :none

        def execute(%{"prompt" => prompt}, context) do
          query_ctx = context[:query_context]
          child_ctx = Synapsis.Agent.QueryLoop.fork(query_ctx,
            system_prompt: "You are a helper. #{prompt}",
            subscriber: self()
          )
          child_state = Synapsis.Agent.QueryLoop.State.new(
            messages: [%{role: "user", content: prompt}]
          )
          case Synapsis.Agent.QueryLoop.run(child_state, child_ctx) do
            {:ok, :completed, final} ->
              last = Enum.find(Enum.reverse(final.messages), & &1.role == "assistant")
              {:ok, last.content |> Enum.map_join("", & &1[:text])}
            {:ok, reason, _} -> {:error, "#{reason}"}
          end
        end
      end

      ctx = Context.new(
        session_id: "test",
        system_prompt: "test",
        tools: [%{name: "task", description: "spawn", parameters: %{}, permission_level: :none}],
        model: "test",
        provider_config: %{type: "test"},
        subscriber: test_pid,
        agent_config: %{stream_fn: mock_stream, tool_modules: %{"task" => MockTaskTool}}
      )

      state = State.new(messages: [%{role: "user", content: "count to 3 via subagent"}])
      assert {:ok, :completed, final} = QueryLoop.run(state, ctx)
      assert final.turn_count >= 2
    end

    test "refuses when depth >= 3" do
      parent = Context.new(
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
```

- [ ] **Step 2: Run tests**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop_fork_test.exs -v'`

- [ ] **Step 3: Fix issues, commit**

```bash
git add apps/synapsis_agent/test/synapsis/agent/query_loop_fork_test.exs
git commit -m "test(agent): add subagent integration tests via QueryLoop.fork"
```

---

## Week 4: Streaming Tool Executor (Tasks 14–17)

### Task 14: StreamingExecutor struct and add_tool/3

**Files:**
- Create: `apps/synapsis_agent/lib/synapsis/agent/streaming_executor.ex`
- Create: `apps/synapsis_agent/test/synapsis/agent/streaming_executor_test.exs`

- [ ] **Step 1: Write failing tests for StreamingExecutor**

```elixir
# apps/synapsis_agent/test/synapsis/agent/streaming_executor_test.exs
defmodule Synapsis.Agent.StreamingExecutorTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.StreamingExecutor

  defmodule FastReadTool do
    use Synapsis.Tool
    def name, do: "fast_read"
    def description, do: "fast read"
    def parameters, do: %{}
    def permission_level, do: :read
    def execute(_input, _ctx) do
      Process.sleep(10)
      {:ok, "fast_read_result"}
    end
  end

  defmodule SlowWriteTool do
    use Synapsis.Tool
    def name, do: "slow_write"
    def description, do: "slow write"
    def parameters, do: %{}
    def permission_level, do: :write
    def execute(_input, _ctx) do
      Process.sleep(50)
      {:ok, "slow_write_result"}
    end
  end

  @tool_map %{"fast_read" => FastReadTool, "slow_write" => SlowWriteTool}
  @ctx %{session_id: "test"}

  describe "new/2" do
    test "creates empty executor" do
      exec = StreamingExecutor.new(@tool_map, @ctx)
      assert exec.tools == []
      assert exec.completed == []
    end
  end

  describe "add_tool/2" do
    test "starts concurrent-safe tool immediately" do
      exec = StreamingExecutor.new(@tool_map, @ctx)
      exec = StreamingExecutor.add_tool(exec, %{id: "r1", name: "fast_read", input: %{}})
      
      # Tool should be executing (has a task)
      assert length(exec.tools) == 1
      assert hd(exec.tools).status == :executing
    end

    test "queues serial tool when concurrent tools are running" do
      exec = StreamingExecutor.new(@tool_map, @ctx)
      exec = StreamingExecutor.add_tool(exec, %{id: "r1", name: "fast_read", input: %{}})
      exec = StreamingExecutor.add_tool(exec, %{id: "w1", name: "slow_write", input: %{}})

      # Write tool should be queued, not executing
      write_tool = Enum.find(exec.tools, & &1.id == "w1")
      assert write_tool.status == :queued
    end
  end

  describe "get_completed_results/1" do
    test "returns completed tool results" do
      exec = StreamingExecutor.new(@tool_map, @ctx)
      exec = StreamingExecutor.add_tool(exec, %{id: "r1", name: "fast_read", input: %{}})
      
      # Wait for completion
      Process.sleep(30)
      
      {results, exec} = StreamingExecutor.get_completed_results(exec)
      assert length(results) >= 1
      assert hd(results).tool_use_id == "r1"
    end

    test "returns empty when nothing completed" do
      exec = StreamingExecutor.new(@tool_map, @ctx)
      {results, _exec} = StreamingExecutor.get_completed_results(exec)
      assert results == []
    end
  end

  describe "get_remaining_results/1" do
    test "waits for all in-flight tools and returns in order" do
      exec = StreamingExecutor.new(@tool_map, @ctx)
      exec = StreamingExecutor.add_tool(exec, %{id: "r1", name: "fast_read", input: %{}})
      exec = StreamingExecutor.add_tool(exec, %{id: "r2", name: "fast_read", input: %{}})

      {results, _exec} = StreamingExecutor.get_remaining_results(exec)
      assert length(results) == 2
      assert Enum.map(results, & &1.tool_use_id) == ["r1", "r2"]
    end

    test "returns results in submission order not completion order" do
      exec = StreamingExecutor.new(@tool_map, @ctx)
      # Add slow then fast — fast finishes first but results should be in add order
      exec = StreamingExecutor.add_tool(exec, %{id: "w1", name: "slow_write", input: %{}})

      # Wait for write to start, then add fast read
      Process.sleep(5)
      exec = StreamingExecutor.add_tool(exec, %{id: "r1", name: "fast_read", input: %{}})

      {results, _exec} = StreamingExecutor.get_remaining_results(exec)
      assert Enum.map(results, & &1.tool_use_id) == ["w1", "r1"]
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/streaming_executor_test.exs -v'`
Expected: FAIL — `StreamingExecutor` not defined

- [ ] **Step 3: Implement StreamingExecutor**

```elixir
# apps/synapsis_agent/lib/synapsis/agent/streaming_executor.ex
defmodule Synapsis.Agent.StreamingExecutor do
  @moduledoc """
  Eagerly dispatches tool calls as they arrive during LLM streaming.
  
  Concurrent-safe tools start immediately. Serial tools queue until
  all prior tools complete. Results are always returned in submission order.
  """

  alias Synapsis.Agent.QueryLoop.Executor

  @concurrent_permission_levels [:none, :read]

  defmodule TrackedTool do
    @moduledoc false
    defstruct [:id, :name, :input, :status, :concurrent_safe?, :task_ref, :result, :order]
    # status: :queued | :executing | :completed
  end

  @type t :: %__MODULE__{
          tools: [TrackedTool.t()],
          completed: [map()],
          tool_map: map(),
          context: map(),
          next_order: non_neg_integer(),
          serial_running?: boolean()
        }

  defstruct tools: [],
            completed: [],
            tool_map: %{},
            context: %{},
            next_order: 0,
            serial_running?: false

  @spec new(map(), map()) :: t()
  def new(tool_map, context) do
    %__MODULE__{tool_map: tool_map, context: context}
  end

  @spec add_tool(t(), map()) :: t()
  def add_tool(%__MODULE__{} = exec, %{id: id, name: name, input: input}) do
    safe? = concurrent_safe?(name, exec.tool_map)

    tracked = %TrackedTool{
      id: id,
      name: name,
      input: input,
      status: :queued,
      concurrent_safe?: safe?,
      order: exec.next_order
    }

    exec = %{exec | tools: exec.tools ++ [tracked], next_order: exec.next_order + 1}
    maybe_start_tools(exec)
  end

  @spec get_completed_results(t()) :: {[map()], t()}
  def get_completed_results(%__MODULE__{} = exec) do
    exec = check_completions(exec)

    {completed, remaining} = Enum.split_with(exec.tools, & &1.status == :completed)

    results =
      completed
      |> Enum.sort_by(& &1.order)
      |> Enum.map(& &1.result)

    exec = %{exec | tools: remaining}
    exec = maybe_start_tools(exec)
    {results, exec}
  end

  @spec get_remaining_results(t()) :: {[map()], t()}
  def get_remaining_results(%__MODULE__{} = exec) do
    # Wait for all in-flight tools
    exec = wait_all(exec)

    results =
      exec.tools
      |> Enum.sort_by(& &1.order)
      |> Enum.map(& &1.result)

    {results, %{exec | tools: []}}
  end

  # -- Private --

  defp concurrent_safe?(name, tool_map) do
    case Map.get(tool_map, name) do
      nil -> false
      mod ->
        level = if function_exported?(mod, :permission_level, 0), do: mod.permission_level(), else: :write
        level in @concurrent_permission_levels
    end
  end

  defp maybe_start_tools(%__MODULE__{} = exec) do
    any_serial_running? = Enum.any?(exec.tools, fn t ->
      t.status == :executing and not t.concurrent_safe?
    end)

    if any_serial_running? do
      exec
    else
      tools = Enum.map(exec.tools, fn
        %TrackedTool{status: :queued, concurrent_safe?: true} = t ->
          start_tool(t, exec)

        %TrackedTool{status: :queued, concurrent_safe?: false} = t ->
          # Only start serial if no other tool is executing
          any_executing? = Enum.any?(exec.tools, & &1.status == :executing)
          if any_executing?, do: t, else: start_tool(t, exec)

        t -> t
      end)

      %{exec | tools: tools}
    end
  end

  defp start_tool(%TrackedTool{} = t, exec) do
    parent = self()
    ref = make_ref()

    Task.start(fn ->
      result = Executor.run_one(%{name: t.name, input: t.input}, exec.tool_map, exec.context)
      send(parent, {:streaming_tool_done, ref, t.id, result})
    end)

    %{t | status: :executing, task_ref: ref}
  end

  defp check_completions(%__MODULE__{} = exec) do
    # Drain mailbox for completed tools
    tools = Enum.map(exec.tools, fn t ->
      if t.status == :executing do
        receive do
          {:streaming_tool_done, ref, id, result} when ref == t.task_ref and id == t.id ->
            %{t | status: :completed, result: format_result(t.id, result)}
        after
          0 -> t
        end
      else
        t
      end
    end)

    %{exec | tools: tools}
  end

  defp wait_all(%__MODULE__{} = exec) do
    tools = Enum.map(exec.tools, fn
      %TrackedTool{status: :queued} = t ->
        # Start any remaining queued tools
        started = start_tool(t, exec)
        wait_for_tool(started)

      %TrackedTool{status: :executing} = t ->
        wait_for_tool(t)

      t -> t
    end)

    %{exec | tools: tools}
  end

  defp wait_for_tool(%TrackedTool{status: :completed} = t), do: t

  defp wait_for_tool(%TrackedTool{task_ref: ref, id: id} = t) do
    receive do
      {:streaming_tool_done, ^ref, ^id, result} ->
        %{t | status: :completed, result: format_result(id, result)}
    after
      60_000 ->
        %{t | status: :completed, result: %{tool_use_id: id, content: "Tool execution timed out", is_error: true}}
    end
  end

  defp format_result(id, {:ok, result}) when is_binary(result) do
    %{tool_use_id: id, content: result, is_error: false}
  end

  defp format_result(id, {:ok, result}) do
    %{tool_use_id: id, content: inspect(result), is_error: false}
  end

  defp format_result(id, {:error, reason}) when is_binary(reason) do
    %{tool_use_id: id, content: reason, is_error: true}
  end

  defp format_result(id, {:error, reason}) do
    %{tool_use_id: id, content: inspect(reason), is_error: true}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/streaming_executor_test.exs -v'`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add apps/synapsis_agent/lib/synapsis/agent/streaming_executor.ex apps/synapsis_agent/test/synapsis/agent/streaming_executor_test.exs
git commit -m "feat(agent): add StreamingExecutor for eager tool dispatch during streaming"
```

---

### Task 15: Integrate StreamingExecutor into QueryLoop.stream_model

**Files:**
- Modify: `apps/synapsis_agent/lib/synapsis/agent/query_loop.ex`
- Modify: `apps/synapsis_agent/test/synapsis/agent/query_loop_test.exs`

- [ ] **Step 1: Write failing test for streaming tool execution**

```elixir
  describe "run/2 — streaming tool execution" do
    defmodule TimedReadTool do
      use Synapsis.Tool
      def name, do: "timed_read"
      def description, do: "timed read"
      def parameters, do: %{"type" => "object", "properties" => %{"n" => %{"type" => "integer"}}}
      def permission_level, do: :read
      def execute(%{"n" => n}, _ctx), do: {:ok, "result_#{n}"}
    end

    test "tool execution overlaps with streaming when streaming_tools_enabled" do
      test_pid = self()
      turn = :counters.new(1, [:atomics])

      mock_stream = fn _request, _config ->
        count = :counters.get(turn, 1)
        :counters.add(turn, 1, 1)

        if count == 0 do
          # Emit tool_use_complete early, then more text
          send(test_pid, {:provider_chunk, {:tool_use_start, "timed_read", "tu_1"}})
          send(test_pid, {:provider_chunk, {:tool_use_complete, "timed_read", %{"n" => 1}}})
          # Tool should start executing NOW while we continue streaming
          Process.sleep(5)
          send(test_pid, {:provider_chunk, {:text_delta, "Checking..."}})
          send(test_pid, {:provider_chunk, :content_block_stop})
          send(test_pid, {:provider_chunk, :done})
        else
          send(test_pid, {:provider_chunk, {:text_delta, "All done."}})
          send(test_pid, {:provider_chunk, :content_block_stop})
          send(test_pid, {:provider_chunk, :done})
        end
        :ok
      end

      ctx = Context.new(
        session_id: "test",
        system_prompt: "test",
        tools: [%{name: "timed_read", description: "reads", parameters: %{}, permission_level: :read}],
        model: "test",
        provider_config: %{type: "test"},
        subscriber: test_pid,
        streaming_tools_enabled: true,
        agent_config: %{
          stream_fn: mock_stream,
          tool_modules: %{"timed_read" => TimedReadTool}
        }
      )

      state = State.new(messages: [%{role: "user", content: "read 1"}])
      assert {:ok, :completed, final} = QueryLoop.run(state, ctx)
      assert final.turn_count == 2
    end
  end
```

- [ ] **Step 2: Run test to verify current behavior**

- [ ] **Step 3: Add StreamingExecutor integration to stream_model**

Modify `collect_stream_events/4` to accept and use a `StreamingExecutor` when `streaming_tools_enabled` is true. On `tool_use_complete` events, call `StreamingExecutor.add_tool/2`. After stream ends, call `get_remaining_results/1`.

The key change: `stream_model/2` checks `ctx.streaming_tools_enabled`. If true, it creates a `StreamingExecutor` and feeds tool blocks to it during streaming. The results come back pre-computed.

- [ ] **Step 4: Run full test suite**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop_test.exs -v'`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add apps/synapsis_agent/lib/synapsis/agent/query_loop.ex apps/synapsis_agent/test/synapsis/agent/query_loop_test.exs
git commit -m "feat(agent): integrate StreamingExecutor into QueryLoop for eager tool dispatch"
```

---

### Task 16: Fallback to batch execution

**Files:**
- Modify: `apps/synapsis_agent/lib/synapsis/agent/query_loop.ex`
- Modify: `apps/synapsis_agent/test/synapsis/agent/query_loop_test.exs`

- [ ] **Step 1: Write test that streaming_tools_enabled=false uses batch path**

```elixir
  describe "run/2 — batch fallback" do
    test "falls back to batch when streaming_tools_enabled is false" do
      test_pid = self()
      turn = :counters.new(1, [:atomics])

      mock_stream = fn _request, _config ->
        count = :counters.get(turn, 1)
        :counters.add(turn, 1, 1)

        if count == 0 do
          send(test_pid, {:provider_chunk, {:tool_use_start, "timed_read", "tu_1"}})
          send(test_pid, {:provider_chunk, {:tool_use_complete, "timed_read", %{"n" => 1}}})
          send(test_pid, {:provider_chunk, :content_block_stop})
          send(test_pid, {:provider_chunk, :done})
        else
          send(test_pid, {:provider_chunk, {:text_delta, "Done."}})
          send(test_pid, {:provider_chunk, :content_block_stop})
          send(test_pid, {:provider_chunk, :done})
        end
        :ok
      end

      ctx = Context.new(
        session_id: "test",
        system_prompt: "test",
        tools: [%{name: "timed_read", description: "reads", parameters: %{}, permission_level: :read}],
        model: "test",
        provider_config: %{type: "test"},
        subscriber: test_pid,
        streaming_tools_enabled: false,  # <-- batch mode
        agent_config: %{stream_fn: mock_stream, tool_modules: %{"timed_read" => TimedReadTool}}
      )

      state = State.new(messages: [%{role: "user", content: "read"}])
      assert {:ok, :completed, final} = QueryLoop.run(state, ctx)
      assert final.turn_count == 2
    end
  end
```

- [ ] **Step 2: Verify it passes (batch path is the default from Week 1)**

Run: `devenv shell -- bash -c 'cd apps/synapsis_agent && mix test test/synapsis/agent/query_loop_test.exs -v'`

- [ ] **Step 3: Commit if all green**

```bash
git add apps/synapsis_agent/test/synapsis/agent/query_loop_test.exs
git commit -m "test(agent): verify batch fallback when streaming tools disabled"
```

---

### Task 17: Final verification

- [ ] **Step 1: Run full compile check**

Run: `devenv shell -- bash -c 'mix compile --warnings-as-errors'`
Expected: zero warnings

- [ ] **Step 2: Run format check**

Run: `devenv shell -- bash -c 'mix format --check-formatted'`
Expected: all files formatted

- [ ] **Step 3: Run full test suite**

Run: `devenv shell -- bash -c 'mix test'`
Expected: all tests pass, no regressions

- [ ] **Step 4: Commit any final fixes**

```bash
git commit -m "chore: final verification — all tests pass"
```

---

## Verification

After completing all tasks:

```bash
devenv shell -- bash -c 'mix compile --warnings-as-errors'
devenv shell -- bash -c 'mix format --check-formatted'
devenv shell -- bash -c 'mix test'
```

Manual smoke test in IEx:

```elixir
# Start a session with query_loop mode
{:ok, session} = Synapsis.Sessions.create("/tmp/test", execution_mode: :query_loop)
Synapsis.Sessions.send_message(session.id, "What files are in this directory?")
# Should see streaming events and tool execution
```

---

## Dependency Graph

```
Task 1 (State) ──→ Task 2 (Context) ──→ Task 5 (QueryLoop.run) ──→ Task 6 (tool path)
                                              │                          │
Task 3 (partition) ──→ Task 4 (Executor.run) ─┘                          │
                                                                         ↓
                                              Task 7 (abort) ──→ Task 8 (wire Worker)
                                                                         │
                                              Task 9 (ContextBuilder) ←──┘
                                                                         │
                                              Task 10 (integration) ←────┘
                                                                         │
                                              Task 11 (fork) ←──────────┘
                                                    │
                                              Task 12 (Task tool) ←── Task 11
                                                    │
                                              Task 13 (subagent test) ←── Task 12
                                                    │
                                              Task 14 (StreamingExecutor) (independent of 11-13)
                                                    │
                                              Task 15 (integrate streaming) ←── Task 14
                                                    │
                                              Task 16 (fallback test)
                                                    │
                                              Task 17 (final verification)
```

**Parallelizable:** Tasks 1+3 can run in parallel. Tasks 11+14 can run in parallel.
