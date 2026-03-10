# Executor Pipeline API Contract

## Status

**Module**: `Synapsis.Tool.Executor` (`apps/synapsis_core/lib/synapsis/tool/executor.ex`)

## Types

```elixir
@type tool_call :: %{
        id: String.t(),
        name: String.t(),
        input: map()
      }

@type context :: Synapsis.Tool.context()

@type execute_result ::
        {:ok, String.t()}
        | {:error, term()}
        | {:pending_approval, reference()}

@type batch_result :: [{call_id :: String.t(), execute_result()}]

@type dispatch_entry ::
        {:module, module(), keyword()}
        | {:process, pid(), keyword()}
```

## Public API

### `execute/2`

Executes a single tool call through the full pipeline.

```elixir
@spec execute(tool_call(), context()) :: execute_result()
def execute(tool_call, context)
```

**Pipeline stages**:

1. **Registry lookup** — `Synapsis.Tool.Registry.lookup(tool_call.name)` to resolve dispatch entry.
2. **Enabled check** — if the resolved module implements `enabled?/0` and returns `false`, return `{:error, :tool_disabled}`.
3. **Permission check** — `Synapsis.Tool.Permission.check(tool_call.name, tool_call.input, context)`.
   - `:allowed` — proceed to dispatch.
   - `:denied` — return `{:error, :permission_denied}`.
   - `:ask` — broadcast approval request, return `{:pending_approval, ref}`. The caller (Session.Worker) parks the tool call and waits for user response.
4. **Dispatch** — execute via the appropriate dispatch mode (see below).
5. **Result handling** — normalize the return value to `{:ok, String.t()} | {:error, term()}`.
6. **Side effect broadcast** — if the tool declares `side_effects/0`, broadcast each effect to `"tool_effects:#{session_id}"` via PubSub.

**Error handling**: All dispatch errors (exceptions, exits, timeouts) are caught and normalized to `{:error, reason}`. The executor never raises.

### `execute_batch/2`

Executes multiple tool calls in parallel with write serialization.

```elixir
@spec execute_batch([tool_call()], context()) :: batch_result()
def execute_batch(tool_calls, context)
```

**Behavior**:

1. **Group by write target** — tool calls that write to the same file path are grouped and serialized. All other calls run in parallel.
2. **Batched permission check** — all tool calls that require `:ask` permission are collected and presented to the user as a single batch approval request. The user can approve/deny individual calls or approve/deny all.
3. **Parallel execution** — uses `Task.async_stream/3` under `Synapsis.Tool.TaskSupervisor` with `max_concurrency: System.schedulers_online()`.
4. **Result collection** — returns a list of `{call_id, result}` tuples in the same order as the input list.

**Write serialization rules**:
- Two tool calls conflict if they both target the same file path (extracted from `input["path"]` or `input["file_path"]`).
- Conflicting calls are executed sequentially in input order.
- Non-conflicting calls execute in parallel.

### `execute_approved/2`

Executes a tool call that was previously pending approval and has now been approved by the user.

```elixir
@spec execute_approved(tool_call(), context()) :: {:ok, String.t()} | {:error, term()}
def execute_approved(tool_call, context)
```

**Behavior**:
- Skips the permission check (already approved).
- Runs stages 1, 2, 4, 5, 6 of the `execute/2` pipeline.
- Called by `Synapsis.Session.Worker` when it receives an approval event.

## Dispatch Modes

### Module dispatch (built-in tools)

```elixir
{:module, module, opts}
```

Execution:
```elixir
Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
  module.execute(input, context)
end)
|> Task.yield(timeout)
```

- `timeout` is read from `opts[:timeout]` or defaults to `30_000` ms.
- On timeout, the task is shut down via `Task.shutdown/1`.
- On `{:exit, reason}`, the error is wrapped as `{:error, {:exit, reason}}`.

### Process dispatch (plugin tools)

```elixir
{:process, pid, opts}
```

Execution:
```elixir
GenServer.call(pid, {:execute, tool_name, input, context}, timeout)
```

- `timeout` from `opts[:timeout]` or `30_000` ms.
- `:exit` from dead/unreachable process is caught and returned as `{:error, {:exit, reason}}`.

## Side Effect Broadcasting

After successful execution, the executor checks for side effects:

```elixir
if function_exported?(module, :side_effects, 0) do
  for effect <- module.side_effects() do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "tool_effects:#{context.session_id}",
      {:tool_effect, effect, %{
        session_id: context.session_id,
        tool_name: tool_call.name,
        tool_call_id: tool_call.id
      }}
    )
  end
end
```

**Known side effects**:
- `:file_changed` — a file was created, modified, or deleted
- `:directory_changed` — directory structure changed
- `:process_spawned` — an external process was started

## Error Normalization

All errors returned by the executor follow this normalization:

| Source | Normalized form |
|---|---|
| Tool returns `{:error, binary}` | `{:error, binary}` (pass-through) |
| Tool returns `{:error, atom}` | `{:error, atom}` (pass-through) |
| Tool raises an exception | `{:error, Exception.message(e)}` |
| Task timeout | `{:error, :timeout}` |
| Task exit | `{:error, {:exit, reason}}` |
| GenServer exit | `{:error, {:exit, reason}}` |
| Tool not found | `{:error, "Unknown tool: #{name}"}` |
| Tool disabled | `{:error, :tool_disabled}` |
| Permission denied | `{:error, :permission_denied}` |
