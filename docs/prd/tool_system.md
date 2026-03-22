# Synapsis Tools System — Product Requirements Document

## 1. Executive Summary

Synapsis is an AI coding agent designed to replace Claude Code, OpenCode, and similar CLI-based agentic coding tools. This PRD specifies the complete tool system — the set of capabilities the agent can invoke during a coding session. The tool system is the agent's interface to the real world: every file read, every shell command, every user interaction is a tool call.

The tool system lives in `apps/synapsis_core/lib/synapsis/tool/` within the `synapsis_core` umbrella sub-app. Per the Constitution, `synapsis_core` is the single application with a supervision tree. Tools share the same process tree as sessions, agents, and config. Both the agent loop (`synapsis_agent`) and the plugin host depend on `synapsis_core`.

This document covers:

- Complete built-in tool inventory with specifications
- Tool behaviour contract and execution pipeline
- Tool registry architecture
- Permission model
- Side effect propagation
- Agent orchestration tools (sub-agents, planning)
- User interaction tools
- Web tools
- Integration with the plugin system (MCP/LSP)

---

## 2. Competitive Landscape

### 2.1 Claude Code (v2.1.71, March 2026) — 20 Built-in Tools

**Filesystem:** Read, Write, Edit, MultiEdit, Glob, Grep, LS
**Execution:** Bash (persistent session)
**Web:** WebFetch, WebSearch
**Planning:** TodoWrite, TaskCreate
**Orchestration:** Task (sub-agent launcher), ToolSearch (deferred tool loader), Skill (skill loader)
**User Interaction:** AskUserQuestion (structured multi-select with HTML preview)
**Mode Control:** EnterPlanMode, ExitPlanMode
**Code Intelligence:** LSP (built-in, goToDefinition/findReferences/hover/symbols)
**Notebook:** NotebookEdit
**Utility:** Sleep (wait with early wake on user input)
**Swarm (experimental):** SendMessageTool, TeammateTool, TeamDelete, Computer

### 2.2 OpenCode (Charm, v1.x) — 15+ Built-in Tools

**Filesystem:** read, write, edit, list, glob, grep, patch (apply diffs)
**Execution:** bash
**Web:** webfetch, websearch (Exa AI)
**Planning:** todoread, todowrite
**Orchestration:** task (sub-agent), skill (SKILL.md loader)
**User Interaction:** question (structured prompts mid-execution)
**Code Intelligence:** lsp (experimental, behind feature flag)

### 2.3 Codex CLI (OpenAI) — Minimal Tool Surface

**Execution:** Sandboxed bash with configurable approval policies
**File Editing:** apply_patch (unified diff format)
**Web:** web_search (cache-first by default)
**Orchestration:** MCP integration

### 2.4 Design Principle

Synapsis targets feature parity with Claude Code's tool surface while maintaining architectural clarity through the Elixir behaviour system. Where Claude Code and OpenCode blur the line between "tool" and "agent mode," Synapsis treats everything as a tool with a uniform `Synapsis.Tool` behaviour contract. All tool infrastructure lives in `apps/synapsis_core/lib/synapsis/tool/`, co-located with the agent and session systems in the `synapsis_core` sub-app.

---

## 3. Architecture

### 3.1 Layers

```
┌─────────────────────────────────────────────────────┐
│                    Agent Loop                        │
│  (synapsis_agent — graph-based CodingLoop)          │
│                                                      │
│  Gathers tools → builds LLM request → processes     │
│  tool_use events → feeds results back to LLM        │
├─────────────────────────────────────────────────────┤
│                  Tool Executor                       │
│  (synapsis_core — Synapsis.Tool.Executor)           │
│                                                      │
│  Permission check → dispatch → side effect broadcast │
├──────────────────────┬──────────────────────────────┤
│   Tool Registry      │   Permission Engine          │
│   (GenServer + ETS)  │   (Synapsis.Tool.Permission) │
│                      │                              │
│   name → {type,      │   tool → level → session     │
│           module/pid, │   config → allow/deny/ask    │
│           opts}       │                              │
├──────────────────────┴──────────────────────────────┤
│                    Tool Modules                      │
│                                                      │
│  Built-in (synapsis_core)      Plugin (MCP/custom)  │
│  ├── Filesystem                ├── MCP tools         │
│  ├── Execution                 ├── LSP tools         │
│  ├── Search                    └── Custom plugins    │
│  ├── Web                                             │
│  ├── Planning                                        │
│  ├── Orchestration                                   │
│  ├── User Interaction                                │
│  ├── Session Control                                 │
│  ├── Memory                                          │
│  └── Swarm                                           │
└─────────────────────────────────────────────────────┘
```

