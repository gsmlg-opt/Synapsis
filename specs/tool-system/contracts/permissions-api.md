# Permission Engine API Contract

## Status

**Module**: `Synapsis.Tool.Permission` (`apps/synapsis_core/lib/synapsis/tool/permission.ex`)
**Existing module**: `Synapsis.Tool.Permissions` (`apps/synapsis_core/lib/synapsis/tool/permissions.ex`) — to be consolidated into `Permission`.

## Types

```elixir
@type permission_level :: :none | :read | :write | :execute | :destructive

@type check_result :: :allowed | :ask | :denied

@type override_rule :: %{
        tool: String.t(),
        pattern: String.t() | nil,
        action: :allow | :deny | :ask
      }

@type session_permission :: %SessionPermission{
        session_id: String.t(),
        mode: :interactive | :autonomous,
        allow_read: boolean(),
        allow_write: boolean(),
        allow_execute: boolean(),
        allow_destructive: :ask | :allow | :deny,
        overrides: [override_rule()]
      }
```

## Public API

### `check/3`

Determines whether a tool call should be allowed, denied, or requires user approval.

```elixir
@spec check(tool_name :: String.t(), input :: map(), context :: Synapsis.Tool.context()) ::
        check_result()
def check(tool_name, input, context)
```

**Resolution order** (first match wins):

1. **Per-tool glob override** — check `overrides` in the session permission config. If a rule matches the tool name and input pattern, return its action.
2. **Session-level default** — check the session permission config for the tool's permission level.
3. **Tool-declared level** — fall back to the tool's `permission_level/0` callback and apply default policy.

**Resolution detail**:

```
check(tool_name, input, context):
  session_config = session_config(context.session_id)

  # Step 1: per-tool glob override
  case resolve_override(tool_name, input, session_config.overrides) do
    {:ok, :allow} -> :allowed
    {:ok, :deny}  -> :denied
    {:ok, :ask}   -> :ask
    :no_match     -> continue to step 2
  end

  # Step 2: resolve via permission level
  level = tool_permission_level(tool_name)

  case {session_config.mode, level} do
    {_, :none}                      -> :allowed
    {_, :read}   when allow_read    -> :allowed
    {:autonomous, :write}           -> :allowed   # autonomous auto-allows write
    {:interactive, :write}          -> apply_setting(session_config.allow_write)
    {:autonomous, :execute}         -> :allowed   # autonomous auto-allows execute
    {:interactive, :execute}        -> apply_setting(session_config.allow_execute)
    {_, :destructive}               -> apply_setting(session_config.allow_destructive)
  end
```

### `resolve_override/3`

Checks if any per-tool override rule matches the given tool call.

```elixir
@spec resolve_override(
        tool_name :: String.t(),
        input :: map(),
        overrides :: [override_rule()]
      ) :: {:ok, :allow | :deny | :ask} | :no_match
def resolve_override(tool_name, input, overrides)
```

**Glob matching**:

Override rules use a pattern syntax: `"tool_name(glob_pattern)"`.

- `"bash(git *)"` — matches the `bash` tool when `input["command"]` starts with `git `.
- `"file_write(/tmp/*)"` — matches `file_write` when `input["path"]` matches `/tmp/*`.
- `"file_read"` — matches all invocations of `file_read` (no input pattern).
- `"mcp:*"` — matches all MCP tools.

**Pattern extraction**:

```elixir
# Parse "bash(git *)" into tool="bash", pattern="git *"
# Parse "file_read" into tool="file_read", pattern=nil
# Parse "mcp:*" into tool="mcp:*", pattern=nil
```

**Input field selection for pattern matching**:
- `bash` — matches against `input["command"]`
- `file_read`, `file_write`, `file_edit`, `file_delete`, `file_move` — matches against `input["path"]`
- `grep` — matches against `input["pattern"]`
- All other tools — matches against `inspect(input)` (full input as string)

### `session_config/1`

Loads the permission configuration for a session.

```elixir
@spec session_config(session_id :: String.t()) :: session_permission()
def session_config(session_id)
```

**Resolution**:
1. Query the database for session-specific permission config (stored in `sessions.config` JSONB column under `"permissions"` key).
2. Merge with application-level defaults from `Application.get_env(:synapsis_core, :permissions)`.
3. Return a `%SessionPermission{}` struct.

**Defaults** (when no session or application config exists):

```elixir
%SessionPermission{
  session_id: session_id,
  mode: :interactive,
  allow_read: true,
  allow_write: true,
  allow_execute: false,
  allow_destructive: :ask,
  overrides: []
}
```

