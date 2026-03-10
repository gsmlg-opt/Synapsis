# Tool System - Phase 0 Research

## Overview

Research output for expanding the Synapsis tool system from 11 to 27 tools. This document captures key technical decisions, their rationale, and rejected alternatives.

### Current State

- 11 tools implemented in `apps/synapsis_core/lib/synapsis/tool/`
- Existing `Synapsis.Tool` behaviour defines core callbacks
- Port-based bash execution already working
- Tool registry (ETS-backed) operational
- Tool executor with basic permission checks in place

### Target State

- 27 tools with 5-level permission system
- Parallel execution with write serialization
- Glob-based permission overrides
- New DB tables: `tool_calls`, `session_permissions`, `session_todos`
- Sub-agent support via `task` tool
- MCP deferred tool loading

---

## 1. Behaviour Extension Strategy

**Problem**: Adding `permission_level/0`, `category/0`, `version/0`, and `enabled?/0` callbacks to the existing `Synapsis.Tool` behaviour would break all 11 existing tool modules that do not implement them.

**Decision**: Use `@optional_callbacks` combined with default implementations provided through a `__using__` macro.

**Rationale**: This is the standard Elixir approach for evolving behaviours without breaking existing implementations. When a tool module does `use Synapsis.Tool`, the `__using__/1` macro injects default implementations for the new callbacks. Existing tools continue to compile and function without any code changes. Teams can adopt new callbacks incrementally.

**Alternatives Considered**:

| Alternative | Why Rejected |
|---|---|
| Required callbacks (breaking change) | Forces immediate updates to all 11 tools in a single commit. High risk of regressions, blocks parallel work on new tools. |
| Separate behaviour module (e.g., `Synapsis.Tool.V2`) | Creates confusion about which behaviour to implement. Doubles the surface area of the tool contract. Registry would need to handle both versions. |
| Protocol-based dispatch | Overkill for simple metadata callbacks. Protocols are better suited for polymorphic data, not module-level metadata. |

**Default Values**:

```elixir
# Injected by __using__ macro
def permission_level, do: :ask        # safest default
def category,         do: :general
def version,          do: "1.0.0"
def enabled?,         do: true
```

---

## 2. Parallel Tool Execution

**Problem**: LLMs frequently emit multiple tool calls in a single response (e.g., read 3 files, then edit 2). Executing sequentially wastes time, but naive parallelism causes write conflicts when two edits target the same file.

**Decision**: Group tool calls by target file path. Serialize execution within each group. Parallelize across groups using `Task.async_stream`.

**Rationale**: This provides optimal throughput without race conditions. Read-only tools (file_read, grep, glob) have no target file conflict and always parallelize freely. Write tools (file_edit, file_write) are serialized only when they share a target path. The grouping logic is straightforward: extract the primary file path from tool input, or `:no_file` for tools without file targets (bash, web_search, etc.).

**Alternatives Considered**:

| Alternative | Why Rejected |
|---|---|
| Global lock per session | Too restrictive. A bash command and a file read have no conflict yet would be serialized. Throughput drops to near-sequential. |
| No serialization | Race conditions on concurrent writes to the same file. Especially dangerous with file_edit (search/replace) where the match string may shift. |
| File-level advisory locks (`:global`) | Adds distributed locking complexity for a single-node use case. The grouping approach achieves the same safety with less machinery. |
| Queue per file path | Correct but over-engineered. A simple `Enum.group_by/2` + sequential map within groups achieves the same ordering guarantee. |

**Implementation Sketch**:

```elixir
tool_calls
|> Enum.group_by(&extract_target_path/1)
|> Task.async_stream(fn {_path, calls} ->
     Enum.map(calls, &execute/1)  # sequential within group
   end, max_concurrency: System.schedulers_online())
|> Enum.flat_map(fn {:ok, results} -> results end)
```

---

## 3. Permission Glob Matching

**Problem**: The 5-level permission system needs per-tool overrides. Users should be able to express rules like `"bash_exec(git *)" => :allow` to auto-approve git commands while requiring approval for other bash invocations.

**Decision**: Parse the override key into `{tool_name, argument_pattern}` tuples. Match against actual tool invocations using glob-style pattern matching (similar to `Path.wildcard/1` semantics).

