# Synapsis Tools System — Product Requirements Document

## 1. Executive Summary

Synapsis is an AI coding agent designed to replace Claude Code, OpenCode, and similar CLI-based agentic coding tools. This PRD specifies the complete tool system — the set of capabilities the agent can invoke during a coding session. The tool system is the agent's interface to the real world: every file read, every shell command, every user interaction is a tool call.

The tool system lives in `apps/synapsis_tool/` as a dedicated sub-application within the Synapsis umbrella. This separation isolates tool behaviour contracts, the tool registry, the executor pipeline, permission engine, and all built-in tool modules from the agent loop (`synapsis_core`) and the plugin host (`synapsis_plugin`). Both `synapsis_core` and `synapsis_plugin` depend on `synapsis_tool`.

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
- Competitive gap analysis against Claude Code, OpenCode, and Codex CLI

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

Synapsis targets feature parity with Claude Code's tool surface while maintaining architectural clarity through the Elixir behaviour system. Where Claude Code and OpenCode blur the line between "tool" and "agent mode," Synapsis treats everything as a tool with a uniform `SynapsisTool` behaviour contract. All tool infrastructure lives in `apps/synapsis_tool/`, a dedicated sub-application that both `synapsis_core` (agent loop) and `synapsis_plugin` (MCP/LSP) depend on.

---

## 3. Architecture

### 3.1 Layers

```
┌─────────────────────────────────────────────────────┐
│                    Agent Loop                        │
│  (synapsis_core — Synapsis.Agent.Loop)              │
│                                                      │
│  Gathers tools → builds LLM request → processes     │
│  tool_use events → feeds results back to LLM        │
├─────────────────────────────────────────────────────┤
│                  Tool Executor                       │
│  (synapsis_tool — SynapsisTool.Executor)            │
│                                                      │
│  Permission check → dispatch → side effect broadcast │
├──────────────────────┬──────────────────────────────┤
│   Tool Registry      │   Permission Engine          │
│   (GenServer)        │   (SynapsisTool.Permissions) │
│                      │                              │
│   name → {type,      │   tool → level → session     │
│           module/pid} │   config → allow/deny/ask    │
├──────────────────────┴──────────────────────────────┤
│                    Tool Modules                      │
│                                                      │
│  Built-in (synapsis_tool)    Plugin (synapsis_plugin)│
│  ├── Filesystem              ├── MCP tools           │
│  ├── Execution               ├── LSP tools           │
│  ├── Search                  └── Custom plugins      │
│  ├── Web                                             │
│  ├── Planning                                        │
│  ├── Orchestration                                   │
│  ├── User Interaction                                │
│  └── Session Control                                 │
└─────────────────────────────────────────────────────┘
```

### 3.2 Tool Behaviour Contract

```elixir
defmodule SynapsisTool do
  @moduledoc """
  Behaviour contract for all tools in the Synapsis agent system.
  Lives in apps/synapsis_tool/.
  """

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

Changes from the existing design doc:

- Added `permission_level/0` callback — tools self-declare their risk level instead of a centralized pattern-match function. Keeps classification co-located with the tool.
- Added `category/0` callback — enables UI grouping and selective tool loading.
- Added `version/0` callback — tools declare a semantic version string. Required for MCP compatibility and future tool evolution. Built-in tools start at `"1.0.0"`. The registry includes version in tool definitions sent to the LLM.
- Added `enabled?/0` callback — tools can be compiled but disabled by default. The registry skips disabled tools in `list_for_llm/1`. Used for future/experimental tools (notebook, computer use) that ship as code but are not activated until configuration enables them.
- Extended `context` with `agent_mode`, `session_pid`, and `parent_agent` — required for orchestration tools and mode-aware behaviour.

### 3.3 Tool Registry

```elixir
defmodule SynapsisTool.Registry do
  use GenServer

  @type registration :: {:module, module()} | {:process, pid(), module()}

  def register(name, registration, opts \\ %{})
  def unregister(name)
  def lookup(name) :: {:ok, registration()} | :error
  def list() :: [%{name: String.t(), description: String.t(), parameters: map()}]
  def list_for_llm(opts \\ []) :: [map()]
  def list_by_category(category) :: [map()]
  def available_for_session(session_id) :: [map()]
end
```

`list_for_llm/1` accepts options for filtering (by category, by permission level, by agent mode). In plan mode, write/execute tools are excluded. Sub-agents receive a scoped tool list based on their declared `tools` allowlist.

### 3.4 Tool Executor Pipeline

```
tool_call from LLM
  │
  ▼
