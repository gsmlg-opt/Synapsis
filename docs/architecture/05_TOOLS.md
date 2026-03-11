# 05 — Tool System

## Overview

The tool system is the agent's interface to the real world — every file read, shell command, web request, and user interaction is a tool call. All tool infrastructure lives in `apps/synapsis_core/lib/synapsis/tool/` as part of the `synapsis_core` application.

**27 built-in tools** across 10 categories, with a uniform behaviour contract, 5-level permission model, parallel execution, and deferred loading for plugin tools.

## Tool Behaviour Contract

```elixir
defmodule Synapsis.Tool do
  @moduledoc "Behaviour contract for all tools in the Synapsis agent system."

  @type context :: %{
    session_id: String.t(),
    project_path: String.t(),
    working_dir: String.t(),
    permissions: map(),
    session_pid: pid() | nil,
    agent_mode: :build | :plan,
    parent_agent: pid() | nil
  }

  @type result :: {:ok, term()} | {:error, term()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(input :: map(), context()) :: result()

  @callback permission_level() :: :read | :write | :execute | :destructive | :none
  @callback side_effects() :: [atom()]
  @callback category() :: :filesystem | :search | :execution | :web
                         | :planning | :orchestration | :interaction | :session
                         | :notebook | :computer | :swarm
  @callback version() :: String.t()
  @callback enabled?() :: boolean()

  @optional_callbacks [side_effects: 0, permission_level: 0, category: 0, version: 0, enabled?: 0]
end
```

Tools self-declare their permission level, category, and side effects. Defaults via `use Synapsis.Tool`: `permission_level: :read`, `side_effects: []`, `version: "1.0.0"`, `enabled?: true`.

## Built-in Tool Inventory

| # | Tool | Name | Category | Permission | Side Effects | Enabled |
|---|---|---|---|---|---|---|
| 1 | FileRead | `file_read` | filesystem | `:read` | — | yes |
| 2 | FileWrite | `file_write` | filesystem | `:write` | `[:file_changed]` | yes |
| 3 | FileEdit | `file_edit` | filesystem | `:write` | `[:file_changed]` | yes |
| 4 | MultiEdit | `multi_edit` | filesystem | `:write` | `[:file_changed]` | yes |
| 5 | FileDelete | `file_delete` | filesystem | `:destructive` | `[:file_changed]` | yes |
| 6 | FileMove | `file_move` | filesystem | `:write` | `[:file_changed]` | yes |
| 7 | ListDir | `list_dir` | filesystem | `:read` | — | yes |
| 8 | Grep | `grep` | search | `:read` | — | yes |
| 9 | Glob | `glob` | search | `:read` | — | yes |
| 10 | BashExec | `bash_exec` | execution | `:execute` | — | yes |
| 11 | WebFetch | `web_fetch` | web | `:read` | — | yes |
| 12 | WebSearch | `web_search` | web | `:read` | — | yes |
| 13 | TodoWrite | `todo_write` | planning | `:none` | — | yes |
| 14 | TodoRead | `todo_read` | planning | `:none` | — | yes |
| 15 | Task | `task` | orchestration | `:none` | — | yes |
| 16 | ToolSearch | `tool_search` | orchestration | `:none` | — | yes |
| 17 | Skill | `skill` | orchestration | `:none` | — | yes |
| 18 | AskUser | `ask_user` | interaction | `:none` | — | yes |
| 19 | EnterPlanMode | `enter_plan_mode` | session | `:none` | — | yes |
| 20 | ExitPlanMode | `exit_plan_mode` | session | `:none` | — | yes |
| 21 | Sleep | `sleep` | session | `:none` | — | yes |
| 22 | NotebookRead | `notebook_read` | notebook | `:read` | — | **no** |
| 23 | NotebookEdit | `notebook_edit` | notebook | `:write` | `[:file_changed]` | **no** |
| 24 | Computer | `computer` | computer | `:execute` | — | **no** |
| 25 | SendMessage | `send_message` | swarm | `:none` | — | yes |
| 26 | Teammate | `teammate` | swarm | `:none` | — | yes |
| 27 | TeamDelete | `team_delete` | swarm | `:none` | — | yes |

**Total: 27 tools (21 enabled by default, 3 disabled/future, 3 swarm)**

### Filesystem Tools (7)

