# Synapsis Tools System — Design Document

## 1. Overview

This document describes the architecture of the Synapsis tool system: how tools are defined, registered, discovered, executed, permission-checked, and how they interact with the workspace virtual filesystem and agent communication layers.

The companion PRD (`tools_system_prd.md`) specifies what each tool does. This document specifies how the system works.

---

## 2. Architecture Layers

```
┌──────────────────────────────────────────────────────────┐
│                      Agent Loop                           │
│  Gathers tools → builds LLM request → processes          │
│  tool_use events → feeds results back to LLM             │
├──────────────────────────────────────────────────────────┤
│                    Tool Executor                          │
│  Permission check → VFS routing → dispatch →             │
│  side effect broadcast → persistence                     │
├────────────────────┬─────────────────────────────────────┤
│   Tool Registry    │   Permission Engine                  │
│   (ETS GenServer)  │   (3-step resolution)                │
│   name → dispatch  │   override → level → session config  │
├────────────────────┴─────────────────────────────────────┤
│                     Tool Modules                          │
│                                                           │
│  Built-in          Plugin           Communication         │
│  ├── Filesystem    ├── MCP tools    ├── agent_send        │
│  ├── Search        ├── LSP tools    ├── agent_ask         │
│  ├── Execution     └── Custom       ├── agent_reply       │
│  ├── Web                            ├── agent_handoff     │
│  ├── Planning                       ├── agent_discover    │
│  ├── Orchestration                  └── agent_inbox       │
│  ├── Interaction                                          │
│  ├── Session                                              │
│  └── Memory                                               │
├──────────────────────────────────────────────────────────┤
│                    VFS Router                             │
│  @synapsis/ → Workspace API     other → real filesystem   │
├──────────────────────────────────────────────────────────┤
│              Workspace          │     Agent.Messaging      │
│  PostgreSQL documents           │  PubSub typed envelopes  │
│  tsvector search                │  agent_messages table    │
│  blob store                     │  correlation refs        │
└─────────────────────────────────┴────────────────────────┘
```

---

## 3. Tool Behaviour Contract

Every tool implements `Synapsis.Tool`. The contract defines:

**Required callbacks**: `name/0` (wire name), `description/0` (LLM-facing), `parameters/0` (JSON Schema), `execute/2` (input map + context → `{:ok, result}` or `{:error, reason}`).

**Optional callbacks with defaults**: `permission_level/0` (default `:read`), `category/0` (default `:uncategorized`), `version/0` (default `"1.0.0"`), `enabled?/0` (default `true`), `side_effects/0` (default `[]`).

**Permission levels**: `:none` → `:read` → `:write` → `:execute` → `:destructive`. Ascending risk.

**Categories**: `:filesystem`, `:search`, `:execution`, `:web`, `:planning`, `:orchestration`, `:interaction`, `:session`, `:memory`, `:communication`, `:workspace`, `:notebook`, `:uncategorized`.

**Context struct**: `session_id`, `project_path`, `working_dir`, `permissions`, `session_pid`, `agent_mode` (`:build` or `:plan`), `parent_agent` (pid or nil), `agent_id`, `project_id`.

The `__using__` macro provides default implementations for all optional callbacks. Tools override only what they need.

---

## 4. Tool Registry

ETS-backed GenServer. Entries stored as `{name, {:module, module, opts}}` for built-in tools or `{name, {:process, pid, opts}}` for plugin tools.

**Registration**: `register_module/3` enriches opts from module callbacks (category, permission_level, version, enabled, deferred, loaded). Called by `Builtin.register_all/0` at startup for all 38 tools.

**Lookup**: `lookup/1` returns the dispatch tuple. `get/1` returns a backward-compatible map format.

**Listing with filters**: `list_for_llm/1` accepts options:
- `:agent_mode` — in `:plan` mode, excludes tools with permission_level in `[:write, :execute, :destructive]`
- `:include_deferred` — when false (default), excludes tools registered with `deferred: true` that haven't been `mark_loaded/1`-ed
- `:categories` — list of category atoms to include

