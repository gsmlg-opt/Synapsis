# PRD: Agent Orchestration & Loop Prevention — Implementation

## Objective

Implement the Agent Orchestration layer in `synapsis_core` to solve the regression loop problem: agent detects bug → applies fix → tests fail → rolls back → forgets failure → repeats same fix infinitely.

**Deliverables:**
- `Synapsis.Session.Orchestrator` — rules-engine GenServer controlling the agent loop
- `Synapsis.Session.Monitor` — deterministic loop/stagnation detector
- `Synapsis.Session.WorkspaceManager` — git patch tracking with atomic revert-and-learn
- `Synapsis.Session.PromptBuilder` — dynamic system prompt assembly with failure log injection
- `Synapsis.Session.AuditorTask` — dual-model escalation (cheap worker, expensive auditor)
- Data layer additions: `FailedAttempt` embedded schema, `Patch` struct, session `failure_constraints` column
- PubSub events: `:auditing`, `:paused`, `:terminated`, `:constraint_added`
- Tests for all new modules

## Prior Art — What Already Exists

The audit (completed) and tier work established these foundations:

| Capability | Status | Location |
|-----------|--------|----------|
| Tool call hashing (MapSet dedup) | **Done** | `Session.Worker` — `tool_call_hashes` field, `:erlang.phash2/1` |
| Iteration cap (25) | **Done** | `Session.Worker` — `@max_tool_iterations`, `iteration_count` |
| Git via Port (not System.cmd) | **Done** | `Synapsis.Git` — `checkpoint`, `undo_last`, `diff`, `is_repo?` |
| Per-session supervisor (`:one_for_all`) | **Done** | `Session.Supervisor` — currently only starts Worker |
| Provider adapter (multi-provider) | **Done** | `Provider.Adapter` — supports Anthropic, OpenAI, Google, local |
| Dual-model capable | **Done** | `Provider.Adapter.stream/2` accepts any config map per call |
| System prompt via Agent.Resolver | **Done** | `Agent.Resolver.resolve/2` → `MessageBuilder.build_request/3` |
| PubSub broadcast infra | **Done** | `session:{id}` topic with 8+ event types, catch-all channel forwarding |
| Error recovery (stream DOWN) | **Done** | Worker handles `:DOWN` with retry, 30-min inactivity timeout |
| Agent switching | **Done** | `Sessions.switch_agent/2` → Worker re-resolves config |
| Context compaction | **Done** | `Session.Compactor` — summarizes old messages, preserves recent 10 |

## Architecture

### Process Tree (per session)

```
Session.Supervisor (:one_for_all)
├── Session.Worker          (existing — state machine, tool dispatch)
├── Session.Orchestrator    (NEW — rules engine, loop control)
└── Session.Monitor         (NEW — hashing, stagnation detection)
```

`WorkspaceManager` is a library module (not a GenServer) called by the Orchestrator. `PromptBuilder` and `AuditorTask` are also library/task modules.

### Data Flow

```
User message
    │
    ▼
Worker.send_message/2
    │
    ├──► Orchestrator.pre_iteration/1     ← check constraints before LLM call
    │       │
    │       ├── PromptBuilder.build/2     ← inject failure log into system prompt
    │       └── Monitor.check/1           ← verify not looping
    │
    ├──► Provider.Adapter.stream/2        ← LLM call (Worker model)
    │
    ├──► Tool execution
    │       │
    │       └──► WorkspaceManager.record_patch/3  ← track what changed
    │
    ├──► Orchestrator.post_iteration/2    ← evaluate results
    │       │
    │       ├── continue    → next iteration
    │       ├── pause       → broadcast :paused, wait for user
    │       ├── escalate    → AuditorTask.analyze/2 (Auditor model)
    │       └── terminate   → broadcast :terminated, force idle
    │
    └──► (on escalation result)
            │
            └── WorkspaceManager.revert_and_learn/2  ← atomic rollback + record lesson
```

## Steps

### Step 1: Data Layer — FailedAttempt and Patch structs

**Location:** `apps/synapsis_data/lib/synapsis/`

