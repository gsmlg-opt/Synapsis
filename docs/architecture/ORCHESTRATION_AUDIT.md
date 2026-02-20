# Agent Orchestration Design — Feasibility Audit

**Date:** 2026-02-21 (updated — modules implemented since 2026-02-20 audit)
**Scope:** Read-only analysis of Synapsis codebase against proposed Agent Orchestration & Loop Prevention design
**Auditor:** Loki Mode — static analysis + live integration testing via chrome-devtools MCP

> **⚠️ Update 2026-02-21:** The prior audit (2026-02-20) was completed before implementation of the orchestration modules. All proposed modules are now implemented. Section 9 (Recommendation) reflects the current state. Individual sections have been updated with `[UPDATED]` markers where findings changed.

---

## 1. Structural Fit

### Can the proposed modules live under `synapsis_core/sessions/`?

**Yes.** `synapsis_core` is the **only OTP application** in the umbrella (confirmed via `mod: {SynapsisCore.Application, []}` in `apps/synapsis_core/mix.exs:23`). All other apps are pure library packages. The proposed target path `apps/synapsis_core/lib/synapsis_core/sessions/` is a valid location for new GenServer modules.

**Current supervision tree** (`apps/synapsis_core/lib/synapsis_core/application.ex:7-20`):

```
SynapsisCore.Supervisor (strategy: :one_for_one)
├── Synapsis.Repo
├── Phoenix.PubSub (name: Synapsis.PubSub)
├── Task.Supervisor (name: Synapsis.Provider.TaskSupervisor)
├── Synapsis.Provider.Registry (GenServer, ETS-backed)
├── Task.Supervisor (name: Synapsis.Tool.TaskSupervisor)
├── Synapsis.Tool.Registry (GenServer, ETS-backed)
├── Registry (keys: :unique, name: Synapsis.Session.Registry)
├── Registry (keys: :unique, name: Synapsis.Session.SupervisorRegistry)
├── Registry (keys: :unique, name: Synapsis.FileWatcher.Registry)
├── Synapsis.Session.DynamicSupervisor
├── SynapsisPlugin.Supervisor
└── SynapsisServer.Supervisor
```

**Supervision tree conflicts:** None. New Orchestrator/Monitor GenServers can be added as children of `SynapsisCore.Supervisor` or nested under a new `Synapsis.Orchestrator.Supervisor`. The existing `Session.DynamicSupervisor` pattern (which starts per-session `Session.Supervisor` trees) provides a template for adding per-session orchestration processes.

### Dependency graph (verified acyclic)

```
synapsis_data        (no umbrella deps)
  ↑
synapsis_provider    (depends on: synapsis_data)
  ↑
synapsis_core        (depends on: synapsis_data, synapsis_provider) ← proposed modules here
  ↑
synapsis_server      (depends on: synapsis_core, synapsis_provider, synapsis_plugin)
synapsis_plugin      (depends on: synapsis_core)
synapsis_web         (depends on: synapsis_server)
synapsis_cli         (no umbrella deps)
```

No violations detected. Adding modules to `synapsis_core` does not create circular dependencies.

---

## 2. Existing Agent Loop [UPDATED]

### Current implementation

The agent loop is implemented in `Synapsis.Session.Worker` (`apps/synapsis_core/lib/synapsis/session/worker.ex`, ~780 lines), a GenServer with a state machine:

**State struct** (as of 2026-02-21):
```elixir
defstruct [:session_id, :session, :agent, :provider_config, :stream_ref, :stream_monitor_ref,
  status: :idle, pending_text: "", pending_tool_use: nil, pending_tool_input: "",
  pending_reasoning: "", tool_uses: [], retry_count: 0,
  tool_call_hashes: MapSet.new(), iteration_count: 0, monitor: nil]
```

**State machine:** `idle → streaming → tool_executing → [orchestrator decision] → idle | streaming | (pause) | (terminate)`

