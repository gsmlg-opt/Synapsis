# synapsis_workspace — Product Requirements Document

## 1. Overview

**Application:** `synapsis_workspace`
**Module namespace:** `SynapsisWorkspace`
**Location:** `apps/synapsis_workspace` within the Synapsis umbrella
**Target:** Elixir >= 1.18 / OTP 28+

synapsis_workspace is the shared collaboration layer for Synapsis. It provides a database-backed, path-addressed storage system where agents write their work products and users browse, edit, and control them through the web UI.

**The problem it solves:** Agents produce artifacts — plans, todos, research notes, handoffs — that are invisible to the user without a dedicated collaboration surface. Without the workspace, agent work is buried in conversation history, scattered across agent memory, or lost when sessions end. The workspace makes agent work visible and controllable.

**One-line definition:** The workspace is the agent's desk that the user can see into.

This document covers:

- Motivation and value proposition
- Directory schema and path semantics
- Canonical data model and projection architecture
- Workspace tools for agent interaction (4 tools)
- Blob storage and search
- Lifecycle, versioning, and garbage collection
- Web UI integration
- Permissions model

### Dependency Position

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

synapsis_workspace depends on synapsis_data (queries) and synapsis_core (domain contexts for projection). It does NOT depend on synapsis_agent, synapsis_server, or synapsis_web. Communication to the UI layer is via PubSub.

---

## 2. Motivation

### 2.1 The Visibility Problem

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

The user opens the app and sees the entire pipeline at a glance.

### 2.2 Why Not Text Files in the Repo

Text files in the repo work fine for a single agent editing code. They fail for multi-agent collaboration:

**Not all agents work in a repo.** The Global Agent manages projects — it has no repo. An architect producing a plan isn't writing code yet. A research agent has no repo context at all. Their outputs have nowhere to go.

**Agent coordination artifacts aren't source code.** Plans, todos, handoffs, research notes — putting them in Git pollutes history with transient coordination. Removing them later is another commit. The repo becomes a message bus, which it isn't designed to be.

**Users need web access without a local clone.** The user might be on their phone checking what agents accomplished overnight. Text files in a repo require a clone or GitHub browsing. The workspace is immediately accessible through the web UI.

**No structure for browsing.** A flat directory of markdown files gives no indication of what's a plan vs. a todo vs. a handoff. The workspace provides typed, scoped, browsable organization that the web UI can render appropriately — todos as checklists, plans as documents, handoffs with sender/receiver metadata.

### 2.3 Value Propositions

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

### 2.4 Scenarios

#### Scenario A: Agent Writes a Todo, User Views It

**Without workspace:** Agent writes a todo list into its conversation context. User sees it only if they scroll to that message. If the agent updates the todo, the user must find the latest version among potentially dozens of messages.

**With workspace:** Agent calls `workspace_write("/projects/myapp/todos/current.md", content)`. The web UI has a Todos view that reads from workspace. User opens the app, sees the todo list rendered as a checklist, can check items off, add notes, reprioritize. Agent sees user's changes on next read.

#### Scenario B: Design Doc Pipeline

**User action:** Uploads `design-spec.pdf` and says "implement this."

1. Global Agent stores attachment: `workspace_write("/projects/myapp/attachments/user/design-spec.pdf", blob)`
2. Global Agent delegates to Project Agent with reference to the attachment path.
3. Project Agent spawns architect. Architect reads spec, produces plan: `workspace_write("/projects/myapp/plans/auth-redesign.md", plan_content)`
4. Project Agent reads plan, splits into tasks: `workspace_write("/projects/myapp/todos/auth-redesign-tasks.md", task_list)`
5. Project Agent spawns implementers, each writes session todo: `workspace_write("/projects/myapp/sessions/<sid>/todo.md", my_tasks)`

User can see every artifact at every step — plans, task breakdowns, per-implementer checklists — and edit any of them.

#### Scenario C: Agent-to-Agent Handoff

Architect writes plan to workspace. Handoff is a structured message (agent-system-prd §AS-7) referencing workspace paths:

```elixir
%{type: :handoff, payload: %{
  artifact_ids: ["01JXYZ..."],
  summary: "Auth redesign plan ready for task splitting",
  instructions: "Break into implementable tasks, one per module"
}}
```

Receiving agent reads referenced artifact from workspace. User sees handoff record, the plan it references, and tasks it produced.

#### Scenario D: User Adds Context Mid-Workflow

User notices agents are heading in the wrong direction. Opens the plan in workspace, adds: "Do NOT use JWT — we're using session tokens." Saves. Next time any agent reads the plan, the constraint is there.

---

## 3. Repo vs. Workspace Boundary

### 3.1 The Rule

If an artifact is primarily part of **runtime collaboration or agent coordination**, it belongs in the workspace. If it is part of the **deliverable product**, it belongs in the repo.

### 3.2 Git Repository Contains

