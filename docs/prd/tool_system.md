# Synapsis Tools System — Product Requirements Document

## 1. Executive Summary

The tool system is the agent's interface to the real world. Every file read, shell command, workspace write, agent-to-agent message, and user interaction is a tool call flowing through a uniform behaviour contract and execution pipeline.

This PRD specifies the complete tool surface: 38 tools across 12 categories, covering filesystem operations, code search, shell execution, web access, workspace virtual files, agent communication, planning, orchestration, user interaction, session control, memory, and reserved future capabilities.

---

## 2. Competitive Landscape

### Claude Code (v2.1.71) — 20 Built-in Tools

Filesystem (7), Execution (1), Web (2), Planning (2), Orchestration (3), User Interaction (1), Mode Control (2), Code Intelligence (1), Notebook (1), Utility (1), Swarm experimental (4).

### OpenCode (Charm, v1.x) — 15+ Built-in Tools

Filesystem (7), Execution (1), Web (2), Planning (2), Orchestration (2), User Interaction (1), Code Intelligence (1 experimental).

### Codex CLI (OpenAI) — Minimal Surface

Execution (1 sandboxed), File Editing (1 apply_patch), Web (1 cache-first), MCP integration.

### Synapsis Differentiation

- **Workspace virtual files** (`@synapsis/` prefix) — DB-backed document storage addressable through the same file tools. No CLI tool has this.
- **Agent communication** — Typed envelopes with persistence, request/response blocking, structured handoffs with workspace artifacts. Claude Code's swarm tools are fire-and-forget with no persistence.
- **SQL-backed search** — Grep and glob over workspace documents via PostgreSQL regex and LIKE queries. Not filesystem-dependent.
- **Unified interface** — Everything is a tool with the same behaviour contract. Where Claude Code and OpenCode blur tools and agent modes, Synapsis treats everything uniformly.

---

## 3. Tool Inventory

### 3.1 Filesystem Tools (7 tools)

| # | Name | Permission | Side Effects | Description |
|---|---|---|---|---|
| 1 | `file_read` | `:read` | — | Read file contents with optional line offset/limit |
| 2 | `file_write` | `:write` | `file_changed` | Write content, create parent directories |
| 3 | `file_edit` | `:write` | `file_changed` | Search/replace exact string in file |
| 4 | `multi_edit` | `:write` | `file_changed` | Batch edits across files with per-file rollback |
| 5 | `file_delete` | `:destructive` | `file_changed` | Delete a file |
| 6 | `file_move` | `:write` | `file_changed` | Move/rename with parent dir creation |
| 7 | `list_dir` | `:read` | — | Directory listing with depth control |

All filesystem tools support the `@synapsis/` virtual prefix. When a path starts with `@synapsis/`, the tool transparently routes to `Synapsis.Workspace` instead of the real filesystem. See §4.

**Parameters per tool**:

- **file_read**: `path` (required), `offset` (optional int, 0-indexed start line), `limit` (optional int, max lines)
- **file_write**: `path` (required), `content` (required)
- **file_edit**: `path` (required), `old_string` (required, exact match), `new_string` (required). Replaces first occurrence only when multiple matches exist.
- **multi_edit**: `edits` (required array of `{path, old_string, new_string}`). Groups by file, applies sequentially within each file, rolls back entire file on any failure. Cross-file edits are independent — partial success is possible.
- **file_delete**: `path` (required)
- **file_move**: `source` (required), `destination` (required). Validates both paths. Cross-boundary moves (real ↔ virtual) are rejected.
- **list_dir**: `path` (required), `depth` (optional int, default 1), `include_hidden` (optional bool), `ignore_gitignore` (optional bool)

---

### 3.2 Search Tools (3 tools)

| # | Name | Permission | Description |
|---|---|---|---|
| 8 | `grep` | `:read` | Regex content search via ripgrep (real files) or PostgreSQL regex (workspace) |
| 9 | `glob` | `:read` | Path pattern matching via `Path.wildcard` (real) or SQL LIKE (workspace) |
| 10 | `diagnostics` | `:read` | LSP-style diagnostics for a file |

Search tools support `@synapsis/` paths. When the `path` parameter starts with `@synapsis/`, search runs against PostgreSQL instead of the filesystem:
- **grep** uses `content_body ~ pattern` (POSIX regex on the `workspace_documents` content column)
- **glob** converts glob syntax to SQL LIKE pattern and queries the `path` column

**Parameters**:

- **grep**: `pattern` (required, regex), `path` (optional, default project root), `include` (optional, filename glob filter), `output_mode` (optional: content/files/count), `context_lines` (optional int)
- **glob**: `pattern` (required, e.g. `"**/*.md"`), `path` (optional base directory)
- **diagnostics**: `path` (required)

---

### 3.3 Execution Tools (1 tool)

| # | Name | Permission | Description |
|---|---|---|---|
| 11 | `bash` | `:execute` | Shell execution with project directory as cwd |

**Parameters**: `command` (required), `timeout` (optional, default 30000ms, max 300000ms), `working_dir` (optional override).

**Behaviour**: Uses `System.cmd("bash", ["-c", command])`. Output truncated at 10MB. Non-zero exit returns `{:ok, output}` with exit code appended (not an error — the LLM needs to see the output). Timeout returns `{:error, "timed out"}`.

---

### 3.4 Web Tools (2 tools)

| # | Name | Permission | Description |
|---|---|---|---|
| 12 | `fetch` | `:read` | HTTP GET with SSRF protection |
| 13 | `web_search` | `:read` | Brave Search API |

**Parameters**:

- **fetch**: `url` (required, http/https only). Blocks localhost, private IPs, metadata endpoints, DNS rebinding. Body truncated at 50KB.
- **web_search**: `query` (required), `max_results` (optional, default 5). Requires `BRAVE_SEARCH_API_KEY`. Returns JSON array of `{title, url, snippet}`.

---

### 3.5 Planning Tools (2 tools)

| # | Name | Permission | Description |
|---|---|---|---|
| 14 | `todo_write` | `:none` | Create/replace session todo list (full replacement, not delta) |
| 15 | `todo_read` | `:none` | Read current session todo list |

**Parameters**:

- **todo_write**: `todos` (required array of `{id, content, status}`). Status enum: pending/in_progress/completed. Deletes all existing todos for session, inserts new set. Broadcasts `{:todo_update}` via PubSub. Persists to `session_todos` table.
- **todo_read**: none. Returns ordered list.

---

### 3.6 Orchestration Tools (3 tools)

| # | Name | Permission | Enabled | Description |
|---|---|---|---|---|
| 16 | `task` | `:none` | **no** (stub) | Launch sub-agent, foreground or background |
| 17 | `tool_search` | `:none` | yes | Discover and activate deferred/MCP tools by keyword |
| 18 | `skill` | `:none` | yes | Load SKILL.md file into conversation context |

**Parameters**:

- **task**: `prompt` (required), `tools` (optional array, default read-only set), `mode` (foreground/background), `model` (optional override). Sub-agents inherit session context but have own conversation history. Cannot use `ask_user` or `enter_plan_mode`.
- **tool_search**: `query` (required), `limit` (optional, default 5). Scores by name/description relevance. Side effect: calls `Registry.mark_loaded/1` on matched tools, activating deferred MCP tools.
- **skill**: `name` (required). Searches `.synapsis/skills/{name}.md` then `~/.config/synapsis/skills/{name}.md`.

---

### 3.7 User Interaction Tools (1 tool)

| # | Name | Permission | Description |
|---|---|---|---|
| 19 | `ask_user` | `:none` | Present structured questions, block until user responds |

**Parameters**: `question` (required), `options` (optional array of `{label, description?}`).

**Constraints**: Blocks via selective receive (5 min timeout). Sub-agents cannot use (returns error if `context.parent_agent` is set). Race-safe: subscribes to response topic before broadcasting question.

---

### 3.8 Session Control Tools (3 tools)

| # | Name | Permission | Description |
|---|---|---|---|
| 20 | `enter_plan_mode` | `:none` | Switch to plan mode, restricts to read-only tools |
| 21 | `exit_plan_mode` | `:none` | Submit plan and return to build mode |
| 22 | `sleep` | `:none` | Interruptible pause, early wake on user input |

**Parameters**:

- **enter_plan_mode**: none. Updates session agent mode. Registry excludes write/execute/destructive tools.
- **exit_plan_mode**: `plan` (optional string). Broadcasts `{:plan_submitted}` then `{:agent_mode_changed, :build}`.
- **sleep**: `duration_ms` (required, capped at 600000), `reason` (optional). Selective receive wakes early on `{:user_input, _}`.

---

### 3.9 Memory Tools (4 tools)