- **`file_read`** — Read file contents with optional line range (`offset`, `limit`). Supports text, images (base64), PDFs (page range), Jupyter notebooks.
- **`file_write`** — Create or overwrite a file. Creates parent directories. Prefer `file_edit` for existing files.
- **`file_edit`** — Exact string replacement (`old_text` → `new_text`). `old_text` must match exactly once. Primary edit tool.
- **`multi_edit`** — Batch edits across one or more files. Edits applied sequentially per file. Rolled back on failure per file.
- **`file_delete`** — Delete file or empty directory. Permission level `:destructive`. Refuses non-empty dirs unless `recursive: true`.
- **`file_move`** — Move/rename a file or directory. Creates destination parent directories.
- **`list_dir`** — List directory contents with depth control. Respects `.gitignore` by default.

### Search Tools (2)

- **`grep`** — Recursive regex search across files. Output modes: `content`, `files`, `count`. Context lines configurable.
- **`glob`** — Find files matching a glob pattern. Returns paths sorted by modification time (newest first).

### Execution Tools (1)

- **`bash_exec`** — Execute shell command in a persistent bash session. State (env, cwd) persists across calls within the session. Implemented as a Port with a long-running bash process. Configurable timeout (default 30s).

### Web Tools (2)

- **`web_fetch`** — Fetch web page content at a URL. Returns extracted text. No JavaScript execution.
- **`web_search`** — Search the web and return results with titles, URLs, and snippets.

### Planning Tools (2)

- **`todo_write`** — Create/update a task checklist for the session. Each call replaces the full list. Items have status: `pending`, `in_progress`, `completed`.
- **`todo_read`** — Read the current todo list state.

### Orchestration Tools (3)

- **`task`** — Launch a sub-agent with scoped tool set. Supports foreground (blocking) and background (async with task ID) modes. Sub-agents inherit session context but have their own conversation history.
- **`tool_search`** — Search for and load deferred tools by keyword. MCP/plugin tools are not loaded by default to save tokens; this tool activates them.
- **`skill`** — Load a SKILL.md file and inject its instructions into the conversation. Discovered from project-local, user-global, and built-in locations.

### User Interaction Tools (1)

- **`ask_user`** — Present structured questions with selectable options. Blocks until user responds. Sub-agents cannot use this tool.

### Session Control Tools (3)

- **`enter_plan_mode`** — Switch to plan mode. Write/execute tools are disabled. Agent explores and builds a plan.
- **`exit_plan_mode`** — Exit plan mode, present the plan for approval. On approval, returns to `:build` mode.
- **`sleep`** — Wait for a duration or until user input. Interruptible via selective receive.

### Notebook Tools (2, disabled by default)

- **`notebook_read`** — Read a `.ipynb` file, return all cells with outputs. Enable with `notebook_tools: true`.
- **`notebook_edit`** — Replace or insert a cell in a notebook. Enable with `notebook_tools: true`.

### Computer Use Tools (1, disabled by default)

- **`computer`** — Desktop/browser interaction for visual verification. Enable with `computer_use: true`. Backend is configurable (Anthropic API, Puppeteer MCP, Playwright).

### Swarm Tools (3)

- **`send_message`** — Send a structured message to a teammate agent in the current swarm. Routed via PubSub.
- **`teammate`** — Create, list, get, or update teammate agents. Teammates are separate agent loop processes.
- **`team_delete`** — Dissolve the current swarm and terminate all teammate agents.

## Tool Registry

ETS-backed GenServer at `Synapsis.Tool.Registry`. Supports module-based tools (`{:module, module, opts}`) and process-based plugin tools (`{:process, pid, opts}`).

```elixir
defmodule Synapsis.Tool.Registry do
  use GenServer

  def register_module(name, module, opts \\ [])
  def unregister(name)
  def lookup(name) :: {:ok, entry} | {:error, :not_found}
  def list_for_llm(opts \\ []) :: [map()]
  def list_by_category(category) :: [map()]
  def mark_loaded(name) :: :ok | {:error, :not_found}
end
```

`list_for_llm/1` accepts filter options:

- `agent_mode: :plan` — excludes tools with permission levels `:write`, `:execute`, `:destructive`
- `categories: [:filesystem, :search]` — filter by category
- `include_deferred: false` (default) — exclude deferred/unloaded plugin tools

