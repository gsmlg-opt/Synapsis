# Registry API Contract — Extensions

## Status

**Module**: `Synapsis.Tool.Registry` (`apps/synapsis_core/lib/synapsis/tool/registry.ex`)

## Types

```elixir
@type tool_name :: String.t()

@type registration ::
        {:module, module(), keyword()}
        | {:process, pid(), keyword()}

@type tool_info :: %{
        name: tool_name(),
        module: module() | nil,
        process: pid() | nil,
        description: String.t(),
        parameters: map(),
        timeout: non_neg_integer() | nil,
        category: Synapsis.Tool.category(),
        permission_level: Synapsis.Tool.permission_level(),
        version: String.t(),
        deferred: boolean(),
        loaded: boolean()
      }

@type tool_definition :: %{
        name: tool_name(),
        description: String.t(),
        parameters: map()
      }

@type list_opts :: [
        agent_mode: :build | :plan,
        include_deferred: boolean(),
        categories: [Synapsis.Tool.category()],
        session_id: String.t()
      ]
```

## Existing API (unchanged signatures)

### `register_module/3`

Registers a module-based tool in the ETS table.

```elixir
@spec register_module(tool_name(), module(), keyword()) :: :ok
def register_module(name, module, opts \\ [])
```

### `register_process/3`

Registers a process-based (plugin) tool.

```elixir
@spec register_process(tool_name(), pid(), keyword()) :: :ok
def register_process(name, pid, opts \\ [])
```

### `unregister/1`

Removes a tool from the registry.

```elixir
@spec unregister(tool_name()) :: :ok
def unregister(name)
```

### `lookup/1`

Returns the raw dispatch tuple for a tool.

```elixir
@spec lookup(tool_name()) :: {:ok, registration()} | {:error, :not_found}
def lookup(name)
```

### `list/0`

Returns all registered tools as info maps.

```elixir
@spec list() :: [tool_info()]
def list()
```

### `list_for_llm/0`

Returns all tools formatted for LLM tool definitions (name, description, parameters only).

```elixir
@spec list_for_llm() :: [tool_definition()]
def list_for_llm()
```

## New API

### `list_for_llm/1` (with filtering options)

Returns tools formatted for LLM consumption, filtered by the provided options.

```elixir
@spec list_for_llm(list_opts()) :: [tool_definition()]
def list_for_llm(opts)
```

**Options**:

- `agent_mode` — filters tools based on their `permission_level/0` relative to the agent mode:
  - `:plan` — only tools with `permission_level` of `:none` or `:read`. Plan mode agents cannot modify state.
  - `:build` — all tools (no permission-level filtering).
- `include_deferred` — when `false` (default), excludes tools registered with `deferred: true` that have not been activated via `mark_loaded/1`. When `true`, includes all tools regardless of deferred status.
- `categories` — when provided, only tools whose `category/0` is in the list are returned. When omitted, all categories are included.
- `session_id` — when provided, applies per-session tool availability rules. Tools can be enabled/disabled per session via session configuration.

**Filtering is applied in order**: agent_mode -> categories -> deferred -> session_id.

**Example**:

```elixir
# Plan mode agent, filesystem and search tools only
Registry.list_for_llm(agent_mode: :plan, categories: [:filesystem, :search])

# Build mode, include deferred tools that have been loaded
Registry.list_for_llm(agent_mode: :build, include_deferred: true)
```

### `list_by_category/1`

Returns all tools belonging to a specific category.

```elixir
@spec list_by_category(Synapsis.Tool.category()) :: [tool_info()]
def list_by_category(category)
```

**Implementation**: Scans the ETS table, calling `module.category()` for each module-based entry. Process-based entries use the `:category` key from their opts.

### `mark_loaded/1`

Activates a previously deferred tool, making it visible to `list_for_llm/1` calls that do not explicitly include deferred tools.

```elixir
@spec mark_loaded(tool_name()) :: :ok | {:error, :not_found}
def mark_loaded(name)
```

**Behavior**:
- Looks up the tool in ETS.
- Sets the `:loaded` flag to `true` in the tool's opts.
- Returns `:ok` on success, `{:error, :not_found}` if the tool does not exist.
- A tool that was not registered as deferred is already considered loaded; calling `mark_loaded/1` on it is a no-op returning `:ok`.

## Extended `register_module/3` Options

The `opts` keyword list now supports these additional keys:

```elixir
opts = [
  # Existing
  timeout: 30_000,
  description: "Override description",
  parameters: %{...},

  # New
  deferred: false,        # When true, tool is registered but hidden from list_for_llm/0
  category: :filesystem,  # Override module's category/0 callback
  permission_level: :read # Override module's permission_level/0 callback
]
```

**Override precedence**: `opts` values take priority over module callback return values. This allows the registry to override tool metadata at registration time (useful for MCP tools where metadata comes from the server, not the module).

## ETS Entry Format

The ETS table stores entries as:

```elixir
# Module-based tool
{name, {:module, module, opts}}

# Process-based tool
{name, {:process, pid, opts}}
```

The `opts` keyword list carries all metadata. For module-based tools, metadata is resolved at query time by calling the module's callbacks, with `opts` values taking precedence.

## Deferred Tool Lifecycle

1. **Registration** — `register_module(name, module, deferred: true)` adds the tool but marks it as deferred.
2. **Discovery** — `list_for_llm(include_deferred: true)` returns deferred tools (useful for showing the LLM what tools exist but are not yet loaded).
3. **Activation** — `mark_loaded(name)` sets the tool as loaded. Subsequent `list_for_llm/0` (without options) includes it.
4. **Deactivation** — `unregister(name)` removes the tool entirely.

This lifecycle supports tools that are expensive to initialize (e.g., MCP tools requiring server startup) or conditionally available (e.g., LSP tools that depend on language detection).
