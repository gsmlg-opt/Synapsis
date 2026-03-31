# Two-Agent System — Product Requirements Document

## 1. Overview

**Scope:** Architectural clarification and augmentation of `agent-system-prd` and `assistant-identity-prd`
**Location:** `apps/synapsis_agent` within the Synapsis umbrella
**Target:** Elixir >= 1.18 / OTP 28+

Synapsis runs **two distinct agent systems** that serve fundamentally different situations:

| System | Analogous To | Situation | Lifecycle | Interface |
|---|---|---|---|---|
| **Assistant** | OpenClaw | Conversation, coordination, proactive work, knowledge management | Long-lived, always-on | Chat UI, multi-channel (future) |
| **Code Agent** | Claude Code | Focused coding tasks, file mutations, test-run-fix loops | Ephemeral, task-scoped | Embedded in chat, terminal (CLI) |

**The core insight:** These are not two modes of the same agent — they are two separate systems with different graphs, different context assembly, different tool sets, different permission models, and different supervision strategies. The Assistant *spawns* Code Agents; Code Agents *report back* to the Assistant. They share infrastructure (graph runtime, provider, workspace) but never share identity or session state.

**One-line definition:** The Assistant thinks; the Code Agent does.

---

## 2. Why Two Systems

### 2.1 The Situation Split

Users interact with AI coding tools in two distinct situations:

**Situation A: "Talk to me"**
- "What's the architecture of this project?"
- "Summarize what I worked on yesterday"
- "Which PR should I review first?"
- "Remember that we decided to use ULID for all IDs"

This is OpenClaw territory. The user wants a *companion* — persistent memory, personality, proactive suggestions, cross-project awareness. The agent rarely touches files. It thinks, recalls, advises, coordinates.

**Situation B: "Do this for me"**
- "Fix the failing auth test"
- "Refactor the provider module to support streaming"
- "Add a migration for the new workspace_documents table"
- "Run the test suite and fix whatever breaks"

This is Claude Code territory. The user wants a *worker* — file reads, edits, shell commands, plan-then-execute, tool approval gates. The agent is heads-down in a codebase. It acts, verifies, reports.

### 2.2 Why Not One Agent

A single agent that does both is the current `Session.Worker` — and it fails at both:

- **Too heavy for conversation.** Loading file trees, git logs, LSP diagnostics for "what did I work on yesterday?" wastes tokens and latency.
- **Too shallow for coding.** A conversational agent with 7 context layers (soul, identity, bootstrap, skills, memory, project, environment) burns 30%+ of the context window before the first tool call.
- **No delegation.** A monolithic agent can't run two coding tasks in parallel (worktrees), can't hand off a research subtask, can't be proactive while also being responsive.
- **Conflated permissions.** The Assistant should never need `bash_exec` approval. The Code Agent should never need heartbeat scheduling.

### 2.3 How They Relate

```
User
 │
 ▼
┌─────────────────────────────────────────────────┐
│                  ASSISTANT                        │
│  (Global Agent / Project Agent)                  │
│                                                  │
│  • Personality (SOUL.md)                         │
│  • Memory (auto-loaded)                          │
│  • Proactive (heartbeats)                        │
│  • Conversational loop                           │
│  • Delegates coding to ↓                         │
│                                                  │
│  Tools: workspace_*, memory_*, ask_user,         │
│         todo_*, web_search, web_fetch,           │
│         agent_send, agent_ask, agent_handoff     │
└──────────────────┬──────────────────────────────┘
                   │ spawns (with injected context)
                   ▼
┌─────────────────────────────────────────────────┐
│                CODE AGENT                         │
│  (General Agent / Special Agent)                 │
│                                                  │
│  • No personality — pure executor                │
│  • Injected context from parent                  │
│  • Coding loop (prompt → LLM → tools → verify)  │
│  • Reports back to parent on completion          │
│                                                  │
│  Tools: file_*, grep, glob, bash_exec,           │
│         multi_edit, todo_*, task (sub-agents),    │
│         web_fetch, web_search                    │
└─────────────────────────────────────────────────┘
```

---