| # | Name | Permission | Side Effects | Description |
|---|---|---|---|---|
| 23 | `session_summarize` | `:read` | — | Extract memory candidates from session (LLM or heuristic) |
| 24 | `memory_save` | `:write` | `memory_promoted` | Persist semantic memory records |
| 25 | `memory_search` | `:read` | — | Search memory with scope hierarchy walk |
| 26 | `memory_update` | `:write` | `memory_updated` | Update/archive/restore memory with audit trail |

**Parameters**:

- **session_summarize**: `scope` (full/recent/range), `message_range` (for range), `focus` (hint string), `kinds` (array), `use_llm` (bool, default true with heuristic fallback)
- **memory_save**: `memories` (required array of `{scope?, kind, title, summary, tags?, importance?}`). Kinds: fact, decision, lesson, preference, pattern, warning.
- **memory_search**: `query` (required), `scope` (shared/project/agent), `kinds` (array filter), `tags` (array filter), `limit` (default 5)
- **memory_update**: `action` (update/archive/restore), `memory_id` (required), `changes` (for update: title, summary, kind, tags, importance, confidence)

---

### 3.10 Communication Tools (6 tools)

Replace the 3 hollow swarm tools. All bridge to `Agent.Messaging` envelope system.

| # | Name | Permission | Side Effects | Description |
|---|---|---|---|---|
| 27 | `agent_send` | `:none` | — | Fire-and-forget message to another agent |
| 28 | `agent_ask` | `:none` | — | Request/response with blocking wait |
| 29 | `agent_reply` | `:none` | — | Reply to a received request |
| 30 | `agent_handoff` | `:none` | `workspace_changed` | Delegate work with workspace artifacts |
| 31 | `agent_discover` | `:none` | — | Query running agents from OTP registry |
| 32 | `agent_inbox` | `:none` | — | Read message history, unread, threads |

**Parameters**:

- **agent_send**: `to` (required), `content` (required), `type` (optional: notification/info/warning), `metadata` (optional map)
- **agent_ask**: `to` (required), `question` (required), `context` (optional map), `timeout_ms` (optional, default 120000, max 300000). Sub-agents cannot use (deadlock prevention).
- **agent_reply**: `ref` (required, from incoming request), `content` (required), `status` (optional: success/error/partial/declined)
- **agent_handoff**: `to` (required), `summary` (required), `instructions` (required), `artifacts` (optional array of `@synapsis/` paths), `priority` (optional: low/normal/high/critical), `constraints` (optional map)
- **agent_discover**: `action` (list/get/find_by_project), `agent_id` (for get), `project_id` (for find_by_project), `type` (optional filter)
- **agent_inbox**: `action` (unread/history/thread), `ref` (for thread), `limit` (default 20), `since` (ISO datetime for history), `type` (filter)

**Agent name resolution**: `"global"`, `"project:{id}"`, `"session:{id}"`, `"parent"`, or UUID/ULID direct lookup.

---

### 3.11 Workspace Tools (4 tools)

Explicit workspace operations for metadata-rich access. Complement the `@synapsis/` VFS routing through filesystem tools.

| # | Name | Permission | Side Effects | Description |
|---|---|---|---|---|
| 33 | `workspace_read` | `:read` | — | Read workspace resource with full metadata |
| 34 | `workspace_write` | `:write` | `workspace_changed` | Write workspace document with metadata, format, lifecycle |
| 35 | `workspace_list` | `:read` | — | List directory with kind/sort filtering, mixed domain+document results |
| 36 | `workspace_search` | `:read` | — | Full-text search via PostgreSQL tsvector (ranked) |

---

### 3.12 Disabled/Future Tools (2 tools)

| # | Name | Permission | Enabled | Description |
|---|---|---|---|---|
| 37 | `notebook_read` | `:read` | **no** | Jupyter notebook cell reading (API reserved) |
| 38 | `notebook_edit` | `:write` | **no** | Jupyter notebook cell editing (API reserved) |

Compiled modules with `enabled?() → false`. Return error on execute. Enable via config. The `computer` tool previously listed is subsumed by MCP plugin integration (Puppeteer MCP, Playwright MCP).

---

## 4. Workspace Virtual Files — `@synapsis/` Prefix

### 4.1 Concept

The `@synapsis/` prefix unifies workspace documents and real files under the same tool surface. The LLM uses `file_read`, `file_write`, `file_edit`, `grep`, `glob` for both — no separate API to learn.

### 4.2 Path Mapping