- Source code, tests, build configuration
- Project-owned docs that version with code (README, CHANGELOG)

### 3.3 Workspace Contains

- Agent-produced plans, todos, notes, ideas
- User-uploaded attachments and reference materials
- Agent-to-agent handoff records
- Session working drafts and scratch
- Persistent memory artifacts extracted from completed work
- Shared and project-scoped skills (SKILL.md bundles)

---

## 4. Architecture

### WS-1: Projection Layer

The workspace is a projection layer, not a replacement for domain schemas.

**WS-1.1** — Two backing stores:

1. **Existing domain schemas** in `synapsis_data` (skills, memory_entries, session_todos) — projected as virtual files at their conventional paths.
2. **`workspace_documents` table** — stores genuinely unstructured content (notes, plans, ideas, scratch, handoffs) that has no existing domain schema.

**WS-1.2** — Uniform resource struct:

```elixir
defmodule SynapsisWorkspace.Resource do
  @type t :: %__MODULE__{
    id: binary(),
    path: String.t(),
    kind: :document | :skill | :todo | :attachment | :handoff | :memory | :session_scratch,
    content: String.t() | binary(),
    content_format: :markdown | :yaml | :json | :text | :binary,
    metadata: map(),
    visibility: :private | :project_shared | :global_shared | :published,
    lifecycle: :scratch | :draft | :shared | :published | :archived,
    version: integer(),
    created_by: String.t(),
    updated_by: String.t(),
    created_at: DateTime.t(),
    updated_at: DateTime.t()
  }
end
```

**WS-1.3** — The caller never knows whether a resource came from `skills`, `session_todos`, `memory_entries`, or `workspace_documents`. Path resolution dispatches to the correct backing store transparently.

**WS-1.4** — For domain-backed resources, paths are computed from domain fields:
- Skill with `scope: :project, project_id: "abc", name: "elixir-patterns"` → `/projects/abc/skills/elixir-patterns/SKILL.md`
- Memory entry with `scope: :project, project_id: "abc", key: "auth-patterns"` → `/projects/abc/memory/semantic/auth-patterns.md`
- Session todo for session `sid` in project `pid` → `/projects/pid/sessions/sid/todo.md`

For `workspace_documents`, the path is stored directly as a mutable indexed column.

### WS-2: Identity Model

**WS-2.1** — `id` (ULID) is the stable identity. Paths are mutable, indexed, and can change via rename/move without breaking references.

**WS-2.2** — Cross-references (handoffs, agent messages) use `id` for resolution and `path` for human readability. Both are stored in handoff payloads; resolution always prefers `id`.

**WS-2.3** — Domain-backed resources use the domain record's existing `id`. `workspace_documents` generate their own ULID on creation.

### WS-3: Directory Schema

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

**WS-3.1** — Scope is derived from path prefix, never stored as a separate field:
- `/shared/**` → global scope, default visibility `:global_shared`
- `/projects/:id/**` → project scope, default visibility `:project_shared`
- `/projects/:id/sessions/:sid/**` → session scope, default visibility `:private`

**WS-3.2** — Only `visibility` is stored as an explicit field. No redundant `scope` column.

### WS-4: Path Resolver

```elixir
defmodule SynapsisWorkspace.PathResolver do
  @type scope :: :global | :project | :session
  @type resolved :: {:document, document_id}
                  | {:skill, skill_id}
                  | {:memory, memory_entry_id}
                  | {:todo, session_todo_id}
                  | :not_found

  @spec resolve(path :: String.t()) :: resolved()
  @spec scope(path :: String.t()) :: scope()
  @spec project_id(path :: String.t()) :: binary() | nil
  @spec session_id(path :: String.t()) :: binary() | nil
  @spec kind(path :: String.t()) :: atom()
  @spec validate(path :: String.t()) :: :ok | {:error, reason :: term()}
end
```

**WS-4.1** — Path validation rules:
- Must start with `/shared/` or `/projects/`
- Path segments are lowercase, alphanumeric, hyphens, underscores
- No `.`, `..`, or empty segments
- Maximum depth: 10 segments
- Maximum path length: 1024 bytes

**WS-4.2** — Resolution order for read operations:
1. Try domain schema dispatch (skills, memory, todos) based on path pattern
2. Fall back to `workspace_documents` table lookup by path
3. Return `:not_found`

**WS-4.3** — Resolution for write operations:
- Paths matching domain schema patterns (`/projects/:id/skills/**`) are rejected — domain records are written through their own contexts (`Synapsis.Skills`, `Synapsis.Sessions`)
- All other paths write to `workspace_documents`

### WS-5: Canonical Data Model

#### workspace_documents