**Loop cycle:**
1. User sends message → Worker persists to DB → builds provider request via `MessageBuilder.build_request/4` (with `prompt_context` from `PromptBuilder.build_failure_context/1`) → starts async stream
2. Provider streams SSE chunks → Worker accumulates text/tool_use parts → flushes to DB on stream end
3. If tool_uses present: transition to `:tool_executing` → permission check → `Monitor.record_tool_call/3` → async tool execution → persist results
4. After all tools complete: `Monitor.record_iteration/2` → `Orchestrator.decide/2` → based on decision: continue loop / pause / escalate / terminate

### What exists vs what needs building [UPDATED]

| Feature | Exists | Location | Gap |
|---------|--------|----------|-----|
| Session GenServer state machine | **Yes** | `worker.ex` | None |
| LLM call cycle (stream → tools → stream) | **Yes** | `worker.ex` | None |
| Tool call hashing (cross-iteration) | **Yes** | `monitor.ex`, `worker.ex` | None — Monitor tracks per session |
| Iteration limit (25 max) | **Yes** | `orchestrator.ex`, `worker.ex` | None — Orchestrator enforces |
| Stagnation detection | **Yes** | `monitor.ex` | None — 3 consecutive empty iterations |
| Test regression tracking | **Yes** | `monitor.ex` | None — pass→fail transition detection |
| Failure log (rolling constraints) | **Yes** | `prompt_builder.ex`, `failed_attempt.ex` | Auditor invocation is stub (see §9) |
| Orchestrator rules engine | **Yes** | `orchestrator.ex` | None |
| Monitor (loop detection) | **Yes** | `monitor.ex` | None |
| WorkspaceManager (git worktrees) | **Yes** | `workspace_manager.ex`, `git_worktree.ex` | `promote/2` function missing |
| AuditorTask (prompt builder) | **Yes** | `auditor_task.ex` | LLM invocation not called (see §9) |
| PromptBuilder (failure injection) | **Yes** | `prompt_builder.ex` | None — wired into Worker loop |
| FailedAttempt schema | **Yes** | `apps/synapsis_data/lib/synapsis/failed_attempt.ex` | None |
| Patch schema | **Yes** | `apps/synapsis_data/lib/synapsis/patch.ex` | None |
| Retry with exponential backoff | **Yes** | `worker.ex` | None — max 3 retries |
| Dual-model (Worker + Auditor) | **Partial** | `auditor_task.ex` | Auditor LLM call is a stub |

### Orchestrator integration (confirmed)

**Tool call monitoring** (Worker `process_tool_uses/1`):
```elixir
monitor = Enum.reduce(state.tool_uses, state.monitor, fn tu, mon ->
  {_signal, mon} = Monitor.record_tool_call(mon, tu.tool, tu.input)
  mon
end)
```

**Orchestrator decision** (Worker `continue_after_tools/2`):
```elixir
decision = Orchestrator.decide(monitor, max_iterations: max_iterations)
applied = Orchestrator.apply_decision(decision, state.session_id)
```

**Prompt context injection** (Worker `do_continue_loop/1`):
```elixir
prompt_context = Synapsis.PromptBuilder.build_failure_context(state.session_id)
request = Synapsis.MessageBuilder.build_request(messages, state.agent, state.session.provider, prompt_context)
```

All three integration points are implemented and wired together.

---

## 3. Tool System Compatibility

### Can tool calls be hashed?

**Yes.** Tool call arguments are fully accessible via `Synapsis.Part.ToolUse.input` (`apps/synapsis_data/lib/synapsis/part/tool_use.ex:3`):

```elixir
defstruct [:tool, :tool_use_id, input: %{}, status: :pending]
```

The `input` field is a plain Elixir map containing all tool arguments. The existing hashing approach (`worker.ex:575`: `:erlang.phash2({tool_use.tool, tool_use.input})`) already demonstrates this works.

### Is the tool registry accessible?