`@synapsis/{workspace_path}` → strips prefix → workspace path `/{workspace_path}`.

Examples:
- `@synapsis/projects/myapp/plans/auth.md` → `/projects/myapp/plans/auth.md`
- `@synapsis/shared/notes/ideas.md` → `/shared/notes/ideas.md`
- `@synapsis/global/soul.md` → `/global/soul.md`

### 4.3 Prefix Rules

- Case-sensitive: only `@synapsis/` is recognized
- `@` prevents POSIX collision — zero risk of matching real filesystem paths
- Virtual paths bypass `PathValidator` — workspace has its own path validation (traversal, depth, segment rules)

### 4.4 Tool Routing

| Tool | Real Files | `@synapsis/` Virtual Files |
|---|---|---|
| `file_read` | `File.read/1` | `Workspace.read/1` |
| `file_write` | `File.write/2` | `Workspace.write/3` |
| `file_edit` | Read → replace → write on disk | Read → replace → write via workspace API |
| `multi_edit` | Same, grouped by file | Same, with VFS-aware read/write helpers |
| `file_delete` | `File.rm/1` | `Workspace.delete/1` |
| `file_move` | `File.rename/2` | `Workspace.move/2` |
| `list_dir` | `File.ls/1` | `Workspace.list/2` (prefix query) |
| `grep` | ripgrep Port process | `content_body ~ pattern` (PostgreSQL regex) |
| `glob` | `Path.wildcard/2` | `path LIKE` (glob→SQL conversion) |
| `bash` | No change | N/A — shell operates on real filesystem |

### 4.5 Search Over Workspace

Since workspace documents are PostgreSQL rows, search is SQL — no filesystem crawl.

- **Grep**: PostgreSQL POSIX regex operator on `content_body`. Supports path prefix filtering, output modes (content/files/count), context lines, filename include filter.
- **Glob**: Converts glob syntax (`**`, `*`, `?`) to SQL LIKE pattern on the `path` column. Results sorted by `updated_at` descending.
- **Full-text**: `workspace_search` tool uses `tsvector` with `websearch_to_tsquery` — ranked, natural language input.

### 4.6 Cross-Boundary Rules

- Moving between real filesystem and `@synapsis/` is rejected
- Grep/glob results from workspace are `@synapsis/`-prefixed so the LLM can chain them into subsequent `file_read` calls
- Domain-backed paths (`@synapsis/projects/x/skills/...`, `@synapsis/projects/x/memory/...`) are write-rejected by workspace API — those records are managed through their domain contexts

---

## 5. Agent Communication

### 5.1 Problem

`Agent.Messaging` (synapsis_agent) has proper typed envelopes with correlation refs. The old swarm tools bypass it entirely with separate PubSub topics and ETS. Two messaging systems that don't connect.

### 5.2 Solution

Six communication tools (§3.10) that bridge LLM tool calls to `Agent.Messaging.send_envelope/1`. One messaging system, not two.

### 5.3 Message Flow Patterns

**Fire-and-forget**: Agent A → `agent_send` → Agent B sees it as injected message in next graph iteration.

**Request/response**: Agent A → `agent_ask` (blocks on selective receive) → Agent B receives, reasons, calls `agent_reply` → Agent A wakes with response.

**Handoff chain**: Global → `agent_handoff` with workspace artifacts → Project Agent reads plan via `file_read @synapsis/...` → spawns General Agents with `task` → they work → `agent_send` completion → Project collects via `agent_inbox`.

**Inbox-driven async**: Messages persist in `agent_messages` table. Agent checks `agent_inbox action="unread"` between graph iterations or on restart. No blocking required for async patterns.

### 5.4 Persistence & Delivery

At-least-once: persist to `agent_messages` BEFORE PubSub broadcast. Crashed agents recover unread messages from DB on restart. Requests expire via `expires_at` TTL.

### 5.5 Handoff as Workspace Document

`agent_handoff` writes a JSON record to `@synapsis/projects/{id}/handoffs/{ref}.json`. This makes handoffs: browsable in workspace explorer, readable via `file_read`, searchable via `workspace_search`, versioned by workspace lifecycle.

---

## 6. Data Model

### 6.1 Existing Tables (from original PRD)

**tool_calls**: id (ULID), message_id, session_id, tool_name, input (JSONB), output (JSONB), status (pending/approved/denied/completed/error), duration_ms, error_message, timestamps.