Built-in tools are registered at application start via `Synapsis.Tool.Builtin.register_all/0`. Plugin tools are registered/unregistered dynamically by MCP/LSP server processes.

## Tool Executor Pipeline

```
tool_call from LLM
  │
  ▼
┌─ Synapsis.Tool.Executor.execute/3 ──────────────┐
│                                                    │
│  1. Registry lookup (tool exists?)                 │
│  2. Permission check                               │
│     ├─ :allowed → proceed                          │
│     ├─ :requires_approval → broadcast event,       │
│     │         block until user responds             │
│     └─ :denied → return {:error, :permission_denied}│
│  3. Dispatch                                        │
│     ├─ {:module, mod} → mod.execute(input, ctx)    │
│     └─ {:process, pid} → GenServer.call(pid, ...)  │
│  4. Persistence                                     │
│     └─ Save tool call to tool_calls table          │
│  5. Side effect broadcast                           │
│     └─ PubSub "tool_effects:#{session_id}"         │
│                                                    │
└────────────────────────────────────────────────────┘
```

### Parallel Tool Execution

When the LLM returns multiple independent tool calls, the executor runs them concurrently:

```elixir
defmodule Synapsis.Tool.Executor do
  def execute_batch(tool_calls, context) when length(tool_calls) > 1 do
    tool_calls
    |> Task.async_stream(fn call -> execute(call, context) end,
         max_concurrency: System.schedulers_online(),
         timeout: 60_000
       )
    |> Enum.zip(tool_calls)
    |> Enum.map(fn {{:ok, result}, call} -> {call.id, result}
                   {{:exit, reason}, call} -> {call.id, {:error, reason}}
                end)
  end
end
```

Constraints:
- Tools with `:file_changed` side effects targeting the same file are serialized to prevent write conflicts
- Permission checks (`:requires_approval`) are batched — all pending approvals presented simultaneously
- Sub-agent tools (`task`) are not parallelized with other tools in the same batch

## Permission Model

### Permission Levels

```
:none        — always available, no approval needed (planning, interaction, orchestration)
:read        — allowed by default, can be restricted
:write       — requires session-level opt-in or per-call approval
:execute     — requires explicit session-level opt-in
:destructive — requires per-call approval by default
```

### Session Permission Configuration

Each session has a permission configuration persisted in `session_permissions`:

```elixir
%SessionPermission{
  mode: :interactive | :autonomous,
  allow_write: true,
  allow_execute: true,
  allow_destructive: :ask,  # :allow | :deny | :ask
  tool_overrides: %{
    "bash_exec" => :ask,
    "bash_exec(git *)" => :allow,
    "bash_exec(rm *)" => :deny,
    "file_write(src/**)" => :allow,
    "file_write(production.*)" => :deny
  }
}
```

### Permission Resolution Order

1. Per-tool glob override (most specific match wins)
2. Permission level default for the session
3. Tool's declared `permission_level/0`

### Autonomous Mode

In autonomous mode, tools at or below `:execute` level are auto-approved. `:destructive` tools follow the session's `allow_destructive` setting.

### Plan Mode Restrictions

When `agent_mode` is `:plan`:
- Tools with permission level `:write`, `:execute`, `:destructive` are excluded from `list_for_llm/1`
- Only `:read` and `:none` tools are available
- The agent can use `ask_user` to clarify requirements
- The agent must call `exit_plan_mode` to present a plan and return to `:build` mode

## Side Effect System

Tools declare side effects statically via the `side_effects/0` callback:

```
:file_changed — a file was created, modified, moved, or deleted
```

After successful tool execution, the executor broadcasts:

```
PubSub topic: "tool_effects:#{session_id}"
Message: {:tool_effect, :file_changed, %{tool: name, input: input, result: result}}
```

Subscribers:
- LSP server processes — send `didChange`, collect diagnostics
- MCP server processes — interested MCP servers
- Session channel — UI notifications (file tree refresh)

## Deferred Tool Loading

To prevent LLM context bloat from large MCP server tool sets:

1. On session start, only built-in tools are included in `list_for_llm/1`
2. MCP/plugin tools are registered in the Registry but marked `deferred: true`
3. The agent uses `tool_search` to discover relevant deferred tools by keyword
4. Once loaded (`mark_loaded/1`), deferred tools are included in subsequent `list_for_llm/1` calls

## Bash Tool — Persistent Port Session