**Yes.** `Synapsis.Tool.Registry` (`apps/synapsis_core/lib/synapsis/tool/registry.ex`) uses a public ETS table (`:synapsis_tools`, line 139: `:named_table, :set, :public, read_concurrency: true`).

**Public API:**
- `lookup(name)` → `{:ok, {:module, module, opts}}` or `{:error, :not_found}`
- `list_for_llm()` → `[%{name, description, parameters}, ...]`
- `register_module(name, module, opts)` / `register_process(name, pid, opts)`

### Tool system overview

- **11 built-in tools** registered at startup (`apps/synapsis_core/lib/synapsis/tool/builtin.ex:4-16`)
- **Behaviour:** `Synapsis.Tool` with callbacks `name/0`, `description/0`, `parameters/0`, `execute/2`, `side_effects/0` (`apps/synapsis_core/lib/synapsis/tool.ex:1-57`)
- **Executor:** Async via `Task.Supervisor` with configurable timeouts (`apps/synapsis_core/lib/synapsis/tool/executor.ex:20-46`)
- **Permission levels:** `:read` (auto-approved), `:write`, `:execute`, `:destructive` (require approval) (`apps/synapsis_core/lib/synapsis/tool/permissions.ex:5-9`)
- **Side effects broadcasting:** After tool success, effects broadcast to `"tool_effects:#{session_id}"` via PubSub (`executor.ex:59-78`)

**Compatibility verdict:** The tool system is fully compatible with the proposed hashing and monitoring design. No changes needed to existing tool modules.

---

## 4. Provider Integration

### System prompt injection point

The system prompt flows through this chain:

1. `Synapsis.Config.resolve/1` merges defaults → user config → project config → env (`apps/synapsis_core/lib/synapsis/config.ex:12-17`)
2. `Synapsis.Agent.Resolver.resolve/2` resolves agent config including `system_prompt` (`apps/synapsis_core/lib/synapsis/agent/resolver.ex:1-65`)
3. `Synapsis.MessageBuilder.build_request/3` passes `agent[:system_prompt]` as part of `opts` (`apps/synapsis_core/lib/synapsis/message_builder.ex:1-36`)
4. `Synapsis.Provider.MessageMapper` formats per-provider:
   - **Anthropic** (lines 20-38): Top-level `system` field
   - **OpenAI** (lines 40-51): First message with `role: "system"`
   - **Google** (lines 53-73): `systemInstruction` field

**Can we inject a "Failed Approaches" block per-turn?**

**Not currently.** The system prompt is loaded once at Worker init (`worker.ex:76`) and never modified during the streaming loop. `MessageBuilder.build_request/3` does not accept dynamic prompt modifications.

**Required change:** Extend `MessageBuilder.build_request/3` to accept an optional `prompt_context` parameter (e.g., failure log entries) that gets appended to `system_prompt` before each provider call. This is a ~10-line change to `message_builder.ex`.

### Multi-model support

**Not currently supported.** Each session has exactly one `provider` and one `model` field (`apps/synapsis_data/lib/synapsis/session.ex:12-13`). The Worker loads a single `provider_config` at init (`worker.ex:77`) and reuses it for all streaming calls.

**Required changes for Worker + Auditor dual-model:**
1. Extend agent config in `Agent.Resolver` to include `provider` field (currently only `model`)
2. Add `auditor_provider`/`auditor_model` fields to session config or agent config
3. Modify Worker to conditionally invoke a second provider for auditor calls
4. This is an additive change — existing single-model sessions continue working unchanged

### `.secrets.toml` status

The file exists at project root (`/home/gao/Workspace/gsmlg-opt/Synapsis/.secrets.toml`, 312 bytes). Structure contains TOML sections per provider with `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_BASE_URL` keys (values NOT examined per audit constraints).