### 3.2 Tool Behaviour Contract

```elixir
defmodule Synapsis.Tool do
  @moduledoc """
  Canonical behaviour for tool implementations.
  Lives in apps/synapsis_core/lib/synapsis/tool.ex.
  """

  @type permission_level :: :none | :read | :write | :execute | :destructive

  @type category ::
          :filesystem | :search | :execution | :web | :planning
          | :orchestration | :interaction | :session | :notebook
          | :computer | :swarm | :memory | :workspace | :uncategorized

  @type context :: %{
    optional(:project_path) => String.t(),
    optional(:session_id) => String.t(),
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
  @callback side_effects() :: [atom()]          # default: []
  @callback permission_level() :: permission_level()  # default: :read
  @callback category() :: category()            # default: :uncategorized
  @callback version() :: String.t()             # default: "1.0.0"
  @callback enabled?() :: boolean()             # default: true
end
```

Usage with the `use` macro:

```elixir
defmodule Synapsis.Tool.FileRead do
  use Synapsis.Tool

  @impl true
  def name, do: "file_read"

  @impl true
  def permission_level, do: :read

  @impl true
  def category, do: :filesystem

  @impl true
  def description, do: "Read the contents of a file at the given path."

  @impl true
  def parameters, do: %{...}

  @impl true
  def execute(input, context), do: {:ok, "file content"}
end
```

The `use Synapsis.Tool` macro injects `@behaviour Synapsis.Tool` and provides overridable defaults for all optional callbacks.

### 3.3 Tool Registry

```elixir
defmodule Synapsis.Tool.Registry do
  use GenServer

  # ETS table: :synapsis_tools
  # Entry format: {name, {:module, module, opts}} or {name, {:process, pid, opts}}

  # Registration
  def register_module(name, module, opts \\ [])
  def register_process(name, pid, opts \\ [])
  def register(tool) when is_map(tool)      # backward-compatible map format

  # Lookup
  def lookup(name) :: {:ok, entry} | {:error, :not_found}
  def get(name) :: {:ok, map()} | {:error, :not_found}

  # Listing
  def list() :: [map()]
  def list_for_llm() :: [map()]              # unfiltered, backward-compatible
  def list_for_llm(opts) :: [map()]          # filtered by agent_mode, deferred, categories
  def list_by_category(category) :: [map()]

  # Deferred loading
  def mark_loaded(name) :: :ok | {:error, :not_found}

  # Unregister
  def unregister(name) :: :ok
end
```

`list_for_llm/1` accepts options for filtering:
- `:agent_mode` — `:plan` excludes tools with permission level in `[:write, :execute, :destructive]`; `:build` (default) includes all.
- `:include_deferred` — when `false` (default), excludes tools registered with `deferred: true` that have not been `mark_loaded/1`-ed.
- `:categories` — list of category atoms to include. `nil` means no filter.

Registration enriches opts from module callbacks (category, permission_level, version, enabled) when not explicitly provided.

### 3.4 Tool Executor Pipeline

```
tool_call from LLM
  │
  ▼
┌─ Synapsis.Tool.Executor.execute/2 ─────────────────┐
│                                                      │
│  1. Registry lookup (tool exists?)                   │
│  2. Enabled check (module.enabled?())                │
│  3. Permission check                                 │
│     ├─ :allowed → proceed                            │
│     ├─ :requires_approval → return error             │
│     └─ :denied → return {:error, :denied}            │
│  4. Dispatch                                         │
│     ├─ {:module, mod, opts} → Task.Supervisor        │
│     │   (async_nolink with timeout)                  │
│     └─ {:process, pid, opts} → GenServer.call        │
│  5. Result handling                                  │
│     ├─ {:ok, result} → persist, broadcast side fx    │
│     └─ {:error, reason} → persist, return error      │
│  6. Persistence (tool_calls table)                   │
│     └─ Synapsis.ToolCall → Synapsis.Repo.insert      │
│                                                      │
└──────────────────────────────────────────────────────┘
```