## 3. System A: The Assistant

### TA-1: Archetype Mapping

The Assistant system maps to two of the four agent archetypes from `agent-system-prd`:

| Archetype | Role in Assistant System |
|---|---|
| **Global Agent** (AS-3) | The primary assistant. Singleton. Personality-driven. Manages all projects and cross-project concerns. |
| **Project Agent** (AS-4) | Project-scoped assistant. One per project. Inherits global soul + project soul overlay. Manages project context. |

### TA-2: What Makes It OpenClaw

The Assistant system implements every OpenClaw primitive mapped to BEAM-native equivalents:

| OpenClaw Feature | Synapsis Implementation | PRD Reference |
|---|---|---|
| `SOUL.md` personality | Workspace file at `/global/soul.md` + `/projects/<id>/soul.md` | AI-1 |
| `IDENTITY.md` user profile | Workspace file at `/global/identity.md` | AI-1.1 |
| `BOOTSTRAP.md` environment | Workspace file at `/global/bootstrap.md` | AI-1.1 |
| System prompt layering | 7-layer `ContextBuilder.build_system_prompt/2` | AI-2 |
| Skills awareness | Skills manifest injected at prompt time | AI-3 |
| Memory as automatic context | `ts_vector` search on user message, auto-injected | AI-4 |
| Session compaction | `CompactContext` graph node, silent with notification | AI-5 |
| Heartbeat / cron | Oban workers, isolated sessions, workspace results | AI-6 |
| Persistent tool approvals | `tool_approvals` table with glob patterns | AI-7 |
| ClawHub skill registry | `synapsis_tool` + `synapsis_plugin` (MCP/LSP) | tools-system-prd §3 |
| Multi-channel gateway | Future: PubSub-based, channel adapters | Not in current PRD |

### TA-3: Assistant Graph — Conversational Loop

```
             ┌──────────────────────────────────┐
             │                                  │
             ▼                                  │
      ┌──────────────┐                          │
      │receive_message│  (pause — waits for      │
      └──────┬───────┘   user or agent message)  │
             │                                  │
             ▼                                  │
   ┌─────────────────┐                          │
   │compact_context  │  (AI-5: token mgmt)       │
   └────────┬────────┘                          │
            │                                   │
            ▼                                   │
   ┌────────────────┐                           │
   │  build_prompt  │  (AI-2: 7-layer assembly)  │
   └────────┬───────┘                           │
            │                                   │
            ▼                                   │
      ┌──────────┐                              │
      │ reason   │  (LLM call with full context) │
      └─────┬────┘                              │
            │                                   │
            ▼                                   │
      ┌──────────┐                              │
      │   act    │  (route based on intent)      │
      └─────┬────┘                              │
            │                                   │
            ├── respond directly ──► respond ────┘
            │
            ├── delegate to project agent ──► agent_send
            │
            ├── spawn code agent ──► spawn_coding_agent
            │                              │
            │                     (async — continues loop)
            │
            └── spawn special agent ──► spawn_special_agent
```

**Key difference from Code Agent graph:** The `act` node is a *router*, not a tool dispatcher. It decides *who* handles the request, not *how* to execute tools.

### TA-4: Assistant Tool Set

The Assistant has a deliberately restricted tool set — no file mutations, no shell access:

| Category | Tools | Purpose |
|---|---|---|
| **Workspace** | `workspace_read`, `workspace_write`, `workspace_list`, `workspace_search` | Identity files, notes, handoff documents |
| **Memory** | `memory_save`, `memory_search` | Explicit memory operations (auto-load is implicit) |
| **Planning** | `todo_write`, `todo_read` | Task tracking across sessions |
| **Interaction** | `ask_user` | Clarification questions |
| **Web** | `web_fetch`, `web_search` | Research, documentation lookup |
| **Orchestration** | `agent_send`, `agent_ask`, `agent_handoff`, `agent_discover`, `agent_inbox` | Inter-agent coordination |
| **Session** | `enter_plan_mode`, `exit_plan_mode` | Mode switching for plan-then-delegate |