**Loading mechanism:** `.secrets.toml` is **not actively loaded** by the Elixir codebase. The codebase uses:
1. Encrypted DB storage via `ProviderConfig.api_key_encrypted` (`apps/synapsis_data/lib/synapsis/provider_config.ex:15`)
2. Auth config file at `~/.config/synapsis/auth.json` (`config.ex:60-63`)
3. Environment variables: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY` (`config.ex:72-94`)

**Gap:** A TOML parser dependency (e.g., `toml_elixir`) and a loader module would be needed to use `.secrets.toml` directly. Alternatively, the existing DB/env-based config could be extended.

---

## 5. Git / Workspace

### Current state

`Synapsis.Git` (`apps/synapsis_core/lib/synapsis/git.ex`, 87 lines) provides:

- `checkpoint(project_path, message)` — stages all + commits (lines 6-15)
- `undo_last(project_path)` — `git reset --soft HEAD~1` for synapsis-prefixed commits (lines 17-29)
- `diff(project_path, opts)` — runs `git diff` (lines 38-41)
- `is_repo?(project_path)` — detects git repo (lines 43-48)

**Execution:** Port-based (compliant with guardrails), 10s timeout (`git.ex:57-63`).

**Integration in Worker** (`worker.ex:579-583`): Auto-checkpoint before `file_edit`, `file_write`, and `bash` tools if project is a git repo.

### Current state vs design requirements

| Requirement | Current | Gap |
|-------------|---------|-----|
| Git operations via Port | **Yes** (`git.ex:57-63`) | None |
| Auto-checkpoint before writes | **Yes** (`worker.ex:579-583`) | None |
| Undo last commit | **Yes** (`git.ex:17-29`) | Only "synapsis "-prefixed commits |
| `git worktree` support | **No** | Need new `Synapsis.GitWorktree` module (~100 LOC) |
| Atomic patch tracking | **No** | Need `Patch` schema + tracking logic |
| Per-session isolated workspace | **No** | Need worktree creation/cleanup per session |
| Patch application (`git apply`) | **No** | Need wrapper in GitWorktree module |
| Revert-and-learn (atomic) | **No** | Need transaction: revert commit + persist failure reason |

**File edit model:** Direct `File.write!` with no intermediate staging (`apps/synapsis_core/lib/synapsis/tool/file_edit.ex:42,64`). No rollback mechanism beyond git undo.

---

## 6. PubSub / Channels

### Current PubSub topic structure

| Topic Pattern | Purpose | Subscribers |
|---------------|---------|-------------|
| `"session:<uuid>"` | All session events | SessionChannel, SSEController |
| `"tool_effects:<uuid>"` | Tool side effects | SynapsisPlugin.Server |
| `"file_changes:<path>"` | File system changes | FileWatcher listeners |
| `"plugin_events"` | Plugin crashes (global) | (internal) |

### Current events broadcast (13 unique types, 24 callsites)

All from `Session.Worker` (`worker.ex:698-703`) via `Phoenix.PubSub.broadcast/3` to `"session:<id>"`:

| Event | Payload |
|-------|---------|
| `"text_delta"` | `%{text: string}` |
| `"reasoning"` | `%{text: string}` |
| `"tool_use"` | `%{tool: string, tool_use_id: string}` |
| `"tool_result"` | `%{tool_use_id: string, content: string, is_error: boolean}` |
| `"permission_request"` | `%{tool: string, tool_use_id: string, input: map}` |
| `"session_status"` | `%{status: string}` |
| `"done"` | `%{}` |
| `"max_iterations"` | `%{iterations: integer}` |
| `"error"` | `%{message: string}` |
| `"agent_switched"` | `%{agent: string}` |

### SessionChannel

`SynapsisServer.SessionChannel` (`apps/synapsis_server/lib/synapsis_server/channels/session_channel.ex`, 82 lines) uses a **generic handler** (lines 73-77):

```elixir
def handle_info({event, payload}, socket) when is_binary(event) do
  push(socket, event, payload)
  {:noreply, socket}