```elixir
defmodule SynapsisData.WorkspaceDocument do
  use Ecto.Schema

  @primary_key {:id, SynapsisData.ULID, autogenerate: true}

  schema "workspace_documents" do
    field :path, :string
    field :kind, Ecto.Enum, values: [:document, :attachment, :handoff, :session_scratch]
    field :visibility, Ecto.Enum, values: [:private, :project_shared, :global_shared, :published]
    field :lifecycle, Ecto.Enum, values: [:scratch, :draft, :shared, :published, :archived]
    field :content_format, Ecto.Enum, values: [:markdown, :yaml, :json, :text, :binary]
    field :content_body, :string
    field :blob_ref, :string
    field :metadata, :map, default: %{}
    field :version, :integer, default: 1
    field :created_by, :string
    field :updated_by, :string
    field :last_accessed_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    belongs_to :project, SynapsisData.Project, type: SynapsisData.ULID
    belongs_to :session, SynapsisData.Session, type: SynapsisData.ULID

    timestamps(type: :utc_datetime_usec)
  end
end
```

**WS-5.1** — Indexes:
- Unique index on `path` where `deleted_at IS NULL`
- GIN index on `search_vector`
- Index on `project_id`
- Index on `session_id`
- Index on `kind`
- Index on `updated_at` (for recent items)

**WS-5.2** — Content storage strategy:
- Small text documents (<64KB): inline in `content_body`, `blob_ref` is null
- Large content or binary attachments: `content_body` is null, content stored in blob store, `blob_ref` holds content-addressable hash

**WS-5.3** — Soft delete via `deleted_at` timestamp. Hard delete by GC after retention period.

#### workspace_document_versions

```elixir
defmodule SynapsisData.WorkspaceDocumentVersion do
  use Ecto.Schema

  @primary_key {:id, SynapsisData.ULID, autogenerate: true}

  schema "workspace_document_versions" do
    field :version, :integer
    field :content_body, :string
    field :blob_ref, :string
    field :content_hash, :string
    field :changed_by, :string

    belongs_to :document, SynapsisData.WorkspaceDocument, type: SynapsisData.ULID

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
```

**WS-5.4** — Search vector (PostgreSQL generated column):

```sql
search_vector tsvector GENERATED ALWAYS AS (
  setweight(to_tsvector('english', coalesce(path, '')), 'A') ||
  setweight(to_tsvector('english', coalesce(metadata->>'title', '')), 'B') ||
  setweight(to_tsvector('english', coalesce(content_body, '')), 'C')
) STORED;
```

### WS-6: Blob Storage

**WS-6.1** — Behaviour:

```elixir
defmodule SynapsisWorkspace.BlobStore do
  @callback put(content :: binary()) :: {:ok, ref :: binary()} | {:error, term()}
  @callback get(ref :: binary()) :: {:ok, binary()} | {:error, :not_found}
  @callback delete(ref :: binary()) :: :ok | {:error, term()}
  @callback exists?(ref :: binary()) :: boolean()
end
```

**WS-6.2** — `BlobStore.Local` adapter: content-addressable local filesystem using SHA-256 hashing.

```
~/.config/synapsis/blobs/
  ab/cd/abcdef1234567890...    # first 2 bytes as directory sharding
```

**WS-6.3** — Deduplication: identical content produces identical refs. Multiple documents can reference the same blob.

**WS-6.4** — `BlobStore.S3` adapter boundary reserved for future. Not implemented in v1.

### WS-7: Search

**WS-7.1** — PostgreSQL `tsvector` full-text search from day one. Queries use `websearch_to_tsquery` for natural language input from agents.

**WS-7.2** — Search fans out across backing stores:
- `workspace_documents.search_vector` for unstructured content
- `skills` table by name and description
- `memory_entries` table by key and content

Results are merged, deduplicated by `id`, and ranked by relevance.

**WS-7.3** — Search accepts scope filtering:
- `:global` — `/shared/**` + projected global records
- `:project` with `project_id` — `/projects/:id/**` + projected project records
- `:session` with `session_id` — `/projects/:id/sessions/:sid/**`
- `:all` — everything accessible to the caller

**WS-7.4** — Phase 3 adds `embedding vector(1536)` column + pgvector for semantic search.

### WS-8: Lifecycle

**WS-8.1** — States:

```
scratch → draft → shared → published → archived
```

**WS-8.2** — Lifecycle determines version history policy:

| Lifecycle | Version Policy |
|---|---|
| `scratch` | No history. Overwrites in place. |
| `draft` | Last 5 versions. Older pruned by GC. |
| `shared` | Full history. |
| `published` | Full history. Immutable (new version = new resource). |
| `archived` | History frozen. No new writes. |

**WS-8.3** — Auto-promotion rules on write:
- Writing to `/projects/:id/sessions/:sid/**` → lifecycle defaults to `:scratch`
- Writing to `/projects/:id/{notes,plans,todos,ideas}/**` → lifecycle defaults to `:shared`
- Writing to `/shared/**` → lifecycle defaults to `:shared`
- Explicit lifecycle override available via opts