**Explicitly excluded from Assistant:** `file_read`, `file_write`, `file_edit`, `multi_edit`, `file_delete`, `file_move`, `bash_exec`, `grep`, `glob`, `task` (sub-agent spawning uses agent messaging, not the `task` tool).

**Rationale:** The Assistant never touches the codebase directly. It reads code via workspace projections or delegates to a Code Agent. This separation means:
- No permission prompts during conversation
- No accidental file mutations
- Smaller tool definition in system prompt (saves tokens)
- Clean audit trail — all code changes come from Code Agents

### TA-5: Assistant Context Assembly

The full 7-layer pipeline from `assistant-identity-prd` AI-2:

```
┌─────────────────────────────────────────┐
│ 1. Base Prompt (hardcoded per type)     │  Safety, response format, role definition
├─────────────────────────────────────────┤
│ 2. Soul (workspace: soul.md)           │  Personality, voice, behavioral rules
├─────────────────────────────────────────┤
│ 3. Identity (workspace: identity.md)   │  User profile, preferences
├─────────────────────────────────────────┤
│ 4. Skills Manifest (computed)          │  Available tools + MCP/LSP plugins
├─────────────────────────────────────────┤
│ 5. Memory Context (auto-retrieved)     │  Top-N relevant memories (5% budget)
├─────────────────────────────────────────┤
│ 6. Bootstrap (workspace: bootstrap.md) │  Environment, conventions
├─────────────────────────────────────────┤
│ 7. Project Context (conditional)       │  Project soul, project context file,
│                                         │  active agents, recent session summaries
└─────────────────────────────────────────┘
```

Token budget: 30% of model context window. Truncation priority: Project Context > Bootstrap > Memory > Skills > Identity = Soul > Base (never truncated).

### TA-6: Assistant Proactive Capabilities

The Assistant (and only the Assistant) supports heartbeats:

- **Morning briefing**: overnight git activity, open PRs, unresolved TODOs
- **Stale PR check**: PRs older than 3 days without review
- **Daily summary**: completed work, remaining tasks
- **Custom heartbeats**: user-defined Oban cron schedules with custom prompts

Heartbeats run in isolated sessions (`metadata: %{type: :heartbeat}`). Results written to workspace at `scratch` lifecycle. User notified via PubSub.

### TA-7: Assistant Session Characteristics

| Property | Value |
|---|---|
| Lifecycle | Long-lived (persists across browser sessions) |
| Compaction | Yes — `CompactContext` node in graph |
| Memory | Auto-loaded per turn |
| Permission mode | Never needs `:write` or `:execute` approval |
| Max turns | Unlimited (conversational) |
| Concurrent instances | 1 Global + N Project (one per project) |
| Restart strategy | Global: permanent; Project: transient |

---

## 4. System B: The Code Agent

### TA-8: Archetype Mapping

The Code Agent system maps to the ephemeral archetypes:

| Archetype | Role in Code Agent System |
|---|---|
| **General Agent** (AS-5) | Primary coding agent. Spawned with full project context. Runs prompt→LLM→tools→verify loop. |
| **Special Agent** (AS-6) | Restricted variant. Research (read-only), parallel worktree work, batch analysis, test execution. |

### TA-9: What Makes It Claude Code

| Claude Code Feature | Synapsis Implementation | PRD Reference |
|---|---|---|
| Agentic coding loop | `Graphs.CodingLoop` — prompt → LLM → tool_dispatch → execute → inject_result → loop | agent-system-prd AS-5 |
| 27 tools (filesystem, search, exec, web, planning, orchestration) | `synapsis_tool` full inventory | tools-system-prd §4-5 |
| Permission model (interactive / autonomous) | Session permission config with glob overrides | tools-system-prd §6 |
| Plan mode | `enter_plan_mode` / `exit_plan_mode` tools, `:read`-only filtering | tools-system-prd §6.5 |
| Persistent bash sessions | `BashExec` as long-running Port | tools-system-prd §4.3 |
| Parallel tool execution | `Task.async_stream/3` for independent tool calls | tools-system-prd §3.5 |
| Sub-agent spawning | `task` tool (foreground/background) | tools-system-prd §4.6 |
| Swarm coordination | `send_message`, `teammate`, `team_delete` | tools-system-prd §4.9 |
| Git worktree isolation | Per-teammate worktree, merge on completion | tools-system-prd Phase 5 |
| Side effect propagation | `PubSub "tool_effects:{session_id}"` → LSP/MCP refresh | tools-system-prd §7 |
| Context injection from parent | Full snapshot at spawn time | agent-system-prd AS-5 |