end
```

This accepts **any** `{event_name :: string, payload :: map}` tuple — new event types are automatically routed to clients without code changes.

### SSE fallback

`SynapsisServer.SSEController` (`apps/synapsis_server/lib/synapsis_server/controllers/sse_controller.ex`) provides `GET /api/sessions/:id/events` with the same PubSub subscription pattern and 30s keepalive.

### Gap: proposed vs existing events

| Proposed Event | Status | Effort |
|----------------|--------|--------|
| `:auditing` | **Missing** | Trivial — just call `broadcast/3` from Orchestrator |
| `:paused` | **Missing** | Trivial — same pattern |
| `:constraint_added` | **Missing** | Trivial — same pattern |
| `:budget_update` | **Missing** | Trivial — same pattern |

**Breaking changes:** None. The generic handler and PubSub infrastructure require zero modifications. New events are purely additive.

---

## 7. Data Layer

### Existing schemas

| Schema | Table | File | Key Fields |
|--------|-------|------|------------|
| `Synapsis.Project` | `projects` | `apps/synapsis_data/lib/synapsis/project.ex` | id (UUID), path, slug, config (JSONB) |
| `Synapsis.Session` | `sessions` | `apps/synapsis_data/lib/synapsis/session.ex` | id (UUID), project_id, agent, provider, model, status, config (JSONB) |
| `Synapsis.Message` | `messages` | `apps/synapsis_data/lib/synapsis/message.ex` | id (UUID), session_id, role, parts (JSONB array), token_count. Append-only (`updated_at: false`) |
| `Synapsis.Part` | — (JSONB) | `apps/synapsis_data/lib/synapsis/part.ex` | Custom Ecto type: 8 part types (Text, ToolUse, ToolResult, Reasoning, Image, File, Snapshot, Agent) |
| `Synapsis.ProviderConfig` | `provider_configs` | `apps/synapsis_data/lib/synapsis/provider_config.ex` | name, type, base_url, api_key_encrypted (AES-256-GCM), config (JSONB) |
| `Synapsis.MemoryEntry` | `memory_entries` | `apps/synapsis_data/lib/synapsis/memory_entry.ex` | scope, scope_id, key, content, metadata (JSONB) |
| `Synapsis.Skill` | `skills` | `apps/synapsis_data/lib/synapsis/skill.ex` | scope, name, system_prompt_fragment, tool_allowlist, config_overrides |
| `Synapsis.PluginConfig` | `plugin_configs` | `apps/synapsis_data/lib/synapsis/plugin_config.ex` | type (mcp/lsp/custom), name, transport, command, args, settings |

### Where `FailedAttempt` and `Patch` structs should live

**In `synapsis_data`** — per the project's Package Policy (CLAUDE.md): "All Postgres persistence MUST go through `synapsis_data`" and "Other packages must NOT define their own Ecto schemas."

**Proposed new schemas:**

**`FailedAttempt`** (`apps/synapsis_data/lib/synapsis/failed_attempt.ex`):
- `id` (UUID), `session_id` (FK → sessions), `attempt_number` (integer), `tool_call_hash` (string), `tool_calls_snapshot` (JSONB), `error_message` (text), `lesson` (text), `triggered_by` (string), `auditor_model` (string), `inserted_at`

**`Patch`** (`apps/synapsis_data/lib/synapsis/patch.ex`):
- `id` (UUID), `session_id` (FK → sessions), `failed_attempt_id` (FK → failed_attempts), `file_path` (string), `diff_text` (text), `git_commit_hash` (string), `test_status` (string: pending/passed/failed), `test_output` (text), `reverted_at` (timestamp), `revert_reason` (text), `inserted_at`, `updated_at`

### Schema migrations needed

Two new migrations:
1. `create_failed_attempts` — new table with session_id FK and indexes
2. `create_patches` — new table with session_id + failed_attempt_id FKs and indexes

Optional: `ALTER TABLE sessions ADD COLUMN orchestrator_status text DEFAULT 'idle'` for tracking orchestration state at the session level.

---

## 8. Test Infrastructure

### Existing patterns

- **46 test files** across 6 apps (all apps except synapsis_web have both unit and integration tests)
- **Test case templates:** `Synapsis.DataCase` (DB sandbox), `SynapsisServer.ConnCase` (HTTP), `SynapsisServer.ChannelCase` (WebSocket) — all in `test/support/`
- **Bypass HTTP mocking:** Used in `synapsis_provider` for streaming SSE tests (`apps/synapsis_provider/test/synapsis/provider/adapter_test.exs`, 327 lines) and declared in `synapsis_core` (`mix.exs:45`)
- **Custom mock:** `SynapsisPlugin.Test.MockPlugin` (`apps/synapsis_plugin/test/support/mock_plugin.ex`) for plugin lifecycle testing
- **No Mox** — custom mocks used instead
- **No coverage tools** — no excoveralls integration

### Testing GenServer message flows without LLM calls

**Pattern available:** The Bypass-based adapter test (`adapter_test.exs`) mocks SSE streams from all 3 providers and collects chunks via a helper function (`collect_chunks/1`, lines 304-325). This pattern can be extended to test the full Worker → Stream → Tool → Worker loop without real LLM calls.

**Channel testing:** `ChannelCase` provides `push/3`, `assert_reply/2`, `assert_broadcast/2` for testing events through the channel (`apps/synapsis_server/test/support/channel_case.ex`).

**Applicable to Orchestrator testing:**
- Bypass for mocking LLM responses (already proven)
- DataCase for testing FailedAttempt/Patch persistence
- GenServer message testing via direct `send/2` to Worker process
- PubSub assertion via `assert_broadcast` for new event types

**Database requirement:** Tests require running PostgreSQL. Connection via socket at `PGHOST` or default socket dir. Database auto-created via mix alias: `test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]` (`apps/synapsis_data/mix.exs:37-43`).

---

## 9. Recommendation [UPDATED]

**Ready to implement** — the design is ~90% complete. Three specific gaps remain.

### Remaining gaps (ordered by priority)

**Gap 1 — Auditor LLM Invocation (Critical)**

**File:** `apps/synapsis_core/lib/synapsis/session/worker.ex`, `execute_orchestrator_actions/2`

**Current:**
```elixir
{:invoke_auditor, _reason} ->
  Logger.info("auditor_invocation_requested", session_id: state.session_id)