### 3.5 Parallel Tool Execution

When the LLM returns multiple independent tool calls in a single response, the executor runs them concurrently using `Task.async_stream/3`. This matches Claude Code's behaviour and significantly reduces latency.

```elixir
defmodule Synapsis.Tool.Executor do
  def execute_batch(tool_calls, context) when is_list(tool_calls) do
    # Group by file path — calls sharing a path are serialized
    # Groups keyed by nil (no file path) can each run independently
    # Uses Task.async_stream with max_concurrency: System.schedulers_online()
  end
end
```

Constraints:
- Tools with side effects (`:file_changed`) that target the same file are serialized to prevent write conflicts (grouped by `input["path"]`, `input["file_path"]`, or `input["source"]`).
- Sub-agent tools (`task`) are not parallelized with other tools in the same batch.

### 3.6 Umbrella Placement and Dependency Direction

Tools live in `apps/synapsis_core/lib/synapsis/tool/` as part of the `synapsis_core` sub-app. Per the Constitution:

```
synapsis_data        (schemas, Repo, migrations — no umbrella deps, no application)
  ↑
synapsis_provider    (provider behaviour + implementations — depends on synapsis_data)
  ↑
synapsis_core        (sessions, tools, agents, config — THE application, starts all supervision)
  ↑
synapsis_web/lsp/server/cli (presentation layers — depend on synapsis_core)
```

- `synapsis_core` depends on `synapsis_data` (for permission configs, tool call persistence via `Synapsis.ToolCall`, `Synapsis.SessionPermission`)
- `synapsis_agent` depends on `synapsis_core` (agent loop calls `Synapsis.Tool.Registry.list_for_llm/1` and `Synapsis.Tool.Executor.execute/2`)
- Plugin tools register into `Synapsis.Tool.Registry` and dispatch via `GenServer.call/3`

On application start, `Synapsis.Tool.Builtin.register_all/0` registers all built-in tools.

---

## 4. Complete Tool Inventory

### 4.1 Filesystem Tools (7 tools)

#### `file_read`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.FileRead` |
| Permission | `:read` |
| Side Effects | none |
| Description | Read file contents with optional line range. Text files only (no PDF parsing). |

Parameters:
- `path` (required, string) — absolute or relative path to the file
- `offset` (optional, integer) — start line (0-indexed)
- `limit` (optional, integer) — number of lines to return

Notes: The agent must read a file before editing it. Multiple reads should be batched in parallel. For large files (>500 lines), encourage use of offset/limit. Does NOT support PDF or Jupyter notebook parsing.

#### `file_write`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.FileWrite` |
| Permission | `:write` |
| Side Effects | `[:file_changed]` |
| Description | Create a new file or overwrite an existing file with the provided content. |

Parameters:
- `path` (required, string)
- `content` (required, string) — full file content

Notes: Creates parent directories if they don't exist. Use `file_edit` for modifying existing files to minimize token usage. Returns `{:ok, "Successfully wrote N bytes to path"}`.

#### `file_edit`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.FileEdit` |
| Permission | `:write` |
| Side Effects | `[:file_changed]` |
| Description | Apply a targeted edit by replacing an exact string match. |

Parameters:
- `path` (required, string)
- `old_string` (required, string) — exact text to find
- `new_string` (required, string) — replacement text

Notes: If `old_string` matches multiple locations, replaces only the first occurrence and warns in the result JSON. Returns `{:ok, json_string}` where JSON contains `status`, `path`, `message`, and `diff` fields. This is the primary edit tool — prefer over `file_write` for existing files.

#### `multi_edit`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.MultiEdit` |
| Permission | `:write` |
| Side Effects | `[:file_changed]` |
| Description | Apply multiple edits to one or more files in a single tool call. Each edit is an exact string replacement. |

Parameters:
- `edits` (required, array of objects) — each with:
  - `path` (required, string)
  - `old_string` (required, string)
  - `new_string` (required, string)

Notes: All edits within a file are applied in order. Cross-file edits are independent. This addresses the common pattern of renaming a symbol across multiple files.

#### `file_delete`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.FileDelete` |
| Permission | `:destructive` |
| Side Effects | `[:file_changed]` |
| Description | Delete a file. |

Parameters:
- `path` (required, string)