┌─ ToolExecutor.execute/2 ─────────────────────────┐
│                                                    │
│  1. Registry lookup (tool exists?)                 │
│  2. Permission check                               │
│     ├─ :allowed → proceed                          │
│     ├─ :ask → broadcast tool_permission event,     │
│     │         block until user responds             │
│     └─ :denied → return {:error, :permission_denied}│
│  3. Dispatch                                        │
│     ├─ {:module, mod} → mod.execute(input, ctx)    │
│     └─ {:process, pid} → GenServer.call(pid, ...)  │
│  4. Result handling                                 │
│     ├─ {:ok, result} → log, broadcast side effects │
│     └─ {:error, reason} → log, return error        │
│  5. Side effect broadcast                           │
│     └─ PubSub "tool_effects:{session_id}"          │
│                                                    │
└────────────────────────────────────────────────────┘
```

### 3.5 Parallel Tool Execution

When the LLM returns multiple independent tool calls in a single response, the executor runs them concurrently using `Task.async_stream/3`. This matches Claude Code's behaviour and significantly reduces latency for common patterns like reading multiple files in parallel.

```elixir
defmodule SynapsisTool.Executor do
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
- Tools with side effects (`:file_changed`) that target the same file are serialized to prevent write conflicts.
- Permission checks (`ask` approval) are batched — all pending approvals are presented to the user simultaneously.
- Sub-agent tools (`task`) are not parallelized with other tools in the same batch.

### 3.6 Umbrella Placement and Dependency Direction

`synapsis_tool` is a sub-application at `apps/synapsis_tool/` in the Synapsis umbrella. It owns:

- `SynapsisTool` behaviour contract
- `SynapsisTool.Registry` (GenServer)
- `SynapsisTool.Executor` (pipeline + parallel dispatch)
- `SynapsisTool.Permissions` (permission engine)
- `SynapsisTool.Tools.*` (all 27 built-in tool modules)

```
apps/
  synapsis_data/        # Ecto schemas, PostgreSQL persistence
  synapsis_tool/        # Tool behaviour, registry, executor, built-in tools ← THIS PRD
  synapsis_core/        # Agent loop, session management, domain logic
  synapsis_plugin/      # MCP/LSP plugin host, dynamic tool registration
  synapsis_provider/    # LLM translation boundary (req_llm)
  synapsis_server/      # Phoenix Endpoint, Channels, REST
  synapsis_web/         # Phoenix LiveView UI + React hooks
```

**Dependency direction:**

```
synapsis_data ← synapsis_tool ← synapsis_core ← synapsis_server ← synapsis_web
                      ↑
               synapsis_plugin
```

- `synapsis_tool` depends on `synapsis_data` (for permission configs, tool call persistence)
- `synapsis_core` depends on `synapsis_tool` (agent loop calls `SynapsisTool.Registry.list_for_llm/1` and `SynapsisTool.Executor.execute/2`)
- `synapsis_plugin` depends on `synapsis_tool` (registers plugin tools into `SynapsisTool.Registry`, implements `SynapsisTool` behaviour)
- `synapsis_tool` has zero knowledge of `synapsis_core`, `synapsis_plugin`, `synapsis_server`, or `synapsis_web`

On application start, `synapsis_tool` registers all built-in tools. `synapsis_plugin` registers/unregisters plugin tools dynamically at session lifecycle boundaries.

---

## 4. Complete Tool Inventory

### 4.1 Filesystem Tools (7 tools)

#### `file_read`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.FileRead` |
| Permission | `:read` |
| Side Effects | none |
| Description | Read file contents with optional line range. Supports text files, images (returns base64), PDFs (page range), and Jupyter notebooks (all cells with outputs). |

Parameters:
- `path` (required, string) — file path relative to project root
- `offset` (optional, integer) — start line (0-indexed)
- `limit` (optional, integer) — number of lines to return
- `pages` (optional, string) — for PDFs, e.g. "1-5" (max 20 pages per request)

Notes: The agent must read a file before editing it. Multiple reads should be batched in parallel. For large files (>500 lines), encourage use of offset/limit.

#### `file_write`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.FileWrite` |
| Permission | `:write` |
| Side Effects | `[:file_changed]` |
| Description | Create a new file or overwrite an existing file with the provided content. |

Parameters:
- `path` (required, string) — file path relative to project root
- `content` (required, string) — full file content

Notes: Creates parent directories if they don't exist. Use `file_edit` for modifying existing files to minimize token usage.

#### `file_edit`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.FileEdit` |
| Permission | `:write` |
| Side Effects | `[:file_changed]` |
| Description | Apply a targeted edit by replacing an exact string match. The old_text must appear exactly once in the file. |

Parameters:
- `path` (required, string)
- `old_text` (required, string) — exact text to find (must be unique)
- `new_text` (required, string) — replacement text

Notes: Fails if old_text matches zero or multiple locations. This is the primary edit tool — prefer over `file_write` for existing files.

#### `multi_edit`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.MultiEdit` |
| Permission | `:write` |
| Side Effects | `[:file_changed]` |
| Description | Apply multiple edits to one or more files in a single tool call. Each edit is an exact string replacement. Edits are applied sequentially within each file. |

Parameters:
- `edits` (required, array of objects) — each with:
  - `path` (required, string)
  - `old_text` (required, string)
  - `new_text` (required, string)

Notes: All edits within a file are applied in order. If any edit fails, the entire operation is rolled back for that file. Cross-file edits are independent (partial success is possible). This addresses the common pattern of renaming a symbol across multiple files.

