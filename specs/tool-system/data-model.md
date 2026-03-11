# Data Model: Tool System

**Feature**: tool-system | **Date**: 2026-03-10 | **Phase**: 1 (Data Model)

## Overview

Three new PostgreSQL tables to support tool execution persistence, per-session permission configuration, and session-scoped todo tracking. All tables follow existing conventions: UUID primary keys, `utc_datetime_usec` timestamps, JSONB for flexible structured data.

All schemas live in `apps/synapsis_data/`. Repo operations are encapsulated within `synapsis_data` — no direct Repo calls from other apps.

---

## New Entities

### 1. `tool_calls`

Persists every tool invocation for audit and replay.

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| `id` | `uuid` | PK | Generated via `Ecto.UUID` |
| `session_id` | `uuid` | FK → `sessions`, NOT NULL, indexed | Parent session |
| `message_id` | `uuid` | FK → `messages`, nullable | May not exist for system-initiated calls |
| `tool_name` | `varchar(255)` | NOT NULL, indexed | e.g., `"file_read"`, `"bash_exec"` |
| `input` | `jsonb` | NOT NULL | Tool input parameters |
| `output` | `jsonb` | nullable | Tool result (`null` while pending) |
| `status` | `varchar(50)` | NOT NULL, default `"pending"` | Enum: `pending`, `approved`, `denied`, `completed`, `error` |
| `duration_ms` | `integer` | nullable | Execution time in milliseconds |
| `error_message` | `text` | nullable | Error details if `status = error` |
| `inserted_at` | `utc_datetime_usec` | NOT NULL | |
| `updated_at` | `utc_datetime_usec` | NOT NULL | |

**Indexes:**

- `tool_calls_session_id_index` on `session_id`
- `tool_calls_session_id_tool_name_index` on `(session_id, tool_name)`
- `tool_calls_session_id_status_index` on `(session_id, status)`

**Ecto Schema:**

```elixir
defmodule Synapsis.ToolCall do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tool_calls" do
    belongs_to :session, Synapsis.Session
    belongs_to :message, Synapsis.Message

    field :tool_name, :string
    field :input, :map
    field :output, :map
    field :status, Ecto.Enum, values: [:pending, :approved, :denied, :completed, :error], default: :pending
    field :duration_ms, :integer
    field :error_message, :string

    timestamps(type: :utc_datetime_usec)
  end
end
```

---

### 2. `session_permissions`

Per-session permission configuration. One row per session.

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| `id` | `uuid` | PK | Generated via `Ecto.UUID` |
| `session_id` | `uuid` | FK → `sessions`, NOT NULL, unique | One config per session |
| `mode` | `varchar(50)` | NOT NULL, default `"interactive"` | Enum: `interactive`, `autonomous` |
| `allow_write` | `boolean` | NOT NULL, default `true` | Allow file write operations |
| `allow_execute` | `boolean` | NOT NULL, default `true` | Allow shell execution |
| `allow_destructive` | `varchar(50)` | NOT NULL, default `"ask"` | Enum: `allow`, `deny`, `ask` |
| `tool_overrides` | `jsonb` | NOT NULL, default `{}` | Map of tool_pattern → permission |
| `inserted_at` | `utc_datetime_usec` | NOT NULL | |
| `updated_at` | `utc_datetime_usec` | NOT NULL | |

**Indexes:**

- `session_permissions_session_id_index` on `session_id` (unique)

**Ecto Schema:**

```elixir
defmodule Synapsis.SessionPermission do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "session_permissions" do
    belongs_to :session, Synapsis.Session

    field :mode, Ecto.Enum, values: [:interactive, :autonomous], default: :interactive
    field :allow_write, :boolean, default: true
    field :allow_execute, :boolean, default: true
    field :allow_destructive, Ecto.Enum, values: [:allow, :deny, :ask], default: :ask
    field :tool_overrides, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end
end
```

---

### 3. `session_todos`

Session-scoped todo/checklist items managed by the agent.

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| `id` | `uuid` | PK | Generated via `Ecto.UUID` |
| `session_id` | `uuid` | FK → `sessions`, NOT NULL, indexed | Parent session |
| `todo_id` | `varchar(255)` | NOT NULL | Stable identifier from agent |
| `content` | `text` | NOT NULL | Task description |
| `status` | `varchar(50)` | NOT NULL, default `"pending"` | Enum: `pending`, `in_progress`, `completed` |
| `sort_order` | `integer` | NOT NULL, default `0` | Display ordering |
| `inserted_at` | `utc_datetime_usec` | NOT NULL | |
| `updated_at` | `utc_datetime_usec` | NOT NULL | |

**Indexes:**