Notes: Returns `{:ok, "Successfully deleted path"}`. First-class tool rather than routing through bash — enables proper permission gating.

#### `file_move`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.FileMove` |
| Permission | `:write` |
| Side Effects | `[:file_changed]` |
| Description | Move or rename a file or directory. |

Parameters:
- `source` (required, string)
- `destination` (required, string)

Notes: Creates destination parent directories if needed. Returns `{:ok, "Moved src to dst"}`.

#### `list_dir`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.ListDir` |
| Permission | `:read` |
| Side Effects | none |
| Description | List directory contents with optional depth control. |

Parameters:
- `path` (required, string)
- `depth` (optional, integer, default: 1) — max depth for recursive listing

### 4.2 Search Tools (2 tools)

#### `grep`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.Grep` |
| Permission | `:read` |
| Side Effects | none |
| Description | Recursive text/regex search across files. Powered by ripgrep internally. |

Parameters:
- `pattern` (required, string) — search pattern (regex supported)
- `path` (optional, string, default: project root) — directory to search
- `include` (optional, string) — filter files by glob pattern, e.g. `"*.ex"`

Notes: Returns `{:ok, "match output"}` or `{:ok, "No matches found."}`. The filter parameter is named `include` (not `glob`).

#### `glob`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.Glob` |
| Permission | `:read` |
| Side Effects | none |
| Description | Find files matching a glob pattern. |

Parameters:
- `pattern` (required, string) — glob pattern, e.g. `"**/*.test.ts"`
- `path` (optional, string, default: project root)

Notes: Returns `{:ok, "file1\nfile2\n..."}` or `{:ok, "No files matched..."}`.

### 4.3 Execution Tools (1 tool)

#### `bash`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.Bash` |
| Permission | `:execute` |
| Side Effects | none (side effects are unpredictable for shell commands) |
| Description | Execute a shell command. Each invocation uses an ephemeral Port (not a persistent session). |

Parameters:
- `command` (required, string) — shell command to execute
- `timeout` (optional, integer, default: 30000) — timeout in milliseconds

Notes: Each command runs in a fresh Port process. State (env vars, cwd) does NOT persist across calls. Exit code 0 returns `{:ok, "output"}`. Non-zero returns `{:ok, "Exit code: N\noutput"}`. Timeout returns `{:error, "Command timed out..."}`. The agent should prefer built-in tools (grep, glob, list_dir) over bash equivalents for permission efficiency.

### 4.4 Web Tools (2 tools)

#### `fetch`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.Fetch` |
| Permission | `:read` |
| Side Effects | none |
| Description | Fetch the content of a web page at a given URL. Returns the page text content. |

Parameters:
- `url` (required, string) — full URL including scheme

Notes: The tool name is `fetch` (not `web_fetch`). Does not execute JavaScript. Returns text content extracted from HTML.

#### `web_search`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.WebSearch` |
| Permission | `:read` |
| Side Effects | none |
| Description | Search the web and return results with titles, URLs, and snippets. |

Parameters:
- `query` (required, string) — search query

### 4.5 Planning Tools (2 tools)

#### `todo_write`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.TodoWrite` |
| Permission | `:none` |
| Side Effects | none |
| Description | Create and manage a task checklist for the current session. |

Parameters:
- `todos` (required, array of objects) — each with:
  - `content` (required, string) — task description
  - `status` (required, enum: "pending" | "in_progress" | "completed")

Notes: Each call replaces the entire todo list (not a delta). Displayed in the UI via PubSub broadcast.

#### `todo_read`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.TodoRead` |
| Permission | `:none` |
| Side Effects | none |
| Description | Read the current todo list state. |

Parameters: none

### 4.6 Orchestration Tools (3 tools)

#### `task`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.Task` |
| Permission | `:none` |
| Side Effects | none |
| Enabled | **false** (currently stubbed) |
| Description | Launch a sub-agent to autonomously handle a complex, multi-step task. |

Parameters:
- `prompt` (required, string) — detailed instructions for the sub-agent

Notes: Currently stubbed with `enabled? = false`. Cannot be wired to the agent runtime from `synapsis_core` because `synapsis_core` cannot depend on `synapsis_agent` per the Constitution's dependency graph. Implementing the task tool requires either: (a) a callback/behaviour injected at runtime, or (b) moving the tool to `synapsis_agent`. This is tracked as a separate architectural decision.

