# Tool Behaviour Contract — Extended

## Status

**Extends**: `Synapsis.Tool` (`apps/synapsis_core/lib/synapsis/tool.ex`)

## Existing Callbacks (unchanged)

```elixir
@callback name() :: String.t()
@callback description() :: String.t()
@callback parameters() :: map()
@callback execute(input :: map(), context :: context()) :: {:ok, String.t()} | {:error, term()}
@callback side_effects() :: [atom()]  # optional, default []
```

## New Optional Callbacks

### `permission_level/0`

Returns the intrinsic permission level of the tool. Replaces the hard-coded lists in `Synapsis.Tool.Permissions`.

```elixir
@type permission_level :: :none | :read | :write | :execute | :destructive

@callback permission_level() :: permission_level()
# Default: :read
```

**Semantics**:
- `:none` — no side effects, never requires approval (e.g., internal plumbing)
- `:read` — reads data without modification (e.g., `file_read`, `grep`, `glob`)
- `:write` — modifies files or state (e.g., `file_write`, `file_edit`, `fetch`)
- `:execute` — runs arbitrary code or shell commands (e.g., `bash`)
- `:destructive` — irreversible operations (e.g., `file_delete`)

### `category/0`

Returns the functional category for filtering and grouping in the registry.

```elixir
@type category ::
        :filesystem
        | :search
        | :execution
        | :web
        | :planning
        | :orchestration
        | :interaction
        | :session
        | :notebook
        | :computer
        | :swarm

@callback category() :: category()
# Default: :filesystem
```

**Category definitions**:
| Category | Description | Example tools |
|---|---|---|
| `:filesystem` | File CRUD operations | `file_read`, `file_write`, `file_edit`, `file_delete`, `file_move`, `list_dir` |
| `:search` | Code and file search | `grep`, `glob` |
| `:execution` | Shell and process execution | `bash` |
| `:web` | HTTP and network operations | `fetch` |
| `:planning` | Agent planning tools | (future: `todo_write`, `plan`) |
| `:orchestration` | Multi-agent coordination | (future: `sub_agent`, `delegate`) |
| `:interaction` | User interaction | (future: `ask_user`, `notify`) |
| `:session` | Session management | (future: `fork_session`, `switch_model`) |
| `:notebook` | Notebook operations | (future: `notebook_edit`) |
| `:computer` | Computer use / UI automation | (future: `screenshot`, `click`) |
| `:swarm` | Multi-agent swarm tools | (future: `spawn_agent`, `collect`) |

### `version/0`

Returns the tool's semantic version string. Used for MCP compatibility and tool evolution tracking.

```elixir
@callback version() :: String.t()
# Default: "1.0.0"
```

### `enabled?/0`

Returns whether the tool is available for use. Allows tools to self-disable based on runtime conditions (e.g., missing binary, unsupported platform).

```elixir
@callback enabled?() :: boolean()
# Default: true
```

**Example**: A `grep` tool checking for `rg` availability:

```elixir
@impl true
def enabled? do
  case System.find_executable("rg") do
    nil -> false
    _path -> true
  end
end
```

## Extended Context Type

The `context` map passed to `execute/2` is extended with additional keys:

```elixir
@type context :: %{
        optional(:session_id) => String.t(),
        optional(:project_path) => String.t(),
        optional(:working_dir) => String.t(),
        optional(:permissions) => map(),
        optional(:session_pid) => pid(),
        optional(:agent_mode) => :build | :plan,
        optional(:parent_agent) => pid() | nil,
        optional(atom()) => term()
      }
```

**New keys**:
- `session_pid` — PID of the `Synapsis.Session.Worker` that initiated the tool call. Used for streaming partial results back to the session.
- `agent_mode` — current agent mode (`:build` or `:plan`). Tools may vary behavior based on mode (e.g., plan mode tools produce plans instead of executing changes).
- `parent_agent` — PID of the parent agent when running as a sub-agent in an orchestration context. `nil` for top-level agents.

## Updated `use Synapsis.Tool` Macro

The `__using__/1` macro provides defaults for all optional callbacks:

```elixir
defmacro __using__(_opts) do
  quote do
    @behaviour Synapsis.Tool

    @impl Synapsis.Tool
    def side_effects, do: []

    @impl Synapsis.Tool
    def permission_level, do: :read

    @impl Synapsis.Tool
    def category, do: :filesystem

    @impl Synapsis.Tool
    def version, do: "1.0.0"

    @impl Synapsis.Tool
    def enabled?, do: true

    defoverridable side_effects: 0,
                   permission_level: 0,
                   category: 0,
                   version: 0,
                   enabled?: 0
  end
end
```

## Complete Behaviour Definition

```elixir
defmodule Synapsis.Tool do
  @type permission_level :: :none | :read | :write | :execute | :destructive

  @type category ::
          :filesystem | :search | :execution | :web | :planning
          | :orchestration | :interaction | :session | :notebook
          | :computer | :swarm

  @type context :: %{
          optional(:session_id) => String.t(),
          optional(:project_path) => String.t(),
          optional(:working_dir) => String.t(),
          optional(:permissions) => map(),
          optional(:session_pid) => pid(),
          optional(:agent_mode) => :build | :plan,
          optional(:parent_agent) => pid() | nil,
          optional(atom()) => term()
        }

  # Required callbacks
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(input :: map(), context :: context()) ::
              {:ok, String.t()} | {:error, term()}

  # Optional callbacks (defaults provided by `use Synapsis.Tool`)
  @callback side_effects() :: [atom()]
  @callback permission_level() :: permission_level()
  @callback category() :: category()
  @callback version() :: String.t()
  @callback enabled?() :: boolean()

  @optional_callbacks [
    side_effects: 0,
    permission_level: 0,
    category: 0,
    version: 0,
    enabled?: 0
  ]
end
```

## Migration Notes

### Backward Compatibility

- All new callbacks are optional with sensible defaults.
- Existing tools that `use Synapsis.Tool` continue to work unchanged.
- `Synapsis.Tool.Permissions.level/1` (the hard-coded tool-name-to-risk-level mapping) is superseded by `permission_level/0` on each tool module. The fallback path in `Permissions.level/1` should delegate to the module callback when available.

### Expected Tool Overrides

| Tool | `permission_level` | `category` |
|---|---|---|
| `FileRead` | `:read` (default) | `:filesystem` (default) |
| `FileWrite` | `:write` | `:filesystem` |
| `FileEdit` | `:write` | `:filesystem` |
| `FileDelete` | `:destructive` | `:filesystem` |
| `FileMove` | `:write` | `:filesystem` |
| `ListDir` | `:read` | `:filesystem` |
| `Grep` | `:read` | `:search` |
| `Glob` | `:read` | `:search` |
| `Bash` | `:execute` | `:execution` |
| `Fetch` | `:write` | `:web` |
| `Diagnostics` | `:read` | `:search` |
