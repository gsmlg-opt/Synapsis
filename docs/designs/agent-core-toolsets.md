# Design — Agent Core Toolsets: Stream Guard, Sandbox Callback Bridge, Session Checkpoints

- **Status:** Proposed
- **Date:** 2026-06-12
- **Related:** ADR-004 (process-per-session), ADR-006 (Concord storage),
  ADR-008 (gen_statem session shell), `docs/designs/synapsis-harness/adr-0004-streaming-persistence.md`

## Context

This design covers three capabilities for the agent runtime:

1. **Stream Guard** — declarative interception rules applied to the LLM
   token stream, able to abort a turn before forbidden content reaches
   downstream consumers.
2. **Sandbox Callback Bridge** — a JSON-RPC channel over a Port's stdio
   that lets sandboxed runtimes (persistent Python, WASI containers)
   invoke host tools mid-execution.
3. **Session Checkpoints** — snapshot/rollback of session state around
   destructive edits, so a failed patch can "time-travel" the
   conversation back to a consistent point.

An earlier draft of this design proposed a self-contained supervision
tree (`SessionSupervisor` with `:one_for_all`, per-session registry,
snapshot stack held only in process memory). Review found that draft
internally inconsistent — its violation path (`exit/1`) combined with
`:one_for_all` and in-memory-only snapshots meant any rule violation
destroyed the very state needed for the promised rollback — and several
of its sketches had production bugs (unframed Port reads, bare `spawn`,
`GenServer.reply` on a `nil` caller, emit-before-check streaming).

This revision fixes those defects and, more importantly, lands each
component inside Synapsis's existing architecture instead of building a
parallel one. Synapsis already has the substrate the draft reinvented:

| Draft component | Existing Synapsis substrate |
|---|---|
| `SessionRunner` (`:gen_statem`) | `Synapsis.Session.Worker` gen_statem (ADR-008) |
| Per-session supervision | per-session supervisors in `synapsis_agent` |
| Snapshot persistence | Concord per-turn snapshots (ADR-006) |
| Token stream plumbing | provider transports in `synapsis_provider` |
| Port-based execution | tool execution guardrails in `synapsis_core` |
| File rollback | git/worktree helpers in `synapsis_core` |

What is genuinely new is (a) the interception rule layer over the token
stream, (b) the JSON-RPC reverse-invocation protocol for sandboxes, and
(c) an explicit checkpoint stack with file-level rollback. This document
designs those three things only.

## Decision Summary

- Stream Guard lives in `synapsis_provider` as a pure scanning stage
  between transport event normalization and PubSub broadcast. It uses a
  **hold-back buffer** so no unchecked byte is ever emitted, matches on
  **bytes** (not graphemes), and reports violations as **data**
  (`{:violation, rule}`) — never `exit/1`.
- The Sandbox Callback Bridge lives in `synapsis_plugin` beside the MCP
  machinery. The Port uses **line framing**; tool dispatch runs under
  `Task.Supervisor.async_nolink` with a deadline; every request gets a
  JSON-RPC response, including on crash and timeout.
- Checkpoints extend `Session.Worker`'s gen_statem data with a snapshot
  stack (cheap by immutability), but durability comes from the existing
  Concord turn snapshots, and **file** rollback comes from git — a
  checkpoint records the workspace's git state, not just a checksum.
- Supervision reuses the existing per-session tree. Sandbox bridges are
  children of the session's tool supervision; the LLM stream task is
  **monitored** by the worker (`{:DOWN, ...}`), not allowed to crash it.
  No `:one_for_all`; the worker is the durable spine and must outlive
  its ephemeral collaborators.

## Component 1 — Stream Guard

### Placement

Provider transports already normalize SSE/HTTP chunks into domain
events. Stream Guard is a stage applied to the normalized text deltas
before they reach the session worker and PubSub. It is a **pure
function over (chunk, state)** — no process, no receive loop. (The
earlier draft's `Stream.repeatedly(fn -> receive ... end)` ran its
`receive` in whichever process consumed the stream and did selective
receive against a busy mailbox; both problems disappear when the guard
is a function the transport calls inline.)