**Rationale**: Glob syntax is familiar to developers (shell expansion, `.gitignore`). It covers the common cases: prefix matching (`git *`), extension matching (`*.ex`), and exact matching (`git status`). The pattern is applied to a string representation of the tool's primary argument.

**Alternatives Considered**:

| Alternative | Why Rejected |
|---|---|
| Regex matching | Too powerful and error-prone for config files. A typo in a regex silently matches nothing or everything. Glob syntax has fewer footguns. |
| Exact match only | Too restrictive. Users would need a separate entry for `git status`, `git diff`, `git log`, etc. instead of `git *`. |
| JSON path matching on input params | Over-engineered. Most override needs are simple prefix/suffix patterns on a single argument. |

**Matching Rules**:

1. `"bash_exec"` -- matches all invocations of `bash_exec` tool
2. `"bash_exec(git *)"` -- matches `bash_exec` where the command argument starts with `git `
3. `"file_write(lib/**/*.ex)"` -- matches `file_write` targeting any `.ex` file under `lib/`
4. No pattern (bare tool name) matches all invocations of that tool

**Precedence**: Most specific match wins. Pattern matches take precedence over bare tool name matches.

---

## 4. Persistent Bash Session

**Problem**: Each bash tool invocation should share environment variables, working directory, and shell history within a session. Spawning a fresh shell per invocation loses state.

**Decision**: Keep the existing Port-based approach with a session-scoped bash process. Each `Synapsis.Session.Worker` owns a long-lived bash Port that persists across tool invocations.

**Rationale**: This is already implemented and working. The Port-based approach satisfies the constitutional requirement ("`Use Port for shell execution, not System.cmd`"). A session-scoped process naturally shares `cd`, `export`, aliases, and other shell state.

**Alternatives Considered**:

| Alternative | Why Rejected |
|---|---|
| `System.cmd/3` | Prohibited by project constitution. Also spawns a new process per call, losing state. |
| PTY emulation (e.g., `ExPTY`) | Adds native dependency and complexity for handling terminal escape codes. Not needed since we don't render a full terminal UI. |
| Named pipes / FIFO | More complex IPC setup for no functional benefit over Port stdin/stdout. |

**Timeout Handling**: Each command invocation has a configurable timeout (default 120s). On timeout, the Port is not killed -- only the current command is interrupted via SIGINT. The session bash process survives for the next invocation.

---

## 5. Web Search Backend

**Problem**: The `web_search` tool needs an external search API. Cost, API key requirements, and result quality vary across providers.

**Decision**: Use Brave Search API as the primary backend with a configurable backend system that allows swapping providers.

**Rationale**: Brave Search offers a free tier (1 request/second, 2000/month) sufficient for development and light usage. The API returns structured results with descriptions, making it easy to format for LLM consumption. No billing setup required for the free tier.

**Alternatives Considered**:

| Alternative | Why Rejected |
|---|---|
| Google Custom Search | Requires Google Cloud billing setup. Free tier is only 100 queries/day. JSON API is well-documented but overkill for our needs. |
| SearXNG (self-hosted) | Requires running an additional service. Good for privacy-focused deployments but adds operational complexity for the default case. |
| Exa AI | Paid only, no free tier. Good for code-focused search but niche. |
| DuckDuckGo Instant Answer | No official API. Scraping is fragile and against ToS. |
| Tavily | Good AI-focused search API but paid. Could be offered as an alternative backend. |

**Configuration**:

```json
{
  "tools": {
    "web_search": {
      "backend": "brave",
      "api_key": "BSA..."
    }
  }
}
```

The backend is swappable via `.opencode.json`. Each backend implements a simple `search(query, opts) :: {:ok, [result]} | {:error, term}` interface.

---

## 6. Deferred Tool Loading

**Problem**: MCP servers expose tools that should appear in the registry but should not be loaded into the LLM context window until explicitly activated (e.g., by a `tool_search` invocation). This prevents context bloat from dozens of rarely-used MCP tools.

**Decision**: Add a `deferred: true` flag to registry entries. The `tool_search` tool queries the registry including deferred tools, and activates matched tools by setting `deferred: false`. The `list_for_llm/1` function filters out deferred tools.