**Deferred tool loading**: MCP tools register as `deferred: true`. The `tool_search` tool discovers and activates them by calling `mark_loaded/1`. Prevents context bloat from large MCP server tool sets.

---

## 5. Tool Executor Pipeline

The executor is the central dispatch point. Every tool call flows through it.

**Pipeline steps**:
1. **Registry lookup** — tool exists?
2. **Enabled check** — `module.enabled?()` returns true?
3. **Permission check** — 3-step resolution (§6)
4. **Dispatch** — module-based: `Task.Supervisor.async_nolink` with timeout; process-based: `GenServer.call`
5. **Side effect broadcast** — PubSub to `"tool_effects:{session_id}"`
6. **Persistence** — insert `ToolCall` record with duration_ms

**Batch execution**: `execute_batch/2` runs multiple tool calls concurrently via `Task.async_stream`. Calls targeting the same file path are serialized (grouped by `input["path"]`). Calls with no file path run independently. Max concurrency: `System.schedulers_online()`. Results returned in original input order.

**Error handling**: Timeout → `{:error, :timeout}`. Exit → `{:error, {:exit, reason}}`. Exception → `{:error, message}`. All error states are persisted.

---

## 6. Permission Engine

Three-step resolution that returns `:allowed`, `:denied`, or `:requires_approval`.

**Step 1 — Glob override**: Check `session_permissions.tool_overrides` for a matching tool+pattern entry. Format: `%{tool: "bash", pattern: "git *", decision: :allowed}`. Pattern matching on the tool's primary input field (e.g., `command` for bash, `path` for file tools, `pattern` for grep). If match → decision wins immediately.

**Step 2 — Level vs session config**: Resolve the tool's `permission_level/0`. Check against session mode:
- **Autonomous mode**: all tools through `:execute` are auto-allowed. Only `:destructive` follows `allow_destructive` setting.
- **Interactive mode**: `:none` and `:read` always allowed. `:write` follows `allow_write`. `:execute` follows `allow_execute`. `:destructive` follows `allow_destructive`.

**Step 3 — Default**: `:requires_approval`.

**Session config**: Loaded from `session_permissions` table. Defaults when no row exists. `update_config/2` upserts.

---

## 7. Virtual Filesystem (VFS) Router

### 7.1 Purpose

Unifies workspace documents and real files under the same tool surface. The LLM uses one set of tools for both. No separate API to learn.

### 7.2 Module: `Synapsis.Tool.VFS`

Single routing module that all filesystem and search tools call.

**Detection**: `virtual?/1` checks for `@synapsis/` prefix. Case-sensitive pattern match.

**Path stripping**: `workspace_path/1` strips `@synapsis/` and prepends `/`.

**Operations**: `read/2`, `write/3`, `delete/2`, `move/3`, `exists?/2`, `list/2` — all delegate to `Synapsis.Workspace` API. For non-virtual paths, returns `{:error, :not_virtual}` and the calling tool falls through to filesystem logic.

### 7.3 Module: `Synapsis.Tool.VFS.Search`

SQL-backed search for workspace documents.

**grep**: Queries `workspace_documents` with PostgreSQL POSIX regex operator (`content_body ~ pattern`). Supports path prefix filtering, output modes, context lines, filename include filter, result limits. Formats output in ripgrep conventions: `path:linenum:line`.

**glob**: Converts glob syntax to SQL LIKE pattern and queries the `path` column. Conversion rules: `**` → `%`, `*` → `%`, `?` → `_`, with proper escaping of literal SQL wildcards. Results sorted by `updated_at` descending.

**fulltext**: Thin wrapper over `Synapsis.Workspace.search/2` — PostgreSQL tsvector with `websearch_to_tsquery`.

### 7.4 Tool Modification Pattern

