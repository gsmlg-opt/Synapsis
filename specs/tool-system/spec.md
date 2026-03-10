# Feature Specification: Synapsis Tool System

**Feature Branch**: `feature/tool-system`
**Created**: 2026-03-10
**Status**: Draft
**Input**: User description: "Implement the complete Synapsis Tool System — 27 built-in tools, tool registry, executor pipeline, permission engine, side effect propagation, and plugin tool integration as specified in PRD.md"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Agent Reads, Edits, and Writes Files (Priority: P1)

An AI coding agent working within a Synapsis session needs to navigate a codebase: read file contents, make targeted edits, create new files, delete obsolete files, and move/rename files. The tool system provides filesystem tools that the agent invokes through the executor pipeline with appropriate permission checks.

**Why this priority**: Filesystem operations are the foundation of every coding agent workflow. Without file read/write capability, no other tool is useful.

**Independent Test**: Can be fully tested by creating a session, invoking `file_read`, `file_write`, `file_edit`, `multi_edit`, `file_delete`, `file_move`, and `list_dir` tools, and verifying file changes on disk. Delivers value as a standalone file manipulation agent.

**Acceptance Scenarios**:

1. **Given** a session with a project path, **When** the agent calls `file_read` with a valid file path, **Then** the tool returns the file contents (with optional line range).
2. **Given** a session, **When** the agent calls `file_edit` with a unique `old_text` match, **Then** exactly that text is replaced with `new_text` and a `:file_changed` side effect is broadcast.
3. **Given** a session, **When** the agent calls `file_edit` with `old_text` that matches zero or multiple locations, **Then** the tool returns an error without modifying the file.
4. **Given** a session, **When** the agent calls `file_write` with a path in a non-existent directory, **Then** parent directories are created and the file is written.
5. **Given** a session, **When** the agent calls `multi_edit` with edits across two files and one edit fails, **Then** the failed file is rolled back while the successful file's edits persist.
6. **Given** a session, **When** the agent calls `file_delete` on a non-empty directory without `recursive: true`, **Then** the tool returns an error.
7. **Given** a session with `:write` permission denied, **When** the agent calls `file_write`, **Then** the executor returns `{:error, :permission_denied}`.

---

### User Story 2 - Agent Searches Codebase (Priority: P1)

An AI agent needs to search across a codebase using text/regex patterns and file glob patterns to locate relevant code before making changes.

**Why this priority**: Search is prerequisite to intelligent code editing — the agent must find code before modifying it.

**Independent Test**: Can be tested by invoking `grep` and `glob` tools against a test project and verifying correct matches are returned.

**Acceptance Scenarios**:

1. **Given** a project with source files, **When** the agent calls `grep` with a regex pattern, **Then** matching lines are returned with file paths and line numbers.
2. **Given** a project, **When** the agent calls `grep` with `output_mode: "files"`, **Then** only file paths containing matches are returned.
3. **Given** a project, **When** the agent calls `glob` with pattern `"**/*.ex"`, **Then** all matching files are returned sorted by modification time.
4. **Given** a project with a `.gitignore`, **When** `grep` is called without `ignore_gitignore`, **Then** ignored files are excluded from results.

---

### User Story 3 - Agent Executes Shell Commands (Priority: P1)

An AI agent needs to run shell commands (compile, test, git operations) in a persistent bash session that maintains state across calls.

**Why this priority**: Shell execution is essential for build/test workflows and operations not covered by dedicated tools.

**Independent Test**: Can be tested by running sequential bash commands and verifying state persistence (env vars, working directory) across calls.

**Acceptance Scenarios**:

1. **Given** a session, **When** the agent calls `bash_exec` with `export FOO=bar` then calls `bash_exec` with `echo $FOO`, **Then** the second call returns `bar` (state persists).
2. **Given** a session, **When** the agent calls `bash_exec` with a command that exceeds the timeout, **Then** the tool returns a timeout error.
3. **Given** a session with `:execute` permission set to `:ask`, **When** the agent calls `bash_exec`, **Then** the executor broadcasts a permission request and blocks until user responds.
4. **Given** a session, **When** the agent calls `bash_exec` with `cd /tmp` then `pwd`, **Then** the working directory persists as `/tmp`.

---

### User Story 4 - Tool Registry and Executor Pipeline (Priority: P1)

The system manages a registry of all available tools and routes tool calls through a pipeline: registry lookup, permission check, dispatch, result handling, and side effect broadcast.

**Why this priority**: The registry and executor are the infrastructure that makes all other tools work. Every tool call flows through this pipeline.