```elixir
defmodule Synapsis.Tool.Bash do
  use Synapsis.Tool

  @impl true
  def permission_level, do: :execute

  def execute(%{"command" => cmd}, %{project_path: cwd}) do
    port = Port.open({:spawn_executable, "/bin/sh"},
      [:binary, :exit_status, :stderr_to_stdout,
       args: ["-c", cmd],
       cd: cwd,
       env: sanitized_env()])

    collect_output(port, [], @timeout)
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} -> collect_output(port, [data | acc], timeout)
      {^port, {:exit_status, 0}} -> {:ok, %{output: IO.iodata_to_binary(Enum.reverse(acc))}}
      {^port, {:exit_status, code}} -> {:ok, %{output: IO.iodata_to_binary(Enum.reverse(acc)), exit_code: code}}
    after
      timeout ->
        Port.close(port)
        {:error, :timeout}
    end
  end
end
```

State (env vars, cwd) persists across calls within the same session. The agent should prefer built-in tools (grep, glob, list_dir) over bash equivalents for permission efficiency.

## Sub-Agent Execution

The `task` tool launches a sub-agent by spawning a new agent loop process:

```elixir
defmodule Synapsis.Tool.Task do
  use Synapsis.Tool

  def execute(%{"prompt" => prompt} = input, ctx) do
    tools = Map.get(input, "tools", ["file_read", "list_dir", "grep", "glob"])
    mode = Map.get(input, "mode", "foreground")

    sub_context = %{ctx |
      parent_agent: self(),
      agent_mode: :build,
      permissions: restrict_permissions(ctx.permissions, tools)
    }

    case mode do
      "foreground" ->
        Synapsis.Agent.SubAgent.run(prompt, tools, sub_context)

      "background" ->
        {:ok, task_id} = Synapsis.Agent.SubAgent.start_background(prompt, tools, sub_context)
        {:ok, %{task_id: task_id, status: "running"}}
    end
  end
end
```

Sub-agents inherit the session context but have their own conversation history. They cannot use `ask_user` or `enter_plan_mode` — only the primary agent interacts with the user.

## MCP Tool Delegation

MCP tools are discovered at startup from config and registered dynamically with `deferred: true`:

```elixir
defmodule Synapsis.MCP.Client do
  use GenServer

  # Each MCP server connection is a GenServer managing a Port (stdio) or HTTP (SSE)
  # Tools are registered in Synapsis.Tool.Registry with prefix "mcp:<server>:<tool>"

  def call_tool(server_name, tool_name, input) do
    GenServer.call(via(server_name), {:call_tool, tool_name, input})
  end
end
```

MCP tools follow the same execution pipeline (permission check → dispatch → side effects) but dispatch via `GenServer.call/3` to the MCP client process.

## Agent Loop Integration

```elixir
# Gathering tools for LLM request
def gather_tools(session, context) do
  Synapsis.Tool.Registry.list_for_llm(
    agent_mode: context.agent_mode,
    session_id: session.id,
    include_deferred: false
  )
end

# Processing tool calls from LLM response
case event do
  {:tool_use, %{name: name, id: id, input: input}} ->
    tool_call = %{name: name, id: id, input: input}
    broadcast_tool_use(session.id, tool_call)

    case Synapsis.Tool.Executor.execute(tool_call, context) do
      {:ok, result} ->
        broadcast_tool_result(session.id, id, result)
        {:cont, append_tool_result(context, id, result)}

      {:error, :permission_denied} ->
        broadcast_tool_result(session.id, id, %{error: "Permission denied"})
        {:cont, append_tool_result(context, id, %{error: "Permission denied"})}

      {:error, :requires_approval} ->
        # Block until approval via channel
        receive do
          {:tool_approved, ^id} ->
            result = Synapsis.Tool.Executor.execute_approved(tool_call, context)
            broadcast_tool_result(session.id, id, result)
            {:cont, append_tool_result(context, id, result)}

          {:tool_denied, ^id} ->
            broadcast_tool_result(session.id, id, %{error: "User denied"})
            {:cont, append_tool_result(context, id, %{error: "User denied tool use"})}
        end
    end
end
```

## Data Persistence

Tool calls are persisted in the `tool_calls` table for audit and replay. See [02_DATA_LAYER.md](02_DATA_LAYER.md) for schema details.

Session permissions and todo lists are also persisted — see `session_permissions` and `session_todos` tables.