Each filesystem/search tool gets one guard at the top of `execute/2`: check `VFS.virtual?(path)`. Virtual branch delegates to VFS module. Non-virtual branch contains original logic unchanged. The guard adds ~8-15 lines per tool. Search logic is centralized in `VFS.Search`, not duplicated across tools.

### 7.5 PathValidator Bypass

Virtual paths bypass `Synapsis.Tool.PathValidator` entirely. Workspace has its own validation in `Workspace.validate_path/1` — checks for traversal (`..`), max depth, max length, valid segment characters, and valid top-level prefixes (`/shared/`, `/projects/`, `/global/`).

### 7.6 Side Effects

Workspace writes broadcast `:workspace_changed` (triggers UI explorer refresh, ContextBuilder cache invalidation). Filesystem writes broadcast `:file_changed` (triggers LSP diagnostics refresh). The two are distinct because they have different subscribers and semantic meaning.

### 7.7 Cross-Boundary Rules

- `file_move` between real and virtual paths → rejected
- `grep`/`glob` results from workspace → `@synapsis/`-prefixed so LLM can chain into `file_read`
- Domain-backed paths (`skills/`, `memory/`, `todos`) → write-rejected by workspace API

---

## 8. Agent Communication Architecture

### 8.1 Problem

Two disconnected messaging layers: `Agent.Messaging` (proper envelopes, correlation refs, used internally) and old swarm tools (separate PubSub, ETS roster, no persistence). Communication tools bridge the gap.

### 8.2 Principle: Tools Surface `Agent.Messaging`

Every communication tool builds envelopes via `Agent.Messaging.envelope/4` and delivers via `Agent.Messaging.send_envelope/1`. No parallel messaging system. The old swarm tools' separate topic namespace is eliminated.

### 8.3 Persistence Layer

New `agent_messages` table in `synapsis_data`. Every message persisted BEFORE PubSub delivery (at-least-once guarantee). Messages survive agent crashes. Agents recover unread messages from DB on startup via `agent_inbox action="unread"`.

Message lifecycle: `delivered` → `read` → `acknowledged`. Requests have `expires_at` TTL. Expired messages marked `expired` and excluded from unread queries.

### 8.4 Request/Response Pattern

`agent_ask` follows the same blocking pattern as `ask_user`: subscribe to a correlation-specific PubSub topic BEFORE sending (race-safe) → selective `receive` with timeout. `agent_reply` broadcasts to `"agent_reply:{ref}"` to wake the caller.

**Deadlock prevention**: Sub-agents cannot use `agent_ask` (checked via `context.parent_agent`). A child blocking on a parent who's blocking on the child is a deadlock. Sub-agents use fire-and-forget `agent_send` and let the parent coordinate.

### 8.5 Handoff as Workspace + Message

`agent_handoff` produces both:
1. A delegation envelope delivered via `Agent.Messaging`
2. A workspace document at `@synapsis/projects/{id}/handoffs/{ref}.json`

This means handoffs are: browsable in workspace explorer by the user, readable by any agent via `file_read`, indexed by full-text search, versioned by workspace lifecycle, cleaned up by workspace GC. Two systems reinforcing each other.

### 8.6 Agent Discovery

`agent_discover` reads live OTP process state from `AgentRegistry` + `AgentProcess`. Returns what's actually running right now — not stale DB records or ETS entries from crashed processes.

### 8.7 Name Resolution