### TA-10: Code Agent Graph — Coding Loop

```
:init_context
  │
  ▼
:build_prompt  ◄──────────────────────────────────┐
  │                                               │
  ▼                                               │
:llm_call                                         │
  │                                               │
  ▼                                               │
:tool_dispatch ──── no tools ──► :complete         │
  │                                  │            │
  │ has tools                        ▼            │
  │                          :report_to_parent    │
  ▼                                  │            │
:approval_gate                      :end          │
  │                                               │
  ▼                                               │
:tool_execute                                     │
  │                                               │
  ▼                                               │
:inject_result ───────────────────────────────────┘
```

**Key difference from Assistant graph:** No `compact_context` (ephemeral — doesn't live long enough), no `receive_message` pause (task-driven — doesn't wait for user), no `act` router (single-purpose — just code).

### TA-11: Code Agent Tool Set

The full 27-tool inventory from `tools-system-prd`, minus the orchestration tools that belong to the Assistant:

| Category | Tools | Permission |
|---|---|---|
| **Filesystem** | `file_read`, `file_write`, `file_edit`, `multi_edit`, `file_delete`, `file_move`, `list_dir` | `:read` / `:write` / `:destructive` |
| **Search** | `grep`, `glob` | `:read` |
| **Execution** | `bash_exec` | `:execute` |
| **Web** | `web_fetch`, `web_search` | `:read` |
| **Planning** | `todo_write`, `todo_read` | `:none` |
| **Orchestration** | `task`, `tool_search`, `skill` | `:none` |
| **Interaction** | `ask_user` | `:none` |
| **Session** | `enter_plan_mode`, `exit_plan_mode`, `sleep` | `:none` |
| **Swarm** | `send_message`, `teammate`, `team_delete` | `:none` |

**Explicitly excluded from Code Agent:** `workspace_write` (to identity/soul files), `memory_save`, heartbeat tools, agent-to-agent messaging tools (`agent_send`, `agent_ask`, etc.). The Code Agent reads workspace via `file_read` against the project path, not via workspace tools.

### TA-12: Code Agent Context Assembly

The Code Agent does **not** use the 7-layer `ContextBuilder` pipeline. It receives a **pre-assembled context snapshot** from its parent at spawn time:

```elixir
%{
  # Task definition
  task_prompt: String.t(),
  
  # Project binding
  project_id: String.t(),
  project_path: String.t(),
  working_dir: String.t(),
  
  # Parent lineage (for reporting)
  parent_agent_id: String.t(),
  
  # Injected knowledge (assembled by parent's ContextBuilder)
  knowledge: %{
    file_tree: String.t(),
    recent_changes: [map()],
    active_diagnostics: [map()],
    relevant_files: [map()],
    memory_entries: [map()],
    skill_prompts: [String.t()]
  },
  
  # Constraints
  tools: [String.t()],          # allowlisted tool names
  permission_mode: :interactive | :autonomous,
  model: String.t(),
  max_turns: pos_integer()
}
```

**System prompt for Code Agent:**

```
<role>
You are a coding agent. You have been given a task by your parent agent.
Execute the task using the available tools. Report back when done.
</role>

<task>
{task_prompt}
</task>

<project>
Working directory: {working_dir}

{file_tree}

Recent changes:
{recent_changes}

Active diagnostics:
{active_diagnostics}
</project>

<relevant_context>
{relevant_files}
{memory_entries}
</relevant_context>

<skills>
{skill_prompts}
</skills>
```

No soul. No identity. No bootstrap. No personality. Pure task execution.

### TA-13: Code Agent Session Characteristics