#### `file_delete`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.FileDelete` |
| Permission | `:destructive` |
| Side Effects | `[:file_changed]` |
| Description | Delete a file or empty directory. |

Parameters:
- `path` (required, string)

Notes: Refuses to delete non-empty directories unless `recursive: true` is passed. First-class tool rather than routing through bash — enables proper permission gating.

#### `file_move`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.FileMove` |
| Permission | `:write` |
| Side Effects | `[:file_changed]` |
| Description | Move or rename a file or directory. |

Parameters:
- `source` (required, string)
- `destination` (required, string)

Notes: Creates destination parent directories if needed.

#### `list_dir`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.ListDir` |
| Permission | `:read` |
| Side Effects | none |
| Description | List directory contents with optional depth control. Returns file names, types, and sizes. Respects .gitignore by default. |

Parameters:
- `path` (required, string)
- `depth` (optional, integer, default: 1) — max depth for recursive listing
- `include_hidden` (optional, boolean, default: false)
- `ignore_gitignore` (optional, boolean, default: false)

### 4.2 Search Tools (2 tools)

#### `grep`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.Grep` |
| Permission | `:read` |
| Side Effects | none |
| Description | Recursive text/regex search across files. Powered by ripgrep internally. Respects .gitignore. |

Parameters:
- `pattern` (required, string) — search pattern (regex supported)
- `path` (optional, string, default: project root) — directory to search
- `glob` (optional, string) — filter files by glob pattern, e.g. "*.ex"
- `type` (optional, string) — filter by file type, e.g. "elixir", "typescript"
- `output_mode` (optional, enum: "content" | "files" | "count", default: "content")
- `context_lines` (optional, integer, default: 0) — lines of context before/after match

#### `glob`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.Glob` |
| Permission | `:read` |
| Side Effects | none |
| Description | Find files matching a glob pattern. Returns paths sorted by modification time (newest first). |

Parameters:
- `pattern` (required, string) — glob pattern, e.g. "**/*.test.ts"
- `path` (optional, string, default: project root)

### 4.3 Execution Tools (1 tool)

#### `bash_exec`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.BashExec` |
| Permission | `:execute` |
| Side Effects | none (side effects are unpredictable for shell commands) |
| Description | Execute a shell command in a persistent bash session. The session maintains state (env vars, cwd) across calls within the same agent session. |

Parameters:
- `command` (required, string) — shell command to execute
- `timeout` (optional, integer, default: 30000) — timeout in milliseconds
- `working_dir` (optional, string) — override working directory for this command

Notes: The persistent session is implemented as a Port with a long-running bash process. State (env vars, aliases, cwd) persists across calls. The agent should prefer built-in tools (grep, glob, list_dir) over bash equivalents (rg, find, ls) for permission efficiency. Commands that modify files do NOT emit `:file_changed` side effects — only built-in file tools do, since bash commands are opaque.

### 4.4 Web Tools (2 tools)

#### `web_fetch`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.WebFetch` |
| Permission | `:read` |
| Side Effects | none |
| Description | Fetch the content of a web page at a given URL. Returns the page text content. Useful for reading documentation, API references, and online resources. |

Parameters:
- `url` (required, string) — full URL including scheme
- `max_tokens` (optional, integer, default: 10000) — truncate response to approximately this many tokens

Notes: Does not execute JavaScript. Returns text content extracted from HTML. Cannot access content behind authentication.

#### `web_search`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.WebSearch` |
| Permission | `:read` |
| Side Effects | none |
| Description | Search the web and return results with titles, URLs, and snippets. Use for finding documentation, current information, or researching unfamiliar APIs. |

Parameters:
- `query` (required, string) — search query (1-6 words for best results)
- `max_results` (optional, integer, default: 5)

Notes: Results include title, URL, and snippet. The agent should use `web_fetch` on specific result URLs to get full content. Today's date should be included in time-sensitive queries.

### 4.5 Planning Tools (2 tools)

#### `todo_write`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.TodoWrite` |
| Permission | `:none` |
| Side Effects | none |
| Description | Create and manage a task checklist for the current session. The todo list is displayed in the UI and helps the agent track multi-step work. Each item has a status: pending, in_progress, or completed. |

Parameters:
- `todos` (required, array of objects) — each with:
  - `id` (required, string) — stable identifier
  - `content` (required, string) — task description
  - `status` (required, enum: "pending" | "in_progress" | "completed")

Notes: Each call replaces the entire todo list (not a delta). The agent should update todo status as it progresses through tasks. Displayed in the UI via PubSub broadcast to the session channel. This tool has no permission requirement — it is always available, including to sub-agents. Equivalent to Claude Code's TodoWrite.

#### `todo_read`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.TodoRead` |
| Permission | `:none` |
| Side Effects | none |
| Description | Read the current todo list state. Used by the agent to check what tasks are pending or completed. |

Parameters: none