Well-known names avoid UUID lookups for common patterns: `"global"` (singleton), `"project:{id}"` (project agent), `"session:{id}"` (session agent), `"parent"` (calling agent's parent from context). Any other string treated as direct agent ID.

### 8.8 Migration from Swarm Tools

`send_message` → `agent_send` (adds persistence, uses Agent.Messaging). `teammate create` → `task` tool (already spawns sub-agents). `teammate list/get` → `agent_discover` (live OTP state). `team_delete` → agent lifecycle (ephemeral agents terminate on completion). Old tools deprecated with `enabled?() → false`.

---

## 9. Side Effect System

Tools declare side effects statically via `side_effects/0`. The executor broadcasts after successful execution.

**Side effect types**: `:file_changed`, `:workspace_changed`, `:memory_promoted`, `:memory_updated`.

**Broadcast**: PubSub to `"tool_effects:{session_id}"`. Subscribers process effects asynchronously.

**Subscribers per effect**:
- `:file_changed` → LSP diagnostics refresh (passive or active injection), ContextBuilder cache invalidation
- `:workspace_changed` → SessionChannel UI notifications, WorkspaceLive explorer refresh, ContextBuilder cache invalidation
- `:memory_promoted` / `:memory_updated` → Memory cache invalidation

Side effects are data-only declarations. No hook framework. The executor broadcasts; subscribers decide what to do.

---

## 10. Plugin Tool Integration

### 10.1 MCP Tools

Namespaced with `mcp_` prefix. Discovered via MCP `tools/list` at plugin initialization. Registered as `deferred: true` in the Registry. Activated demand via `tool_search`. Dispatched via `GenServer.call` to the `SynapsisPlugin.Server` process managing the MCP connection.

### 10.2 LSP Tools

Namespaced with `lsp_` prefix. Fixed set: `lsp_diagnostics`, `lsp_definition`, `lsp_references`, `lsp_hover`, `lsp_symbols`. Accept symbol names instead of line:column positions — the plugin resolves positions internally. LLMs are unreliable with exact positions.

### 10.3 Uniform Interface

Built-in tools and plugin tools share the same dispatch path in the executor. The only difference is step 3: module-based dispatch calls `module.execute(input, context)`, process-based dispatch calls `GenServer.call(pid, {:execute, name, input, context})`.

---

## 11. Module Layout

### synapsis_core — Tool modules and infrastructure

```
lib/synapsis/tool/
├── behaviour.ex              # Deprecated compat shim
├── builtin.ex                # register_all/0 for 38 tools
├── context.ex                # Context struct
├── executor.ex               # Pipeline + execute_batch
├── path_validator.ex         # Real filesystem traversal prevention
├── permission.ex             # 3-step resolution engine
├── permission/session_config.ex
├── registry.ex               # ETS GenServer + filtering
├── vfs.ex                    # @synapsis/ router
├── vfs/search.ex             # SQL-backed grep + glob
│
├── # Filesystem (7)
├── file_read.ex, file_write.ex, file_edit.ex
├── multi_edit.ex, file_delete.ex, file_move.ex, list_dir.ex
│
├── # Search (3)
├── grep.ex, glob.ex, diagnostics.ex
│
├── # Execution (1)
├── bash.ex
│
├── # Web (2)
├── fetch.ex, web_search.ex
│
├── # Planning (2)
├── todo_write.ex, todo_read.ex
│
├── # Orchestration (3)
├── task.ex, tool_search.ex, skill.ex
│
├── # Interaction (1)
├── ask_user.ex
│
├── # Session (3)
├── enter_plan_mode.ex, exit_plan_mode.ex, sleep.ex
│
├── # Memory (4)
├── session_summarize.ex, memory_save.ex
├── memory_search.ex, memory_update.ex
│
├── # Communication (6)
├── agent_send.ex, agent_ask.ex, agent_reply.ex
├── agent_handoff.ex, agent_discover.ex, agent_inbox.ex
│
├── # Disabled (2)
├── notebook_read.ex, notebook_edit.ex
│
└── # Deprecated (3, enabled?→false)
    ├── send_message.ex, teammate.ex, team_delete.ex
```

### synapsis_workspace — Workspace API

```
lib/synapsis/workspace/
├── workspace.ex              # Public API facade
├── resource.ex               # Resource struct
├── path_resolver.ex          # Path parsing, scope derivation
├── resources.ex              # CRUD + versioning
├── projection.ex             # Domain schema → Resource mapping
├── permissions.ex            # Agent-scoped access checks
├── search.ex                 # tsvector full-text search
├── gc.ex                     # Periodic cleanup GenServer
├── blob_store.ex             # Behaviour
├── blob_store/local.ex       # Content-addressable local FS
└── tools/                    # Workspace-specific tool modules
    ├── workspace_read.ex
    ├── workspace_write.ex
    ├── workspace_list.ex
    ├── workspace_search.ex
    └── workspace_delete.ex
```

### synapsis_data — Schemas and contexts

```
lib/synapsis/
├── tool_call.ex              # ToolCall schema
├── session_permission.ex     # SessionPermission schema
├── session_todo.ex           # SessionTodo schema
├── workspace_document.ex     # WorkspaceDocument schema
├── workspace_document_version.ex
├── workspace_documents.ex    # Data context (queries)
└── agent_message.ex          # AgentMessage schema (new)
```

### synapsis_agent — Messaging and process infrastructure

```
lib/synapsis/agent/
├── messaging.ex              # Envelope builder + PubSub delivery
├── work_item.ex              # Structured delegation unit
└── (agent processes, registry, supervisor — used by agent_discover)
```

---

## 12. Test Strategy

### Unit Tests Per Tool Module

Every tool has a dedicated test file verifying: metadata callbacks (name, category, permission_level, side_effects, enabled?), parameter schema shape, execute happy path, execute error cases, path validation, context requirements.

### Behaviour Contract Tests

One cross-cutting test module iterates ALL 38 tool modules and verifies: all required callbacks return correct types, names are unique, names are snake_case, write/destructive tools declare `file_changed`, disabled tools return `false` from `enabled?/0`.

### VFS Tests

Three test modules: pure logic tests (virtual?/1 detection, path mapping — async), integration tests (write→read round-trip, delete, move, cross-boundary rejection — requires DataCase), tool integration tests (file_read/file_write/file_edit/grep/glob with `@synapsis/` paths).

### Communication Tests

Per-tool tests (send, ask, reply, handoff, discover, inbox). Integration tests: full request/response round-trip, handoff chain with workspace artifacts, crash recovery with inbox-based message retrieval.

### E2E LLM Tests

Single-turn agent interaction tests: send user prompt → verify LLM selects correct tool → verify tool executes successfully → verify LLM incorporates result. Organized by category: filesystem, search, execution, planning, orchestration, web, multi-tool workflows.

---

## 13. Resolved Architectural Decisions

1. **Tools in synapsis_core, not separate app** — existing 32 tools, registry, executor already there. Constitution places tools in synapsis_core. Extraction cost outweighs benefit. Isolation achieved via module boundary.

2. **VFS as routing module, not interceptor** — single `VFS` module that tools call explicitly. No middleware, no macro magic. Each tool has a clear `if virtual?` branch. Debuggable.

3. **SQL search over workspace, not ripgrep** — workspace docs are DB rows. PostgreSQL regex is faster, indexed, doesn't need Port process. Grep and glob share the same VFS.Search module.

4. **Communication tools bridge Agent.Messaging** — not a parallel system. Tools call existing `envelope/4` and `send_envelope/1`. One messaging path.

5. **Persist-before-broadcast** — at-least-once delivery for agent messages. Trade-off: extra DB write per message. Benefit: crash safety, inbox recovery, audit trail.

6. **Selective receive for request/response** — same proven pattern as `ask_user`. Subscribe before send (race-safe). Timeout with expiry marking.

7. **Handoffs are dual: message + workspace doc** — not either/or. PubSub for real-time delivery. Workspace for persistence, browsing, search. Two systems reinforce rather than duplicate.

8. **Glob-to-SQL conversion** — simple string replacement (`**`→`%`, `*`→`%`, `?`→`_`) with proper escaping. Doesn't cover 100% of glob edge cases but handles the patterns LLMs actually produce.

9. **Old swarm tools deprecated, not removed** — `enabled?() → false` preserves compilation. Consumers that reference the modules don't break. Clean removal after one release cycle.

10. **No FUSE, no kernel filesystem for workspace** — path-based addressing via SQL queries. Workspace needs browsing and search, not POSIX semantics.