| Property | Value |
|---|---|
| Lifecycle | Ephemeral (dies on completion, error, or cancellation) |
| Compaction | No — short-lived sessions don't need it |
| Memory | Injected at spawn time, not auto-loaded per turn |
| Permission mode | Configurable: `:interactive` (default) or `:autonomous` |
| Max turns | Configurable, default 50 |
| Concurrent instances | N (limited by supervision config) |
| Restart strategy | Temporary — never auto-restarted |
| Reporting | Sends `{:agent_completed, ...}` to parent on termination |

### TA-14: Code Agent Variants

#### General Agent (default coding agent)

- Full tool set
- Interactive permission mode by default
- Parent provides complete project context
- Reports: summary, files_changed, tool_calls, turns

#### Special Agent (restricted variant)

| Variant | Tool Restriction | Use Case |
|---|---|---|
| **Research** | Read-only: `file_read`, `grep`, `glob`, `list_dir`, `web_fetch`, `web_search` | Background research, doc reading |
| **Worktree** | Full tools, but isolated `working_dir` in git worktree | Parallel feature branches |
| **Test runner** | `file_read`, `bash_exec`, `grep`, `list_dir` | Run tests, report failures |
| **Analyzer** | Read-only + `bash_exec` (restricted commands) | Static analysis, dependency audit |

---

## 5. The Boundary: How They Interact

### TA-15: Spawn Protocol

When the Assistant decides a coding task is needed:

```
1. Assistant's `act` node classifies intent as coding task
2. Assistant assembles context via ContextBuilder
3. Assistant sends spawn message:
   {:spawn, :general, %{
     task_prompt: "Fix the auth bug in lib/myapp/auth.ex",
     project_id: "proj-123",
     knowledge: ContextBuilder.build_coding_context(project_id),
     permission_mode: :interactive,
     model: "claude-sonnet-4-20250514"
   }}
4. AgentSupervisor starts GeneralAgent under EphemeralAgentSupervisor
5. Code Agent runs coding loop autonomously
6. On completion, Code Agent sends back:
   {:agent_completed, agent_id, %{
     status: :completed,
     summary: "Fixed auth bug by...",
     files_changed: [...],
     tool_calls: 12,
     turns: 8
   }}
7. Assistant receives report, relays to user
```

### TA-16: Communication Boundaries

| Direction | Mechanism | Content |
|---|---|---|
| Assistant → Code Agent | Spawn with injected context | Task prompt + project knowledge + constraints |
| Code Agent → Assistant | `:notification` message via PubSub | Completion report (status, summary, files_changed) |
| Code Agent → User | Tool approval pause (via PubSub to UI) | "Allow `bash_exec: mix test`?" |
| User → Code Agent | Approval/denial (via PubSub from UI) | Approve/deny specific tool call |
| Code Agent → Code Agent | `task` tool (sub-agent) / `teammate` (swarm) | Task delegation within coding context |

**Hard rules:**
- Code Agent **never** writes to soul/identity/bootstrap workspace files
- Code Agent **never** creates heartbeats or schedules proactive work
- Code Agent **never** saves long-term memory (that's the Assistant's job post-report)
- Assistant **never** runs `bash_exec`, `file_write`, or `file_edit` directly
- Assistant **never** spawns inside a git worktree

### TA-17: Post-Task Memory Flow

After a Code Agent completes and reports back, the Assistant decides what to remember:

```
Code Agent → {:agent_completed, %{summary: "...", files_changed: [...]}}
    │
    ▼
Assistant receives report
    │
    ├── Relays summary to user via chat
    │
    ├── Optionally saves to memory:
    │   memory_save("Fixed auth bug: updated token expiry in lib/myapp/auth.ex")
    │
    └── Optionally writes to workspace:
        workspace_write("/projects/proj-123/changelog.md", updated_changelog)
```

The Code Agent doesn't know or care about memory. Knowledge management is the Assistant's responsibility.

---

## 6. Supervision Tree (Unified View)