**WS-8.4** — Promotion is also explicit: user can promote session scratch to project level via web UI "Promote to Project" action, which copies the document to a non-session path and updates lifecycle.

### WS-9: Garbage Collection

**WS-9.1** — `SynapsisWorkspace.GC` is a GenServer running on configurable interval (default: 24 hours).

**WS-9.2** — GC tasks:
1. Delete session scratch documents where session completed > `session_scratch_retention_days` ago (default: 7)
2. Prune draft version history beyond `draft_version_retention` count (default: 5)
3. Delete orphaned blobs with no referencing document
4. Hard-delete soft-deleted documents past retention period

**WS-9.3** — Promoted documents (lifecycle ≥ `:shared`) are excluded from session scratch GC regardless of `session_id` association.

**WS-9.4** — Configuration:

```elixir
config :synapsis_workspace, :gc,
  session_scratch_retention_days: 7,
  draft_version_retention: 5,
  gc_interval_hours: 24,
  soft_delete_retention_days: 30
```

---

## 5. Public API

### WS-10: Workspace API

```elixir
defmodule SynapsisWorkspace do
  @type path :: String.t()
  @type opts :: keyword()

  @spec read(path) :: {:ok, Resource.t()} | {:error, :not_found}
  @spec read!(path) :: Resource.t()

  @spec write(path, content :: String.t() | binary(), opts) :: {:ok, Resource.t()} | {:error, term()}
  # opts: :metadata, :content_format, :visibility, :lifecycle, :created_by

  @spec list(path, opts) :: {:ok, [Resource.t()]} | {:error, term()}
  # opts: :depth (default 1), :sort (:name | :recent | :kind), :kind, :lifecycle

  @spec search(query :: String.t(), opts) :: {:ok, [Resource.t()]}
  # opts: :scope, :project_id, :kind, :limit (default 20)

  @spec delete(path) :: :ok | {:error, term()}

  @spec move(from :: path, to :: path) :: {:ok, Resource.t()} | {:error, term()}

  @spec stat(path) :: {:ok, Resource.t()} | {:error, :not_found}
  # Returns resource without content (metadata only)

  @spec exists?(path) :: boolean()
end
```

**WS-10.1** — `write/3` auto-creates parent directory entries. Directories are implicit — they exist when any child document exists.

**WS-10.2** — `write/3` checks lifecycle before creating version history entry. Scratch documents skip versioning.

**WS-10.3** — `write/3` validates path via `PathResolver.validate/1` and rejects writes to domain-backed paths (skills, memory, todos).

**WS-10.4** — `list/2` returns resources at the given path prefix. For mixed backing stores (e.g., `/projects/:id/` contains both domain-projected skills and workspace documents), results are merged.

**WS-10.5** — All write operations broadcast `{:workspace_changed, path, action}` via PubSub to `"workspace:{project_id}"` for UI updates.

---

## 6. Workspace Tools

Four tools for agent interaction, registered in `Synapsis.ToolRegistry` alongside the 27 existing tools from `synapsis_tool`.

### WS-11: workspace_read

| Field | Value |
|---|---|
| Module | `SynapsisTool.WorkspaceRead` |
| Permission | `:read` |
| Side Effects | none |
| Description | Read a workspace resource by path. Returns content and metadata. Supports text, markdown, yaml, json, and binary content. |

Parameters:
- `path` (required, string) — workspace path, e.g. "/projects/myapp/plans/auth-redesign.md"

Notes: Also accepts `id` as path for direct ID-based lookup. Returns content inline for text, base64 for binary.

### WS-12: workspace_write

| Field | Value |
|---|---|
| Module | `SynapsisTool.WorkspaceWrite` |
| Permission | `:write` |
| Side Effects | `[:workspace_changed]` |
| Description | Create or update a workspace document. Auto-creates parent directories. Lifecycle and visibility default based on path prefix. |

Parameters:
- `path` (required, string) — workspace path
- `content` (required, string) — file content
- `content_format` (optional, enum: "markdown" | "yaml" | "json" | "text", default: inferred from extension)
- `metadata` (optional, object) — arbitrary metadata (title, tags, etc.)

Notes: Rejects writes to domain-backed paths (skills, memory, todos). Those must be created through their domain contexts. Broadcasts `:workspace_changed` side effect.

### WS-13: workspace_list

| Field | Value |
|---|---|
| Module | `SynapsisTool.WorkspaceList` |
| Permission | `:read` |
| Side Effects | none |
| Description | List workspace directory contents. Returns resource names, kinds, and metadata. Supports depth, sorting, and filtering. |

Parameters:
- `path` (required, string) — directory path to list
- `depth` (optional, integer, default: 1) — max depth for recursive listing
- `sort` (optional, enum: "name" | "recent" | "kind", default: "name")
- `kind` (optional, string) — filter by resource kind

Notes: Merges results from domain-backed and document-backed resources transparently. `sort: "recent"` with `depth: 0` at a project root provides a "recent items" view.