1. Create `Synapsis.FailedAttempt` embedded schema:
   ```elixir
   embedded_schema do
     field :approach, :string        # what was tried
     field :result, :string          # what happened
     field :lesson, :string          # why it's a dead end
     field :patch_hash, :string      # hash of the code change
     field :recorded_at, :utc_datetime
   end
   ```

2. Create `Synapsis.Patch` embedded schema:
   ```elixir
   embedded_schema do
     field :path, :string            # file path
     field :diff, :string            # unified diff
     field :hash, :string            # content hash for dedup
     field :tool_call_id, :string    # which tool call produced it
     field :applied_at, :utc_datetime
   end
   ```

3. Add migration: `failure_constraints` JSONB column on `sessions` table (array of `FailedAttempt`, default `[]`).

4. Update `Synapsis.Session` schema to include `failure_constraints` field with `{:array, :map}` type.

5. Register both as castable in `Synapsis.Part` if needed for message serialization.

**Tests:** Round-trip serialization, changeset validation, empty defaults.

### Step 2: Session.Monitor — Deterministic Loop Detection

**Location:** `apps/synapsis_core/lib/synapsis/session/monitor.ex`

Pure-function module (NOT a GenServer — keeps it simple, called by Orchestrator).

```elixir
defmodule Synapsis.Session.Monitor do
  @type state :: %{
    tool_hashes: MapSet.t(),
    test_results: [{String.t(), :pass | :fail}],
    stagnation_counter: non_neg_integer(),
    iteration: non_neg_integer()
  }

  def new() :: state
  def record_tool_call(state, tool_name, input) :: {state, :ok | :duplicate}
  def record_test_result(state, test_output) :: {state, :improved | :regressed | :unchanged}
  def record_iteration(state) :: {state, :ok | :stagnating}
  def reset(state) :: state
end
```

**Detection rules:**
- **Duplicate tool call:** `:erlang.phash2({tool_name, input})` collision in MapSet → `:duplicate`
- **Test regression:** Compare latest test pass/fail counts against previous. If fail count increased → `:regressed`
- **Stagnation:** If 3 consecutive iterations produce no test improvement and no new file changes → `:stagnating`

**Move existing logic:** Extract `tool_call_hashes` and `iteration_count` from `Session.Worker` into Monitor. Worker calls `Monitor.record_tool_call/3` instead of maintaining its own MapSet.

**Tests:** Unit tests for each detection rule with mock tool calls and test outputs.

### Step 3: Session.PromptBuilder — Dynamic System Prompt with Failure Log

**Location:** `apps/synapsis_core/lib/synapsis/session/prompt_builder.ex`

```elixir
defmodule Synapsis.Session.PromptBuilder do
  def build(base_system_prompt, failure_constraints) :: String.t()
  def format_constraint(failed_attempt) :: String.t()
end
```

**Behavior:**
- Takes the base system prompt from `Agent.Resolver` and the session's `failure_constraints` list
- Appends a `## Failed Approaches — Do NOT Repeat` block at the end of the system prompt
- Each constraint formatted as:
  ```
  ### Attempt: [approach]
  Result: [result]
  Lesson: [lesson]
  ```
- Maximum 7 constraints. When adding an 8th, drop the oldest.
- If `failure_constraints` is empty, return base prompt unchanged.

**Integration point:** In `Session.Worker`, before calling `MessageBuilder.build_request/3`, replace `agent[:system_prompt]` with `PromptBuilder.build(agent[:system_prompt], session.failure_constraints)`.

**Tests:** Empty constraints → unchanged prompt. 1-7 constraints → appended block. 8+ → oldest dropped. Format matches expected markdown.

### Step 4: Session.WorkspaceManager — Git Patch Tracking

**Location:** `apps/synapsis_core/lib/synapsis/session/workspace_manager.ex`

Library module using existing `Synapsis.Git`.

```elixir
defmodule Synapsis.Session.WorkspaceManager do
  def record_patch(project_path, tool_call_id) :: {:ok, Patch.t()} | {:error, term()}
  def revert_and_learn(project_path, patch, lesson) :: {:ok, FailedAttempt.t()} | {:error, term()}
  def list_patches(project_path) :: [Patch.t()]
end
```