```
SynapsisAgent.Application
│
├── SynapsisAgent.Runner.Supervisor (DynamicSupervisor)
│   └── (graph run processes — all agents execute here)
│
├── SynapsisAgent.AgentSupervisor (DynamicSupervisor)
│   │
│   ├── ─── ASSISTANT SYSTEM ───────────────────────────
│   │   │
│   │   ├── GlobalAgent (singleton, permanent)
│   │   │   graph: Graphs.ConversationalLoop
│   │   │   tools: workspace_*, memory_*, agent_*, ask_user, web_*
│   │   │   context: 7-layer ContextBuilder pipeline
│   │   │
│   │   └── ProjectAgentSupervisor (DynamicSupervisor)
│   │       ├── ProjectAgent<proj-1> (transient)
│   │       ├── ProjectAgent<proj-2> (transient)
│   │       └── ...
│   │           graph: Graphs.ConversationalLoop (project-scoped)
│   │           tools: same as Global + project-specific MCP/LSP
│   │           context: 7-layer with project soul overlay
│   │
│   └── ─── CODE AGENT SYSTEM ─────────────────────────
│       │
│       └── EphemeralAgentSupervisor (DynamicSupervisor)
│           ├── GeneralAgent<task-1> (temporary)
│           ├── GeneralAgent<task-2> (temporary)
│           ├── SpecialAgent<research-1> (temporary)
│           └── ...
│               graph: Graphs.CodingLoop | Graphs.TaskGraph
│               tools: file_*, grep, glob, bash_exec, ...
│               context: injected snapshot from parent
│
├── SynapsisAgent.AgentRegistry (Registry)
│
├── SynapsisAgent.ContextBuilder (GenServer — caches for Assistant)
│
└── SynapsisAgent.Checkpoint.ETS (GenServer — dev/test)
```

---

## 7. UI Implications

### TA-18: Chat Interface Split

The web UI reflects the two-system split:

**Assistant panel (primary):**
- Standard chat interface
- Message history with compaction markers
- Personality-aware responses
- Memory indicators ("recalled from previous session")
- Heartbeat notification cards

**Code Agent panel (embedded):**
- Appears inline in chat when Assistant spawns a Code Agent
- Shows: task description, progress (todo list), tool calls with results
- Collapsible tool call details
- Approval cards for permission requests
- Completion summary card with files changed
- Multiple Code Agents can be active simultaneously (accordion/tab view)

**The user interacts primarily with the Assistant.** Code Agent activity is visible but secondary — like watching a worker in a split terminal.

### TA-19: CLI Interface (synapsis_cli)

The CLI escript can operate in two modes:

**Chat mode** (`synapsis chat`): Connects to the Assistant via WebSocket. Conversational.

**Code mode** (`synapsis code "fix the auth bug"`): Spawns a Code Agent directly, bypassing the Assistant. Equivalent to running `claude code` or `codex exec`. Interactive permission prompts in terminal. Outputs completion report on exit.

---

## 8. Configuration

### TA-20: Per-System Defaults

```elixir
# config/config.exs

config :synapsis_agent, :assistant,
  default_model: "claude-sonnet-4-20250514",
  context_budget_ratio: 0.30,
  compaction_threshold_ratio: 0.75,
  compaction_model: "claude-haiku-4-5-20251001",
  memory_budget_ratio: 0.05,
  memory_max_entries: 10,
  identity_cache_ttl_ms: 60_000

config :synapsis_agent, :code_agent,
  default_model: "claude-sonnet-4-20250514",
  max_turns: 50,
  default_permission_mode: :interactive,
  parallel_tool_concurrency: System.schedulers_online(),
  tool_timeout_ms: 60_000,
  bash_session_timeout_ms: 300_000

config :synapsis_agent, :heartbeat,
  enabled: false,
  templates: [:morning_briefing, :stale_pr_check, :daily_summary]
```

---

## 9. Implementation Phases

### Phase 1: Assistant Foundation

**Goal:** Global Agent runs conversational loop with identity files and context assembly.