### WS-14: workspace_search

| Field | Value |
|---|---|
| Module | `SynapsisTool.WorkspaceSearch` |
| Permission | `:read` |
| Side Effects | none |
| Description | Full-text search across workspace resources. Searches path, title, and content with weighted ranking. |

Parameters:
- `query` (required, string) — search query (natural language)
- `scope` (optional, enum: "global" | "project" | "session", default: "project")
- `project_id` (optional, string) — required when scope is "project" or "session"
- `kind` (optional, string) — filter by resource kind
- `limit` (optional, integer, default: 20)

Notes: Fans out across `workspace_documents` and projected domain records. Uses `websearch_to_tsquery` for natural language input.

### Tool Inventory Addition

| # | Tool | Name | Category | Permission | Side Effects | Enabled |
|---|---|---|---|---|---|---|
| 28 | WorkspaceRead | `workspace_read` | workspace | `:read` | — | yes |
| 29 | WorkspaceWrite | `workspace_write` | workspace | `:write` | `[:workspace_changed]` | yes |
| 30 | WorkspaceList | `workspace_list` | workspace | `:read` | — | yes |
| 31 | WorkspaceSearch | `workspace_search` | workspace | `:read` | — | yes |

Total Synapsis tool count: **31 tools** (27 from tools-system-prd + 4 workspace).

---

## 7. Handoff Integration

### WS-15: Handoffs Through Agent Messaging

**WS-15.1** — Handoffs are NOT a workspace tool. They are a message type (`:handoff`) in the existing agent message bus (agent-system-prd §AS-7).

