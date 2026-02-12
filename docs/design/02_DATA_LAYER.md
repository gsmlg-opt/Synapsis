# 02 — Data Layer

## Storage Strategy

PostgreSQL via Ecto. Single database, projects distinguished by `project_id` column. Standard Phoenix conventions — `mix ecto.gen.migration`, `Repo.all/insert/update`.

```
PostgreSQL: synapsis_dev / synapsis_prod
├── projects    (project path registry)
├── sessions    (project scoped)
└── messages    (session scoped, append-only)
```

File-based storage (not in Postgres):
```
~/.config/synapsis/
├── config.json          # user-level preferences
└── auth.json            # provider API keys
```

## Schema

### projects

```sql
CREATE TABLE projects (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  path TEXT NOT NULL UNIQUE,         -- absolute path to project root
  slug TEXT NOT NULL UNIQUE,         -- URL-safe identifier
  config JSONB DEFAULT '{}',         -- project-level config cache
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);
```

### sessions

```sql
CREATE TABLE sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  title TEXT,
  agent TEXT NOT NULL DEFAULT 'build',
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'idle',
  config JSONB DEFAULT '{}',
  inserted_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX idx_sessions_project ON sessions(project_id, updated_at DESC);
```

### messages

```sql
CREATE TABLE messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  role TEXT NOT NULL,                -- user | assistant | system
  parts JSONB NOT NULL DEFAULT '[]', -- array of part objects
  token_count INTEGER DEFAULT 0,
  inserted_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX idx_messages_session ON messages(session_id, inserted_at);
```

## Why PostgreSQL

- **Development velocity**: `mix phx.gen.schema`, migrations, seeds — all Phoenix tooling works out of the box
- **JSONB**: first-class JSON querying for parts and config — search within message content, filter by tool type
- **Concurrency**: no WAL tuning, no single-writer limitations
- **Ecto ecosystem**: LiveDashboard stats, Oban (if needed later), all Ecto libraries assume Postgres
- **AI tooling**: every code generation model knows Ecto + Postgres patterns cold

Trade-off: requires a running PostgreSQL instance. Acceptable — devs already have Postgres or can `docker compose up`.

## Ecto Schemas

```elixir
defmodule Synapsis.Project do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "projects" do
    field :path, :string
    field :slug, :string
    field :config, :map, default: %{}
    has_many :sessions, Synapsis.Session
    timestamps()
  end
end

defmodule Synapsis.Session do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "sessions" do
    field :title, :string
    field :agent, Ecto.Enum, values: [:build, :plan, :custom]
    field :provider, Ecto.Enum, values: [:anthropic, :openai, :google, :copilot, :local]
    field :model, :string
    field :status, Ecto.Enum, values: [:idle, :streaming, :tool_executing, :error]
    field :config, :map, default: %{}
    belongs_to :project, Synapsis.Project, type: :binary_id
    has_many :messages, Synapsis.Message
    timestamps()
  end
end

defmodule Synapsis.Message do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "messages" do
    field :role, Ecto.Enum, values: [:user, :assistant, :system]
    field :parts, {:array, Synapsis.Part}, default: []  # custom Ecto type over JSONB
    field :token_count, :integer, default: 0
    belongs_to :session, Synapsis.Session, type: :binary_id
    timestamps(updated_at: false)
  end
end
```

## Custom Ecto Type: Part

Parts stored as JSONB array, deserialized into tagged structs:

```elixir
defmodule Synapsis.Part do
  use Ecto.Type

  def type, do: :map  # JSONB in Postgres

  def cast(parts) when is_list(parts), do: {:ok, Enum.map(parts, &cast_part/1)}
  def load(parts) when is_list(parts), do: {:ok, Enum.map(parts, &load_part/1)}
  def dump(parts) when is_list(parts), do: {:ok, Enum.map(parts, &dump_part/1)}

  defp load_part(%{"type" => "text"} = data), do: struct(Synapsis.TextPart, atomize(data))
  defp load_part(%{"type" => "tool_use"} = data), do: struct(Synapsis.ToolUsePart, atomize(data))
  # ... etc
end
```

## Querying Patterns

JSONB enables queries OpenCode's JSON files can't do:

```elixir
# Search messages containing a specific tool use
from m in Message,
  where: fragment("? @> ?", m.parts, ^[%{type: "tool_use", tool: "file_edit"}])

# Sessions with recent activity
from s in Session,
  where: s.project_id == ^project_id,
  order_by: [desc: s.updated_at],
  limit: 20

# Full-text search across message content (future)
# Can add tsvector column + GIN index when needed
```

## ETS for Runtime State

PostgreSQL handles persistence. ETS handles hot runtime data:

- `Synapsis.Provider.Registry` — provider configs, model lists (read-heavy)
- `Synapsis.Tool.Registry` — tool definitions including MCP-discovered tools
- `Synapsis.Config.Cache` — resolved config per project (invalidated on file change)

These are **caches and registries**, not source of truth. All can be rebuilt from config files + DB on restart.