Notes: Returns the current todo list as set by the most recent `todo_write` call. Disabled for sub-agents by default (sub-agents manage their own scope). Equivalent to Claude Code's TodoRead (implicit in TodoWrite) and OpenCode's todoread.

### 4.6 Orchestration Tools (3 tools)

#### `task`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.Task` |
| Permission | `:none` |
| Side Effects | none |
| Description | Launch a sub-agent to autonomously handle a complex, multi-step task. The sub-agent runs in the same session with a scoped tool set and its own conversation context. Can run in foreground (blocks until complete) or background (returns immediately with a task ID). |

Parameters:
- `prompt` (required, string) — detailed instructions for the sub-agent
- `tools` (optional, array of strings) — tool allowlist for the sub-agent. Defaults to read-only tools: ["file_read", "list_dir", "grep", "glob"]
- `mode` (optional, enum: "foreground" | "background", default: "foreground")
- `model` (optional, string) — override model for cost optimization (e.g. use a faster model for search tasks)

Notes: Sub-agents inherit the session context (project path, working directory) but have their own conversation history. Background tasks run in a separate process and notify on completion via PubSub. Sub-agents cannot use `ask_user` or `enter_plan_mode` — only the primary agent can interact with the user. The `tools` parameter prevents sub-agents from accessing destructive operations unless explicitly granted. Equivalent to Claude Code's Task/Agent tool.

#### `tool_search`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.ToolSearch` |
| Permission | `:none` |
| Side Effects | none |
| Description | Search for and load deferred tools by keyword. MCP tools and other dynamically available tools are not loaded into context by default to save tokens. Use this tool to discover and activate them. |

Parameters:
- `query` (required, string) — search keywords
- `limit` (optional, integer, default: 5)

Notes: Returns tool names, descriptions, and parameter schemas. Once a deferred tool is loaded via tool_search, it becomes available for the remainder of the session. This prevents bloating the LLM context with tool definitions for MCP servers that expose dozens of tools. Equivalent to Claude Code's ToolSearch.

#### `skill`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.Skill` |
| Permission | `:none` |
| Side Effects | none |
| Description | Load a skill (a SKILL.md file) and inject its instructions into the current conversation. Skills provide domain-specific expertise, coding patterns, and workflow guidance. |

Parameters:
- `name` (required, string) — skill name to load

Notes: Skills are discovered from project-local (`.synapsis/skills/`), user-global (`~/.config/synapsis/skills/`), and built-in locations. Each skill has a SKILL.md with frontmatter (name, description, tools, model) and markdown body. Loading a skill adds its content as a system message in the conversation. The agent can then follow the skill's instructions. Equivalent to Claude Code's Skill tool and OpenCode's skill tool.

### 4.7 User Interaction Tools (1 tool)

#### `ask_user`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.AskUser` |
| Permission | `:none` |
| Side Effects | none |
| Description | Present structured questions to the user with selectable options. Use when the agent encounters ambiguity, needs to clarify requirements, or wants to offer implementation choices. |

Parameters:
- `questions` (required, array of objects) — each with:
  - `question` (required, string) — the question text
  - `options` (required, array of objects) — each with:
    - `label` (required, string) — option text
    - `description` (optional, string) — additional context
  - `multi_select` (optional, boolean, default: false) — allow multiple selections

Notes: Users can always provide free-text input instead of selecting an option. This tool blocks until the user responds. It is broadcast through the session channel as a `tool_permission` event variant. Sub-agents cannot use this tool — only the primary agent can interact with the user. If the recommended option is clear, place it first and append "(Recommended)" to the label. Equivalent to Claude Code's AskUserQuestion.

### 4.8 Session Control Tools (2 tools)

#### `enter_plan_mode`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.EnterPlanMode` |
| Permission | `:none` |
| Side Effects | none |
| Description | Switch to plan mode. In plan mode, the agent explores the codebase and builds a plan without making changes. Write/execute tools are disabled. The agent uses ask_user to clarify requirements before finalizing the plan. |

Parameters: none

Notes: Calling this tool updates the session's `agent_mode` to `:plan`. The ToolRegistry filters out write/execute tools when `agent_mode` is `:plan`. The UI reflects the mode change. Equivalent to Claude Code's EnterPlanMode.

#### `exit_plan_mode`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.ExitPlanMode` |
| Permission | `:none` |
| Side Effects | none |
| Description | Exit plan mode and present the plan to the user for approval. The plan is displayed in the UI. If approved, the agent proceeds to execute with full tool access. |

Parameters:
- `plan` (required, string) — the finalized plan in markdown format

Notes: The plan is broadcast to the session channel for UI display. The user can approve, reject, or provide feedback. On approval, `agent_mode` returns to `:build` and all tools become available again. Equivalent to Claude Code's ExitPlanMode.

### 4.9 Utility Tools (1 tool)

#### `sleep`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.Sleep` |
| Permission | `:none` |
| Side Effects | none |
| Description | Wait for a specified duration or until the user provides input. Useful for polling-style workflows or waiting for external processes to complete. |