#### `tool_search`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.ToolSearch` |
| Permission | `:none` |
| Side Effects | none |
| Description | Search for and load deferred tools by keyword. |

Parameters:
- `query` (required, string) — search keywords

Notes: Returns tool names, descriptions, and parameter schemas. Once a deferred tool is loaded via tool_search, it becomes available for the remainder of the session.

#### `skill`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.Skill` |
| Permission | `:none` |
| Side Effects | none |
| Description | Load a skill and inject its instructions into the current conversation. |

Parameters:
- `name` (required, string) — skill name to load

### 4.7 User Interaction Tools (1 tool)

#### `ask_user`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.AskUser` |
| Permission | `:none` |
| Side Effects | none |
| Description | Present structured questions to the user with selectable options. |

Parameters:
- `question` (required, string) — the question text
- `options` (optional, array of strings) — selectable options

### 4.8 Session Control Tools (3 tools)

#### `enter_plan_mode`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.EnterPlanMode` |
| Permission | `:none` |
| Side Effects | none |
| Description | Switch to plan mode. Write/execute tools are disabled. |

Parameters: none

#### `exit_plan_mode`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.ExitPlanMode` |
| Permission | `:none` |
| Side Effects | none |
| Description | Exit plan mode and present the plan to the user. |

Parameters:
- `plan` (optional, string) — the finalized plan in markdown format

#### `sleep`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.Sleep` |
| Permission | `:none` |
| Side Effects | none |
| Description | Wait for a specified duration. Useful for polling-style workflows. |

Parameters:
- `duration_ms` (required, integer) — maximum wait time in milliseconds

### 4.9 Memory Tools (4 tools)

#### `memory_save`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.MemorySave` |
| Permission | `:write` |
| Side Effects | none |
| Description | Save a memory entry for the current session/project. |

#### `memory_search`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.MemorySearch` |
| Permission | `:read` |
| Side Effects | none |
| Description | Search existing memory entries. |

#### `memory_update`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.MemoryUpdate` |
| Permission | `:write` |
| Side Effects | none |
| Description | Update an existing memory entry. |

#### `session_summarize`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.SessionSummarize` |
| Permission | `:none` |
| Side Effects | none |
| Description | Summarize the current session conversation for context compaction. |

### 4.10 Swarm Tools (3 tools)

#### `send_message`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.SendMessage` |
| Permission | `:none` |
| Side Effects | none |
| Description | Send a structured message to a teammate agent in the current swarm. |

#### `teammate`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.Teammate` |
| Permission | `:none` |
| Side Effects | none |
| Description | Create, configure, or query teammate agents in the current swarm. |

#### `team_delete`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.TeamDelete` |
| Permission | `:none` |
| Side Effects | none |
| Description | Dissolve the current swarm and terminate all teammate agents. |

### 4.11 Special Tools (1 tool)

#### `diagnostics`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.Diagnostics` |
| Permission | `:read` |
| Side Effects | none |
| Description | Query LSP diagnostics for current project files. |

### 4.12 Disabled Stubs (3 tools)

These tools ship as compiled modules but return `enabled?() -> false` by default.

#### `notebook_read`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.NotebookRead` |
| Enabled | **false** |

#### `notebook_edit`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.NotebookEdit` |
| Enabled | **false** |

#### `computer`

| Field | Value |
|---|---|
| Module | `Synapsis.Tool.Computer` |
| Enabled | **false** |

---

## 5. Tool Inventory Summary