### The hold-back invariant

A scanner that emits each chunk and only then checks a sliding window
detects violations *after* the offending prefix has already been
streamed downstream. To actually intercept, the guard must never emit a
byte that could still be part of a forming pattern:

> With `max_len` = the longest rule pattern in bytes, the guard always
> retains the last `max_len - 1` bytes and emits only the prefix older
> than that. On `:eof`, the retained tail is checked and flushed.

This bounds added latency to one pattern-length of text, which is
negligible against token cadence.

### Bytes, not graphemes

Network chunks split UTF-8 codepoints. `String.slice/2` and
`String.contains?/2` on a binary ending mid-codepoint misbehave. The
guard operates on raw binaries with `:binary.match/2` (which compiles
patterns once via `:binary.compile_pattern/1`) and lets the UI layer
worry about display boundaries. Held-back bytes also naturally buffer
incomplete codepoints.

### Violations are data

```elixir
defmodule Synapsis.Provider.StreamGuard do
  @moduledoc """
  Pure interception stage over normalized text deltas.
  Holds back `max_len - 1` bytes so no unchecked byte is emitted.
  """

  defstruct [:pattern, :max_len, held: <<>>]

  def new(rules) when is_list(rules) and rules != [] do
    %__MODULE__{
      pattern: :binary.compile_pattern(rules),
      max_len: rules |> Enum.map(&byte_size/1) |> Enum.max()
    }
  end

  @doc "Returns {:ok, emit_binary, guard} | {:violation, matched_rule}"
  def scan(%__MODULE__{} = g, chunk) when is_binary(chunk) do
    buffer = g.held <> chunk

    case :binary.match(buffer, g.pattern) do
      {pos, len} ->
        {:violation, binary_part(buffer, pos, len)}

      :nomatch ->
        keep = min(g.max_len - 1, byte_size(buffer))
        emit = binary_part(buffer, 0, byte_size(buffer) - keep)
        held = binary_part(buffer, byte_size(buffer) - keep, keep)
        {:ok, emit, %{g | held: held}}
    end
  end

  @doc "Flush at end of stream; final chance to match the tail."
  def finish(%__MODULE__{} = g) do
    case :binary.match(g.held, g.pattern) do
      {pos, len} -> {:violation, binary_part(g.held, pos, len)}
      :nomatch -> {:ok, g.held}
    end
  end
end
```

On `{:violation, rule}` the transport stops consuming (closing the
connection via its existing cancellation path) and sends the worker a
normal domain event, e.g. `{:stream_violation, rule}`. The worker — not
an exit signal — decides what happens next: abort the turn, pop a
checkpoint (Component 3), append a correction message, re-prompt. The
draft's `exit({:rule_violation, ...})` is rejected: an exit in the
consumer destroys exactly the state machine that owns the recovery
logic.

Two notes from implementation:

- The matched rule is **redacted** before it crosses the adapter
  boundary (`StreamGuard.redact/1`, byte length only). Rules often
  guard secrets, and provider-error reasons are logged downstream.
- The guard covers **all streamed deltas** (text, reasoning, tool-call
  arguments), not just text: a forbidden pattern in tool input is at
  least as dangerous as one in prose. The guard flushes held bytes when
  the delta kind changes so patterns never match across kinds.

Substring rules are the v1 scope. "Invalid AST prefix" detection from
the draft is out of scope — substring matching cannot express it, and
nothing downstream needs it yet. If it becomes real, it slots in as an
additional rule type behind the same `scan/2` contract.

Timeouts stay where they already live: the transport's existing
HTTP/SSE deadlines. The guard adds none.

## Component 2 — Sandbox Callback Bridge

### Placement and protocol