Parameters:
- `duration_ms` (required, integer) — maximum wait time in milliseconds
- `reason` (optional, string) — displayed to user explaining the wait

Notes: The sleep is interruptible — if the user sends a message, the sleep ends early and the agent receives the message. Implemented as a `receive` with timeout in the agent loop process. Equivalent to Claude Code's Sleep tool.

### 4.10 Notebook Tools (2 tools, disabled by default)

These tools ship as compiled modules but return `enabled?() -> false` by default. Enable via session or project configuration when Jupyter workflow support is needed.

#### `notebook_read`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.NotebookRead` |
| Permission | `:read` |
| Side Effects | none |
| Enabled | `false` (opt-in via config) |
| Description | Read a Jupyter notebook (.ipynb) file and return all cells with their outputs — code, markdown, and visualizations. |

Parameters:
- `path` (required, string) — path to .ipynb file

Notes: Disabled by default. Enable with `notebook_tools: true` in session or project config. Returns cells as structured data with cell type, source, and outputs. Equivalent to Claude Code's NotebookRead (bundled into Read tool).

#### `notebook_edit`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.NotebookEdit` |
| Permission | `:write` |
| Side Effects | `[:file_changed]` |
| Enabled | `false` (opt-in via config) |
| Description | Replace the contents of a specific cell in a Jupyter notebook, or insert a new cell at a given position. |

Parameters:
- `path` (required, string) — path to .ipynb file
- `cell_number` (required, integer) — 0-indexed cell position
- `content` (required, string) — new cell source content
- `cell_type` (optional, enum: "code" | "markdown", default: "code")
- `edit_mode` (optional, enum: "replace" | "insert", default: "replace")

Notes: Disabled by default. When `edit_mode` is "insert", a new cell is created at the specified position. Equivalent to Claude Code's NotebookEdit.

### 4.11 Computer Use Tools (1 tool, disabled by default)

Ships as a compiled module but returns `enabled?() -> false` by default. Enable when browser automation or visual verification is needed. Intended for future integration with Claude's computer use API or local browser automation.

#### `computer`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.Computer` |
| Permission | `:execute` |
| Side Effects | none |
| Enabled | `false` (opt-in via config) |
| Description | Interact with a desktop environment or browser for visual verification, screenshot capture, and UI testing. Delegates to the Anthropic computer use API or a configured browser automation backend. |

Parameters:
- `action` (required, enum: "screenshot" | "click" | "type" | "scroll" | "key" | "navigate")
- `coordinate` (optional, array of [x, y]) — for click/type actions
- `text` (optional, string) — for type action
- `key` (optional, string) — for key action
- `url` (optional, string) — for navigate action

Notes: Disabled by default. Enable with `computer_use: true` in session config. The backend is configurable — can delegate to Anthropic's computer use API, Puppeteer MCP, or a local Playwright instance. Equivalent to Claude Code's Computer tool (used in Chrome extension). Implementation is deferred; the behaviour contract and tool definition are reserved now for forward compatibility.

### 4.12 Swarm Tools (3 tools)

Multi-agent coordination tools for swarm-style parallel workflows. These enable agents to form teams, delegate to teammates, and communicate via structured message passing. Maps to Claude Code's experimental swarm system.

#### `send_message`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.SendMessage` |
| Permission | `:none` |
| Side Effects | none |
| Description | Send a structured message to a teammate agent in the current swarm. Used for inter-agent communication, delegation, and protocol request/response patterns. |

Parameters:
- `to` (required, string) — teammate agent identifier
- `content` (required, string) — message content
- `type` (optional, enum: "request" | "response" | "notify", default: "notify")
- `in_reply_to` (optional, string) — message ID this responds to

Notes: Messages are routed via PubSub through the swarm coordinator process. Only available when the session is part of a swarm (has a `swarm_id` in context). The receiving agent sees the message as a system injection in its next LLM iteration. Equivalent to Claude Code's SendMessageTool.

#### `teammate`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.Teammate` |
| Permission | `:none` |
| Side Effects | none |
| Description | Create, configure, or query teammate agents in the current swarm. Manages the swarm roster and agent capabilities. |

Parameters:
- `action` (required, enum: "create" | "list" | "get" | "update")
- `name` (optional, string) — teammate name (for create/get/update)
- `prompt` (optional, string) — system prompt for the teammate (for create/update)
- `tools` (optional, array of strings) — tool allowlist for the teammate
- `model` (optional, string) — model override for the teammate

Notes: Created teammates are spawned as separate agent loop processes, each with their own conversation history and tool set. Teammates share the project workspace but can be isolated to separate git worktrees. Only the swarm coordinator (primary agent) should create teammates. Equivalent to Claude Code's TeammateTool.

#### `team_delete`

| Field | Value |
|---|---|
| Module | `SynapsisTool.Tools.TeamDelete` |
| Permission | `:none` |
| Side Effects | none |
| Description | Dissolve the current swarm and terminate all teammate agents. |