**Rationale**: Minimal change to the existing ETS-backed registry. The activation flag is a single field update. No separate storage or registration path needed. The `tool_search` tool becomes the sole activation mechanism, giving the LLM explicit control over when to expand its tool set.

**Alternatives Considered**:

| Alternative | Why Rejected |
|---|---|
| Separate deferred registry | Duplicates registry logic. Activation requires moving entries between registries, which is more error-prone than flipping a flag. |
| On-demand registration (register when first called) | Race condition: the LLM cannot call a tool it doesn't know about. The tool must appear in the LLM context before it can be invoked, which requires explicit activation. |
| Always include all MCP tools | Context window bloat. A project with 3 MCP servers could add 50+ tool definitions, consuming thousands of tokens and degrading LLM tool selection accuracy. |

**Lifecycle**:

1. MCP client discovers tools on startup -> registered with `deferred: true`
2. LLM calls `tool_search(query)` -> registry returns matching tools (including deferred)
3. Matched tools are set to `deferred: false` -> now included in `list_for_llm/1`
4. LLM can now invoke the activated tools in subsequent turns

---

## 7. Sub-Agent Process Model

**Problem**: The `task` tool spawns a sub-agent that independently runs a multi-step task (with its own LLM loop). This sub-agent needs crash isolation, its own tool subset, and a way to report results back.

**Decision**: Spawn sub-agents under the existing `Task.Supervisor` with a restricted tool list passed in the context. The sub-agent runs a simplified version of the session agent loop.

**Rationale**: `Task.Supervisor` provides crash isolation out of the box -- if a sub-agent crashes, it does not take down the parent session. The restricted tool list is enforced by passing an explicit allowlist in the sub-agent context rather than relying on the full registry. Results are returned as the task's return value.

**Alternatives Considered**:

| Alternative | Why Rejected |
|---|---|
| DynamicSupervisor per sub-agent | Unnecessary overhead. Sub-agents are short-lived (single task) and do not need their own supervision tree. `Task.Supervisor` already handles the lifecycle. |
| Inline execution (no process) | No crash isolation. A sub-agent error (e.g., infinite loop in tool calls) would crash the parent session worker. |
| Full session (spawn a new Session.Worker) | Too heavyweight. Sub-agents don't need their own DB session, PubSub broadcasting, or connection state. They are internal to the parent session. |

**Restrictions on Sub-Agents**:

- Cannot spawn further sub-agents (no recursive `task` calls)
- Limited tool list (no `task`, no `web_search`, configurable)
- Shared token budget with parent session
- Output is captured and returned as a `ToolResultPart` to the parent

---

## 8. Plan Mode Implementation

**Problem**: Synapsis supports agent modes (build, plan, custom). In plan mode, the agent should only have access to read-only tools. The tool set must change dynamically when the user switches modes.

**Decision**: Store `agent_mode` in session state. The `list_for_llm/1` function filters tools based on their `permission_level` and the current mode. Plan mode excludes tools with side effects (file_write, file_edit, bash_exec, etc.).

**Rationale**: Filtering at the registry/listing level means excluded tools never appear in the LLM's system prompt. The LLM cannot invoke tools it does not know about, providing a hard guarantee rather than a soft one. This also saves context window tokens.

**Alternatives Considered**:

| Alternative | Why Rejected |
|---|---|
| Executor-level denial | The tool still appears in the LLM context, so the LLM may attempt to call it, receive a denial, and retry -- wasting tokens and turns. |
| Separate tool lists per mode | Duplication. Adding a new tool requires updating multiple lists. A single registry with mode-based filtering is DRY. |
| Separate agent configurations | Overly rigid. Modes should be lightweight switches, not entirely separate agent definitions. Custom agents already handle full configuration overrides. |

**Mode-to-Tool Mapping**:

| Mode | Included Tools |
|---|---|
| `build` | All tools (subject to permission level) |
| `plan` | Read-only tools: file_read, grep, glob, web_search, tool_search, memory_read, diagnostics |
| Custom | Explicit tool list from agent config in `.opencode.json` |

---

## 9. Tool Call Persistence

**Problem**: Every tool invocation needs an audit trail for debugging, replay, and UI display. The existing `Part` type embeds tool data in messages as JSONB, but this lacks independent queryability.

