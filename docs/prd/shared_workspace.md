# Synapsis Shared Workspace — Design Document

## 1. Why the Workspace Exists

Agents do work. That work produces artifacts — plans, todos, research notes, handoffs between agents. **Without the workspace, that work is invisible to the user.** It lives buried in conversation history, scattered across agent memory, or lost when a session ends.

The workspace exists so that **users can see and control what agents are doing, without reading conversation history.**

### 1.1 The Visibility Problem

Consider a typical multi-agent workflow:

1. User uploads a design spec and asks the assistant to implement it.
2. The Global Agent reads the spec, delegates to the Project Agent.
3. The Project Agent produces an architecture plan, splits it into tasks.
4. Each task is handed to a separate General Agent (implementer).
5. Implementers work in parallel, producing code changes.

Without the workspace, the user's only view into this pipeline is the chat log. To find out what the architect decided, the user scrolls through hundreds of messages. To check what implementer #2 is stuck on, the user opens a different session and scrolls again. To see whether the original spec was correctly interpreted, the user compares messages across three conversations.

With the workspace, every step produces a visible artifact:

```
/projects/synapsis/attachments/user/design-spec.pdf      ← user uploaded
/projects/synapsis/plans/auth-redesign.md                 ← architect wrote
/projects/synapsis/todos/auth-redesign-tasks.md           ← task splitter wrote
/projects/synapsis/sessions/<impl-1>/todo.md              ← implementer 1's checklist
/projects/synapsis/sessions/<impl-2>/todo.md              ← implementer 2's checklist
/projects/synapsis/handoffs/architect-to-splitter.json    ← handoff record
```

The user opens the app and sees the entire pipeline at a glance. "What did the architect decide?" — read the plan. "What's implementer 2 stuck on?" — read their todo. "Did the spec get correctly interpreted?" — compare the attachment to the plan. No message archaeology required.

### 1.2 Why Not Text Files in the Repo

Text files in the repo work fine for a single agent editing code. They fail for multi-agent collaboration:

**Not all agents work in a repo.** The Global Agent manages projects — it has no repo. An architect producing a plan isn't writing code yet. A research agent has no repo context at all. Their outputs have nowhere to go.

**Agent coordination artifacts aren't source code.** Plans, todos, handoffs, research notes — putting them in Git pollutes history with transient coordination. Removing them later is another commit. The repo becomes a message bus, which it isn't designed to be.

**Users need web access without a local clone.** The user might be on their phone checking what agents accomplished overnight. Text files in a repo require a clone or GitHub browsing. The workspace is immediately accessible through the web UI.

**No structure for browsing.** A flat directory of markdown files gives no indication of what's a plan vs. a todo vs. a handoff. The workspace provides typed, scoped, browsable organization that the web UI can render appropriately — todos as checklists, plans as documents, handoffs with sender/receiver metadata.

### 1.3 What the Workspace Is

The workspace is the **agent's desk that the user can see into.**

It is a database-backed, path-addressed shared storage layer where agents write their work products and users browse, edit, and control them through the web UI. It uses file-like semantics (paths, directories, markdown content) because that's the natural interaction model for both agents and humans — but the canonical data lives in the database, not the filesystem.

### 1.4 Core Value Propositions

**For users:**
- See what every agent is doing, right now, without reading chat logs
- Browse plans, todos, notes, and handoffs in organized views
- Edit agent-produced artifacts directly (reprioritize a todo, annotate a plan)
- Access from any device via the web UI
- Track the history of how artifacts evolved