| # | Module | Name | Category | Permission | Side Effects | Enabled |
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
| 10 | Bash | `bash` | execution | `:execute` | — | yes |
| 11 | Fetch | `fetch` | web | `:read` | — | yes |
| 12 | WebSearch | `web_search` | web | `:read` | — | yes |
| 13 | TodoWrite | `todo_write` | planning | `:none` | — | yes |
| 14 | TodoRead | `todo_read` | planning | `:none` | — | yes |
| 15 | Task | `task` | orchestration | `:none` | — | **no** (stubbed) |
| 16 | ToolSearch | `tool_search` | orchestration | `:none` | — | yes |
| 17 | Skill | `skill` | orchestration | `:none` | — | yes |
| 18 | AskUser | `ask_user` | interaction | `:none` | — | yes |
| 19 | EnterPlanMode | `enter_plan_mode` | session | `:none` | — | yes |
| 20 | ExitPlanMode | `exit_plan_mode` | session | `:none` | — | yes |
| 21 | Sleep | `sleep` | session | `:none` | — | yes |
| 22 | SendMessage | `send_message` | swarm | `:none` | — | yes |
| 23 | Teammate | `teammate` | swarm | `:none` | — | yes |
| 24 | TeamDelete | `team_delete` | swarm | `:none` | — | yes |
| 25 | SessionSummarize | `session_summarize` | memory | `:none` | — | yes |
| 26 | MemorySave | `memory_save` | memory | `:write` | — | yes |
| 27 | MemorySearch | `memory_search` | memory | `:read` | — | yes |
| 28 | MemoryUpdate | `memory_update` | memory | `:write` | — | yes |
| 29 | Diagnostics | `diagnostics` | uncategorized | `:read` | — | yes |
| 30 | NotebookRead | `notebook_read` | notebook | `:read` | — | **no** |
| 31 | NotebookEdit | `notebook_edit` | notebook | `:write` | `[:file_changed]` | **no** |
| 32 | Computer | `computer` | computer | `:execute` | — | **no** |

**Total: 32 tools registered (28 enabled by default, 3 disabled stubs, 1 stubbed orchestration)**

---

## 6. Permission Model

### 6.1 Permission Levels

```
:none        — always available, no approval needed (planning, interaction, orchestration)
:read        — always allowed by default, can be restricted
:write       — requires session-level opt-in or per-call approval
:execute     — requires explicit session-level opt-in
:destructive — requires per-call approval by default
```

### 6.2 Session Permission Configuration

Each session has a permission configuration stored in `Synapsis.SessionPermission` (in `synapsis_data`):

```elixir
# Synapsis.Tool.Permission.SessionConfig struct
%Synapsis.Tool.Permission.SessionConfig{
  session_id: "uuid",
  mode: :interactive | :autonomous,
  allow_read: true,                    # always true
  allow_write: :allow | :deny | :ask,  # default: :allow
  allow_execute: :allow | :deny | :ask, # default: :ask
  allow_destructive: :allow | :deny | :ask, # default: :ask
  overrides: [
    %{tool: "bash", pattern: "git *", decision: :allowed},
    %{tool: "bash", pattern: "rm *", decision: :denied},
    %{tool: "file_write", pattern: "src/**", decision: :allowed}
  ]
}
```

### 6.3 Permission Resolution Order (3 steps)

1. **Per-tool glob overrides** — if a matching override exists in the session config, its decision wins immediately. Overrides match tool name + glob pattern against the tool's primary input field (e.g., `command` for bash, `path` for file tools, `pattern` for grep/glob).
2. **Permission level vs session config** — the tool's permission level is checked against the session's mode and allow_* settings.
3. **Default policy** — `:requires_approval`.

### 6.4 Autonomous Mode

In autonomous mode (`mode: :autonomous`), all tools at or below `:execute` level are auto-approved. `:destructive` tools follow the session's `allow_destructive` setting.

### 6.5 Plan Mode Restrictions

When `agent_mode` is `:plan`:
- Tools with permission level `:write`, `:execute`, `:destructive` are excluded from `list_for_llm/1`
- Only `:read` and `:none` tools are available
- The agent must call `exit_plan_mode` to return to `:build` mode

---

## 7. Side Effect System

### 7.1 Declared Side Effects

Tools declare side effects as static data via the `side_effects/0` callback:

```
:file_changed — a file was created, modified, moved, or deleted
```

### 7.2 Side Effect Propagation

```
Synapsis.Tool.Executor
  → tool executes successfully
  → reads module.side_effects()
  → broadcasts to PubSub topic "tool_effects:{session_id}"
  → message: {:tool_effect, :file_changed, %{session_id: session_id}}
```

Only module-based tools with non-empty `side_effects/0` trigger broadcasts. Process-based tools (plugins) do not automatically broadcast side effects.

---

## 8. Plugin Tool Integration

### 8.1 Plugin Tools

Plugin tools are dynamically registered into `Synapsis.Tool.Registry` via `register_process/3`. They follow the same execution pipeline as built-in tools but dispatch via `GenServer.call/3` instead of direct module invocation.