```

**Required:** Call `AuditorTask.prepare_escalation/3` to build the prompt, then send it via `Provider.Adapter.stream/2` using the auditor provider/model from agent config, then call `AuditorTask.record_analysis/3` to persist the result as a `FailedAttempt`. Run as `Task.Supervisor.async_nolink` to avoid blocking the Worker.

**Effort:** ~50 LOC change to `worker.ex`, tests via existing Bypass pattern.

---

**Gap 2 — Worktree Patch Promotion (Medium)**

**File:** `apps/synapsis_core/lib/synapsis/session/workspace_manager.ex`

**Current:** `WorkspaceManager` has `setup/2`, `apply_and_test/4`, `revert_and_learn/3`, `teardown/2`. Missing: `promote/2`.

**Required:** Add `promote/2` that applies a tested patch's `diff_text` to the main project tree via `git apply <patch>` in `project_path`. After promotion, the worktree changes are merged to main.

**Also required:** Wire `WorkspaceManager` into `execute_tool_async/2` so file edits go through the worktree instead of writing directly to `project_path`. Currently, tools write directly.

**Effort:** ~30 LOC for `promote/2`, ~20 LOC wiring in `worker.ex`.

---

**Gap 3 — Constraint Broadcast (Minor)**

**File:** `apps/synapsis_core/lib/synapsis/session/auditor_task.ex`, `record_analysis/3`

**Required:** After persisting a `FailedAttempt`, broadcast `"constraint_added"` to `"session:#{session_id}"` so the UI can display new negative constraints.

**Effort:** 3 LOC.

---

**Gap 4 — Provider Model Mismatch (Operational/Config)**

The default model `claude-sonnet-4-20250514` is sent to Moonshot/Z-AI proxy providers that use different model name formats. Sessions produce empty responses because the model is not found. Configure correct model names per provider in the agent config or provider config.

**Effort:** 0 LOC — configuration change only.

### What no longer needs building (implemented since prior audit)

| Component | Status |
|-----------|--------|
| `FailedAttempt` + `Patch` schemas | ✅ Implemented in synapsis_data |
| Migrations | ✅ Applied |
| `Synapsis.Session.Orchestrator` (rules engine) | ✅ Implemented |
| `Synapsis.Session.Monitor` (loop detection) | ✅ Implemented |
| `Synapsis.GitWorktree` | ✅ Implemented |
| `Synapsis.Session.WorkspaceManager` | ✅ Implemented |
| `MessageBuilder` (prompt injection) | ✅ `build_request/4` with `prompt_context` |
| `prompt_builder.ex` (failure log formatting) | ✅ Implemented |
| `auditor_task.ex` (prompt builder) | ✅ Implemented (LLM call is stub) |
| Worker integration | ✅ Monitor/Orchestrator/PromptBuilder wired |

### No breaking changes required

All remaining work is purely additive. The existing 453-test suite passes.

---

## Appendix: Files Examined

### synapsis_core (27 files)
- `apps/synapsis_core/mix.exs`
- `apps/synapsis_core/lib/synapsis_core/application.ex`
- `apps/synapsis_core/lib/synapsis/session/worker.ex`
- `apps/synapsis_core/lib/synapsis/session/supervisor.ex`
- `apps/synapsis_core/lib/synapsis/session/dynamic_supervisor.ex`
- `apps/synapsis_core/lib/synapsis/session/stream.ex`
- `apps/synapsis_core/lib/synapsis/session/compactor.ex`
- `apps/synapsis_core/lib/synapsis/session/fork.ex`
- `apps/synapsis_core/lib/synapsis/session/sharing.ex`
- `apps/synapsis_core/lib/synapsis/sessions.ex`
- `apps/synapsis_core/lib/synapsis/message_builder.ex`
- `apps/synapsis_core/lib/synapsis/config.ex`
- `apps/synapsis_core/lib/synapsis/context_window.ex`
- `apps/synapsis_core/lib/synapsis/agent/resolver.ex`
- `apps/synapsis_core/lib/synapsis/git.ex`
- `apps/synapsis_core/lib/synapsis/file_watcher.ex`
- `apps/synapsis_core/lib/synapsis/tool.ex`
- `apps/synapsis_core/lib/synapsis/tool/behaviour.ex`
- `apps/synapsis_core/lib/synapsis/tool/registry.ex`
- `apps/synapsis_core/lib/synapsis/tool/executor.ex`
- `apps/synapsis_core/lib/synapsis/tool/permission.ex`
- `apps/synapsis_core/lib/synapsis/tool/permissions.ex`
- `apps/synapsis_core/lib/synapsis/tool/builtin.ex`
- `apps/synapsis_core/lib/synapsis/tool/file_read.ex`
- `apps/synapsis_core/lib/synapsis/tool/file_edit.ex`
- `apps/synapsis_core/lib/synapsis/tool/file_write.ex`
- `apps/synapsis_core/lib/synapsis/tool/bash.ex`

### synapsis_data (22 files)
- `apps/synapsis_data/mix.exs`
- `apps/synapsis_data/lib/synapsis/repo.ex`
- `apps/synapsis_data/lib/synapsis/project.ex`
- `apps/synapsis_data/lib/synapsis/session.ex`
- `apps/synapsis_data/lib/synapsis/message.ex`
- `apps/synapsis_data/lib/synapsis/part.ex`
- `apps/synapsis_data/lib/synapsis/part/text.ex`
- `apps/synapsis_data/lib/synapsis/part/tool_use.ex`
- `apps/synapsis_data/lib/synapsis/part/tool_result.ex`
- `apps/synapsis_data/lib/synapsis/part/reasoning.ex`
- `apps/synapsis_data/lib/synapsis/part/image.ex`
- `apps/synapsis_data/lib/synapsis/part/file.ex`
- `apps/synapsis_data/lib/synapsis/part/snapshot.ex`
- `apps/synapsis_data/lib/synapsis/part/agent.ex`
- `apps/synapsis_data/lib/synapsis/provider_config.ex`
- `apps/synapsis_data/lib/synapsis/memory_entry.ex`
- `apps/synapsis_data/lib/synapsis/skill.ex`
- `apps/synapsis_data/lib/synapsis/plugin_config.ex`
- `apps/synapsis_data/lib/synapsis/mcp_config.ex`
- `apps/synapsis_data/lib/synapsis/lsp_config.ex`
- `apps/synapsis_data/lib/synapsis/encrypted/binary.ex`
- `apps/synapsis_data/priv/repo/migrations/` (10 migration files)

### synapsis_provider (10 files)
- `apps/synapsis_provider/mix.exs`
- `apps/synapsis_provider/lib/synapsis/providers.ex`
- `apps/synapsis_provider/lib/synapsis/provider/adapter.ex`
- `apps/synapsis_provider/lib/synapsis/provider/registry.ex`
- `apps/synapsis_provider/lib/synapsis/provider/retry.ex`
- `apps/synapsis_provider/lib/synapsis/provider/model_registry.ex`
- `apps/synapsis_provider/lib/synapsis/provider/message_mapper.ex`
- `apps/synapsis_provider/lib/synapsis/provider/event_mapper.ex`
- `apps/synapsis_provider/lib/synapsis/provider/transport/sse.ex`
- `apps/synapsis_provider/lib/synapsis/provider/transport/anthropic.ex`

### synapsis_server (7 files)
- `apps/synapsis_server/mix.exs`
- `apps/synapsis_server/lib/synapsis_server/supervisor.ex`
- `apps/synapsis_server/lib/synapsis_server/endpoint.ex`
- `apps/synapsis_server/lib/synapsis_server/router.ex`
- `apps/synapsis_server/lib/synapsis_server/channels/user_socket.ex`
- `apps/synapsis_server/lib/synapsis_server/channels/session_channel.ex`
- `apps/synapsis_server/lib/synapsis_server/controllers/sse_controller.ex`

### synapsis_plugin (7 files)
- `apps/synapsis_plugin/mix.exs`
- `apps/synapsis_plugin/lib/synapsis_plugin/supervisor.ex`
- `apps/synapsis_plugin/lib/synapsis_plugin/server.ex`
- `apps/synapsis_plugin/lib/synapsis_plugin/loader.ex`
- `apps/synapsis_plugin/lib/synapsis_plugin/lsp/manager.ex`
- `apps/synapsis_plugin/lib/synapsis_plugin/lsp/protocol.ex`
- `apps/synapsis_plugin/lib/synapsis_plugin/mcp/protocol.ex`

### synapsis_web (2 files)
- `apps/synapsis_web/mix.exs`
- `apps/synapsis_web/lib/synapsis_web/endpoint.ex`

### synapsis_cli (2 files)
- `apps/synapsis_cli/mix.exs`
- `apps/synapsis_cli/lib/synapsis_cli/main.ex`

### Test files (46 files across all apps)
- `apps/synapsis_data/test/` (5 files)
- `apps/synapsis_provider/test/` (8 files)
- `apps/synapsis_core/test/` (11 files)
- `apps/synapsis_server/test/` (6 files)
- `apps/synapsis_plugin/test/` (6 files)
- `apps/synapsis_cli/test/` (3 files)
- `apps/synapsis_web/test/` (5 files)

### Configuration & documentation
- `mix.exs` (umbrella root)
- `config/config.exs`
- `config/test.exs`
- `CLAUDE.md`
- `PRD.md`
- `.secrets.toml` (structure only, no values)
- `docs/architecture/` (7 existing architecture docs)
- `docs/guardrails/GUARDRAILS.md`