Parameters: none (or `team_id` if multiple swarms are supported)

Notes: Terminates all teammate processes, collects their final outputs, and returns a summary. The primary agent's session continues after the swarm is dissolved. Equivalent to Claude Code's TeamDelete.

---

## 5. Tool Inventory Summary

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

Each session has a permission configuration stored in `synapsis_data`:

```elixir
%{
  mode: :interactive | :autonomous,
  
  # Level-based defaults
  allow_write: true,
  allow_execute: true,
  allow_destructive: :ask,  # :allow | :deny | :ask
  
  # Per-tool overrides (glob patterns supported)
  tool_overrides: %{
    "bash_exec" => :ask,
    "bash_exec(git *)" => :allow,
    "bash_exec(rm *)" => :deny,
    "file_write(src/**)" => :allow,
    "file_write(production.*)" => :deny
  }
}
```

### 6.3 Permission Resolution Order

1. Per-tool override (most specific glob match wins)
2. Permission level default for the session
3. Tool's declared `permission_level/0`

### 6.4 Autonomous Mode

In autonomous mode (`mode: :autonomous`), the agent does not pause for user approval. All tools at or below `:execute` level are auto-approved. `:destructive` tools follow the session's `allow_destructive` setting. This is the mode used for background/headless sessions where multiple Claude Code agents work in parallel via git worktrees.

### 6.5 Plan Mode Restrictions

When `agent_mode` is `:plan`:

- Tools with permission level `:write`, `:execute`, `:destructive` are excluded from `list_for_llm/1`
- Only `:read` and `:none` tools are available
- The agent can use `ask_user` to clarify requirements
- The agent must call `exit_plan_mode` to present a plan and return to `:build` mode

---

## 7. Side Effect System

### 7.1 Declared Side Effects

Tools declare side effects as static data via the `side_effects/0` callback:

```
:file_changed — a file was created, modified, moved, or deleted
```

Future side effects (not in initial implementation):

```
:dependency_changed — package.json, mix.exs, etc. was modified
:config_changed — configuration file was modified
:test_failed — a test execution produced failures
```

### 7.2 Side Effect Propagation

```
ToolExecutor
  → tool executes successfully
  → reads tool.side_effects()
  → broadcasts to PubSub topic "tool_effects:{session_id}"
  → message: {:tool_effect, :file_changed, %{tool: name, input: input, result: result}}

Subscribers:
  → SynapsisPlugin.Server (LSP) — sends didChange, collects diagnostics
  → SynapsisPlugin.Server (MCP) — any interested MCP servers
  → SessionChannel — UI notifications (file tree refresh, etc.)
```

### 7.3 Diagnostic Injection

When an LSP plugin receives a `:file_changed` effect and produces diagnostics:

**Passive mode** (default for interactive sessions): Diagnostics are broadcast to the session channel for UI display only.

**Active mode** (default for autonomous sessions): Diagnostics are injected as a system message into the session context. The agent sees them before its next LLM request and can self-correct.

---

## 8. Plugin Tool Integration

### 8.1 Plugin Tools via synapsis_plugin

Plugin tools are dynamically registered into `SynapsisTool.Registry` by `SynapsisPlugin.Server` processes. They follow the same execution pipeline as built-in tools but dispatch via `GenServer.call/3` instead of direct module invocation.

### 8.2 MCP Tools

MCP tools are namespaced with `mcp_` prefix. They are discovered via MCP `tools/list` at plugin initialization. The `tool_search` built-in tool enables lazy loading — MCP tool definitions are not included in every LLM request by default.

### 8.3 LSP Tools

LSP tools are namespaced with `lsp_` prefix. They expose a fixed set of operations:

- `lsp_diagnostics` — get diagnostics for a file
- `lsp_definition` — go to definition (accepts symbol name, not line:col)
- `lsp_references` — find all references to a symbol
- `lsp_hover` — get type/doc info for a symbol
- `lsp_symbols` — list symbols in a file or workspace

The decision to accept symbol names instead of line:column positions is a key design choice — LLMs are unreliable with exact positions, so the plugin resolves positions internally by searching the file for the symbol name.

### 8.4 Deferred Tool Loading

To avoid bloating LLM context with dozens of MCP tool definitions:

1. On session start, only built-in tools are included in `list_for_llm/1`
2. MCP/plugin tools are registered in the ToolRegistry but marked as `deferred: true`
3. The agent uses `tool_search` to discover relevant deferred tools
4. Once loaded, deferred tools are included in subsequent `list_for_llm/1` calls for the session

---

## 9. Agent Loop Integration

### 9.1 Tool Gathering

```elixir
def gather_tools(session, context) do
  SynapsisTool.Registry.list_for_llm(
    agent_mode: context.agent_mode,
    session_id: session.id,
    include_deferred: false  # only loaded tools
  )
end
```

### 9.2 Tool Call Processing