### 8.2 MCP Tools

MCP tools are discovered via MCP `tools/list` at plugin initialization. The `tool_search` built-in tool enables lazy loading — MCP tool definitions are not included in every LLM request by default.

### 8.3 Deferred Tool Loading

To avoid bloating LLM context with dozens of MCP tool definitions:

1. On session start, only built-in tools are included in `list_for_llm/1`
2. MCP/plugin tools are registered in the Registry but marked as `deferred: true`
3. The agent uses `tool_search` to discover relevant deferred tools
4. Once loaded via `mark_loaded/1`, deferred tools are included in subsequent `list_for_llm/1` calls

---

## 9. Agent Loop Integration

### 9.1 Graph-Based Agent Runner

The agent loop is implemented as a graph-based runner in `synapsis_agent`, not a simple sequential loop. Key nodes:

- `Synapsis.Agent.Nodes.ToolDispatch` — receives tool_use events from the LLM stream, dispatches to the executor
- `Synapsis.Agent.Nodes.ToolExecute` — executes tool calls and feeds results back
- `Synapsis.Agent.Nodes.Complete` — handles completion and response flushing

### 9.2 Tool Gathering

```elixir
Synapsis.Tool.Registry.list_for_llm(
  agent_mode: context.agent_mode,
  include_deferred: false
)
```

### 9.3 Tool Call Processing

The executor handles dispatch, persistence, and side effect broadcasting. Results are fed back into the graph runner for the next LLM iteration.

---

## 10. Data Persistence

### 10.1 Tool Calls

Tool calls are persisted in the `tool_calls` table:

```
tool_calls: id (UUID), message_id (nullable), session_id,
            tool_name, input (JSONB), output (JSONB),
            status (pending | completed | error),
            duration_ms, error_message, timestamps
```

Persistence happens in the executor after each tool call completes. Errors during persistence are logged but do not fail the tool call.

### 10.2 Session Permissions

```
session_permissions: id, session_id,
                     mode (interactive | autonomous),
                     allow_write (boolean),
                     allow_execute (boolean),
                     allow_destructive (enum: allow | deny | ask),
                     tool_overrides (JSONB),
                     timestamps
```

### 10.3 Todo Items

```
session_todos: id, session_id,
               content, status (pending | in_progress | completed),
               sort_order, timestamps
```

---

## 11. Resolved Decisions

1. **32 tools total** — 28 enabled by default, 3 disabled/future (notebook, computer), 1 stubbed (task). Comprehensive surface matching Claude Code while maintaining Elixir behaviour uniformity.

2. **Self-declared permissions** — tools declare `permission_level/0` instead of a centralized classification function. Co-locates the permission decision with the tool implementation.

3. **Ephemeral bash** — `bash` uses a fresh Port per command. State does NOT persist across calls. This differs from Claude Code's persistent bash session.

4. **Deferred tool loading** — MCP tools are not included in LLM context by default. The `tool_search` tool enables demand-driven loading.

5. **Plan mode is tool-based** — enter/exit plan mode are tools, not out-of-band commands.

6. **Todo is session-scoped** — todo lists are per-session, persisted in the database, and visible in the UI.

7. **Side effects remain data-only** — tools declare `[:file_changed]` statically. The executor broadcasts. No hook framework.

8. **Web tools are built-in** — `fetch` and `web_search` are core tools, not plugins.

9. **Sleep tool included** — enables polling workflows.

10. **Tool versioning** — all tools declare `version/0` returning a semver string. Built-in tools start at `"1.0.0"`.

11. **Parallel tool calls** — `Task.async_stream/3` for concurrent independent tool calls with file-level serialization.

12. **Swarm tools are built-in** — `send_message`, `teammate`, and `team_delete` are core tools for within-session multi-agent coordination.

13. **Memory tools** — `memory_save`, `memory_search`, `memory_update`, and `session_summarize` support persistent session memory.

14. **file_edit uses old_string/new_string** — parameter names are `old_string` and `new_string` (not `old_text`/`new_text`).

15. **grep uses include for filtering** — the glob filter parameter is named `include` (not `glob`).

16. **Tool name is fetch, not web_fetch** — the web page fetching tool is registered as `fetch`.

---

## 12. Open Questions

None. All previously open questions have been resolved as decisions above.