**Decision**: Create a dedicated `tool_calls` table with JSONB `input` and `output` columns, foreign keys to `messages` and `sessions`.

**Rationale**: A dedicated table enables querying tool calls independently of messages (e.g., "find all bash commands that failed in the last hour"). JSONB columns accommodate tool-specific input/output schemas without requiring schema migrations per tool. Foreign keys to both messages and sessions enable efficient joins for session history reconstruction and per-message tool call grouping.

**Alternatives Considered**:

| Alternative | Why Rejected |
|---|---|
| Embedded in messages JSONB (existing `Part` type) | Already exists for LLM context purposes, but lacks queryability. Cannot index on tool name, status, or duration without extracting from JSONB arrays. |
| Normalized columns per tool type | Requires schema migrations whenever a new tool is added. JSONB is more flexible for heterogeneous tool data. |
| Separate event log table | Conflates tool calls with other events. A dedicated table with tool-specific columns (name, status, duration, input, output) is more ergonomic. |

**Schema**:

```
tool_calls
  id          UUID PK
  session_id  UUID FK -> sessions
  message_id  UUID FK -> messages
  tool_name   VARCHAR NOT NULL
  status      VARCHAR NOT NULL (pending, running, complete, error, timeout)
  input       JSONB NOT NULL
  output      JSONB
  duration_ms INTEGER
  inserted_at TIMESTAMP
  updated_at  TIMESTAMP
```

**Indexes**: `(session_id)`, `(message_id)`, `(tool_name, inserted_at)`.

---

## 10. Side Effect Broadcasting

**Problem**: Tools produce side effects (file created, file modified, command executed) that the UI needs to display in real time. The broadcasting mechanism must be consistent and not overwhelm subscribers.

**Decision**: Use the existing `"tool_effects:{session_id}"` PubSub topic with `{:tool_effect, effect_type, metadata}` message format.

**Rationale**: This pattern is already established in the codebase. Session-scoped topics ensure subscribers only receive events for sessions they are watching. The three-element tuple format is simple and extensible -- new effect types can be added without changing the message structure.

**Alternatives Considered**:

| Alternative | Why Rejected |
|---|---|
| Per-tool topics (e.g., `"bash_exec:{session_id}"`) | Too many subscriptions. A UI component showing tool activity would need to subscribe to 27 separate topics. |
| Global topic (e.g., `"tool_effects"`) | Too noisy. Every subscriber receives events from every session. Requires client-side filtering. |
| Direct process messaging | Tightly couples tool execution to specific subscribers. PubSub decouples producers and consumers. |

**Effect Types**:

| Effect Type | Metadata |
|---|---|
| `:file_created` | `%{path: String.t()}` |
| `:file_modified` | `%{path: String.t(), diff: String.t()}` |
| `:file_deleted` | `%{path: String.t()}` |
| `:command_started` | `%{command: String.t(), pid: integer()}` |
| `:command_output` | `%{chunk: String.t(), stream: :stdout \| :stderr}` |
| `:command_finished` | `%{exit_code: integer(), duration_ms: integer()}` |
| `:todo_updated` | `%{id: String.t(), status: atom()}` |
| `:permission_requested` | `%{tool: String.t(), input: map()}` |

**Persistence Rule**: Per the project constitution, all effects are persisted to DB *before* broadcasting via PubSub. The tool_calls table serves as the persistence layer for tool-related effects.

---

## Open Questions

These items do not block implementation but should be revisited:

1. **Token budget for sub-agents**: Should sub-agents have a hard token cap, or share the parent session's remaining budget? Leaning toward a configurable cap (default 4096 output tokens) to prevent runaway costs.

2. **Tool versioning strategy**: The `version/0` callback is defined but the versioning scheme (semver? integer?) and its runtime effect (compatibility checks? migration?) are not yet specified. For now, it is informational only.

3. **Web search result caching**: Should identical queries within the same session return cached results? Leaning toward a short TTL cache (5 minutes) to avoid redundant API calls during iterative research.

4. **Permission persistence across sessions**: The `session_permissions` table stores per-session overrides. Should there be a project-level permission memory that carries across sessions? Deferred to Phase 10 polish.