- `session_todos_session_id_index` on `session_id`
- `session_todos_session_id_todo_id_index` on `(session_id, todo_id)` (unique)

**Ecto Schema:**

```elixir
defmodule Synapsis.SessionTodo do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "session_todos" do
    belongs_to :session, Synapsis.Session

    field :todo_id, :string
    field :content, :string
    field :status, Ecto.Enum, values: [:pending, :in_progress, :completed], default: :pending
    field :sort_order, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end
end
```

---

## Relationships

```
sessions 1──* tool_calls       (session_id FK)
sessions 1──1 session_permissions (session_id FK, unique)
sessions 1──* session_todos    (session_id FK)
messages 1──* tool_calls       (message_id FK, nullable)
```

**Entity-Relationship Diagram:**

```
┌──────────┐       ┌──────────────┐       ┌──────────┐
│ sessions │──1:*──│  tool_calls  │──*:1──│ messages │
│          │       └──────────────┘       │(nullable)│
│          │                              └──────────┘
│          │──1:1──┌────────────────────┐
│          │       │session_permissions │
│          │       └────────────────────┘
│          │
│          │──1:*──┌───────────────┐
│          │       │ session_todos │
└──────────┘       └───────────────┘
```

---

## State Transitions

### `tool_calls.status`

```
         ┌─────────► approved ──┬──► completed
         │                      └──► error
pending ─┼─────────► denied
         │
         ├─────────► completed  (auto-approved, execution succeeded)
         └─────────► error      (auto-approved, execution failed)
```

- `pending → approved` — user approves permission request
- `pending → denied` — user denies permission request
- `pending → completed` — auto-approved tool, execution succeeded
- `pending → error` — auto-approved tool, execution failed
- `approved → completed` — execution succeeded after user approval
- `approved → error` — execution failed after user approval

### `session_todos.status`

```
pending ──► in_progress ──► completed
   │                            ▲
   └────────────────────────────┘  (skip directly)
```

- `pending → in_progress` — agent starts work on the todo
- `in_progress → completed` — agent finishes work
- `pending → completed` — skipped directly to done
- Any status can be overwritten via `todo_write` (full replacement semantics)

---

## Migration Outline

Three migrations in `apps/synapsis_data/priv/repo/migrations/`:

### Migration 1: `create_tool_calls`

```elixir
create table(:tool_calls, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
  add :message_id, references(:messages, type: :binary_id, on_delete: :nilify_all)
  add :tool_name, :string, size: 255, null: false
  add :input, :map, null: false
  add :output, :map
  add :status, :string, size: 50, null: false, default: "pending"
  add :duration_ms, :integer
  add :error_message, :text

  timestamps(type: :utc_datetime_usec)
end

create index(:tool_calls, [:session_id])
create index(:tool_calls, [:session_id, :tool_name])
create index(:tool_calls, [:session_id, :status])
```

### Migration 2: `create_session_permissions`

```elixir
create table(:session_permissions, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
  add :mode, :string, size: 50, null: false, default: "interactive"
  add :allow_write, :boolean, null: false, default: true
  add :allow_execute, :boolean, null: false, default: true
  add :allow_destructive, :string, size: 50, null: false, default: "ask"
  add :tool_overrides, :map, null: false, default: %{}

  timestamps(type: :utc_datetime_usec)
end

create unique_index(:session_permissions, [:session_id])
```

### Migration 3: `create_session_todos`

```elixir
create table(:session_todos, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
  add :todo_id, :string, size: 255, null: false
  add :content, :text, null: false
  add :status, :string, size: 50, null: false, default: "pending"
  add :sort_order, :integer, null: false, default: 0

  timestamps(type: :utc_datetime_usec)
end

create index(:session_todos, [:session_id])
create unique_index(:session_todos, [:session_id, :todo_id])
```

---

## On-Delete Behavior

| Parent | Child | Strategy |
|--------|-------|----------|
| `sessions` | `tool_calls` | `delete_all` — cascade delete when session is removed |
| `sessions` | `session_permissions` | `delete_all` — cascade delete when session is removed |
| `sessions` | `session_todos` | `delete_all` — cascade delete when session is removed |
| `messages` | `tool_calls` | `nilify_all` — set `message_id` to null if message is deleted |

---

## Existing Entities (Unchanged)

No changes to existing schemas:

- `Synapsis.Project`
- `Synapsis.Session`
- `Synapsis.Message`
- `Synapsis.Provider`
- `Synapsis.Skill`
- `Synapsis.MCPServer`
- `Synapsis.LSPServer`

The `Synapsis.Session` schema will gain `has_many`/`has_one` associations to the new entities, but its database table is not modified.