**Independent Test**: Can be tested by registering mock tools, executing calls through the pipeline, and verifying each stage (lookup, permission, dispatch, side effects).

**Acceptance Scenarios**:

1. **Given** built-in tools are registered on startup, **When** `Registry.list_for_llm/1` is called, **Then** all enabled tools are returned with name, description, and parameter schemas.
2. **Given** `agent_mode` is `:plan`, **When** `list_for_llm/1` is called, **Then** only `:read` and `:none` permission-level tools are included.
3. **Given** a tool call for a non-existent tool, **When** the executor processes it, **Then** it returns `{:error, :tool_not_found}`.
4. **Given** multiple independent tool calls in one LLM response, **When** the executor processes them, **Then** they run concurrently and results are returned in order.
5. **Given** two write tools targeting the same file in a batch, **When** executed, **Then** they are serialized (not concurrent) to prevent write conflicts.

---

### User Story 5 - Permission System Controls Tool Access (Priority: P1)

Session administrators configure permission levels that control which tools require approval before execution. The permission engine resolves per-tool overrides, level defaults, and declared permission levels.

**Why this priority**: Without permission controls, the agent could execute destructive operations without user consent — a core safety requirement.

**Independent Test**: Can be tested by configuring various permission profiles and verifying that tool calls are allowed, denied, or prompt for approval correctly.

**Acceptance Scenarios**:

1. **Given** a session with `allow_destructive: :ask`, **When** the agent calls `file_delete`, **Then** the executor broadcasts a permission request and blocks.
2. **Given** a per-tool override `"bash_exec(git *)" => :allow`, **When** the agent calls `bash_exec` with `git status`, **Then** the command executes without approval.
3. **Given** a per-tool override `"bash_exec(rm *)" => :deny`, **When** the agent calls `bash_exec` with `rm -rf /`, **Then** the executor returns `{:error, :permission_denied}` immediately.
4. **Given** autonomous mode, **When** the agent calls any tool at `:execute` level or below, **Then** it is auto-approved without user interaction.

---

### User Story 6 - Agent Uses Planning and Todo Tools (Priority: P2)

An AI agent tracks multi-step work using a todo checklist and can switch between plan mode (read-only exploration) and build mode (full tool access).

**Why this priority**: Planning tools improve agent reliability on complex tasks but are not required for basic file editing workflows.

**Independent Test**: Can be tested by creating todos, switching to plan mode, verifying write tools are disabled, then exiting plan mode and verifying full access resumes.

**Acceptance Scenarios**:

1. **Given** a session, **When** the agent calls `todo_write` with a list of tasks, **Then** the todo list is stored and broadcast to the UI.
2. **Given** a session in `:build` mode, **When** the agent calls `enter_plan_mode`, **Then** write and execute tools are no longer available.
3. **Given** a session in `:plan` mode, **When** the agent calls `exit_plan_mode` with a plan, **Then** the plan is broadcast for user approval and mode returns to `:build` on approval.
4. **Given** a session, **When** `todo_read` is called, **Then** the current todo list state is returned.

---

### User Story 7 - Agent Launches Sub-Agents (Priority: P2)

An AI agent delegates complex tasks to sub-agents that run with scoped tool sets and independent conversation contexts. Sub-agents can run in foreground (blocking) or background (async).

**Why this priority**: Sub-agents enable parallel work and task decomposition, but the primary agent loop must work first.

**Independent Test**: Can be tested by launching a foreground sub-agent with read-only tools, verifying it completes and returns results to the parent.

**Acceptance Scenarios**:

1. **Given** a session, **When** the agent calls `task` with a prompt and default tools, **Then** a sub-agent is spawned with only read tools and returns its result when complete.
2. **Given** a session, **When** the agent calls `task` with `mode: "background"`, **Then** a task ID is returned immediately and the parent agent continues.
3. **Given** a background sub-agent, **When** it completes, **Then** a notification is broadcast via PubSub.
4. **Given** a sub-agent, **When** it attempts to use `ask_user`, **Then** the call is denied (only primary agent can interact with user).

---

### User Story 8 - Agent Searches Web and Fetches Pages (Priority: P2)

An AI agent searches the web for documentation and fetches page content to inform coding decisions.

**Why this priority**: Web access is important for documentation lookup but not required for core coding workflows.

**Independent Test**: Can be tested by calling `web_search` and `web_fetch` with mock HTTP backends and verifying results are returned.

**Acceptance Scenarios**:

1. **Given** a session, **When** the agent calls `web_search` with a query, **Then** results with titles, URLs, and snippets are returned.
2. **Given** a session, **When** the agent calls `web_fetch` with a URL, **Then** extracted text content is returned, truncated to `max_tokens`.
3. **Given** a URL behind authentication, **When** `web_fetch` is called, **Then** an appropriate error is returned (not a crash).

---

### User Story 9 - Agent Interacts with User (Priority: P2)

When the AI agent encounters ambiguity, it presents structured questions to the user with selectable options and waits for a response.

**Why this priority**: User interaction enables the agent to clarify requirements mid-task rather than guessing wrong.

**Independent Test**: Can be tested by triggering `ask_user` and verifying the question is broadcast and the tool blocks until a response is received.

**Acceptance Scenarios**:

1. **Given** a session, **When** the agent calls `ask_user` with questions and options, **Then** the questions are broadcast to the session channel.
2. **Given** a pending `ask_user` call, **When** the user selects an option, **Then** the tool unblocks and returns the user's selection.
3. **Given** a pending `ask_user` call, **When** the user provides free-text instead of selecting an option, **Then** the free-text response is returned.

---

### User Story 10 - Plugin Tools via MCP/LSP (Priority: P3)

External tools from MCP servers and LSP servers are dynamically registered into the tool registry and callable through the same executor pipeline. Deferred loading prevents context bloat.

**Why this priority**: Plugin integration extends the tool surface but requires the core tool system to be stable first.

**Independent Test**: Can be tested by registering a mock MCP tool, using `tool_search` to discover it, and executing it through the pipeline.

**Acceptance Scenarios**:

1. **Given** an MCP server is configured, **When** the session starts, **Then** MCP tools are registered in the registry as deferred.
2. **Given** deferred MCP tools, **When** the agent calls `tool_search` with a keyword, **Then** matching tool definitions are returned and activated.
3. **Given** an activated MCP tool, **When** the agent calls it, **Then** the executor dispatches via process call to the plugin server.
4. **Given** a session start, **When** `list_for_llm/1` is called, **Then** deferred tools are NOT included (saving context tokens).

---

### User Story 11 - Swarm Multi-Agent Coordination (Priority: P3)

Multiple AI agents within a session form a team, communicate via structured messages, and work in parallel on different parts of a codebase.

**Why this priority**: Swarm tools enable advanced parallel workflows but are experimental and depend on all other tool infrastructure.

**Independent Test**: Can be tested by creating teammate agents, sending messages between them, and dissolving the team.

**Acceptance Scenarios**:

1. **Given** a session, **When** the primary agent calls `teammate` with `action: "create"`, **Then** a new agent process is spawned with its own conversation history.
2. **Given** a swarm, **When** agent A calls `send_message` to agent B, **Then** agent B receives the message as a system injection.
3. **Given** a swarm, **When** `team_delete` is called, **Then** all teammate processes are terminated and their final outputs are collected.

---

### Edge Cases