**WS-15.2** — Handoff message envelope:

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
  },
  timestamp: ~U[2026-03-13 10:00:00Z]
}
```

**WS-15.3** — After delivery, the agent messaging layer persists handoff metadata as a `workspace_document` at `/projects/:id/handoffs/:ref.json` with `kind: :handoff`. This provides searchability and audit trail.

**WS-15.4** — The receiving agent uses `workspace_read` to access referenced artifacts by `id`.

---

## 8. Side Effect Integration

### WS-16: Workspace Side Effects

**WS-16.1** — New side effect type: `:workspace_changed`

**WS-16.2** — `workspace_write` and `workspace_delete` broadcast to PubSub topic `"workspace:{project_id}"`:

```elixir
{:workspace_changed, %{path: path, action: :created | :updated | :deleted, resource_id: id}}
```

**WS-16.3** — Subscribers:
- `SessionChannel` → UI notifications (workspace explorer refresh, todo updates)
- `SynapsisAgent.ContextBuilder` → invalidate cached project context when workspace changes
- `WorkspaceLive.Explorer` → LiveView update via `handle_info`

---

## 9. Permissions Model

### WS-17: Access Rules

**WS-17.1** — Current design assumes single-user (per design-v2.md). Permission checks are agent-scoped, not user-scoped.

**WS-17.2** — Agent access rules:
- Global Agent: read/write `/shared/**`, read/write any `/projects/:id/**` it is delegated to
- Project Agent: read/write own `/projects/:id/**`, read-only `/shared/**`
- Session Agent (General/Special): read/write `/projects/:id/sessions/<own-session>/**`, read project-shared content
- All agents: read access to resources with visibility ≥ `:project_shared` within their project scope

**WS-17.3** — Permission checks operate on path prefix matching. Implemented in `SynapsisWorkspace.Permissions`:

```elixir
defmodule SynapsisWorkspace.Permissions do
  @spec check(agent_id :: binary(), path :: String.t(), action :: :read | :write) ::
    :allowed | :denied
end
```

**WS-17.4** — Users have unrestricted read/write access to all workspace content (single-user tool). The `visibility` field and path-based checks are designed to support future multi-user scenarios without schema changes.

---

## 10. Web UI Integration

### WS-18: Views

**WS-18.1** — New LiveView: `WorkspaceLive.Explorer` — folder tree with file preview and inline editing. Mounts at `/projects/:project_id/workspace`.

**WS-18.2** — Dedicated views per resource type:

| View | Route | Source | Rendering |
|---|---|---|---|
| Workspace Explorer | `/projects/:id/workspace` | `workspace_list` tree | LiveView — tree + preview |
| Plans | `/projects/:id/workspace/plans` | `/projects/:id/plans/**` | LiveView — markdown + edit |
| Todos | `/projects/:id/workspace/todos` | `/projects/:id/todos/**` + `session_todos` | LiveView — checklist |
| Notes | `/projects/:id/workspace/notes` | `/projects/:id/notes/**` | LiveView — markdown editor |
| Handoffs | `/projects/:id/workspace/handoffs` | `/projects/:id/handoffs/**` | LiveView — sender/receiver/status |
| Attachments | `/projects/:id/workspace/attachments` | `/projects/:id/attachments/**` | LiveView — file list |

**WS-18.3** — Existing LiveViews (`SkillLive`, `MemoryLive`) continue to work against domain schemas directly. Workspace projection is additive — the explorer provides a unified browsing alternative, not a replacement.

**WS-18.4** — User edits go through `SynapsisWorkspace.write/3` with `updated_by: "user"`. Agents see user changes on next `workspace_read`. Optimistic concurrency with version checks on write (no real-time collaborative editing in v1).

**WS-18.5** — PubSub-driven updates: workspace changes broadcast to `"workspace:{project_id}"`, LiveView subscribes and updates explorer tree in real-time as agents write.

---

## 11. Module Layout

```
apps/synapsis_workspace/
├── lib/
│   ├── synapsis_workspace.ex                      # Public API facade
│   └── synapsis_workspace/
│       ├── application.ex                         # Supervision tree (GC)
│       ├── resource.ex                            # %Resource{} struct
│       ├── path_resolver.ex                       # Path parsing, validation, dispatch
│       ├── resources.ex                           # workspace_documents CRUD + versioning
│       ├── projection.ex                          # Domain schema → Resource mapping
│       ├── permissions.ex                         # Path-based access checks
│       ├── search.ex                              # tsvector queries + cross-schema fan-out
│       ├── gc.ex                                  # Periodic cleanup GenServer
│       ├── blob_store.ex                          # Behaviour
│       └── blob_store/
│           └── local.ex                           # Content-addressable local FS
│
├── test/
│   ├── test_helper.exs
│   ├── support/
│   │   ├── workspace_case.ex                      # Shared test helpers
│   │   └── blob_store_case.ex                     # Shared blob store tests
│   ├── synapsis_workspace/
│   │   ├── resource_test.exs
│   │   ├── path_resolver_test.exs
│   │   ├── resources_test.exs
│   │   ├── projection_test.exs
│   │   ├── permissions_test.exs
│   │   ├── search_test.exs
│   │   ├── gc_test.exs
│   │   └── blob_store/
│   │       └── local_test.exs
│   └── integration/
│       ├── workspace_api_test.exs
│       ├── projection_roundtrip_test.exs
│       ├── lifecycle_promotion_test.exs
│       ├── search_fanout_test.exs
│       └── gc_cleanup_test.exs
│
└── mix.exs
```

Schemas (`SynapsisData.WorkspaceDocument`, `SynapsisData.WorkspaceDocumentVersion`) live in `apps/synapsis_data/` per umbrella convention.

Tool modules (`SynapsisTool.WorkspaceRead`, etc.) live in `apps/synapsis_tool/` per tool system convention.

---

## 12. Implementation Phases

### Phase 1: Core Workspace

**Goal:** Agents can write and read workspace documents. Users can browse in web UI.

**Modules:** `Resource`, `PathResolver`, `Resources`, `BlobStore.Local`, `SynapsisWorkspace` (API)

**Migrations:** `workspace_documents`, `workspace_document_versions` tables with indexes and search vector.

**Tests:**

```
test/synapsis_workspace/resource_test.exs
├── describe "new/1"
│   ├── creates resource with valid fields
│   ├── validates required fields (path, kind)
│   └── defaults lifecycle from path prefix

test/synapsis_workspace/path_resolver_test.exs
├── describe "validate/1"
│   ├── accepts valid /shared/ paths
│   ├── accepts valid /projects/:id/ paths
│   ├── accepts valid session paths
│   ├── rejects empty segments
│   ├── rejects .. traversal
│   ├── rejects paths exceeding max depth
│   └── rejects paths exceeding max length
├── describe "scope/1"
│   ├── returns :global for /shared/**
│   ├── returns :project for /projects/:id/**
│   └── returns :session for session paths
├── describe "resolve/1"
│   ├── resolves skill paths to {:skill, id}
│   ├── resolves memory paths to {:memory, id}
│   ├── resolves document paths to {:document, id}
│   └── returns :not_found for nonexistent paths
├── describe "kind/1"
│   ├── infers :document for notes/plans/ideas
│   ├── infers :attachment for attachments/**
│   ├── infers :handoff for handoffs/**
│   └── infers :session_scratch for session scratch/**

test/synapsis_workspace/resources_test.exs
├── describe "create/2"
│   ├── creates document with inline content
│   ├── creates document with blob ref for large content
│   ├── auto-sets lifecycle from path
│   ├── auto-sets visibility from path
│   ├── increments version on update
│   ├── creates version entry for non-scratch lifecycle
│   ├── skips version entry for scratch lifecycle
│   ├── rejects duplicate path
│   └── validates content format
├── describe "get_by_path/1"
│   ├── returns document by path
│   ├── returns nil for nonexistent
│   └── excludes soft-deleted documents
├── describe "update/3"
│   ├── updates content and version
│   ├── checks optimistic concurrency (version match)
│   ├── rejects stale version
│   └── creates version history entry per lifecycle rules
├── describe "delete/1"
│   ├── soft-deletes document
│   └── frees path for reuse
├── describe "list_by_prefix/2"
│   ├── returns children at depth 1
│   ├── returns recursive children with depth option
│   ├── filters by kind
│   └── sorts by name, recent, kind

test/synapsis_workspace/blob_store/local_test.exs
├── describe "put/1"
│   ├── stores content and returns SHA-256 ref
│   ├── deduplicates identical content
│   └── creates directory structure
├── describe "get/1"
│   ├── retrieves content by ref
│   └── returns error for nonexistent ref
├── describe "delete/1"
│   ├── removes blob file
│   └── handles nonexistent ref gracefully
├── describe "exists?/1"
│   ├── returns true for stored blob
│   └── returns false for nonexistent
```

### Phase 2: Search + Tools

**Goal:** Full-text search. Agent tools registered and functional.

**Modules:** `Search`, workspace tools in `synapsis_tool`

**Tests:**

```
test/synapsis_workspace/search_test.exs
├── describe "query/2"
│   ├── finds documents by content match
│   ├── finds documents by path match (weighted higher)
│   ├── finds documents by metadata title match
│   ├── filters by scope
│   ├── filters by kind
│   ├── limits results
│   ├── returns empty for no matches
│   └── ranks path matches above content matches

test/integration/workspace_api_test.exs
├── describe "read/1"
│   ├── reads workspace document by path
│   ├── returns :not_found for nonexistent
│   └── returns domain-projected resource (skill by path)
├── describe "write/3"
│   ├── creates new document
│   ├── updates existing document
│   ├── rejects write to domain-backed path
│   ├── broadcasts :workspace_changed event
│   └── auto-creates parent directories implicitly
├── describe "list/2"
│   ├── lists mixed domain + document resources
│   ├── sorts by recent
│   └── filters by kind
├── describe "search/2"
│   ├── searches across workspace documents
│   ├── searches across projected domain records
│   └── merges and deduplicates results
```

### Phase 3: Projection + Lifecycle

**Goal:** Domain schemas projected as workspace resources. Lifecycle management. GC.

**Modules:** `Projection`, `GC`, `Permissions`

**Tests:**

```
test/synapsis_workspace/projection_test.exs
├── describe "project_skill/1"
│   ├── maps skill to Resource with computed path
│   ├── sets kind to :skill
│   ├── includes SKILL.md content
│   └── handles global vs project scope
├── describe "project_memory/1"
│   ├── maps memory entry to Resource
│   ├── computes path from scope and category
│   └── includes content as markdown
├── describe "project_todo/1"
│   ├── maps session todo to Resource
│   └── computes path from session

test/synapsis_workspace/gc_test.exs
├── describe "cleanup_session_scratch/0"
│   ├── deletes scratch for completed sessions past retention
│   ├── preserves scratch for active sessions
│   ├── preserves promoted documents regardless of session
│   └── respects retention configuration
├── describe "prune_draft_versions/0"
│   ├── keeps last N versions for draft documents
│   ├── preserves all versions for shared/published
│   └── skips scratch documents (no versions to prune)
├── describe "cleanup_orphaned_blobs/0"
│   ├── deletes blobs with no referencing document
│   └── preserves blobs with active references

test/synapsis_workspace/permissions_test.exs
├── describe "check/3"
│   ├── allows project agent to write own project
│   ├── denies project agent writing other project
│   ├── allows session agent to write own session path
│   ├── allows global agent to write any project
│   └── allows read for project_shared visibility

test/integration/projection_roundtrip_test.exs
├── create skill via domain context → read via workspace path
├── create memory entry → read via workspace path
├── list project workspace → includes both domain and documents
└── search finds both domain records and workspace documents

test/integration/lifecycle_promotion_test.exs
├── write to session path → lifecycle is scratch
├── write to project path → lifecycle is shared
├── session scratch excluded from search by default
├── promote session scratch to project → lifecycle changes
└── GC deletes expired session scratch

test/integration/search_fanout_test.exs
├── search matches workspace document content
├── search matches skill name/description
├── search matches memory entry content
├── results deduplicated by id
└── scope filtering works across backing stores

test/integration/gc_cleanup_test.exs
├── full GC cycle: scratch + versions + blobs
├── concurrent GC with writes (no race conditions)
└── configurable retention periods respected
```

### Phase 4: Web UI

**Goal:** Workspace explorer LiveView. User can browse and edit.

**Modules:** `WorkspaceLive.Explorer` and related LiveViews in `synapsis_web`

**Tests:**

```
# LiveView tests in apps/synapsis_web/test/
test/synapsis_web/live/workspace_live/explorer_test.exs
├── renders folder tree
├── navigates into subdirectories
├── displays document preview
├── inline edit and save
├── reflects real-time workspace changes via PubSub
├── promote action on session scratch
└── delete action with confirmation
```

---

## 13. Acceptance Criteria

### Core Workspace (Phase 1-2)

- [ ] Agents can write documents to workspace via `workspace_write` tool
- [ ] Agents can read documents via `workspace_read` tool
- [ ] Agents can list directory contents via `workspace_list` tool
- [ ] Agents can search workspace via `workspace_search` tool
- [ ] Full-text search returns ranked results across workspace documents
- [ ] Blob store handles large content and binary attachments
- [ ] Version history created per lifecycle rules
- [ ] Path validation rejects malformed paths
- [ ] PubSub broadcasts on workspace changes
- [ ] >= 90% test coverage, Dialyzer clean

### Projection + Lifecycle (Phase 3)

- [ ] Skills, memory entries, and session todos projected as workspace resources
- [ ] `workspace_list` returns mixed domain + document results
- [ ] `workspace_search` fans out across all backing stores
- [ ] Lifecycle auto-promotion based on path prefix
- [ ] GC cleans up expired session scratch
- [ ] GC prunes draft version history
- [ ] GC removes orphaned blobs
- [ ] Permission checks enforce agent scope boundaries

### Web UI (Phase 4)

- [ ] Workspace explorer renders folder tree with preview
- [ ] User can edit workspace documents inline
- [ ] Real-time updates via PubSub when agents write
- [ ] Promote action moves session scratch to project level
- [ ] Existing SkillLive/MemoryLive unaffected by workspace addition

---

## 14. Synapsis Integration Points

**synapsis_data provides:** `WorkspaceDocument` and `WorkspaceDocumentVersion` Ecto schemas. Migrations. Existing domain schemas (`Skill`, `MemoryEntry`, `SessionTodo`, `Project`, `Session`) for projection.

**synapsis_core provides:** Domain contexts (`Synapsis.Skills`, `Synapsis.Sessions`, `Synapsis.Projects`, `Synapsis.Memory`) consumed by `Projection` module.

**synapsis_tool provides:** Host application for the 4 workspace tool modules (`SynapsisTool.WorkspaceRead`, etc.). Tools follow the `Synapsis.Tool` behaviour contract.

**synapsis_agent consumes:** Workspace tools via `ToolRegistry`. `ContextBuilder` subscribes to `"workspace:{project_id}"` for cache invalidation. Handoff messages reference workspace paths.

**synapsis_server consumes:** PubSub events from workspace for `SessionChannel` UI notifications.

**synapsis_web consumes:** `SynapsisWorkspace` API for `WorkspaceLive.Explorer` and related views. Subscribes to workspace PubSub for real-time updates.

---

## 15. Resolved Decisions

1. **Workspace is a projection layer**, not a replacement for domain schemas. Structured domain records (skills, todos, memory) stay in their Ecto schemas. Unstructured content (notes, plans, ideas, scratch) lives in `workspace_documents`. The workspace API presents a uniform view over both.

2. **New umbrella app `synapsis_workspace`**, depends on `synapsis_data` + `synapsis_core`. Owns path resolution, projection, versioning, search, and blob storage.

3. **`id` is identity, path is mutable.** Every resource has a stable ULID. Paths are indexed and can change via rename/move. Cross-references use `id` for resolution.

4. **Scope derived from path, only visibility stored.** No redundant `scope` field. Path prefix determines scope. `visibility` is the only explicit access-control field.

5. **4 workspace tools.** `workspace_read`, `workspace_write`, `workspace_list`, `workspace_search`. No separate stat/recent/publish/handoff tools — covered by existing tools with options.

6. **Handoffs through agent messaging.** Handoffs are `:handoff` type messages in the existing agent message bus (agent-system-prd §AS-7), referencing workspace paths. Handoff metadata persisted as workspace documents for audit.

7. **Version history is lifecycle-gated.** Scratch: none. Draft: last 5. Shared/published: full. Prevents unbounded history growth from high-frequency agent writes to scratch.

8. **Content-addressable local FS for blobs.** Inline `content_body` for small documents (<64KB). SHA-256 addressed local store for large/binary content. Adapter boundary for future S3.

9. **Session scratch GC at 7 days post-completion.** Configurable. Promoted documents excluded.

10. **PostgreSQL tsvector from day one.** Weighted search across path, title, and content. pgvector for semantic search in Phase 3.

11. **No FUSE, no kernel filesystem.** The workspace needs path-based addressing, directory browsing, and file-like content access — not POSIX semantics.

12. **Domain-backed paths are read-only through workspace.** Writing to paths matching skill/memory/todo patterns is rejected. Domain records are created and modified through their own contexts. Workspace only projects them for unified browsing.

13. **Directories are implicit.** No directory records in the database. A directory "exists" when any child document exists under that path prefix. `workspace_list` synthesizes directory entries from path prefixes.

---

## 16. Open Questions

None. All architectural questions resolved during design review.