**`record_patch/2`:**
1. Run `Synapsis.Git.diff(project_path)` to capture what changed since last checkpoint
2. Hash the diff with `:crypto.hash(:sha256, diff)`
3. Return a `Patch` struct

**`revert_and_learn/3`:** (atomic operation)
1. `Synapsis.Git.undo_last(project_path)` — revert the code
2. Build a `FailedAttempt` struct with the lesson
3. Return both — caller persists the `FailedAttempt` to the session's `failure_constraints`

**Extend `Synapsis.Git`:** Add `worktree_add/3`, `worktree_remove/2` for scratch worktree support (Phase 2 — not required for initial implementation).

**Tests:** Mock git operations, verify patch capture, verify atomic revert-and-learn produces correct structs.

### Step 5: Session.AuditorTask — Dual-Model Escalation

**Location:** `apps/synapsis_core/lib/synapsis/session/auditor_task.ex`

```elixir
defmodule Synapsis.Session.AuditorTask do
  def analyze(context, opts \\ []) :: {:ok, FailedAttempt.t()} | {:error, term()}
end
```

**Behavior:**
1. Called by Orchestrator when escalation is triggered (3 consecutive failures, test regression, or stagnation)
2. Assembles a concise prompt: "Here is what was tried, here is what failed, here is the test output. What is the root cause and what lesson should be recorded?"
3. Calls `Provider.Adapter.stream/2` with the **auditor model** config (expensive reasoning model)
4. Parses the response into a `FailedAttempt` struct
5. Returns the constraint to be added to the failure log

**Model selection:**
- Read `auditor` config from agent config: `agent[:auditor_model]` and `agent[:auditor_provider]`
- Defaults: use the same provider but with a reasoning-class model (e.g., `claude-opus-4-20250514` if worker is `claude-sonnet-4-20250514`)
- Extend `Agent.Resolver` to support `auditor_model` and `auditor_provider` fields

**Tests:** Mock provider response, verify FailedAttempt parsing, verify it uses the auditor model config.

### Step 6: Session.Orchestrator — Rules Engine

**Location:** `apps/synapsis_core/lib/synapsis/session/orchestrator.ex`

GenServer, sibling to Worker under `Session.Supervisor`.

```elixir
defmodule Synapsis.Session.Orchestrator do
  use GenServer

  defstruct [
    :session_id,
    :monitor,          # Monitor state
    :failure_log,      # [FailedAttempt.t()]
    :patches,          # [Patch.t()]
    escalation_count: 0,
    max_escalations: 3
  ]

  # Called by Worker before each LLM call
  def pre_iteration(session_id) :: :continue | :pause | :terminate

  # Called by Worker after tool execution
  def post_iteration(session_id, result) :: :continue | :pause | :escalate | :terminate

  # Called by Worker to get the augmented system prompt
  def get_system_prompt(session_id, base_prompt) :: String.t()

  # Manual override from UI
  def force_continue(session_id) :: :ok
  def clear_constraints(session_id) :: :ok
end
```

**Rules (pattern-matched `handle_call` clauses):**

| Condition | Action |
|-----------|--------|
| Monitor returns `:duplicate` | Warn in tool result (existing behavior), increment stagnation |
| Monitor returns `:stagnating` (3+ iterations) | `:escalate` → trigger AuditorTask |
| Monitor returns `:regressed` | `:escalate` → trigger AuditorTask |
| Escalation returns a lesson | Record `FailedAttempt`, call `WorkspaceManager.revert_and_learn`, broadcast `:constraint_added` |
| `escalation_count >= max_escalations` | `:terminate` → too many failures, stop |
| Iteration count > `@max_tool_iterations` | `:terminate` (existing, moved from Worker) |
| All checks pass | `:continue` |

**PubSub broadcasts:** On state transitions, broadcast to `session:{id}`:
- `"orchestrator_status"` with `%{status: :auditing | :paused | :terminated}`
- `"constraint_added"` with `%{lesson: "...", approach: "..."}`