**Deliverables:**
- `SynapsisWorkspace.Identity` — load soul/identity/bootstrap from workspace
- `ContextBuilder.build_system_prompt/2` — 7-layer pipeline with XML tags
- `Graphs.ConversationalLoop` — receive → compact → build_prompt → reason → act → respond
- `GlobalAgent` implementation with `Agent` behaviour
- `Nodes.ReceiveMessage`, `Nodes.Reason`, `Nodes.Act`, `Nodes.Respond`
- Default identity file seeding

**Tests:**
```
test/synapsis_workspace/identity_test.exs
test/synapsis_agent/context_builder_test.exs
test/synapsis_agent/graphs/conversational_loop_test.exs
test/synapsis_agent/agents/global_agent_test.exs
test/synapsis_agent/nodes/{receive_message,reason,act,respond}_test.exs
```

### Phase 2: Code Agent Foundation

**Goal:** General Agent runs coding loop with injected context and full tool set.

**Deliverables:**
- `Graphs.CodingLoop` — init → prompt → llm → dispatch → execute → inject → loop
- `GeneralAgent` implementation
- `Nodes.InitContext`, `Nodes.BuildPrompt`, `Nodes.LlmCall`, `Nodes.ToolDispatch`, `Nodes.ToolExecute`, `Nodes.ApprovalGate`, `Nodes.InjectResult`, `Nodes.ReportToParent`
- Context injection protocol (parent assembles, child receives)
- Permission engine integration

**Tests:**
```
test/synapsis_agent/graphs/coding_loop_test.exs
test/synapsis_agent/agents/general_agent_test.exs
test/synapsis_agent/nodes/{init_context,build_prompt,llm_call,...}_test.exs
test/integration/coding_loop_test.exs
```

### Phase 3: Spawn & Report

**Goal:** Assistant can spawn Code Agents and receive completion reports.

**Deliverables:**
- `Act` node routing: classify intent → delegate/spawn/respond
- `ContextBuilder.build_coding_context/1` — assembles injection payload
- Inter-agent messaging (`:spawn`, `:notification`, `:delegation`)
- `AgentRegistry` tracking
- UI: embedded Code Agent panel in chat

**Tests:**
```
test/integration/global_project_delegation_test.exs
test/integration/agent_messaging_test.exs
test/integration/spawn_and_report_test.exs
```

### Phase 4: Assistant Intelligence

**Goal:** Memory, compaction, skill injection, proactive execution.

**Deliverables:**
- Auto-memory loading (AI-4)
- Session compaction (AI-5)
- Skills manifest generation (AI-3)
- Heartbeat workers (AI-6)
- Persistent tool approvals (AI-7)
- Project Agent with soul inheritance

**Tests:**
```
test/synapsis_agent/compaction_test.exs
test/synapsis_agent/nodes/compact_context_test.exs
test/synapsis_agent/heartbeat/worker_test.exs
```

### Phase 5: Code Agent Advanced

**Goal:** Swarm, worktrees, autonomous mode, Special Agent variants.

**Deliverables:**
- `SpecialAgent` with variant configs (research, worktree, test runner, analyzer)
- Swarm tools (`teammate`, `send_message`, `team_delete`)
- Git worktree isolation per teammate
- Autonomous mode (`permission_mode: :autonomous`)
- Background sub-agents via `task` tool

**Tests:**
```
test/synapsis_agent/agents/special_agent_test.exs
test/integration/swarm_test.exs
test/integration/worktree_isolation_test.exs
```

---

## 10. Acceptance Criteria

### Assistant System

- [ ] AC-1: User edits `soul.md` → next response reflects personality change
- [ ] AC-2: System prompt includes all 7 layers with XML tags
- [ ] AC-3: Agent references memory from previous session without explicit tool call
- [ ] AC-4: 200+ message session compacts without losing key facts
- [ ] AC-5: Heartbeat fires on schedule and writes workspace artifact
- [ ] AC-6: Assistant delegates coding task to Code Agent and relays result
- [ ] AC-7: Project soul overrides global soul for project-scoped agents
- [ ] AC-8: Assistant never has access to `file_write`, `bash_exec`, or filesystem tools

### Code Agent System

