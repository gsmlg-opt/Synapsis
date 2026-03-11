# Tasks: Synapsis Tool System

**Input**: Design documents from `/specs/tool-system/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/

**Tests**: Tests are included for each phase since the CLAUDE.md requires `mix test` passes after each phase.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2)
- Include exact file paths in descriptions

## Path Conventions

- **Core tools**: `apps/synapsis_core/lib/synapsis/tool/`
- **Core tests**: `apps/synapsis_core/test/synapsis/tool/`
- **Data schemas**: `apps/synapsis_data/lib/synapsis/`
- **Data tests**: `apps/synapsis_data/test/synapsis/`
- **Migrations**: `apps/synapsis_data/priv/repo/migrations/`

---

## Phase 1: Setup (Database Schemas & Migrations)

**Purpose**: Create the 3 new database tables and Ecto schemas required by the tool system

- [x] T001 [P] Create migration for `tool_calls` table in `apps/synapsis_data/priv/repo/migrations/*_create_tool_calls.exs` per data-model.md (UUID PK, session_id FK, message_id FK nullable, tool_name, input JSONB, output JSONB nullable, status, duration_ms, error_message, indexes on session_id, session_id+tool_name, session_id+status)
- [x] T002 [P] Create migration for `session_permissions` table in `apps/synapsis_data/priv/repo/migrations/*_create_session_permissions.exs` per data-model.md (UUID PK, session_id FK unique, mode, allow_write, allow_execute, allow_destructive, tool_overrides JSONB)
- [x] T003 [P] Create migration for `session_todos` table in `apps/synapsis_data/priv/repo/migrations/*_create_session_todos.exs` per data-model.md (UUID PK, session_id FK, todo_id, content, status, sort_order, unique index on session_id+todo_id)
- [x] T004 [P] Implement `Synapsis.ToolCall` Ecto schema in `apps/synapsis_data/lib/synapsis/tool_call.ex` with changeset, status enum (pending/approved/denied/completed/error), belongs_to session and message
- [x] T005 [P] Implement `Synapsis.SessionPermission` Ecto schema in `apps/synapsis_data/lib/synapsis/session_permission.ex` with changeset, mode enum (interactive/autonomous), allow_destructive enum (allow/deny/ask), belongs_to session
- [x] T006 [P] Implement `Synapsis.SessionTodo` Ecto schema in `apps/synapsis_data/lib/synapsis/session_todo.ex` with changeset, status enum (pending/in_progress/completed), belongs_to session
- [x] T007 [P] Add `has_many :tool_calls`, `has_one :permission`, and `has_many :todos` associations to existing `Synapsis.Session` schema in `apps/synapsis_data/lib/synapsis/session.ex`
- [x] T008 [P] Write tests for ToolCall schema in `apps/synapsis_data/test/synapsis/tool_call_test.exs` — changeset validations, status transitions, association loading
- [x] T009 [P] Write tests for SessionPermission schema in `apps/synapsis_data/test/synapsis/session_permission_test.exs` — changeset validations, unique session constraint, enum values
- [x] T010 [P] Write tests for SessionTodo schema in `apps/synapsis_data/test/synapsis/session_todo_test.exs` — changeset validations, unique session_id+todo_id constraint

**Checkpoint**: `mix ecto.migrate && mix test apps/synapsis_data` — all migrations run, all schema tests pass.

---

## Phase 2: Foundational (Behaviour Extension & Existing Tool Updates)

**Purpose**: Extend the `Synapsis.Tool` behaviour with new callbacks and update all 11 existing tools. BLOCKS all user story phases.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [x] T011 Extend `Synapsis.Tool` behaviour in `apps/synapsis_core/lib/synapsis/tool.ex` — add `@callback permission_level/0`, `@callback category/0`, `@callback version/0`, `@callback enabled?/0` as `@optional_callbacks`, add `@type permission_level`, `@type category` types, update `__using__/1` macro to provide defaults (`:read`, `:filesystem`, `"1.0.0"`, `true`) per contracts/tool-behaviour.md
- [x] T012 Create `Synapsis.Tool.Context` struct in `apps/synapsis_core/lib/synapsis/tool/context.ex` — defstruct with fields: session_id, project_path, working_dir, permissions, session_pid, agent_mode (:build/:plan), parent_agent (pid|nil), plus `new/1` constructor and `sub_agent_context/2` helper
- [x] T013 [P] Update `Synapsis.Tool.FileRead` in `apps/synapsis_core/lib/synapsis/tool/file_read.ex` — add `permission_level: :read`, `category: :filesystem` callbacks
- [x] T014 [P] Update `Synapsis.Tool.FileWrite` in `apps/synapsis_core/lib/synapsis/tool/file_write.ex` — add `permission_level: :write`, `category: :filesystem`, `side_effects: [:file_changed]` callbacks
- [x] T015 [P] Update `Synapsis.Tool.FileEdit` in `apps/synapsis_core/lib/synapsis/tool/file_edit.ex` — add `permission_level: :write`, `category: :filesystem`, `side_effects: [:file_changed]` callbacks
- [x] T016 [P] Update `Synapsis.Tool.FileDelete` in `apps/synapsis_core/lib/synapsis/tool/file_delete.ex` — add `permission_level: :destructive`, `category: :filesystem`, `side_effects: [:file_changed]` callbacks
- [x] T017 [P] Update `Synapsis.Tool.FileMove` in `apps/synapsis_core/lib/synapsis/tool/file_move.ex` — add `permission_level: :write`, `category: :filesystem`, `side_effects: [:file_changed]` callbacks
- [x] T018 [P] Update `Synapsis.Tool.ListDir` in `apps/synapsis_core/lib/synapsis/tool/list_dir.ex` — add `permission_level: :read`, `category: :filesystem` callbacks
- [x] T019 [P] Update `Synapsis.Tool.Grep` in `apps/synapsis_core/lib/synapsis/tool/grep.ex` — add `permission_level: :read`, `category: :search` callbacks
- [x] T020 [P] Update `Synapsis.Tool.Glob` in `apps/synapsis_core/lib/synapsis/tool/glob.ex` — add `permission_level: :read`, `category: :search` callbacks
- [x] T021 [P] Update `Synapsis.Tool.Bash` in `apps/synapsis_core/lib/synapsis/tool/bash.ex` — add `permission_level: :execute`, `category: :execution` callbacks
- [x] T022 [P] Update `Synapsis.Tool.Fetch` in `apps/synapsis_core/lib/synapsis/tool/fetch.ex` — add `permission_level: :read`, `category: :web` callbacks
- [x] T023 [P] Update `Synapsis.Tool.Diagnostics` in `apps/synapsis_core/lib/synapsis/tool/diagnostics.ex` — add `permission_level: :read`, `category: :search` callbacks
- [x] T024 Write tests for extended behaviour in `apps/synapsis_core/test/synapsis/tool/behaviour_test.exs` — verify new callbacks have defaults, verify overrides work, verify @optional_callbacks compile, test Tool.Context struct creation and sub_agent_context helper

**Checkpoint**: `mix compile --warnings-as-errors && mix test apps/synapsis_core` — all existing tools compile with new callbacks, all existing tests still pass, new behaviour tests pass.

---

## Phase 3: US4 — Tool Registry & Executor Pipeline (Priority: P1)

**Goal**: Extend the registry with filtering (agent_mode, category, deferred, enabled) and extend the executor with parallel batch execution and tool call persistence.

**Independent Test**: Register mock tools with various categories/permissions/enabled flags, call `list_for_llm/1` with different filters, execute batch calls and verify parallelism and serialization.

### Implementation

- [x] T025 [US4] Extend `Synapsis.Tool.Registry` in `apps/synapsis_core/lib/synapsis/tool/registry.ex` — update ETS schema to store category, permission_level, version, enabled, deferred flags; update `register_module/3` to accept opts `deferred: bool`; read category/permission_level/version/enabled from module callbacks during registration
- [x] T026 [US4] Add `list_for_llm/1` with opts to `Synapsis.Tool.Registry` — filter by `agent_mode` (exclude write/execute/destructive in :plan mode), `include_deferred` (default false), `categories` (list filter); add `list_by_category/1`; add `mark_loaded/1` to activate deferred tools
- [x] T027 [US4] Extend `Synapsis.Tool.Executor` in `apps/synapsis_core/lib/synapsis/tool/executor.ex` — add enabled check after registry lookup (return `{:error, :tool_disabled}` if `enabled?/0` returns false); add `{:pending_approval, ref}` return path for `:ask` permission result
- [x] T028 [US4] Implement `execute_batch/2` in `Synapsis.Tool.Executor` — group tool calls by target file path, serialize same-file writes, parallelize independent calls via `Task.async_stream/3` under `Synapsis.Tool.TaskSupervisor` with `max_concurrency: System.schedulers_online()`, return `[{call_id, result}]` in input order
- [x] T029 [US4] Add tool call persistence to executor — after each tool execution, insert `Synapsis.ToolCall` record via `Synapsis.Repo` with tool_name, input, output, status, duration_ms; update status on approval/denial
- [x] T030 [US4] Update `Synapsis.Tool.Builtin.register_all/0` in `apps/synapsis_core/lib/synapsis/tool/builtin.ex` — ensure registration reads new callback values (category, permission_level, version, enabled) from each tool module
- [x] T031 [P] [US4] Write registry extension tests in `apps/synapsis_core/test/synapsis/tool/registry_test.exs` — test list_for_llm filtering by agent_mode, category, deferred; test mark_loaded; test enabled filtering; test list_by_category
- [x] T032 [P] [US4] Write executor extension tests in `apps/synapsis_core/test/synapsis/tool/executor_test.exs` — test execute_batch parallel execution (verify speedup), test same-file serialization, test enabled check, test pending_approval flow, test tool call persistence to DB

**Checkpoint**: `mix test apps/synapsis_core/test/synapsis/tool/registry_test.exs apps/synapsis_core/test/synapsis/tool/executor_test.exs` — registry filtering and parallel execution work correctly.

---

## Phase 4: US5 — Permission System (Priority: P1)

**Goal**: Redesign the permission engine with 5 levels, per-tool glob overrides, session-level config from DB, and autonomous mode.

**Independent Test**: Configure various permission profiles (interactive with overrides, autonomous), invoke tools at different permission levels, verify allow/deny/ask resolution.

### Implementation

- [x] T033 [US5] Redesign `Synapsis.Tool.Permission` in `apps/synapsis_core/lib/synapsis/tool/permission.ex` — implement `check/3` with 3-step resolution: (1) per-tool glob override match, (2) session-level default for tool's permission_level, (3) tool-declared permission_level; implement `resolve_override/3` for glob pattern matching (e.g., `"bash(git *)"` matches bash tool with git commands)
- [x] T034 [US5] Implement `session_config/1` and `update_config/2` in `Synapsis.Tool.Permission` — load `Synapsis.SessionPermission` from DB for session, cache in process dictionary or ETS for performance, return defaults if no config exists; `update_config` upserts the session_permissions row
- [x] T035 [US5] Implement autonomous mode logic in `Synapsis.Tool.Permission` — when `mode: :autonomous`, auto-allow all tools at `:execute` level and below; `:destructive` tools follow `allow_destructive` setting
- [x] T036 [P] [US5] Write comprehensive permission tests in `apps/synapsis_core/test/synapsis/tool/permission_test.exs` — test all 5 permission levels with interactive/autonomous modes; test glob override matching (exact match, wildcard match, no match fallback); test resolution priority order; test session config loading from DB; test defaults when no config

**Checkpoint**: `mix test apps/synapsis_core/test/synapsis/tool/permission_test.exs` — 100% coverage on permission resolution logic.

---

## Phase 5: US1 — Agent Reads, Edits, and Writes Files (Priority: P1) 🎯 MVP

**Goal**: Implement the `multi_edit` tool (only new filesystem tool). Existing filesystem tools already updated in Phase 2.

**Independent Test**: Call multi_edit with edits across two files where one edit fails — verify rollback per file, verify side effect broadcast for successful file.

### Implementation

- [x] T037 [US1] Implement `Synapsis.Tool.MultiEdit` in `apps/synapsis_core/lib/synapsis/tool/multi_edit.ex` — accept `edits` array of `{path, old_text, new_text}`; group by file; apply edits sequentially within each file; rollback file on any edit failure; cross-file edits are independent (partial success); broadcast `:file_changed` side effect per successful file; `permission_level: :write`, `category: :filesystem`, `side_effects: [:file_changed]`
- [x] T038 [US1] Register `multi_edit` in `Synapsis.Tool.Builtin.register_all/0` in `apps/synapsis_core/lib/synapsis/tool/builtin.ex`
- [x] T039 [P] [US1] Write tests for MultiEdit in `apps/synapsis_core/test/synapsis/tool/multi_edit_test.exs` — test single file multiple edits, test cross-file edits, test rollback on failure within one file while other file succeeds, test non-existent file returns error, test path validation

**Checkpoint**: `mix test apps/synapsis_core/test/synapsis/tool/multi_edit_test.exs` — multi_edit works with rollback semantics.

---

## Phase 6: US2+US3 — Agent Searches Codebase & Executes Shell Commands (Priority: P1)

**Goal**: Verify existing search and bash tools work correctly with new behaviour callbacks. No new tools needed — grep, glob, bash already exist and were updated in Phase 2.

**Independent Test**: Invoke grep, glob, and bash tools through the executor pipeline and verify they pass with new callback metadata.

### Implementation

- [x] T040 [US2] [US3] Write integration test in `apps/synapsis_core/test/synapsis/tool/integration_test.exs` — test grep/glob/bash tools through full executor pipeline with new registry metadata (verify category, permission_level are correctly stored and filtered); test bash state persistence across calls; test grep .gitignore filtering; test glob sorting by modification time

**Checkpoint**: `mix test apps/synapsis_core/test/synapsis/tool/integration_test.exs` — existing tools work end-to-end with new infrastructure.

---

## Phase 7: US6 — Agent Uses Planning and Todo Tools (Priority: P2)

**Goal**: Implement todo_write, todo_read, enter_plan_mode, exit_plan_mode tools and plan mode filtering.

**Independent Test**: Create todos, switch to plan mode, verify write tools are disabled, exit plan mode, verify full access resumes.

### Implementation

- [x] T041 [P] [US6] Implement `Synapsis.Tool.TodoWrite` in `apps/synapsis_core/lib/synapsis/tool/todo_write.ex` — accept `todos` array of `{id, content, status}`; replace entire todo list in DB via `Synapsis.SessionTodo` (delete existing + insert new); broadcast `todo_update` to session PubSub topic; `permission_level: :none`, `category: :planning`
- [x] T042 [P] [US6] Implement `Synapsis.Tool.TodoRead` in `apps/synapsis_core/lib/synapsis/tool/todo_read.ex` — query `Synapsis.SessionTodo` for session, return ordered list; `permission_level: :none`, `category: :planning`
- [x] T043 [P] [US6] Implement `Synapsis.Tool.EnterPlanMode` in `apps/synapsis_core/lib/synapsis/tool/enter_plan_mode.ex` — update session's `agent_mode` to `:plan` via context/session state; broadcast mode change; `permission_level: :none`, `category: :session`
- [x] T044 [P] [US6] Implement `Synapsis.Tool.ExitPlanMode` in `apps/synapsis_core/lib/synapsis/tool/exit_plan_mode.ex` — accept `plan` string; broadcast plan to session channel for user approval; on approval, set `agent_mode` back to `:build`; `permission_level: :none`, `category: :session`
- [x] T045 [US6] Register todo_write, todo_read, enter_plan_mode, exit_plan_mode in `Synapsis.Tool.Builtin.register_all/0`
- [x] T046 [P] [US6] Write todo tool tests in `apps/synapsis_core/test/synapsis/tool/todo_test.exs` — test todo_write replaces full list, test todo_read returns current state, test PubSub broadcast on write, test empty list handling
- [x] T047 [P] [US6] Write plan mode tests in `apps/synapsis_core/test/synapsis/tool/plan_mode_test.exs` — test enter_plan_mode disables write/execute/destructive tools in list_for_llm, test exit_plan_mode restores full access, test plan broadcast

**Checkpoint**: `mix test apps/synapsis_core/test/synapsis/tool/todo_test.exs apps/synapsis_core/test/synapsis/tool/plan_mode_test.exs` — planning workflow works.

---

## Phase 8: US8 — Agent Searches Web and Fetches Pages (Priority: P2)

**Goal**: Implement `web_search` tool. The existing `Fetch` tool already handles web_fetch functionality.

**Independent Test**: Call web_search with mock Bypass backend, verify results with titles/URLs/snippets are returned.

### Implementation

- [x] T048 [US8] Implement `Synapsis.Tool.WebSearch` in `apps/synapsis_core/lib/synapsis/tool/web_search.ex` — accept `query` and optional `max_results` (default 5); use Req to call configurable search API (Brave Search by default); parse results into `[%{title, url, snippet}]`; `permission_level: :read`, `category: :web`
- [x] T049 [US8] Register web_search in `Synapsis.Tool.Builtin.register_all/0`
- [x] T050 [P] [US8] Write web_search tests in `apps/synapsis_core/test/synapsis/tool/web_search_test.exs` — use Bypass to mock search API; test successful query, test max_results parameter, test API error handling, test missing API key error

**Checkpoint**: `mix test apps/synapsis_core/test/synapsis/tool/web_search_test.exs` — web search returns structured results.

---

## Phase 9: US9 — Agent Interacts with User (Priority: P2)

**Goal**: Implement `ask_user` tool that presents structured questions and blocks until user response.

**Independent Test**: Trigger ask_user, verify PubSub broadcast, send response, verify tool unblocks.

### Implementation

- [x] T051 [US9] Implement `Synapsis.Tool.AskUser` in `apps/synapsis_core/lib/synapsis/tool/ask_user.ex` — accept `questions` array with `question`, `options` (label+description), `multi_select`; broadcast questions to session PubSub topic as `{:ask_user, ref, questions}`; block via `receive` waiting for `{:user_response, ref, response}`; return user's selection or free-text; `permission_level: :none`, `category: :interaction`; deny if `context.parent_agent` is not nil (sub-agents cannot use ask_user)
- [x] T052 [US9] Register ask_user in `Synapsis.Tool.Builtin.register_all/0`
- [x] T053 [P] [US9] Write ask_user tests in `apps/synapsis_core/test/synapsis/tool/ask_user_test.exs` — test question broadcast, test blocking and unblocking on response, test free-text response, test sub-agent denial (parent_agent set), test multi_select option

**Checkpoint**: `mix test apps/synapsis_core/test/synapsis/tool/ask_user_test.exs` — user interaction flow works.

---

## Phase 10: US7 — Agent Launches Sub-Agents (Priority: P2)

**Goal**: Implement `task` tool for foreground and background sub-agent execution, plus `skill` and `sleep` tools.

**Independent Test**: Launch foreground sub-agent with read-only tools, verify it completes and returns result; test sub-agent cannot use ask_user.

### Implementation

- [x] T054 [US7] Implement `Synapsis.Tool.Task` in `apps/synapsis_core/lib/synapsis/tool/task.ex` — accept `prompt`, optional `tools` (default read-only: file_read, list_dir, grep, glob), optional `mode` (foreground/background), optional `model`; foreground: spawn sub-agent process under Task.Supervisor, block until complete, return result; background: spawn and return `{:ok, %{task_id, status: "running"}}`; restrict tools via `Tool.Context.sub_agent_context/2`; `permission_level: :none`, `category: :orchestration`
- [x] T055 [P] [US7] Implement `Synapsis.Tool.Skill` in `apps/synapsis_core/lib/synapsis/tool/skill.ex` — accept `name`; search for SKILL.md in project `.synapsis/skills/`, user `~/.config/synapsis/skills/`, and built-in locations; parse frontmatter (name, description, tools, model); return skill content for injection into conversation; `permission_level: :none`, `category: :orchestration`
- [x] T056 [P] [US7] Implement `Synapsis.Tool.Sleep` in `apps/synapsis_core/lib/synapsis/tool/sleep.ex` — accept `duration_ms` and optional `reason`; implement via `receive after duration_ms` with early wake on `{:user_input, _}` message; `permission_level: :none`, `category: :session`
- [x] T057 [US7] Register task, skill, sleep in `Synapsis.Tool.Builtin.register_all/0`
- [x] T058 [P] [US7] Write task tool tests in `apps/synapsis_core/test/synapsis/tool/task_test.exs` — test foreground sub-agent with restricted tools, test background mode returns task_id, test sub-agent cannot use ask_user (parent_agent set in context), test sub-agent tool restriction
- [x] T059 [P] [US7] Write skill and sleep tests in `apps/synapsis_core/test/synapsis/tool/skill_test.exs` and `apps/synapsis_core/test/synapsis/tool/sleep_test.exs` — test skill discovery from project/user/builtin paths, test sleep with early wake, test sleep timeout

**Checkpoint**: `mix test apps/synapsis_core/test/synapsis/tool/task_test.exs apps/synapsis_core/test/synapsis/tool/skill_test.exs apps/synapsis_core/test/synapsis/tool/sleep_test.exs` — orchestration tools work.

---

## Phase 11: US10 — Plugin Tools via MCP/LSP (Priority: P3)

**Goal**: Implement `tool_search` for deferred tool discovery and activation. Wire deferred loading into existing plugin system.

**Independent Test**: Register mock deferred tools, call tool_search to discover them, verify they become available in list_for_llm after activation.

### Implementation

- [x] T060 [US10] Implement `Synapsis.Tool.ToolSearch` in `apps/synapsis_core/lib/synapsis/tool/tool_search.ex` — accept `query` and optional `limit` (default 5); search registry for deferred tools matching query against name and description; return matching tool definitions (name, description, parameters); call `Registry.mark_loaded/1` to activate matched tools; `permission_level: :none`, `category: :orchestration`
- [x] T061 [US10] Update plugin registration in `apps/synapsis_plugin/lib/synapsis_plugin/loader.ex` — when registering MCP tools, pass `deferred: true` to `Registry.register_process/3`; ensure deferred tools have full metadata (description, parameters) stored in ETS
- [x] T062 [US10] Register tool_search in `Synapsis.Tool.Builtin.register_all/0`
- [x] T063 [P] [US10] Write tool_search tests in `apps/synapsis_core/test/synapsis/tool/tool_search_test.exs` — test search by keyword, test limit parameter, test mark_loaded activates deferred tool, test deferred tools excluded from list_for_llm before activation, test included after activation

**Checkpoint**: `mix test apps/synapsis_core/test/synapsis/tool/tool_search_test.exs` — deferred loading lifecycle works.

---

## Phase 12: US11 — Swarm Multi-Agent Coordination (Priority: P3)

**Goal**: Implement send_message, teammate, team_delete swarm tools for within-session multi-agent coordination.

**Independent Test**: Create a teammate agent, send a message to it, dissolve the team, verify outputs collected.

### Implementation

- [x] T064 [P] [US11] Implement `Synapsis.Tool.SendMessage` in `apps/synapsis_core/lib/synapsis/tool/send_message.ex` — accept `to` (teammate ID), `content`, optional `type` (request/response/notify), optional `in_reply_to`; route message via PubSub to `"swarm:#{swarm_id}:#{to}"`; `permission_level: :none`, `category: :swarm`
- [x] T065 [P] [US11] Implement `Synapsis.Tool.Teammate` in `apps/synapsis_core/lib/synapsis/tool/teammate.ex` — accept `action` (create/list/get/update), `name`, `prompt`, `tools`, `model`; create: spawn agent process with own conversation history under Task.Supervisor; list: return roster; get: return teammate info; update: modify teammate config; `permission_level: :none`, `category: :swarm`
- [x] T066 [P] [US11] Implement `Synapsis.Tool.TeamDelete` in `apps/synapsis_core/lib/synapsis/tool/team_delete.ex` — terminate all teammate processes, collect final outputs, return summary; `permission_level: :none`, `category: :swarm`
- [x] T067 [US11] Register send_message, teammate, team_delete in `Synapsis.Tool.Builtin.register_all/0`
- [x] T068 [P] [US11] Write swarm tests in `apps/synapsis_core/test/synapsis/tool/swarm_test.exs` — test teammate creation and listing, test send_message routing via PubSub, test team_delete terminates processes and collects outputs

**Checkpoint**: `mix test apps/synapsis_core/test/synapsis/tool/swarm_test.exs` — swarm coordination works.

---

## Phase 13: Disabled Tool Stubs (Priority: P3)

**Goal**: Implement notebook_read, notebook_edit, and computer as disabled-by-default tool modules with reserved parameter schemas.

**Independent Test**: Verify disabled tools compile, return `enabled?: false`, are excluded from list_for_llm, and executor returns `{:error, :tool_disabled}`.

### Implementation

- [x] T069 [P] Implement `Synapsis.Tool.NotebookRead` in `apps/synapsis_core/lib/synapsis/tool/notebook_read.ex` — full parameter schema (path), `enabled?: false`, `permission_level: :read`, `category: :notebook`; execute returns `{:error, "Notebook tools are not enabled"}`
- [x] T070 [P] Implement `Synapsis.Tool.NotebookEdit` in `apps/synapsis_core/lib/synapsis/tool/notebook_edit.ex` — full parameter schema (path, cell_number, content, cell_type, edit_mode), `enabled?: false`, `permission_level: :write`, `category: :notebook`, `side_effects: [:file_changed]`; execute returns `{:error, "Notebook tools are not enabled"}`
- [x] T071 [P] Implement `Synapsis.Tool.Computer` in `apps/synapsis_core/lib/synapsis/tool/computer.ex` — full parameter schema (action, coordinate, text, key, url), `enabled?: false`, `permission_level: :execute`, `category: :computer`; execute returns `{:error, "Computer use is not enabled"}`
- [x] T072 Register notebook_read, notebook_edit, computer in `Synapsis.Tool.Builtin.register_all/0`
- [x] T073 [P] Write disabled tool tests in `apps/synapsis_core/test/synapsis/tool/disabled_tools_test.exs` — verify `enabled?/0` returns false, verify excluded from list_for_llm, verify executor returns :tool_disabled

**Checkpoint**: `mix test apps/synapsis_core/test/synapsis/tool/disabled_tools_test.exs` — disabled stubs work correctly.

---

## Phase 14: Polish & Cross-Cutting Concerns

**Purpose**: End-to-end integration, performance validation, and final cleanup

- [x] T074 Write end-to-end integration test in `apps/synapsis_core/test/synapsis/tool/e2e_test.exs` — simulate full agent workflow: grep for code, file_read, file_edit, bash to run tests; verify tool calls persisted to DB with correct status and duration
- [x] T075 Write parallel execution benchmark test in `apps/synapsis_core/test/synapsis/tool/parallel_test.exs` — execute 5 file_reads in batch, verify 2x+ speedup over sequential, verify 50 concurrent calls complete without deadlock
- [x] T076 Verify all 27 tools are registered by updating `apps/synapsis_core/test/synapsis/tool/builtin_test.exs` — assert `Registry.list/0` returns exactly 27 tools (21 enabled + 3 disabled + 3 swarm), assert enabled count is 24, assert disabled count is 3
- [x] T077 Run `mix compile --warnings-as-errors` from umbrella root and fix any warnings
- [x] T078 Run `mix format --check-formatted` from umbrella root and fix any formatting issues
- [x] T079 Run `mix test` from umbrella root and ensure all tests pass (zero failures)

**Checkpoint**: All success criteria (SC-001 through SC-010) validated. Feature complete.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies — can start immediately. All T001-T010 tasks are parallel.
- **Phase 2 (Foundational)**: Depends on Phase 1 (schemas exist). T011-T012 sequential, then T013-T024 parallel.
- **Phase 3 (US4 Registry/Executor)**: Depends on Phase 2. BLOCKS Phases 5-13.
- **Phase 4 (US5 Permissions)**: Depends on Phase 2. Can run PARALLEL with Phase 3.
- **Phase 5 (US1 Filesystem)**: Depends on Phases 3+4.
- **Phase 6 (US2+US3 Search/Bash)**: Depends on Phases 3+4. Can run PARALLEL with Phase 5.
- **Phase 7 (US6 Planning)**: Depends on Phases 3+4. Can run PARALLEL with Phases 5-6.
- **Phase 8 (US8 Web)**: Depends on Phases 3+4. Can run PARALLEL with Phases 5-7.
- **Phase 9 (US9 Interaction)**: Depends on Phases 3+4. Can run PARALLEL with Phases 5-8.
- **Phase 10 (US7 Sub-Agents)**: Depends on Phases 3+4+9 (ask_user denial test).
- **Phase 11 (US10 Plugin)**: Depends on Phases 3+4.
- **Phase 12 (US11 Swarm)**: Depends on Phases 3+4.
- **Phase 13 (Disabled Stubs)**: Depends on Phase 2 only.
- **Phase 14 (Polish)**: Depends on all previous phases.

### User Story Dependencies

```
Phase 1 (Setup) ──► Phase 2 (Foundational) ──┬──► Phase 3 (US4) ──┬──► Phase 5 (US1) 🎯 MVP
                                              │                    ├──► Phase 6 (US2+US3) [P]
                                              │                    ├──► Phase 7 (US6) [P]
                                              │                    ├──► Phase 8 (US8) [P]
                                              │                    ├──► Phase 9 (US9) [P]
                                              │                    ├──► Phase 10 (US7)
                                              │                    ├──► Phase 11 (US10) [P]
                                              │                    └──► Phase 12 (US11) [P]
                                              │
                                              ├──► Phase 4 (US5) [P with Phase 3]
                                              └──► Phase 13 (Disabled Stubs) [P]
```

### Parallel Opportunities

**Within Phase 1**: All 10 tasks (T001-T010) run in parallel — independent files.
**Within Phase 2**: T013-T023 run in parallel (11 existing tool updates, independent files).
**Phases 3+4**: Registry/executor and permissions can run in parallel.
**Phases 5-9, 11-12**: All user story phases can run in parallel after Phase 3+4 complete.
**Phase 13**: Can run in parallel with any phase after Phase 2.

---

## Implementation Strategy

### MVP First (Phases 1-5 = US1+US4+US5)

1. Complete Phase 1: Setup (DB migrations + schemas)
2. Complete Phase 2: Foundational (behaviour extension + existing tool updates)
3. Complete Phase 3+4: US4+US5 (registry, executor, permissions) — in parallel
4. Complete Phase 5: US1 (multi_edit — only new filesystem tool)
5. **STOP and VALIDATE**: Full agent can read, search, edit, and execute with permission controls
6. Run `mix test` — verify all existing + new tests pass

### Incremental Delivery

After MVP, add user stories incrementally:
- Phase 7: US6 (planning/todo) → agent tracks work
- Phase 8: US8 (web search) → agent can research
- Phase 9: US9 (ask_user) → agent clarifies ambiguity
- Phase 10: US7 (sub-agents) → agent delegates work
- Phase 11+12: US10+US11 (plugins, swarm) → advanced features
- Phase 13: Disabled stubs → reserve API surface
- Phase 14: Polish → validate all success criteria

---

## Notes

- [P] tasks = different files, no dependencies within the same phase
- [Story] label maps task to specific user story for traceability
- All new tools follow the same pattern: module + register in builtin.ex + tests
- Existing tools only need callback additions (non-breaking changes)
- Tests use `start_supervised!/1`, `Bypass` for HTTP, no `Process.sleep`
- Commit after each phase completion with conventional commits
