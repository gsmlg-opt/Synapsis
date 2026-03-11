# Tool System - Developer Quickstart

## Prerequisites

- Elixir 1.18+ / OTP 28+ (via devenv)
- PostgreSQL running
- Existing tool system with 11 tools working (`FileRead`, `FileEdit`, `FileWrite`, `Bash`, `Grep`, `Glob`, `Fetch`, `Diagnostics`, `ListDir`, `FileDelete`, `FileMove`)

## Development Commands

```bash
# Compile
devenv shell -- bash -c 'mix compile --warnings-as-errors'

# Run all tests
devenv shell -- bash -c 'mix test'

# Run only tool system tests
devenv shell -- bash -c 'mix test apps/synapsis_core/test/synapsis/tool/'

# Run only data schema tests
devenv shell -- bash -c 'mix test apps/synapsis_data/test/'

# Run single test file
devenv shell -- bash -c 'mix test apps/synapsis_core/test/synapsis/tool/multi_edit_test.exs'

# Create migration
devenv shell -- bash -c 'cd apps/synapsis_data && mix ecto.gen.migration create_tool_calls'

# Run migrations
devenv shell -- bash -c 'mix ecto.migrate'

# Format code
devenv shell -- bash -c 'mix format'
```

## Adding a New Tool (Step by Step)

1. Create module at `apps/synapsis_core/lib/synapsis/tool/<tool_name>.ex`
2. `use Synapsis.Tool` and implement required callbacks: `name/0`, `description/0`, `parameters/0`, `execute/2`
3. Override optional callbacks as needed (`side_effects/0`)
4. Register in `Synapsis.Tool.Builtin.register_all/0` by adding the module to the `@tools` list and a `default_timeout/1` clause
5. Write tests at `apps/synapsis_core/test/synapsis/tool/<tool_name>_test.exs`
6. Run `mix compile --warnings-as-errors && mix test` to verify

## Example: Minimal Tool Implementation

```elixir
defmodule Synapsis.Tool.Sleep do
  @moduledoc "Pauses execution for a specified duration in milliseconds."

  use Synapsis.Tool

  @impl true
  def name, do: "sleep"

  @impl true
  def description, do: "Pauses execution for the given number of milliseconds (max 10000)."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "duration_ms" => %{
          "type" => "integer",
          "description" => "Duration to sleep in milliseconds (1-10000)"
        }
      },
      "required" => ["duration_ms"]
    }
  end

  @impl true
  def execute(%{"duration_ms" => ms}, _context) when is_integer(ms) and ms >= 1 and ms <= 10_000 do
    Process.sleep(ms)
    {:ok, "Slept for #{ms}ms"}
  end

  def execute(%{"duration_ms" => ms}, _context) when is_integer(ms) do
    {:error, "duration_ms must be between 1 and 10000, got #{ms}"}
  end

  def execute(_input, _context) do
    {:error, "Missing or invalid duration_ms parameter"}
  end
end
```

Register it in `apps/synapsis_core/lib/synapsis/tool/builtin.ex`:

```elixir
@tools [
  # ... existing tools ...
  Synapsis.Tool.Sleep
]

# Add timeout clause:
defp default_timeout("sleep"), do: 15_000
```

## Implementation Order

**Phase 1: Infrastructure** -- Behaviour extension, registry updates, executor enhancements, permissions system, DB schemas for tool calls.

**Phase 2: Core tools** -- `multi_edit`, `web_search`, `todo_write`, `todo_read`, `ask_user`.

**Phase 3: Orchestration** -- `task`, `tool_search`, `skill`, `enter_plan_mode`/`exit_plan_mode`, `sleep`.

**Phase 4: Advanced** -- Swarm tools, disabled stubs for future capabilities.

**Phase 5: Integration** -- Existing tool updates for new behaviour fields, parallel execution support, end-to-end tests.

## Key Patterns

- All tools return `{:ok, result} | {:error, reason}` from `execute/2`.
- Use `Synapsis.Tool.PathValidator` for any file path arguments -- validates paths are within project root.
- Broadcast side effects via `Phoenix.PubSub.broadcast/3` -- persist to DB first, then broadcast.
- Test with `start_supervised!/1` for process cleanup in ExUnit.
- Use `Bypass` for HTTP-dependent tools (`Fetch`, `web_search`).
- The `context` map carries `:project_path`, `:session_id`, `:working_dir`, and `:permissions`.
- Tools registered via `Synapsis.Tool.Registry.register_module/3` with name, module, and options (timeout, description, parameters).
- Declare `side_effects/0` (e.g., `[:file_changed]`, `[:shell_executed]`) so the session worker knows what happened after tool execution.

## File Locations

| What | Path |
|------|------|
| Tool behaviour | `apps/synapsis_core/lib/synapsis/tool.ex` |
| Built-in registry | `apps/synapsis_core/lib/synapsis/tool/builtin.ex` |
| Tool registry (ETS) | `apps/synapsis_core/lib/synapsis/tool/registry.ex` |
| Executor | `apps/synapsis_core/lib/synapsis/tool/executor.ex` |
| Permissions | `apps/synapsis_core/lib/synapsis/tool/permission.ex` |
| Path validator | `apps/synapsis_core/lib/synapsis/tool/path_validator.ex` |
| Data schemas | `apps/synapsis_data/lib/` |
| Tool tests | `apps/synapsis_core/test/synapsis/tool/` |
| Data tests | `apps/synapsis_data/test/` |