A `Synapsis.Plugin.SandboxBridge` GenServer in `synapsis_plugin` wraps
one OS Port per sandbox runtime, supervised under the session's tool
supervision (DynamicSupervisor, `:one_for_one`). The wire protocol is
newline-delimited JSON-RPC 2.0 on stdout/stdin — the same family as the
MCP stdio transport already in this app, and deliberately so.

Sandbox → host messages on stdout are one of:

- a JSON-RPC **request** (`method`/`params`/`id`): a reverse tool
  invocation, routed through the session's tool registry — which means
  the full existing tool pipeline applies: path validation, permission
  checks, persistence, timeouts. The bridge gets no side door.
- a JSON-RPC **response** (`result`/`error` + `id`): completion of an
  `eval` the host issued.
- anything that doesn't parse as JSON-RPC: console output, forwarded to
  the session as ordinary tool output events.

### Framing (the draft's fatal bug)

The draft opened the Port with `:stream` and called `Jason.decode/1` on
each `{:data, binary}`. Port data arrives at arbitrary boundaries: one
JSON-RPC message split across two deliveries, or several coalesced into
one. The fragment fails to decode, falls into the console-output branch,
and corrupts the protocol silently.

The Port is opened with `{:line, @max_line}` framing plus
`:exit_status`:

```elixir
port =
  Port.open({:spawn_executable, exec_cmd}, [
    :binary,
    {:line, 1_048_576},
    :use_stdio,
    :exit_status,
    args: args
  ])
```

`{:line, _}` delivers `{:data, {:eol | :noeol, line}}`; the bridge
accumulates `:noeol` fragments in state and only attempts decode on a
complete line. Sandbox adapters (the in-sandbox shim) must emit exactly
one JSON document per line. Lines exceeding the cap are an adapter bug
and fail the request explicitly rather than being silently truncated.

### Every request gets a response

The draft dispatched reverse invocations with a bare `spawn/1`: if the
tool crashed, no response was ever written and the sandboxed script
blocked forever. Here, dispatch runs under the session's
`Task.Supervisor` with `async_nolink`, the bridge tracks
`%{task_ref => rpc_id}`, and **all three terminal outcomes write a
response to the Port**:

- task completes → JSON-RPC `result`
- task crashes (`{:DOWN, ref, :process, _, reason}`) → JSON-RPC `error`
  (code `-32000`, sanitized reason)
- deadline exceeded (per-call timer) → `Task.Supervisor` shutdown +
  JSON-RPC `error` (timeout code)

### Call discipline

The draft kept a single `current_caller` and overwrote it on concurrent
`eval` calls, orphaning the first caller, and called
`GenServer.reply(nil, ...)` (an `ArgumentError`) when console output
arrived with no caller pending. Instead:

- `eval/3` takes an explicit timeout and the bridge **rejects** a
  second `eval` while one is in flight (`{:error, :busy}`). Sandbox
  runtimes are single-threaded REPLs; queueing hides bugs.
- Console output is never a `reply`. It is broadcast as an output
  event (existing tool-output PubSub shape) whether or not an eval is
  pending; the pending eval is completed only by a matching JSON-RPC
  response or by its deadline.
- An in-flight eval has a timer; on expiry the caller gets
  `{:error, :timeout}` and the bridge marks the runtime suspect (see
  below).

### Lifecycle

`{:data, ...}` after framing is handled as above; additionally:

- `{port, {:exit_status, status}}` → fail the in-flight eval (if any)
  with `{:error, {:sandbox_exited, status}}`, fail all pending reverse
  invocations' tasks are irrelevant (their responses have nowhere to
  go; they are demonitored and shut down), then `{:stop, ...}`. The
  DynamicSupervisor's restart policy brings up a fresh runtime;
  warm-state reconstruction is the adapter's concern, not the bridge's.
- `terminate/2` closes the Port explicitly.
- A timed-out eval leaves the runtime in an unknown state (it may still
  be computing). The bridge kills and restarts the runtime rather than
  reusing it — predictable cold restarts over unpredictable shared
  state.

JSON encoding/decoding uses the built-in `JSON` module (Elixir 1.18+),
not Jason.