**session_permissions**: id, session_id (unique), mode (interactive/autonomous), allow_write (bool), allow_execute (bool), allow_destructive (allow/deny/ask), tool_overrides (JSONB), timestamps.

**session_todos**: id, session_id, todo_id, content, status (pending/in_progress/completed), sort_order, timestamps.

### 6.2 Workspace Tables (from workspace PRD)

**workspace_documents**: id (ULID), path (unique indexed), kind, content_body, blob_ref, content_format, visibility, lifecycle, metadata (JSONB), project_id, session_id, version, created_by, updated_by, deleted_at, search_vector (tsvector), timestamps.

**workspace_document_versions**: id, document_id (FK), version, content_body, blob_ref, content_hash, changed_by, timestamps.

### 6.3 New Table — Agent Messages

**agent_messages**: id (ULID), ref (correlation string), from_agent_id, to_agent_id, type (request/response/notification/delegation/handoff/completion), in_reply_to (FK to self), payload (JSONB), status (delivered/read/acknowledged/expired), project_id (FK nullable), session_id (FK nullable), expires_at, timestamps.

**Indexes**: `(to_agent_id, inserted_at)`, `(from_agent_id, inserted_at)`, `(ref)`, `(in_reply_to)`, `(project_id, inserted_at)`, `(type)`.

---

## 7. Implementation Phases

### Phase 1: Core Filesystem + Search + Execution (done)

file_read, file_write, file_edit, file_delete, file_move, list_dir, grep, glob, bash. Tool behaviour, Registry, Executor, Permission engine, side effect broadcasting.

### Phase 2: Planning + User Interaction (done)

todo_write, todo_read, ask_user, enter_plan_mode, exit_plan_mode. Plan mode tool filtering. Session permission config.

### Phase 3: Orchestration + Web (done)

task (stub), web_search, fetch, skill, multi_edit, tool_search, sleep.

### Phase 4: Memory Tools (done)

session_summarize, memory_save, memory_search, memory_update.

### Phase 5: Workspace Virtual Files (done)

VFS router module. `@synapsis/` guard in all filesystem tools. VFS.Search for SQL-backed grep and glob. Workspace tools (workspace_read, workspace_write, workspace_list, workspace_search).

### Phase 6: Agent Communication (done)

`agent_messages` migration and schema. agent_send, agent_ask, agent_reply, agent_handoff, agent_discover, agent_inbox. Agent name resolution. Deprecate old swarm tools.

### Phase 7: Sub-Agent Wiring (done)

Wire `task` tool to actual `Agent.SessionBridge` process spawning. Foreground mode blocks until completion. Background mode returns immediately with task_id and sends completion notification. Session result collection from last assistant message.

### Phase 8: Disabled Tool Activation (done)

notebook_read, notebook_edit behind config flags (`notebook_tools_enabled`). Computer use via MCP plugin.

---

## 8. Acceptance Criteria

### Core Tools (Phase 1-4)
- Agent can navigate, read, edit, and execute commands against a codebase
- Agent supports plan-then-execute workflows with user interaction
- Agent can launch sub-agents, search the web, and load skills
- Agent can save, search, and update semantic memory
- All tool calls persisted to `tool_calls` table with duration tracking
- Permission engine resolves 5 levels with glob overrides and autonomous mode
- Parallel tool execution via batch when LLM returns multiple independent calls
- ≥90% test coverage on all tool modules, Dialyzer clean

### Workspace Virtual Files (Phase 5)
- `file_read path="@synapsis/..."` reads workspace document content
- `file_write path="@synapsis/..."` creates/updates workspace document
- `file_edit path="@synapsis/..."` performs search/replace on workspace content
- `grep pattern="TODO" path="@synapsis/projects/myapp/"` searches via SQL regex
- `glob pattern="**/*.md" path="@synapsis/projects/myapp/"` matches via SQL LIKE
- Results from workspace grep/glob are `@synapsis/`-prefixed for LLM chaining
- Cross-boundary moves (real ↔ virtual) rejected
- Domain-backed paths write-rejected through workspace

### Agent Communication (Phase 6)
- `agent_send` persists then delivers via Agent.Messaging
- `agent_ask` → `agent_reply` round-trip completes with correlated response
- `agent_ask` times out and marks expired when no reply
- Sub-agents cannot use `agent_ask` (deadlock prevention)
- `agent_handoff` writes handoff record to workspace, readable via `file_read`
- `agent_discover` returns live OTP process state
- `agent_inbox` returns unread messages, marks as read
- `agent_inbox action="thread"` follows full conversation by ref
- Messages survive agent crashes (persist-before-broadcast)
- Restarted agents recover unread from DB