```elixir
case event do
  {:tool_use, %{name: name, id: id, input: input}} ->
    tool_call = %{name: name, id: id, input: input}
    
    broadcast_tool_use(session.id, tool_call)
    
    case SynapsisTool.Executor.execute(tool_call, context) do
      {:ok, result} ->
        broadcast_tool_result(session.id, id, result)
        {:cont, append_tool_result(context, id, result)}
      
      {:error, :permission_denied} ->
        broadcast_tool_result(session.id, id, %{error: "Permission denied"})
        {:cont, append_tool_result(context, id, %{error: "Permission denied"})}
      
      {:pending_approval, ref} ->
        # Block until approval via channel
        receive do
          {:tool_approved, ^ref} ->
            result = SynapsisTool.Executor.execute_approved(tool_call, context)
            broadcast_tool_result(session.id, id, result)
            {:cont, append_tool_result(context, id, result)}
          
          {:tool_denied, ^ref} ->
            broadcast_tool_result(session.id, id, %{error: "User denied"})
            {:cont, append_tool_result(context, id, %{error: "User denied tool use"})}
        end
    end
end
```

### 9.3 Sub-Agent Execution

The `task` tool launches a sub-agent by spawning a new agent loop process:

```elixir
defmodule SynapsisTool.Tools.Task do
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
        # Synchronous — blocks until sub-agent completes
        Synapsis.Agent.SubAgent.run(prompt, tools, sub_context)
      
      "background" ->
        # Async — returns task_id immediately
        {:ok, task_id} = Synapsis.Agent.SubAgent.start_background(prompt, tools, sub_context)
        {:ok, %{task_id: task_id, status: "running"}}
    end
  end
end
```

---

## 10. UI Integration

### 10.1 Channel Events for Tools

All tool activity flows through `SessionChannel` to the React chat UI:

```
← broadcast("tool_use", %{id, name, input})           # tool call started
← broadcast("tool_result", %{id, output, status})      # tool call completed
← broadcast("tool_permission", %{id, name, input,      # approval needed
                                  questions: [...]})
← broadcast("todo_update", %{todos: [...]})             # todo list changed
← broadcast("plan_submitted", %{plan: "..."})           # plan mode exit
← broadcast("task_status", %{task_id, status, result})  # background task update
```

### 10.2 React Components for Tools

The `@synapsis/ui` package includes components for rendering tool interactions:

- `ToolCallCard` — displays tool name, input, approve/deny buttons
- `ToolResultCard` — displays tool output (formatted per tool type)
- `AskUserCard` — renders structured questions with selectable options
- `TodoList` — displays the current todo checklist with status indicators
- `PlanView` — displays a submitted plan with approve/reject/feedback controls
- `DiffViewer` — renders file edit diffs (for file_edit, multi_edit results)
- `TerminalOutput` — renders bash_exec output with ANSI support

---

## 11. Data Model

### 11.1 Tool Calls in synapsis_data

Tool calls are persisted as part of the message history:

```
tool_calls: id (ULID), message_id, session_id,
            tool_name, input (JSONB), output (JSONB),
            status (pending | approved | denied | completed | error),
            duration_ms, timestamps
```

### 11.2 Session Permissions

```
session_permissions: id, session_id,
                     mode (interactive | autonomous),
                     allow_write (boolean),
                     allow_execute (boolean),
                     allow_destructive (enum: allow | deny | ask),
                     tool_overrides (JSONB),
                     timestamps
```

### 11.3 Todo Items

```
session_todos: id, session_id,
               content, status (pending | in_progress | completed),
               sort_order, timestamps
```

---

## 12. Differences from Existing Design Document

This PRD extends `plugin-and-tools-design.md` with the following additions:

1. **18 new built-in tools** — multi_edit, web_fetch, web_search, todo_write, todo_read, task, tool_search, skill, ask_user, enter_plan_mode, exit_plan_mode, sleep, notebook_read, notebook_edit, computer, send_message, teammate, team_delete
2. **Self-declared permission levels** — tools declare their own level via `permission_level/0` callback instead of a centralized pattern-match
3. **Category system** — `category/0` callback for UI grouping and selective loading
4. **Tool versioning** — `version/0` callback returning semver strings for MCP compatibility
5. **Enabled flag** — `enabled?/0` callback for tools that ship disabled (notebook, computer use)
6. **Deferred tool loading** — `tool_search` for lazy-loading MCP tools
7. **Plan mode integration** — mode-aware tool filtering in the registry
8. **Session permission model** — glob-pattern tool overrides, autonomous mode
9. **Persistent bash sessions** — bash_exec uses a long-running Port, not one-shot commands
10. **Background sub-agents** — task tool supports foreground and background execution
11. **Parallel tool execution** — `Task.async_stream/3` for concurrent independent tool calls
12. **Swarm tools** — send_message, teammate, team_delete for within-session multi-agent coordination
13. **Extended context** — agent_mode, session_pid, parent_agent in tool context

---

## 13. Implementation Phases

### Phase 1: Core Filesystem + Search + Execution

- file_read, file_write, file_edit, file_delete, file_move, list_dir
- grep, glob
- bash_exec (persistent session)
- Tool behaviour, ToolRegistry, ToolExecutor, Permission engine
- Side effect system with PubSub broadcasting