**For agents:**
- A known, stable location to write working artifacts
- Shared context across agent boundaries (architect's plan is readable by implementer)
- Structured handoff mechanism (not "here's a wall of text in a message")
- Persistent scratch space that survives session restarts

**For the system:**
- Single source of truth for non-code collaboration artifacts
- Searchable, indexed, versioned content
- Clean separation: Git owns code, workspace owns coordination

---

## 2. Design Principles

### 2.1 Visibility First

Every design decision serves the primary goal: making agent work visible and controllable by the user. If an artifact is produced by an agent and might matter to the user, it belongs in the workspace.

### 2.2 Out-of-Repo by Default

Anything that is not source code but needs to be shared belongs in the workspace, not the Git repository.

### 2.3 File Semantics, Not Filesystem Emulation

The system should feel like a project file tree — paths, directories, markdown files — without requiring full POSIX behavior. No FUSE, no kernel mounts, no inode semantics.

### 2.4 Database as Source of Truth

Canonical state lives in the database and blob storage. Local file projections are caches, not authority.

### 2.5 Workspace Is a Projection Layer

The workspace presents a unified file-like view over both structured domain records (skills, todos, memory entries) and unstructured documents (notes, plans, ideas, scratch). The user and agent experience is identical regardless of the backing store.

### 2.6 Shared but Scoped

Resources are scoped by path prefix: global (`/shared/`), project (`/projects/:id/`), or session (`/projects/:id/sessions/:sid/`). Scope is derived from path, never stored redundantly.

### 2.7 Lifecycle-Aware

Temporary session scratch is not the same as a published plan. The workspace tracks lifecycle state (scratch → draft → shared → published → archived) and treats each differently for versioning, garbage collection, and visibility.

---

## 3. Scenarios

These scenarios ground the design in concrete user and agent workflows.

### 3.1 Agent Writes a Todo, User Views It

**Without workspace:** Agent writes a todo list into its conversation context. User sees it only if they scroll to that message. If the agent updates the todo, the user must find the latest version among potentially dozens of messages.

**With workspace:** Agent calls `workspace_write("/projects/myapp/todos/current.md", content)`. The web UI has a Todos view that reads from workspace. User opens the app, sees the todo list rendered as a checklist, can check items off, add notes, reprioritize. Agent sees user's changes on next read. Shared, live, zero friction.

### 3.2 Design Doc Pipeline

**User action:** Uploads `design-spec.pdf` and says "implement this."

**Agent pipeline:**
1. Global Agent receives the message, stores the attachment: `workspace_write("/projects/myapp/attachments/user/design-spec.pdf", blob)`
2. Global Agent delegates to Project Agent with reference to the attachment path.
3. Project Agent spawns an architect General Agent. Architect reads the spec, produces a plan: `workspace_write("/projects/myapp/plans/auth-redesign.md", plan_content)`
4. Project Agent reads the plan, splits into tasks: `workspace_write("/projects/myapp/todos/auth-redesign-tasks.md", task_list)`
5. Project Agent spawns implementer General Agents, each with their task slice.
6. Each implementer writes their own session todo: `workspace_write("/projects/myapp/sessions/<sid>/todo.md", my_tasks)`
7. As implementers complete tasks, they update their session todos.

**User experience at any point:**
- Opens the Workspace Explorer → sees all artifacts organized by type
- Opens Plans → reads the architect's plan
- Opens Todos → sees the task breakdown with status
- Opens a session → sees what that specific implementer is working on
- Can annotate the plan, reprioritize tasks, or add constraints — agents see the changes

### 3.3 Agent-to-Agent Handoff

An architect agent completes a design and needs to hand it to a task-splitting agent.

**Without workspace:** The architect writes a long message to its parent. The parent extracts relevant parts, reformats them, and passes them as context to the next agent. Information is lost in translation, and the user never sees the intermediate artifact.

**With workspace:** The architect writes the plan to workspace. The handoff is a structured message (using the existing agent messaging system, §AS-7) that references the workspace path:

```elixir
%{type: :handoff, payload: %{
  artifact_ids: ["01JXYZ..."],
  summary: "Auth redesign plan ready for task splitting",
  instructions: "Break into implementable tasks, one per module"
}}
```

The receiving agent reads the referenced artifact from workspace. The user can see the handoff record, the plan it references, and the tasks it produced — full audit trail of the agent pipeline.

### 3.4 Research Agent Shares Findings

A Special Agent is spawned to research a library's API before the coding agent starts work.

**Without workspace:** Research results exist only in the Special Agent's conversation history. When it reports back to the parent, the full context is compressed into a summary message.

**With workspace:** The research agent writes findings to workspace: `workspace_write("/projects/myapp/notes/stripe-api-research.md", findings)`. The coding agent reads this file directly. The user can review the research independently. The findings persist after the research agent terminates.

### 3.5 User Adds Context Mid-Workflow

User notices the agents are heading in the wrong direction. They want to add a constraint.

**Without workspace:** User types a message into the chat and hopes the right agent sees it.

**With workspace:** User opens the plan in the workspace, adds a note: "Do NOT use JWT — we're using session tokens." Saves. The next time any agent reads the plan, the constraint is there. The user has directly edited the agent's working document.

---

## 4. Repo vs. Workspace Boundary

### 4.1 Git Repository Contains

- Source code
- Tests
- Build configuration
- Project-owned docs that version with code (README, CHANGELOG)

### 4.2 Workspace Contains

- Agent-produced plans, todos, notes, ideas
- User-uploaded attachments and reference materials
- Agent-to-agent handoff records
- Session working drafts and scratch
- Persistent memory artifacts extracted from completed work
- Shared and project-scoped skills (SKILL.md bundles)

### 4.3 The Rule

If an artifact is primarily part of **runtime collaboration or agent coordination**, it belongs in the workspace. If it is part of the **deliverable product**, it belongs in the repo.

---

## 5. Directory Schema

```
/shared/
  skills/                           # global reusable skills
  notes/                            # cross-project knowledge
  ideas/                            # unassigned ideas

/projects/<project_id>/
  skills/                           # project-specific skills
  notes/                            # project notes and context
  plans/                            # implementation plans, roadmaps
  todos/                            # project task lists
  ideas/                            # project ideas not yet promoted
  handoffs/                         # agent-to-agent transfer records
  attachments/
    user/                           # user-uploaded files
    derived/                        # agent-generated summaries, extractions
  memory/
    episodic/                       # session/task summaries
    semantic/                       # durable project knowledge
    decisions/                      # explicit design decisions
  sessions/<session_id>/
    scratch/                        # temporary working drafts
    todo.md                         # session checklist
    plan.md                         # session draft plan
    handoff.md                      # session draft handoff
```

### 5.1 Path Semantics

Paths are human-readable, agent-discoverable, and scoped by convention:

- `/shared/**` → global scope, default visibility `global_shared`
- `/projects/:id/**` → project scope, default visibility `project_shared`
- `/projects/:id/sessions/:sid/**` → session scope, default visibility `private`

Scope is derived from path prefix. Only `visibility` is stored as an explicit field, never `scope`.

---

## 6. Architecture

### 6.1 Workspace Is a Projection Layer

The workspace presents a uniform file-like interface over two backing stores:

1. **Existing domain schemas** in `synapsis_data` (skills, memory_entries, session_todos) — projected as virtual files at their conventional paths
2. **`workspace_documents` table** — stores genuinely unstructured content (notes, plans, ideas, scratch, handoffs) that has no existing domain schema

The caller receives a uniform `%Workspace.Resource{}` struct regardless of source:

```elixir
%Workspace.Resource{
  id: ulid,
  path: "/projects/synapsis/plans/auth-redesign.md",
  kind: :document,
  content: "# Auth Redesign Plan\n...",
  metadata: %{},
  visibility: :project_shared,
  lifecycle: :shared,
  version: 3
}
```

For domain-backed resources, the path is computed from domain fields (a skill with `scope: :project, project_id: "abc", name: "elixir-patterns"` resolves to `/projects/abc/skills/elixir-patterns/SKILL.md`). For `workspace_documents`, the path is stored directly.

### 6.2 Identity Model

`id` (ULID) is the stable identity. Paths are mutable, indexed, and can change via rename/move without breaking references. Handoffs and cross-references use `id` for resolution and `path` for human readability.

### 6.3 Umbrella Placement

New app: `synapsis_workspace`.

```
synapsis_data (schemas — owns workspace_documents table)
    ↑
synapsis_core (domain contexts: Skills, Sessions, Projects)
    ↑
synapsis_workspace (path resolution, projection, versioning, search, blob store)
    ↑
synapsis_agent (consumes workspace via tools)
    ↑
synapsis_server / synapsis_web (web explorer, API)
```

`synapsis_workspace` depends on `synapsis_data` (queries) and `synapsis_core` (domain contexts for projection). It does not depend on agent, server, or web layers.

### 6.4 Canonical Data Model

#### workspace_documents table

```
id              ULID, primary key
path            text, unique index, not null
kind            enum (document | attachment | handoff | session_scratch)
project_id      references projects, nullable (null for /shared/)
session_id      references sessions, nullable
visibility      enum (private | project_shared | global_shared | published)
lifecycle       enum (scratch | draft | shared | published | archived)
content_format  enum (markdown | yaml | json | text | binary)
content_body    text, nullable (inline for small content, <64KB)
blob_ref        text, nullable (content-addressable hash for large/binary)
metadata        jsonb, default '{}'
version         integer, default 1
created_by      text (agent_id or "user")
updated_by      text
search_vector   tsvector, generated (weighted: path A, metadata.title B, content_body C)
created_at      utc_datetime_usec
updated_at      utc_datetime_usec
last_accessed_at utc_datetime_usec, nullable
deleted_at      utc_datetime_usec, nullable (soft delete)
```

GIN index on `search_vector`. Unique index on `path` where `deleted_at IS NULL`.

#### workspace_document_versions table

```
id              ULID, primary key
document_id     references workspace_documents
version         integer
content_body    text, nullable
blob_ref        text, nullable
content_hash    text
changed_by      text
created_at      utc_datetime_usec
```

Version history is lifecycle-gated:

| Lifecycle | Version Policy |
|---|---|
| `scratch` | No history. Overwrites in place. |
| `draft` | Last 5 versions. Older pruned by GC. |
| `shared` | Full history. |
| `published` | Full history. Immutable (new version = new resource). |
| `archived` | History frozen. No new writes. |

### 6.5 Blob Storage

Small text documents (<64KB) store content inline in `content_body`. Larger content and binary attachments use a content-addressable local filesystem:

```
~/.config/synapsis/blobs/
  ab/cd/abcdef1234567890...    # SHA-256 path segments
```

Adapter boundary:

```elixir
defmodule Synapsis.Workspace.BlobStore do
  @callback put(content :: binary()) :: {:ok, ref :: binary()}
  @callback get(ref :: binary()) :: {:ok, binary()} | {:error, :not_found}
  @callback delete(ref :: binary()) :: :ok
  @callback exists?(ref :: binary()) :: boolean()
end
```

`BlobStore.Local` for v1. `BlobStore.S3` adapter boundary reserved for future.

### 6.6 Search

PostgreSQL `tsvector` from day one:

```sql
search_vector tsvector GENERATED ALWAYS AS (
  setweight(to_tsvector('english', coalesce(path, '')), 'A') ||
  setweight(to_tsvector('english', coalesce(metadata->>'title', '')), 'B') ||
  setweight(to_tsvector('english', coalesce(content_body, '')), 'C')
) STORED;
```

The `workspace_search` tool translates agent queries to `websearch_to_tsquery`. Search fans out across both `workspace_documents` and projected domain records (skills by name, memory by content).

Phase 3 adds `embedding vector(1536)` column + pgvector for semantic search.

---

## 7. Agent Interaction

### 7.1 Workspace Tools (4 tools)

```
workspace_read(path)                 — read content by path or id
workspace_write(path, content, opts) — create or update; auto-creates parent dirs
workspace_list(path, opts)           — list dir; opts: sort, depth, kind, recent
workspace_search(query, opts)        — full-text + path search; opts: scope, kind
```

These register in `Synapsis.ToolRegistry` alongside the 27 existing tools. Permission level `:none` for read/list/search, `:write` for write.

No `workspace_stat` (covered by `workspace_list` with `depth: 0`). No `workspace_recent` (covered by `workspace_list` with `sort: :recent`). No `workspace_publish` (write to a non-scratch path auto-promotes lifecycle). No `workspace_handoff` (handoffs are agent messages that reference workspace paths).

### 7.2 Handoffs Through Agent Messaging

Handoffs use the existing agent message envelope (agent PRD §AS-7) with type `:handoff`:

```elixir
%{
  from: architect_agent_id,
  to: project_agent_id,
  type: :handoff,
  ref: "handoff-01JXYZ",
  payload: %{
    artifact_ids: ["01JXYZ..."],
    summary: "Auth redesign plan ready for task splitting",
    instructions: "Break into implementable tasks, one per module"
  }
}
```

Handoff metadata is persisted as a `workspace_document` at `/projects/:id/handoffs/:ref.json` by the agent messaging layer after delivery. This provides both searchability and audit trail without a separate tool.

### 7.3 Workspace vs. Repo Tool Boundary

Clear rule for agents:

- **Repo files** (source code, tests, configs) → use `file_read`, `file_write`, `file_edit`, `grep`, `glob`, `bash_exec`
- **Workspace files** (plans, todos, notes, handoffs, skills, memory) → use `workspace_read`, `workspace_write`, `workspace_list`, `workspace_search`

Agents should never use `file_write` to create plans in the repo, and should never use `workspace_write` to create source code.

---

## 8. Web UI Integration

The web UI is the primary surface for user visibility and control.

### 8.1 Core Views

| View | Source | Rendering |
|---|---|---|
| Workspace Explorer | `workspace_list` tree traversal | LiveView — folder tree + file preview |
| Plans | `/projects/:id/plans/**` | LiveView — markdown rendering, inline edit |
| Todos | `/projects/:id/todos/**` + `session_todos` | LiveView — checklist with status toggles |
| Notes | `/projects/:id/notes/**` + `/shared/notes/**` | LiveView — markdown editor |
| Ideas | `/projects/:id/ideas/**` | LiveView — card view with promote action |
| Skills | projected from `skills` schema | LiveView — existing SkillLive views |
| Handoffs | `/projects/:id/handoffs/**` | LiveView — sender/receiver/status/artifacts |
| Attachments | `/projects/:id/attachments/**` | LiveView — file list with preview |
| Memory | projected from `memory_entries` + `/projects/:id/memory/**` | LiveView — categorized knowledge base |
| Recent | `workspace_list(sort: :recent)` | LiveView — timeline of recent changes |

### 8.2 User Editing

Users can edit workspace documents directly in the web UI. Edits go through `Synapsis.Workspace.write/3` with `updated_by: "user"`. Agents see user changes on their next `workspace_read`. No real-time collaborative editing for v1 — optimistic concurrency with version checks on write.

### 8.3 Integration with Existing LiveViews

The workspace explorer is a new LiveView (`WorkspaceLive.Explorer`). Existing views (SkillLive, MemoryLive) continue to work against domain schemas directly — workspace projection is additive, not a replacement for existing CRUD. The explorer provides a unified browsing alternative.

---

## 9. Lifecycle and Garbage Collection

### 9.1 Lifecycle States

```
scratch → draft → shared → published → archived
```

Session scratch is temporary. Published is durable. The lifecycle determines version history retention, GC eligibility, and default visibility.

### 9.2 Promotion

Promotion is explicit: writing a scratch artifact to a non-session path promotes it automatically.

```
# Agent promotes session scratch to project plan:
workspace_write("/projects/myapp/plans/auth-redesign.md", content)
# lifecycle auto-set to :shared based on target path
```

Users can also promote via the web UI — a "Promote to Project" action on any session-scoped artifact.

### 9.3 Session Scratch GC

A periodic `Synapsis.Workspace.GC` GenServer cleans up:

1. Session scratch documents where the session completed more than 7 days ago (configurable)
2. Draft version history beyond the 5-version retention window
3. Orphaned blobs with no referencing document

Promoted documents (lifecycle ≥ `shared`) are excluded from GC regardless of session association.

```elixir
config :synapsis_workspace, :gc,
  session_scratch_retention_days: 7,
  draft_version_retention: 5,
  gc_interval_hours: 24
```

---

## 10. Permissions Model

### 10.1 Scope Rules

- Global Agent may access `/shared/**` and any `/projects/:id/**` it is delegated to
- Project Agent may access its own `/projects/:id/**` and `/shared/**` (read-only)
- Session-scoped agents may access their session path and promoted project-shared materials
- Users may browse and edit all workspace content (single-user tool, no auth)

### 10.2 Path-Based Access

Permission checks operate on path prefixes:

- Project Agent for `synapsis` can read/write `/projects/synapsis/**`
- Project Agent cannot write `/projects/other-project/**`
- Session Agent can write `/projects/synapsis/sessions/<own-session>/**`

### 10.3 Future Multi-User

Current design assumes single-user (per design-v2.md: "No auth. Access = admin. Single-user local tool"). Permission model is designed to support future multi-user scenarios without schema changes — the `visibility` field and path-based checks are sufficient.

---

## 11. Module Boundaries

```
apps/synapsis_workspace/
├── lib/synapsis_workspace/
│   ├── workspace.ex                # Public API: read, write, list, search
│   ├── path_resolver.ex            # Path parsing, scope derivation, domain dispatch
│   ├── resources.ex                # workspace_documents CRUD + versioning
│   ├── projection.ex               # Domain schema → Workspace.Resource mapping
│   ├── blob_store.ex               # Behaviour
│   ├── blob_store/
│   │   └── local.ex                # Content-addressable local FS
│   ├── search.ex                   # tsvector queries + cross-schema fan-out
│   ├── gc.ex                       # Periodic cleanup GenServer
│   └── resource.ex                 # %Workspace.Resource{} struct
```

Schemas (`workspace_documents`, `workspace_document_versions`) live in `synapsis_data` per umbrella convention.

---

## 12. Implementation Phases

### Phase 1: Core Workspace

- `workspace_documents` schema + migrations
- `Workspace.Resource` struct
- `Workspace` public API (read, write, list, search)
- `PathResolver` — path parsing, scope derivation
- `Resources` — CRUD for `workspace_documents` with version history
- `BlobStore.Local` — content-addressable local storage
- `Search` — tsvector full-text search
- 4 workspace agent tools registered in ToolRegistry
- Basic `WorkspaceLive.Explorer` in web UI

**Deliverable:** Agents can write plans/todos/notes to workspace. Users can browse and edit them in the web UI.

### Phase 2: Projection + Lifecycle

- `Projection` — domain schema mapping (skills, memory, todos as workspace resources)
- Lifecycle state machine with auto-promotion rules
- `GC` GenServer for session scratch cleanup
- Version history lifecycle gating
- Handoff persistence in workspace from agent messaging layer
- Attachments with blob storage for binary files

**Deliverable:** Unified workspace view over both domain schemas and documents. Full lifecycle management.

### Phase 3: Search + Sync

- Semantic search with pgvector embeddings
- Cross-schema fan-out search (documents + skills + memory)
- Recent items view with access tracking
- Optional local read-only cache projection at `<repo>/.synapsis-cache/workspace/`
- Richer permissions for multi-user scenarios (future)

**Deliverable:** Workspace is fully searchable, including semantic similarity. Optional shell-friendly local projection.

---

## 13. Resolved Decisions

1. **Workspace is a projection layer**, not a replacement for domain schemas. Structured domain records (skills, todos, memory) stay in their Ecto schemas. Unstructured content (notes, plans, ideas, scratch) lives in `workspace_documents`. The workspace API presents a uniform view over both.

2. **New umbrella app `synapsis_workspace`**, depends on `synapsis_data` + `synapsis_core`. Owns path resolution, projection, versioning, search, and blob storage.

3. **`id` is identity, path is mutable.** Every resource has a stable ULID. Paths are indexed and can change via rename/move. Cross-references use `id` for resolution.

4. **Scope derived from path, only visibility stored.** No redundant `scope` field. Path prefix determines scope. `visibility` is the only explicit access-control field.

5. **4 workspace tools.** `workspace_read`, `workspace_write`, `workspace_list`, `workspace_search`. No separate stat/recent/publish/handoff tools. Covered by existing tools with options.

6. **Handoffs through agent messaging.** Handoffs are `:handoff` type messages in the existing agent message bus (agent PRD §AS-7), referencing workspace paths. Handoff metadata persisted as workspace documents for audit.

7. **Version history is lifecycle-gated.** Scratch: none. Draft: last 5. Shared/published: full. Prevents unbounded history growth from high-frequency agent writes to scratch.

8. **Content-addressable local FS for blobs.** Inline `content_body` for small documents (<64KB). SHA-256 addressed local store for large/binary content. Adapter boundary for future S3.

9. **Session scratch GC at 7 days post-completion.** Configurable. Promoted documents excluded.

10. **PostgreSQL tsvector from day one.** Weighted search across path, title, and content. pgvector for semantic search in Phase 3.

11. **No FUSE, no kernel filesystem.** The workspace needs path-based addressing, directory browsing, and file-like content access — not POSIX semantics. A shared workspace layer, not a virtual filesystem.