## Component 3 — Session Checkpoints

### Placement

Checkpoints extend the existing `Synapsis.Session.Worker` gen_statem
(ADR-008). No new process. The worker's data gains a `checkpoints`
stack; states gain nothing new — checkpoint push/pop happen as internal
events inside the existing build-mode flow (`coding_loop`).

The draft's observation about immutability is correct and kept: pushing
a checkpoint that references the current history is O(1) and shares
structure; no deep copy occurs. What the draft missed is that this is
only true *while the process lives* — which is why durability is
delegated to the substrate that already has it.

### What a checkpoint contains

```elixir
%{
  id: Ecto.UUID.generate(),
  reason: reason,
  engine_node: data.engine_node,        # engine fields by reference —
  engine_state: data.engine_state,      # shared structure, O(1)
  engine_ctx: data.engine_ctx,
  stream_acc: data.stream_acc,
  executed_tool_ids: data.executed_tool_ids,
  turn_count: turn_count,               # Store.count_turns/1 (key scan)
  workspace_ref: head_and_stash,        # Synapsis.Git.capture_ref/1, or :history_only
  created_at: DateTime.utc_now()
}
```

The draft snapshotted a file's SHA-256 and then never used it; rolling
back `history` while the file stayed half-patched left the LLM
reasoning about a filesystem that no longer matched its restored
context. A checkpoint must capture **restorable** workspace state, not
a checksum:

- In worktree-isolated sessions (the existing `.trees/` flow), the
  checkpoint records the worktree's HEAD plus a stash/commit of dirty
  state via the `synapsis_core` git helpers. Rollback = reset to that
  ref. This is the primary path.
- For non-git workspaces, v1 simply does not offer file rollback —
  rollback restores conversation state and the correction prompt tells
  the model to re-read affected files. Honest degradation beats a
  checksum that verifies nothing.

### Rollback flow

Two entry points exist: a `{:stream_violation, rule}` event from
Component 1 rolls back automatically when a checkpoint exists (falling
through to ordinary provider-error handling when none does), and a
public `Worker.push_checkpoint/2` / `rollback_checkpoint/2` API lets
graph nodes and operators bracket risky edits explicitly. The original
draft's `prepare_edit`/`patch_failed` events do not exist in the
current coding loop; automatic push at edit-tool dispatch is follow-up
work. The rollback steps:

1. Pop the top checkpoint. The `Checkpoint` module has **no
   empty-stack clause** — an internal rollback without a prior push is
   an invariant violation and must crash (the draft's silent
   `[] -> {:next_state, :idle, data}` swallowed a bug). Only the
   public-API call boundary in the worker answers an empty stack with
   `{:error, :no_checkpoint}`, because there it is the *caller's*
   error, not a broken invariant.
2. Restore the workspace: `git reset --hard` to the checkpoint's
   recorded HEAD, then re-apply the captured dirty state
   (`Synapsis.Git.restore_ref/2`). Failure degrades to history-only
   with a warning, and the correction message says so.
3. Truncate the durable turns to the checkpoint's `turn_count` and
   append a structured correction message (reason, workspace outcome,
   instruction to re-read).
4. Resume the engine from the restored node (`Worker.step_engine/1`),
   which re-invokes the LLM when the checkpoint was taken pre-stream.

### Durability

Process-memory checkpoints die with the process — and v1 accepts that:
the stack is **in-memory only**. There is no per-session "worker data"
snapshot vehicle in the current Concord schema, and persisting the
stack under its own key would violate GUARDRAILS NEVER #1 (no durable
session state outside the per-turn snapshot) while adding consensus
writes to the worker's hot path (NEVER #7). A checkpoint protects the
edit it brackets; after a worker restart the transcript is already
consistent as of the last turn boundary, which is the same recovery
guarantee the rest of the session has. If the turn snapshot later grows
a worker-state section, the stack can ride along then.