---

## 9. Tool Inventory Summary

| # | Name | Category | Permission | Side Effects | Enabled |
|---|---|---|---|---|---|
| 1 | `file_read` | filesystem | `:read` | — | yes |
| 2 | `file_write` | filesystem | `:write` | `file_changed` | yes |
| 3 | `file_edit` | filesystem | `:write` | `file_changed` | yes |
| 4 | `multi_edit` | filesystem | `:write` | `file_changed` | yes |
| 5 | `file_delete` | filesystem | `:destructive` | `file_changed` | yes |
| 6 | `file_move` | filesystem | `:write` | `file_changed` | yes |
| 7 | `list_dir` | filesystem | `:read` | — | yes |
| 8 | `grep` | search | `:read` | — | yes |
| 9 | `glob` | search | `:read` | — | yes |
| 10 | `diagnostics` | search | `:read` | — | yes |
| 11 | `bash` | execution | `:execute` | — | yes |
| 12 | `fetch` | web | `:read` | — | yes |
| 13 | `web_search` | web | `:read` | — | yes |
| 14 | `todo_write` | planning | `:none` | — | yes |
| 15 | `todo_read` | planning | `:none` | — | yes |
| 16 | `task` | orchestration | `:none` | — | **no** (stub) |
| 17 | `tool_search` | orchestration | `:none` | — | yes |
| 18 | `skill` | orchestration | `:none` | — | yes |
| 19 | `ask_user` | interaction | `:none` | — | yes |
| 20 | `enter_plan_mode` | session | `:none` | — | yes |
| 21 | `exit_plan_mode` | session | `:none` | — | yes |
| 22 | `sleep` | session | `:none` | — | yes |
| 23 | `session_summarize` | memory | `:read` | — | yes |
| 24 | `memory_save` | memory | `:write` | `memory_promoted` | yes |
| 25 | `memory_search` | memory | `:read` | — | yes |
| 26 | `memory_update` | memory | `:write` | `memory_updated` | yes |
| 27 | `agent_send` | communication | `:none` | — | yes |
| 28 | `agent_ask` | communication | `:none` | — | yes |
| 29 | `agent_reply` | communication | `:none` | — | yes |
| 30 | `agent_handoff` | communication | `:none` | `workspace_changed` | yes |
| 31 | `agent_discover` | communication | `:none` | — | yes |
| 32 | `agent_inbox` | communication | `:none` | — | yes |
| 33 | `workspace_read` | workspace | `:read` | — | yes |
| 34 | `workspace_write` | workspace | `:write` | `workspace_changed` | yes |
| 35 | `workspace_list` | workspace | `:read` | — | yes |
| 36 | `workspace_search` | workspace | `:read` | — | yes |
| 37 | `notebook_read` | notebook | `:read` | — | **no** |
| 38 | `notebook_edit` | notebook | `:write` | `file_changed` | **no** |

**Total: 38 tools** (34 enabled, 2 disabled/future, 1 stub, 1 deprecated-computer-removed)

---

## 10. Resolved Decisions

1. **`@synapsis/` prefix over separate workspace tools** — filesystem tools route to workspace transparently. Agents don't learn two APIs.
2. **SQL-backed search for workspace** — grep uses PostgreSQL regex, glob uses LIKE. No filesystem crawl for DB-resident content.
3. **Communication tools bridge to Agent.Messaging** — one messaging system. Old swarm tools deprecated.
4. **Persist-before-broadcast for agent messages** — at-least-once delivery. Messages survive crashes.
5. **Sub-agents cannot `agent_ask`** — deadlock prevention. Use `agent_send` and let parent coordinate.
6. **Handoffs are messages + workspace documents** — delegation envelope via PubSub, audit record as `@synapsis/` doc. Two systems reinforce each other.
7. **Agent names not UUIDs** — `"global"`, `"project:{id}"`, `"session:{id}"`, `"parent"` for common operations.
8. **Cross-boundary moves rejected** — cannot move between real filesystem and `@synapsis/`. Clean separation.
9. **Domain-backed workspace paths are read-only** — skills, memory, todos created through their own contexts. Workspace only projects them.
10. **`computer` tool removed** — subsumed by MCP plugin integration (Puppeteer, Playwright). No need for a built-in stub.

---

## 11. Open Questions

None.