- [ ] AC-9: Code Agent spawns with injected context, runs coding loop, reports back
- [ ] AC-10: Tool approval gate pauses for user input, resumes on approval
- [ ] AC-11: Autonomous mode runs without approval pauses
- [ ] AC-12: Multiple Code Agents run in parallel (different tasks, different worktrees)
- [ ] AC-13: Code Agent never writes to soul/identity/bootstrap files
- [ ] AC-14: Code Agent never saves long-term memory
- [ ] AC-15: max_turns enforced — agent completes or fails at limit
- [ ] AC-16: Parent notified on completion, failure, or cancellation

### Integration

- [ ] AC-17: Full round trip: user message → Assistant → spawn Code Agent → code change → report → user sees result
- [ ] AC-18: CLI `synapsis code` spawns Code Agent directly without Assistant
- [ ] AC-19: UI shows embedded Code Agent panel with progress and tool calls
- [ ] AC-20: Post-task memory: Assistant saves relevant facts from Code Agent report

---

## 11. Resolved Decisions

### RD-1: Why Not Let the Assistant Edit Files

**Decision:** The Assistant has zero filesystem tools.

**Alternatives considered:**
- Give Assistant read-only filesystem access → rejected because it blurs the boundary and adds tools to the system prompt that waste tokens in conversation
- Give Assistant write access with higher approval → rejected because it creates a second code path for mutations with different context, breaking auditability

**The boundary is enforced at the tool registry level.** When `ContextBuilder` assembles tools for the Assistant, it filters by a tool allowlist stored in the agent type config. No runtime check needed — the tools simply aren't registered for Assistant agents.

### RD-2: Why Code Agent Has No Personality

**Decision:** Code Agents receive a minimal role prompt, not the 7-layer context pipeline.

**Rationale:** Every token in the Code Agent's context window is precious — it needs that space for file contents, tool results, error logs, and iteration history. Soul + identity + bootstrap + memory can easily consume 5-10K tokens. That's 3-4 file reads worth of context. For an agent that might run 50 turns with 12 tool calls, context efficiency is everything.

If the user wants the Code Agent to behave differently (e.g., "write Elixir in a specific style"), that goes into the task prompt or the project's `CLAUDE.md` / `SOUL.md` which gets included via `skill_prompts` in the injected knowledge.

### RD-3: Post-Task Memory Is the Assistant's Responsibility

**Decision:** Code Agents cannot call `memory_save`. Only the Assistant saves long-term memories.

**Rationale:** Code Agents are ephemeral — they don't have the context to know what's worth remembering long-term. The Assistant, which maintains conversational continuity and understands user preferences, is better positioned to decide: "this architectural decision should be remembered" vs. "this was a one-off bug fix."

If Code Agents could save memory, you'd get noisy, low-value entries like "changed line 42 of auth.ex" cluttering the memory store. The Assistant filters the Code Agent's report and saves only what matters.

### RD-4: CLI Code Mode Bypasses Assistant

**Decision:** `synapsis code "task"` spawns a Code Agent directly under EphemeralAgentSupervisor without involving the Global Agent.

**Rationale:** CLI users want Claude Code behavior — fast, direct, no intermediary. The Assistant adds latency (LLM call to classify intent) and overhead (7-layer context) that's unnecessary when the user has already expressed a clear coding task.

The CLI code mode constructs the injection context itself using `ContextBuilder.build_coding_context/1` and spawns the `GeneralAgent` with `permission_mode: :interactive`.

---

## 12. Migration Path from Current Session.Worker

The current `Session.Worker` GenServer is a monolith that handles both conversation and coding. The migration:

1. **Phase 0 (Convergence):** Decompose Worker into graph nodes (already specced in convergence PRD)
2. **Phase 1:** Wire conversational nodes into `Graphs.ConversationalLoop`, run Global Agent alongside Worker (feature flag)
3. **Phase 2:** Wire coding nodes into `Graphs.CodingLoop`, spawn as GeneralAgent
4. **Phase 3:** Route new sessions to Agent system, deprecate Worker for new sessions
5. **Phase 4:** Migrate existing sessions, remove Worker

Each phase is independently deployable. The Agent system and Worker can coexist during migration via the session's `engine: :worker | :agent` field.