**Deliverable:** Agent can navigate, read, edit, and execute commands against a codebase.

### Phase 2: Planning + User Interaction

- todo_write, todo_read
- ask_user
- enter_plan_mode, exit_plan_mode
- Plan mode tool filtering in registry
- Session permission configuration

**Deliverable:** Agent supports plan-then-execute workflows with user interaction.

### Phase 3: Orchestration + Web

- task (foreground sub-agents)
- web_fetch, web_search
- skill
- multi_edit

**Deliverable:** Agent can launch sub-agents, search the web, and load skills.

### Phase 4: Advanced Features

- task (background sub-agents with notifications)
- tool_search (deferred tool loading)
- sleep
- Plugin tool integration (MCP/LSP via synapsis_plugin)
- Autonomous mode support
- Parallel tool execution (Task.async_stream)

**Deliverable:** Full tool parity with Claude Code. Ready for multi-agent autonomous workflows.

### Phase 5: Swarm + Future Tools

- send_message, teammate, team_delete (swarm coordination)
- Swarm coordinator process in synapsis_core (tool modules in synapsis_tool)
- Git worktree isolation per teammate agent
- notebook_read, notebook_edit (disabled by default, API reserved)
- computer (disabled by default, API reserved)
- Tool versioning in registry and LLM definitions

**Deliverable:** Multi-agent swarm support within a single Synapsis instance. Notebook and computer use APIs reserved for future activation.

---

## 14. Resolved Decisions

1. **27 tools total** — 21 enabled by default, 3 disabled/future (notebook, computer), 3 swarm tools. Comprehensive surface matching Claude Code while maintaining Elixir behaviour uniformity.

2. **Self-declared permissions** — tools declare `permission_level/0` instead of a centralized classification function. Co-locates the permission decision with the tool implementation.

3. **Persistent bash sessions** — bash_exec maintains a long-running Port process per session. State (env, cwd) persists across calls. Matches Claude Code and OpenCode behaviour.

4. **Deferred tool loading** — MCP tools are not included in LLM context by default. The `tool_search` tool enables demand-driven loading. Prevents context bloat with large MCP server tool sets.

5. **Plan mode is tool-based** — enter/exit plan mode are tools, not out-of-band commands. The LLM decides when to enter plan mode based on task complexity.

6. **Sub-agents cannot interact with users** — `ask_user` is restricted to the primary agent. Sub-agents that encounter ambiguity must make reasonable decisions or return to the parent with questions.

7. **Todo is session-scoped** — todo lists are per-session, persisted in the database, and visible in the UI. Sub-agents get independent todo state.

8. **Side effects remain data-only** — no change from existing design. Tools declare `[:file_changed]` statically. The executor broadcasts. No hook framework.

9. **Web tools are built-in** — web_fetch and web_search are core tools, not plugins. They are essential for documentation lookup and are available in every session.

10. **Sleep tool included** — enables polling workflows and prevents busy-waiting in autonomous sessions. The early-wake-on-user-input pattern is implemented via selective receive.

11. **Tool versioning** — all tools declare `version/0` returning a semver string. Built-in tools start at `"1.0.0"`. The registry includes version in tool definitions. This is required for MCP compatibility (MCP tools carry version from their server) and enables future tool evolution without breaking consumers. Version is informational — the registry does not enforce compatibility checks.

12. **Parallel tool calls** — when the LLM returns multiple independent tool calls in a single response, the executor runs them concurrently via `Task.async_stream/3`. Write tools targeting the same file are serialized. Permission approvals are batched. This matches Claude Code's behaviour and is critical for performance (e.g., reading 5 files in parallel instead of sequentially).

13. **Swarm tools are built-in** — `send_message`, `teammate`, and `team_delete` are core tools in `synapsis_tool`, not deferred to Samgita. The swarm coordinator process lives in `synapsis_core` alongside the agent loop, but tool modules live in `synapsis_tool`. Samgita orchestrates *across* Synapsis instances (multi-repo, multi-machine); Synapsis swarm tools handle *within-session* multi-agent coordination (same project, same machine, parallel worktrees). Clear boundary: swarm = local parallelism, Samgita = distributed orchestration.

14. **Notebook tools ship disabled** — `notebook_read` and `notebook_edit` are compiled modules with `enabled?() -> false`. Enable via `notebook_tools: true` in session or project config. The behaviour contract and parameters are finalized now; implementation is deferred to a future release. This reserves the tool names and API surface for forward compatibility.

15. **Computer use ships disabled** — `computer` is a compiled module with `enabled?() -> false`. Enable via `computer_use: true` in session config. Backend is configurable (Anthropic computer use API, Puppeteer MCP, local Playwright). The tool definition and parameter schema are reserved now; full implementation is deferred. This ensures the tool surface is stable when the feature ships.

---

## 15. Open Questions

None. All previously open questions have been resolved as decisions #11–#15 above.
