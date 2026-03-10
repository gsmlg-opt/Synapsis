# Implementation Plan: Synapsis Tool System

**Branch**: `feature/tool-system` | **Date**: 2026-03-10 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/tool-system/spec.md`

## Summary

Expand the Synapsis tool system from 11 to 27 built-in tools with enhanced behaviour contract (self-declared permission levels, categories, versioning, enabled flags), extended permission engine with per-tool glob overrides and autonomous mode, parallel tool execution via Task.async_stream, side effect broadcasting, deferred tool loading for MCP plugins, plan mode integration, sub-agent orchestration, and swarm coordination tools.

The existing tool infrastructure in `apps/synapsis_core/lib/synapsis/tool/` provides the foundation: `Synapsis.Tool` behaviour, ETS-backed `Synapsis.Tool.Registry`, `Synapsis.Tool.Executor` with Task.Supervisor, `Synapsis.Tool.Permission`, and 11 built-in tools. This feature extends rather than replaces the existing code.

## Technical Context

**Language/Version**: Elixir 1.18+ / OTP 28+
**Primary Dependencies**: Phoenix 1.8+ (PubSub only in core), Ecto, Req + Finch (for web tools)
**Storage**: PostgreSQL 16+ via Ecto (tool_calls table, session_permissions, session_todos)
**Testing**: ExUnit with Bypass for HTTP mocking, start_supervised!/1 for process cleanup
**Target Platform**: Linux server (BEAM VM)
**Project Type**: Elixir umbrella (8 apps)
**Performance Goals**: Tool executor pipeline <50ms for non-I/O tools, 50 concurrent tool calls per session, parallel execution achieves 2x+ speedup over sequential
**Constraints**: All tools implement `Synapsis.Tool` behaviour, path validation against project root, Port-based shell execution, structured logging only
**Scale/Scope**: 27 tool modules, 16 new tools to implement, extensions to registry/executor/permissions

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Functional Core, Imperative Shell | PASS | Tool behaviour is pure (parameters, name, description). Side effects at process boundaries only (executor broadcasts via PubSub). |
| II. Database as Source of Truth | PASS | Tool calls persisted to DB. Todo items in DB. Session permissions in DB. GenServers hold only transient state. |
| III. Process-per-Session | PASS | Bash tool uses Port per session. Sub-agents spawn as separate processes. Tool executor uses Task.Supervisor. |
| IV. Provider-Agnostic Streaming | N/A | Tool system does not directly interact with providers. |
| V. Permission-Controlled Tool Execution | PASS | Core requirement of this feature. Extended from 3 to 5 permission levels with glob overrides. |
| VI. Structured Observability | PASS | All tool calls logged via structured logging. Tests use Bypass, start_supervised!, no Process.sleep. |
| VII. Strict Umbrella Dependency Direction | DISCUSSION | PRD proposes new `apps/synapsis_tool/` app. See Complexity Tracking. |

### Umbrella Placement Decision

The PRD specifies a new `apps/synapsis_tool/` sub-application. However, the existing codebase already has the tool system in `apps/synapsis_core/lib/synapsis/tool/` with 11 working tools, and the constitution designates `synapsis_core` as the home for "sessions, tools, agents, config."

**Decision: Keep tools in `synapsis_core`**. Rationale:
1. The existing 11 tools, registry, executor, and permission engine are already in `synapsis_core` and working
2. The constitution explicitly lists tools as `synapsis_core` scope
3. Extracting to a new app would require moving ~15 modules, updating all imports, and rewriting tests — high cost, low value
4. The PRD's architectural goal (isolate tool contracts from agent loop) is already achieved via the `Synapsis.Tool` behaviour module boundary within `synapsis_core`
5. `synapsis_plugin` already depends on `synapsis_core` for tool registration — adding an intermediate `synapsis_tool` app changes the dependency graph without clear benefit

All 27 tools will live under `apps/synapsis_core/lib/synapsis/tool/` using the `Synapsis.Tool.*` namespace, consistent with existing code.

## Project Structure

### Documentation (this feature)

```text
specs/tool-system/
├── plan.md              # This file
├── research.md          # Phase 0: Research findings
├── data-model.md        # Phase 1: Data model for new tables
├── quickstart.md        # Phase 1: Developer quickstart
├── contracts/           # Phase 1: API contracts
│   ├── tool-behaviour.md    # Extended behaviour contract
│   ├── executor-api.md      # Executor pipeline API
│   ├── registry-api.md      # Registry API extensions
│   └── permissions-api.md   # Permission engine API
└── tasks.md             # Phase 2: Task breakdown (via /speckit.tasks)
```

### Source Code (repository root)

```text
apps/synapsis_core/
├── lib/synapsis/tool/
│   ├── behaviour.ex              # Extended: add permission_level, category, version, enabled?
│   ├── registry.ex               # Extended: list_for_llm filtering, deferred tools, categories
│   ├── executor.ex               # Extended: parallel execution, batch permission approval
│   ├── permission.ex             # Redesigned: 5 levels, glob overrides, autonomous mode
│   ├── permissions.ex            # Extended: session permission config resolution
│   ├── path_validator.ex         # Existing (no changes)
│   ├── builtin.ex                # Extended: register all 27 tools
│   ├── context.ex                # NEW: Tool context struct (agent_mode, parent_agent, etc.)
│   │
│   ├── # Existing tools (extend as needed)
│   ├── file_read.ex              # Existing — add category, version, permission_level callbacks
│   ├── file_edit.ex              # Existing — add new callbacks
│   ├── file_write.ex             # Existing — add new callbacks
│   ├── file_delete.ex            # Existing — add new callbacks
│   ├── file_move.ex              # Existing — add new callbacks
│   ├── bash.ex                   # Existing — add new callbacks
│   ├── grep.ex                   # Existing — add new callbacks
│   ├── glob.ex                   # Existing — add new callbacks
│   ├── fetch.ex                  # Existing (rename to web_fetch?) — add new callbacks
│   ├── diagnostics.ex            # Existing — add new callbacks
│   ├── list_dir.ex               # Existing — add new callbacks
│   │
│   ├── # New tools (16 new modules)
│   ├── multi_edit.ex             # NEW: Multi-file edit with rollback
│   ├── web_search.ex             # NEW: Web search engine queries
│   ├── todo_write.ex             # NEW: Session-scoped task checklist
│   ├── todo_read.ex              # NEW: Read current todo state
│   ├── task.ex                   # NEW: Sub-agent launcher (foreground/background)
│   ├── tool_search.ex            # NEW: Deferred tool discovery
│   ├── skill.ex                  # NEW: Skill file loader
│   ├── ask_user.ex               # NEW: Structured user questions
│   ├── enter_plan_mode.ex        # NEW: Switch to plan mode
│   ├── exit_plan_mode.ex         # NEW: Exit plan mode with plan
│   ├── sleep.ex                  # NEW: Interruptible wait
│   ├── send_message.ex           # NEW: Inter-agent messaging (swarm)
│   ├── teammate.ex               # NEW: Agent creation/management (swarm)
│   ├── team_delete.ex            # NEW: Swarm dissolution
│   ├── notebook_read.ex          # NEW: Jupyter notebook read (disabled)
│   └── notebook_edit.ex          # NEW: Jupyter notebook edit (disabled)
│   └── computer.ex               # NEW: Computer use stub (disabled)
│
├── test/synapsis/tool/
│   ├── behaviour_test.exs        # Extended behaviour tests
│   ├── registry_test.exs         # Extended registry tests
│   ├── executor_test.exs         # Extended executor tests (parallel, batch)
│   ├── permission_test.exs       # Redesigned permission tests
│   ├── context_test.exs          # NEW: context struct tests
│   ├── multi_edit_test.exs       # NEW
│   ├── web_search_test.exs       # NEW (Bypass)
│   ├── todo_write_test.exs       # NEW
│   ├── todo_read_test.exs        # NEW
│   ├── task_test.exs             # NEW
│   ├── tool_search_test.exs      # NEW
│   ├── skill_test.exs            # NEW
│   ├── ask_user_test.exs         # NEW
│   ├── plan_mode_test.exs        # NEW (covers enter/exit)
│   ├── sleep_test.exs            # NEW
│   ├── swarm_test.exs            # NEW (covers send_message, teammate, team_delete)
│   ├── notebook_test.exs         # NEW (disabled tools test)
│   └── computer_test.exs         # NEW (disabled tool test)

apps/synapsis_data/
├── lib/synapsis/
│   ├── tool_call.ex              # NEW: Tool call persistence schema
│   ├── session_permission.ex     # NEW: Session permission config schema
│   └── session_todo.ex           # NEW: Todo item schema
├── priv/repo/migrations/
│   ├── *_create_tool_calls.exs   # NEW
│   ├── *_create_session_permissions.exs  # NEW
│   └── *_create_session_todos.exs        # NEW
```

**Structure Decision**: Extend existing `synapsis_core` tool system in-place. New schemas in `synapsis_data`. No new umbrella app created. This follows the existing dependency direction and constitution.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| PRD specifies `apps/synapsis_tool/` as separate app | Not implementing — tools stay in `synapsis_core` | Constitution places tools in `synapsis_core`. Existing 11 tools already there. Extraction costs outweigh benefits. The PRD's isolation goal is achieved via module boundary (`Synapsis.Tool.*` namespace). |