**Integration:** Modify `Session.Supervisor` to start Orchestrator alongside Worker. Modify Worker's `continue_after_tools/2` to call `Orchestrator.post_iteration/2` before unconditionally restarting the stream.

### Step 7: Wire Into Session.Worker

Minimal changes to existing Worker:

1. **Remove** `tool_call_hashes`, `iteration_count`, and `@max_tool_iterations` from Worker — these move to Monitor/Orchestrator
2. **Before** `MessageBuilder.build_request/3`: call `Orchestrator.get_system_prompt(session_id, agent[:system_prompt])` to get the augmented prompt
3. **In** `continue_after_tools/2`: call `Orchestrator.post_iteration(session_id, result)` and act on the response:
   - `:continue` → proceed as before
   - `:pause` → transition to `:idle`, broadcast `:paused`
   - `:escalate` → broadcast `:auditing`, let Orchestrator handle async
   - `:terminate` → transition to `:idle`, broadcast `:terminated`
4. **In** `execute_tool_async/2`: call `WorkspaceManager.record_patch/2` after write tools, call `Monitor.record_tool_call/3` before execution

### Step 8: Channel & UI Integration

1. Add `handle_in("session:force_continue", ...)` to `SessionChannel` → calls `Orchestrator.force_continue/1`
2. Add `handle_in("session:clear_constraints", ...)` → calls `Orchestrator.clear_constraints/1`
3. The existing catch-all `handle_info({event, payload}, socket)` already forwards new PubSub events to the client — no channel code changes needed for broadcasts

### Step 9: Tests

1. **Monitor tests** — unit tests for each detection rule
2. **PromptBuilder tests** — prompt assembly with 0, 1, 7, 8 constraints
3. **WorkspaceManager tests** — patch recording, revert-and-learn (mock Git)
4. **AuditorTask tests** — mock provider, verify FailedAttempt parsing
5. **Orchestrator tests** — full rules engine: simulate sequences of `:duplicate`, `:regressed`, `:stagnating` and verify correct decisions
6. **Integration test** — Worker → Orchestrator → Monitor → PromptBuilder round-trip with mock provider

## Constraints

- **`synapsis_data` boundary:** `FailedAttempt` and `Patch` are embedded schemas in `synapsis_data`. No business logic in the data layer.
- **DB is source of truth:** `failure_constraints` persisted to session record after each update. Orchestrator ephemeral state is reconstructable from DB.
- **No ML in Orchestrator:** All rules are deterministic pattern matches. The only LLM call is `AuditorTask` for failure analysis.
- **Backward compatible:** Sessions without an Orchestrator (e.g., from before migration) work fine — Worker falls back to direct iteration if Orchestrator process isn't found.
- **Port for shell execution:** Any new git operations must use Port, not System.cmd.
- **Structured logging:** All new Logger calls use `Logger.info("event_name", key: value)`.

## Verification

```bash
# All tests pass
mix test

# No warnings
mix compile --warnings-as-errors

# Formatted
mix format --check-formatted

# New modules exist
test -f apps/synapsis_core/lib/synapsis/session/orchestrator.ex && echo "PASS"
test -f apps/synapsis_core/lib/synapsis/session/monitor.ex && echo "PASS"
test -f apps/synapsis_core/lib/synapsis/session/workspace_manager.ex && echo "PASS"
test -f apps/synapsis_core/lib/synapsis/session/prompt_builder.ex && echo "PASS"
test -f apps/synapsis_core/lib/synapsis/session/auditor_task.ex && echo "PASS"
test -f apps/synapsis_data/lib/synapsis/failed_attempt.ex && echo "PASS"
test -f apps/synapsis_data/lib/synapsis/patch.ex && echo "PASS"

# Integration: Orchestrator starts in session supervision tree
mix run -e '
  {:ok, session} = Synapsis.Sessions.create("/tmp/test-orch")
  pid = GenServer.whereis({:via, Registry, {Synapsis.Session.Registry, session.id}})
  IO.inspect(pid != nil, label: "worker_alive")
'
```