- What happens when a tool call targets a file outside the project root? The executor must validate paths are within the project boundary and return an error.
- What happens when a persistent bash session's Port process crashes? The session should detect the crash and restart the Port transparently.
- What happens when the LLM returns a tool call with missing required parameters? The executor returns a validation error without dispatching.
- What happens when parallel tool execution hits the concurrency limit? Excess calls are queued and executed as slots become available.
- What happens when a permission approval request times out? The executor returns a timeout error to the LLM.
- What happens when a sub-agent exceeds its context window? The sub-agent should compact or terminate gracefully.
- What happens when a tool's `enabled?/0` returns `false`? The registry excludes it from `list_for_llm/1` and the executor returns `{:error, :tool_disabled}`.
- What happens when `multi_edit` receives edits for a file that doesn't exist? The tool returns an error for that file without affecting other files.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST implement a `SynapsisTool` behaviour contract with callbacks: `name/0`, `description/0`, `parameters/0`, `execute/2`, and optional `permission_level/0`, `side_effects/0`, `category/0`, `version/0`, `enabled?/0`.
- **FR-002**: System MUST implement a tool registry that registers, unregisters, and looks up tools by name, and provides filtered tool listings by agent mode, category, and permission level.
- **FR-003**: System MUST implement an executor pipeline: registry lookup, permission check, dispatch (module or process), result handling, side effect broadcast.
- **FR-004**: System MUST implement a permission engine that resolves permissions using per-tool glob overrides, session-level defaults, and tool-declared levels in that priority order.
- **FR-005**: System MUST implement 7 filesystem tools: `file_read`, `file_write`, `file_edit`, `multi_edit`, `file_delete`, `file_move`, `list_dir`.
- **FR-006**: System MUST implement 2 search tools: `grep` (regex search across files respecting .gitignore) and `glob` (file pattern matching sorted by modification time).
- **FR-007**: System MUST implement `bash_exec` with persistent session state (env vars, working directory) via a long-running shell process.
- **FR-008**: System MUST implement 2 web tools: `web_fetch` (page content extraction with token truncation) and `web_search` (search engine queries with title/URL/snippet results).
- **FR-009**: System MUST implement 2 planning tools: `todo_write` (create/update session-scoped checklist) and `todo_read` (retrieve current state).
- **FR-010**: System MUST implement 3 orchestration tools: `task` (sub-agent launcher with foreground/background modes), `tool_search` (deferred tool discovery and activation), `skill` (skill file loader).
- **FR-011**: System MUST implement `ask_user` interaction tool that presents structured questions with selectable options and blocks until user response.
- **FR-012**: System MUST implement 2 session control tools: `enter_plan_mode` (disable write/execute tools) and `exit_plan_mode` (present plan, restore full access on approval).
- **FR-013**: System MUST implement `sleep` utility tool with configurable duration and early wake on user input.
- **FR-014**: System MUST implement 3 swarm tools: `send_message` (inter-agent messaging), `teammate` (agent creation/management), `team_delete` (swarm dissolution).
- **FR-015**: System MUST implement 2 notebook tools and 1 computer tool as disabled-by-default modules with reserved parameter schemas.
- **FR-016**: System MUST support parallel execution of independent tool calls, serializing write operations targeting the same file.
- **FR-017**: System MUST broadcast side effects via PubSub after successful tool execution.
- **FR-018**: System MUST support deferred tool loading — plugin tools registered but excluded from context until activated via `tool_search`.
- **FR-019**: System MUST persist tool call records (name, input, output, status, duration) in the database.
- **FR-020**: System MUST validate that file operation paths are within the project root to prevent path traversal.
- **FR-021**: System MUST support both module-based dispatch (built-in tools) and process-based dispatch (plugin tools).
- **FR-022**: The `file_edit` tool MUST fail if `old_text` matches zero or more than one location in the target file.
- **FR-023**: The `multi_edit` tool MUST roll back all edits for a file if any edit in that file fails, while allowing independent files to succeed.
- **FR-024**: Sub-agents MUST NOT be able to use `ask_user` or `enter_plan_mode` — only the primary agent can interact with the user.
- **FR-025**: The tool registry MUST auto-register all built-in tools on application startup.

### Key Entities

- **Tool Registration**: A named entry in the registry mapping a tool name to either a module (built-in) or a process (plugin). Includes metadata: description, parameters schema, category, permission level, version, enabled flag, deferred flag.
- **Tool Call**: A record of a single tool invocation — tool name, input parameters, output result, status (pending/approved/denied/completed/error), execution duration. Persisted per message and session.
- **Session Permission Config**: Per-session configuration controlling tool access — mode (interactive/autonomous), level defaults (allow_write, allow_execute, allow_destructive), and per-tool glob pattern overrides.
- **Todo Item**: A task in a session-scoped checklist — content, status (pending/in_progress/completed), sort order.
- **Tool Context**: Runtime context passed to every tool execution — session ID, project path, working directory, permissions, agent mode, session process, parent agent process.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All 27 tool modules compile and pass their unit tests, with 21 enabled by default and 3 disabled.
- **SC-002**: The executor pipeline processes a tool call (registry lookup through result return) in under 50ms for non-I/O tools.
- **SC-003**: Parallel execution of 5 independent file reads completes faster than sequential execution (at least 2x speedup).
- **SC-004**: The permission engine correctly resolves allow/deny/ask for all combinations of per-tool overrides, level defaults, and tool-declared levels (100% test coverage on resolution logic).
- **SC-005**: An AI agent can complete a full coding workflow — search for code, read files, edit files, run tests — using only Synapsis tools (end-to-end integration test).
- **SC-006**: Side effects broadcast within 10ms of tool completion and are received by all PubSub subscribers.
- **SC-007**: Deferred tools are excluded from `list_for_llm/1` output, reducing token usage proportionally.
- **SC-008**: The tool system handles 50 concurrent tool calls per session without errors or deadlocks.
- **SC-009**: All tool calls are persisted to the database with complete audit trail (name, input, output, status, duration).
- **SC-010**: Plan mode correctly filters out all write/execute/destructive tools, and build mode restores full access.