Push is correspondingly cheap: engine state by reference, the durable
turn count (`Store.count_turns/1`, a key scan), and a git ref. Rollback
is a compaction-class operation (read + truncate + correction append) —
the same cost profile as `Synapsis.Session.Compactor`, which also runs
in the worker.

## Supervision

No new topology. The earlier draft's tree is rejected on three points:

1. **Per-session `SessionRegistry` is misplaced.** A Registry must sit
   above the sessions (one shared, optionally partitioned instance) for
   `{:via, Registry, {SessionRegistry, id}}` to work; Synapsis already
   has session registration. A registry that restarts with its session
   registers nothing useful.
2. **`:one_for_all` inverts the durability hierarchy.** The worker is
   the live source of truth (ADR-006); ephemeral collaborators (LLM
   stream task, sandbox bridge) must be able to die without taking it
   down. The worker **monitors** the stream task and handles
   `{:DOWN, ref, :process, pid, reason}` as a domain event (turn
   failed → recover, possibly via checkpoint). Note this is monitoring,
   not `trap_exit` — the draft conflated the two (`trap_exit` yields
   `{:EXIT, pid, reason}`; `{:DOWN, ...}` comes from monitors).
3. **Sandbox bridges** live under the session's existing
   DynamicSupervisor (`:one_for_one` — the only strategy it supports).
   A leaking or crashing runtime is contained there; the worker
   observes bridge death the same way it observes any tool failure.

If anything, the ordering dependency inside a session is
`worker → dependents`, which is `:rest_for_one` shape — already how the
session tree is arranged.

## Guardrail compliance

Mapping to `docs/guardrails/GUARDRAILS.md`:

- No synchronous LLM calls in worker paths — guard is inline in the
  transport's stream task, violations arrive as async events.
- `Port` (never `System.cmd`), with `{:line, _}` framing,
  `:exit_status`, explicit close in `terminate/2`.
- Reverse invocations route through the standard tool pipeline: path
  validation against project root, permission checks (run even under
  dev auto-approve), persistence, timeouts.
- Explicit timeouts on: eval calls, reverse-invocation tasks, stream
  consumption (transport deadlines).
- `{:DOWN, ...}` handled for stream tasks and dispatch tasks.
- Structured logging; JSON-RPC error reasons sanitized before crossing
  the Port (no secrets, no full stacktraces into the sandbox).
- Provider behavior tested with `Bypass`; guard itself is pure and unit
  tested without any process.

## Testing strategy

- **StreamGuard**: property tests — for random rule sets and random
  chunkings of a corpus, (a) concatenated emissions never contain a
  rule, (b) a corpus containing a rule always yields `{:violation, _}`
  regardless of chunk boundaries (including boundaries inside the
  pattern and inside multi-byte codepoints), (c) clean corpus passes
  through byte-identical after `finish/1`.
- **SandboxBridge**: a scripted fake sandbox executable (escript or
  shell) driving framing edge cases — split lines, coalesced lines,
  oversized lines, interleaved console output and RPC, crash-mid-eval,
  exit during pending reverse invocation. Assert every JSON-RPC `id`
  receives exactly one response.
- **Checkpoints**: worker-level tests in `synapsis_agent` — push/pop
  around simulated patch failure, git-backed workspace restore in a
  `@tag :tmp_dir` repo, crash-and-recover restoring the stack from the
  Concord turn snapshot, stale `workspace_ref` degrading to
  history-only rollback.

## Consequences

- Stream interception adds at most `max_len - 1` bytes of latency to
  visible streaming output; UI deltas lag by under a pattern length.
- Sandbox adapters must speak newline-delimited JSON-RPC; existing
  ad-hoc stdio tools are unaffected (they don't go through the bridge).
- Checkpoint file-rollback is only as good as the workspace's git
  isolation; sessions outside a worktree get conversation-only
  rollback, stated explicitly to the model in the correction prompt.
- Rejecting concurrent `eval` pushes concurrency to the caller (one
  runtime per concurrent need), keeping the bridge trivially correct.
