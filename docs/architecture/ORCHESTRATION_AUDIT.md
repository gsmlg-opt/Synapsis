# Agent Orchestration Design — Feasibility Audit

**Date:** 2026-02-20
**Scope:** Read-only analysis of Synapsis codebase against proposed Agent Orchestration & Loop Prevention design
**Auditor:** Automated via 8 parallel exploration agents covering all 7 umbrella apps

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

## 2. Existing Agent Loop

### Current implementation

The agent loop is implemented in `Synapsis.Session.Worker` (`apps/synapsis_core/lib/synapsis/session/worker.ex`, ~780 lines), a GenServer with a state machine:

**State struct** (lines 16-32):
```elixir
defstruct [:session_id, :session, :agent, :provider_config, :stream_ref, :stream_monitor_ref,
  status: :idle, pending_text: "", pending_tool_use: nil, pending_tool_input: "",
  pending_reasoning: "", tool_uses: [], retry_count: 0,
  tool_call_hashes: MapSet.new(), iteration_count: 0]
```

**State machine:** `idle → streaming → tool_executing → idle`

**Loop cycle** (lines 611-676):
1. User sends message → Worker persists to DB → builds provider request via `MessageBuilder` → starts async stream
2. Provider streams SSE chunks → Worker accumulates text/tool_use parts → flushes to DB on stream end
3. If tool_uses present: transition to `:tool_executing` → permission check → async tool execution → persist results
4. After all tools complete: increment `iteration_count` → reload messages from DB → build new request → restart stream → loop back to step 2
5. Loop terminates when: no tool_uses remain, or `iteration_count >= 25` (max iterations, line 612-629)

### What exists vs what needs building

| Feature | Exists | Location | Gap |
|---------|--------|----------|-----|
| Session GenServer state machine | **Yes** | `worker.ex:16-32` | None |
| LLM call cycle (stream → tools → stream) | **Yes** | `worker.ex:611-676` | None |
| Tool call hashing (duplicate detection) | **Yes** | `worker.ex:540-545, 575-577` | Warning only, doesn't prevent execution |
| Iteration limit (25 max) | **Yes** | `worker.ex:612-629` | Hard cap, no escalation |
| Retry with exponential backoff | **Yes** | `worker.ex:267-283` | Max 3 retries, provider errors only |
| Stagnation detection | **No** | — | Needs new Monitor module |
| Test regression tracking | **No** | — | Needs WorkspaceManager |
| Failure log (rolling constraints) | **No** | — | Needs FailedAttempt schema + prompt injection |
| Orchestrator rules engine | **No** | — | Needs new Orchestrator GenServer |
| Dual-model (Worker + Auditor) | **No** | — | Needs per-agent provider selection |

### Existing loop detection detail

**Hash calculation** (`worker.ex:575-577`):
```elixir
call_hash = :erlang.phash2({tool_use.tool, tool_use.input})
is_duplicate = MapSet.member?(state.tool_call_hashes, call_hash)
```

**Hash accumulation** (`worker.ex:540-545`): Hashes stored in `tool_call_hashes` MapSet, reset on each new user message (`worker.ex:119`).

**Current behavior on duplicate** (`worker.ex:596-601`): Appends warning string to tool output but **does not block execution**. This is a foundation that the proposed Monitor can build on.

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

## 9. Recommendation

**Feasible with modifications**

The Synapsis codebase is well-structured for the proposed orchestration design. The foundation is strong: session GenServers, tool call hashing, PubSub infrastructure, and Port-based git operations are all in place. However, several prerequisite changes are needed before implementation can begin.

### Prerequisites (ordered by dependency)

**P1 — New schemas in `synapsis_data`** (blocks everything else):
- Add `FailedAttempt` schema and migration
- Add `Patch` schema and migration
- Optional: add `orchestrator_status` field to `sessions` table

**P2 — System prompt injection** (~10 LOC change):
- Extend `Synapsis.MessageBuilder.build_request/3` (`apps/synapsis_core/lib/synapsis/message_builder.ex`) to accept optional `prompt_context` parameter
- Append failure log entries as `## Failed Approaches` block to system prompt before each provider call

**P3 — Git worktree support** (~100 LOC new module):
- Create `Synapsis.GitWorktree` module with Port-based `git worktree add/remove/list` commands
- Add `git apply` wrapper for patch application
- Follow existing `Synapsis.Git` patterns (`git.ex:57-63`)

**P4 — Per-agent provider selection** (~30 LOC change):
- Extend agent config format to include `provider` field alongside existing `model`
- Update `Synapsis.Agent.Resolver` to resolve provider from agent config (fallback to session provider)
- Update `Synapsis.MessageBuilder` to accept provider from agent

**P5 — `.secrets.toml` loading** (optional, ~50 LOC):
- Add TOML parser dependency
- Create loader module to parse `.secrets.toml` and register providers
- Alternative: use existing DB/env-based config (no code change needed)

### No breaking changes required

All proposed additions are **additive**:
- New GenServer modules under `synapsis_core`
- New schemas in `synapsis_data`
- New PubSub events (generic handler accepts them automatically)
- Extended `MessageBuilder` API (backward-compatible with optional param)
- Existing session lifecycle unchanged — orchestration wraps around it

### Estimated scope

| Component | New/Modify | LOC Estimate |
|-----------|-----------|--------------|
| `FailedAttempt` + `Patch` schemas | New | ~120 |
| Migrations | New | ~60 |
| `Synapsis.Orchestrator` (rules engine) | New | ~300 |
| `Synapsis.Monitor` (loop detection) | New | ~150 |
| `Synapsis.GitWorktree` | New | ~100 |
| `MessageBuilder` (prompt injection) | Modify | ~10 |
| `Agent.Resolver` (provider selection) | Modify | ~30 |
| `prompt_builder.ex` (failure log formatting) | New | ~80 |
| `auditor_task.ex` (secondary model call) | New | ~100 |
| `token_budget.ex` (budget tracking) | New | ~60 |
| Tests | New | ~500 |
| **Total** | | **~1,510** |

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