### `update_config/2`

Updates the permission configuration for a session.

```elixir
@spec update_config(session_id :: String.t(), changes :: map()) ::
        {:ok, session_permission()} | {:error, term()}
def update_config(session_id, changes)
```

**Accepted changes**:

```elixir
changes = %{
  mode: :autonomous,
  allow_write: true,
  allow_execute: true,
  allow_destructive: :ask,
  overrides: [
    %{tool: "bash(git *)", action: :allow},
    %{tool: "bash(rm *)", action: :deny},
    %{tool: "file_write(/tmp/*)", action: :allow}
  ]
}
```

**Persistence**: Updates the `"permissions"` key in the session's `config` JSONB column via `Synapsis.Data` (the data layer). The updated config is also cached in the session's Worker process state.

## Permission Levels and Default Policies

| Level | `:interactive` default | `:autonomous` default |
|---|---|---|
| `:none` | `:allowed` | `:allowed` |
| `:read` | `:allowed` | `:allowed` |
| `:write` | `:allowed` | `:allowed` |
| `:execute` | `:ask` | `:allowed` |
| `:destructive` | `:ask` | follows `allow_destructive` setting |

### Interactive Mode

Standard mode where the user is actively engaged. Permissions follow the session config settings directly:

- `:read` — always allowed (cannot be disabled)
- `:write` — controlled by `allow_write` (default: `true` -> `:allowed`)
- `:execute` — controlled by `allow_execute` (default: `false` -> `:ask`)
- `:destructive` — controlled by `allow_destructive` (default: `:ask`)

### Autonomous Mode

When `mode: :autonomous`, the agent is running with reduced human supervision:

- `:none`, `:read`, `:write`, `:execute` — all auto-allowed. The assumption is that autonomous mode implies trust for standard operations.
- `:destructive` — follows the `allow_destructive` session setting. Even in autonomous mode, destructive operations respect the explicit setting (default: `:ask`).

This means switching to autonomous mode effectively auto-approves `:write` and `:execute` operations without changing session config.

## Permission Level Resolution

The permission level for a tool is resolved in this order:

1. **Registry override** — if the tool was registered with an explicit `permission_level` option in its registry opts, use that.
2. **Module callback** — if the tool module implements `permission_level/0`, call it.
3. **Legacy fallback** — use the hard-coded mapping from `Synapsis.Tool.Permissions.level/1` (to be removed once all tools implement the callback).

```elixir
defp tool_permission_level(tool_name) do
  case Synapsis.Tool.Registry.lookup(tool_name) do
    {:ok, {:module, module, opts}} ->
      opts[:permission_level] || safe_callback(module, :permission_level) || legacy_level(tool_name)

    {:ok, {:process, _pid, opts}} ->
      opts[:permission_level] || :write

    {:error, :not_found} ->
      :write
  end
end

defp safe_callback(module, callback) do
  if function_exported?(module, callback, 0) do
    apply(module, callback, [])
  else
    nil
  end
end
```

## `SessionPermission` Struct

```elixir
defmodule Synapsis.Tool.Permission.SessionPermission do
  @enforce_keys [:session_id]
  defstruct [
    :session_id,
    mode: :interactive,
    allow_read: true,
    allow_write: true,
    allow_execute: false,
    allow_destructive: :ask,
    overrides: []
  ]
end
```

## Approval Flow Integration

When `check/3` returns `:ask`:

1. The `Executor` returns `{:pending_approval, ref}` to the `Session.Worker`.
2. The `Session.Worker` broadcasts `{:tool_approval_required, ref, tool_call}` via PubSub to the session channel.
3. The UI presents the approval dialog to the user.
4. The user responds with approve or deny.
5. On approve: `Session.Worker` calls `Executor.execute_approved/2`.
6. On deny: `Session.Worker` sends a tool result with `{:error, :denied_by_user}` back to the provider.

## Configuration Examples

### Application config (`config/config.exs`)

```elixir
config :synapsis_core, :permissions,
  default_mode: :interactive,
  allow_read: true,
  allow_write: true,
  allow_execute: false,
  allow_destructive: :ask
```

### Session config (in `.opencode.json`)

```json
{
  "permissions": {
    "mode": "autonomous",
    "allowWrite": true,
    "allowExecute": true,
    "allowDestructive": "ask",
    "overrides": [
      {"tool": "bash(git *)", "action": "allow"},
      {"tool": "bash(rm -rf *)", "action": "deny"},
      {"tool": "file_write(/tmp/*)", "action": "allow"}
    ]
  }
}
```
