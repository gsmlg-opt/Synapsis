# Synapsis Convergence — Product Requirements Document

## 1. Executive Summary

Synapsis has two execution engines that do not talk to each other. The **Session.Worker** GenServer (1195 LOC) implements the full `idle → streaming → tool_executing → idle` agent loop that powers every user interaction today. The **Agent Runtime** in `synapsis_agent` implements a complete graph-based execution engine with checkpointing, sub-graphs, pause/resume, and four agent archetypes — but nothing in the running system invokes it.

This PRD specifies the convergence of these two engines into a single execution model where:

1. Session.Worker becomes a thin process wrapper around graph-driven execution
2. The dependency graph is corrected so agents can invoke tools and LLMs without circular deps
3. The 1195-line Worker is decomposed into focused, testable modules
4. The Auditor LLM path is wired end-to-end
5. The Phoenix dependency in `synapsis_core` is removed

**One-line definition:** Make the agent system the execution engine, not a sidecar.

This document covers:

- Dependency graph restructuring
- Session.Worker decomposition into graph nodes
- Agent-to-session bridging
- Auditor LLM wiring
- Phoenix dep extraction from core
- Multi-agent activation path
- Frontend boundary contract (LiveView vs React)

---

## 2. Current State Analysis

### 2.1 The Two Engines

**Engine A — Session.Worker** (working, user-facing):

```
SessionChannel
  → Sessions.send_message/2
    → Session.Worker GenServer
      → MessageBuilder.build_request/4
        → Provider streaming (SSE)
          → handle_stream_event/2 (chunk accumulation)
            → Tool.Executor.execute/3
              → Monitor.record_tool_call/3
                → Orchestrator.decide/2
                  → continue | pause | escalate | terminate
```

**Engine B — Agent Runtime** (implemented, disconnected):

```
GlobalAssistant
  → ProjectAssistant.enqueue/2
    → ProjectGraph.run/3
      → Runtime.Runner GenServer
        → Graph node execution
          → Checkpoint/Resume
            → (no tool or LLM bridge)
```

### 2.2 Why They're Disconnected

The dependency graph makes connection impossible without circular deps:

```
synapsis_data       ← no umbrella deps
synapsis_provider   ← depends on data
synapsis_agent      ← depends on data only
synapsis_core       ← depends on data, agent, provider (owns tools, LLM, sessions)
```

`synapsis_agent` cannot call `Tool.Executor` (in core) or `Synapsis.LLM` (in core) because core depends on agent, not the other way around. The agent PRD specifies injecting provider and tool_dispatcher as config, but the graph nodes still need concrete modules at runtime.

### 2.3 Session.Worker Responsibilities (current)

The Worker handles 12 distinct concerns in one module:

1. **State machine** — idle/streaming/tool_executing/error transitions
2. **Message persistence** — insert user/assistant messages to DB
3. **Provider lifecycle** — start stream, monitor stream process, handle crashes
4. **Chunk accumulation** — text_delta, tool_use_start, tool_input_delta, reasoning_delta
5. **Tool dispatch** — permission check, async execution, result collection
6. **Orchestrator integration** — Monitor recording, Orchestrator decisions
7. **Retry logic** — exponential backoff on provider errors
8. **Model/agent/mode switching** — runtime config changes
9. **Worktree management** — git worktree setup via WorkspaceManager
10. **Memory integration** — subscribe to memory writer events
11. **PubSub broadcasting** — stream chunks, status, tool events to UI
12. **Inactivity timeout** — 30min idle → shutdown

### 2.4 Phoenix Deps in Core

`synapsis_core/mix.exs` depends on `phoenix`, `phoenix_live_view`, `bandit`. The stated guardrail is "pure business logic in synapsis_core — zero Phoenix deps in core." The actual dependency chain:

- `Phoenix.PubSub` — used directly throughout core for broadcasting
- `phoenix` — pulled as transitive dep of PubSub
- `phoenix_live_view`, `bandit` — not used in core source; stale deps from earlier scaffolding

---

## 3. Target Architecture

### 3.1 Dependency Graph (Target)

```
synapsis_data         ← Ecto schemas, Repo
    ↑
synapsis_provider     ← LLM transport, streaming, model registry
    ↑
synapsis_core         ← domain logic, tools, executor, permissions, sessions context
    ↑                    NO phoenix dep. Uses phoenix_pubsub only.
synapsis_agent        ← graph runtime, agent archetypes, coding loop nodes
    ↑                    depends on core (tools, LLM), provider, data
synapsis_plugin       ← MCP/LSP plugin host
    ↑
synapsis_workspace    ← projection, search, blob store
    ↑
synapsis_server       ← Phoenix endpoint, channels, REST, PubSub relay
    ↑
synapsis_web          ← LiveView + React hybrid UI
```

**Key change:** `synapsis_agent` moves above `synapsis_core` in the dependency graph. Agent depends on core, not core on agent. This allows graph nodes to call `Tool.Executor`, `Synapsis.LLM`, and `Synapsis.Sessions` directly.

### 3.2 Module Relocation Plan

| Module | Current Location | Target Location | Reason |
|--------|-----------------|-----------------|--------|
| `Synapsis.Agent.Resolver` | synapsis_core | synapsis_agent | Agent concern |
| `Synapsis.Session.Worker` | synapsis_core | synapsis_agent (decomposed) | Becomes graph-driven |
| `Synapsis.Session.Orchestrator` | synapsis_core | synapsis_agent | Orchestration is agent logic |
| `Synapsis.Session.Monitor` | synapsis_core | synapsis_agent | Orchestration concern |
| `Synapsis.Session.AuditorTask` | synapsis_core | synapsis_agent | Orchestration concern |
| `Synapsis.Session.Stream` | synapsis_core | synapsis_agent | Stream handling for agent loop |
| `Synapsis.Session.Compactor` | synapsis_core | stays in core | Context window is domain logic |
| `Synapsis.Session.Fork` | synapsis_core | stays in core | Session management is domain logic |
| `Synapsis.Session.Sharing` | synapsis_core | stays in core | Session management is domain logic |
| `Synapsis.Session.DynamicSupervisor` | synapsis_core | synapsis_agent | Supervises agent processes |
| `Synapsis.Session.Supervisor` | synapsis_core | synapsis_agent | Per-session supervision |
| `SynapsisCore.Application` | synapsis_core | split | Core starts Repo/PubSub/Registries; Agent starts supervisors |

### 3.3 Convergence Model

Session.Worker's agent loop becomes a graph definition executed by the Runtime.Runner:

```
┌──────────────────────────────────────────────────────┐
│  Session.Worker (thin GenServer wrapper)              │
│                                                       │
│  Owns: session_id, runner_pid, PubSub subscription    │
│  Delegates: all execution to Runner                   │
│  Handles: external API (send_message, cancel, retry)  │
│           + inactivity timeout                        │
├──────────────────────────────────────────────────────┤
│  Runtime.Runner (existing graph engine)               │
│                                                       │
│  Executes: CodingLoop graph                           │
│  Nodes: ReceiveMessage → BuildPrompt → LLMCall →     │
│         AccumulateStream → ToolDispatch →             │
│         ApprovalGate → ToolExecute →                  │
│         OrchestratorCheck → (loop or end)             │
├──────────────────────────────────────────────────────┤
│  Graph Nodes (pure functions + side effects)          │
│                                                       │
│  Each node: (state, ctx) → {patch, next_edge}         │
│  Side effects through injected dependencies           │
└──────────────────────────────────────────────────────┘
```

---

## 4. Requirements

### CV-1: Dependency Inversion

**CV-1.1** — `synapsis_agent/mix.exs` depends on `synapsis_core`, `synapsis_provider`, and `synapsis_data`.

**CV-1.2** — `synapsis_core/mix.exs` does NOT depend on `synapsis_agent`. The current `{:synapsis_agent, in_umbrella: true}` dep is removed.

**CV-1.3** — `synapsis_core/mix.exs` does NOT depend on `phoenix`, `phoenix_live_view`, or `bandit`. It depends on `phoenix_pubsub` only (standalone package, no Phoenix framework dep).

**CV-1.4** — `SynapsisCore.Application` starts only: `Repo`, `PubSub`, `TaskSupervisor` (provider), `TaskSupervisor` (tool), `Provider.Registry`, `Tool.Registry`, `FileWatcher.Registry`, `Memory.Supervisor`, `Workspace.GC`, `Oban`. No agent or server supervisors.

**CV-1.5** — `synapsis_agent` gains an `Application` module (`SynapsisAgent.Application`) that starts: `Session.Registry`, `Session.SupervisorRegistry`, `Session.DynamicSupervisor`, `Agent.Supervisor` (which starts `GlobalAssistant`, `ProjectSupervisor`, `RunRegistry`).

**CV-1.6** — Release config in root `mix.exs` changes `synapsis_agent` from `:load` to `:permanent`.

**CV-1.7** — `synapsis_server` depends on `synapsis_agent` (replaces its current dep on `synapsis_core` for session management). `synapsis_server` still depends on `synapsis_core` for non-session domain logic.

**CV-1.8** — `synapsis_plugin` dependency is unchanged (depends on `synapsis_core`).

### CV-2: Session.Worker Decomposition

**CV-2.1** — `Synapsis.Session.Worker` is reduced to < 200 LOC. It is a GenServer that:
- Holds `session_id`, `runner_pid`, and configuration
- Translates external API calls (`send_message`, `cancel`, `retry`, `switch_*`) into graph inputs
- Manages inactivity timeout
- Subscribes to Runner events and relays to PubSub

**CV-2.2** — `Synapsis.Agent.Graphs.CodingLoop` defines the graph that replaces the Worker's internal loop:

```elixir
@type coding_loop_state :: %{
  session_id: String.t(),
  messages: [map()],
  pending_text: String.t(),
  pending_tool_use: map() | nil,
  pending_tool_input: String.t(),
  pending_reasoning: String.t(),
  tool_uses: [map()],
  monitor: Monitor.t(),
  iteration_count: non_neg_integer(),
  provider_config: map(),
  agent_config: map(),
  worktree_path: String.t() | nil
}
```

**CV-2.3** — The CodingLoop graph has these nodes:

| Node | Module | Responsibility |
|------|--------|---------------|
| `:receive` | `Nodes.ReceiveMessage` | Wait for user input, persist to DB |
| `:build_prompt` | `Nodes.BuildPrompt` | Load messages, build provider request via MessageBuilder |
| `:llm_stream` | `Nodes.LLMStream` | Start provider stream, accumulate chunks |
| `:process_response` | `Nodes.ProcessResponse` | Flush accumulated text/tools to DB, broadcast |
| `:tool_dispatch` | `Nodes.ToolDispatch` | Permission check, route to approval or execute |
| `:approval_gate` | `Nodes.ApprovalGate` | Pause graph, wait for user approval/denial |
| `:tool_execute` | `Nodes.ToolExecute` | Run tools via Executor, persist results |
| `:orchestrate` | `Nodes.Orchestrate` | Monitor.record + Orchestrator.decide |
| `:escalate` | `Nodes.Escalate` | Invoke AuditorTask with LLM call |
| `:complete` | `Nodes.Complete` | Final state, report to parent if applicable |

**CV-2.4** — Graph edges:

```
:receive → :build_prompt
:build_prompt → :llm_stream
:llm_stream → :process_response
:process_response → {:route, fn state ->
  if Enum.empty?(state.tool_uses), do: :complete, else: :tool_dispatch
end}
:tool_dispatch → {:route, fn state ->
  if needs_approval?(state), do: :approval_gate, else: :tool_execute
end}
:approval_gate → {:route, fn state ->
  if approved?(state), do: :tool_execute, else: :process_denial
end}
:tool_execute → :orchestrate
:orchestrate → {:route, fn state ->
  case state.decision do
    :continue -> :build_prompt
    :pause -> :receive
    :escalate -> :escalate
    :terminate -> :complete
  end
end}
:escalate → :build_prompt
:complete → :end
```

**CV-2.5** — Each node implements `SynapsisAgent.Runtime.Node`:

```elixir
@callback execute(state :: map(), ctx :: map()) ::
  {:ok, patch :: map()}
  | {:pause, patch :: map()}
  | {:error, reason :: term(), patch :: map()}
```

**CV-2.6** — Provider streaming in `:llm_stream` node uses `{:pause, patch}` to yield control while the stream is active. The Runner's event_handler receives stream chunks and calls `Runner.resume/2` when the stream completes.

**CV-2.7** — The `:approval_gate` node uses `{:pause, patch}` and resumes when the Worker forwards an `approve_tool`/`deny_tool` message to the Runner.

### CV-3: Agent Application Bootstrap

**CV-3.1** — `SynapsisAgent.Application` supervision tree:

```
SynapsisAgent.Supervisor (strategy: :rest_for_one)
├── Registry (keys: :unique, name: Synapsis.Session.Registry)
├── Registry (keys: :unique, name: Synapsis.Session.SupervisorRegistry)
├── Synapsis.Session.DynamicSupervisor
├── Registry (keys: :unique, name: Synapsis.Agent.ProjectRegistry)
├── Registry (keys: :unique, name: Synapsis.Agent.Runtime.RunRegistry)
├── DynamicSupervisor (name: Synapsis.Agent.ProjectSupervisor)
└── Synapsis.Agent.GlobalAssistant
```

**CV-3.2** — `Synapsis.Sessions` context module stays in `synapsis_core` as a thin facade. Functions that start/manage Worker processes (`ensure_running/1`, `send_message/2`, `cancel/1`, etc.) delegate to `Synapsis.Session.Worker` in `synapsis_agent`. Functions that query session data (`list/0`, `get/1`, `get_messages/1`) stay as Ecto queries in core.

**CV-3.3** — After boot, `SynapsisAgent.Application` calls `Synapsis.Tool.Builtin.register_all/0` and `Synapsis.Workspace.Tools.register_all/0`. This registration logic moves out of `SynapsisCore.Application`.

### CV-4: Auditor LLM Wiring

**CV-4.1** — `Synapsis.Session.AuditorTask` (relocated to `synapsis_agent`) makes a real LLM call, not a stub. It uses `Synapsis.LLM.complete/2` with the session's configured auditor model (defaults to the same model as the session, can be overridden to a cheaper model via agent config).

**CV-4.2** — The auditor prompt includes:
- The session's recent failed attempts (from `FailedAttempt` schema)
- The current tool call that triggered escalation
- The Monitor's signal history
- The Orchestrator's reason string

**CV-4.3** — The auditor response is parsed for:
- `{:constraint, text}` — added to `FailedAttempt`, injected into next prompt via `PromptBuilder`
- `{:abort, reason}` — terminates the session loop with an explanation message
- `{:continue, guidance}` — guidance text prepended to next LLM call as system context

**CV-4.4** — Auditor invocation is async via `Task.Supervisor`. The graph pauses at `:escalate` node and resumes when the auditor task completes.

### CV-5: PubSub Extraction

**CV-5.1** — `synapsis_core` depends on `{:phoenix_pubsub, "~> 2.1"}` directly, not on `:phoenix`.

**CV-5.2** — Remove `{:phoenix, "~> 1.8"}`, `{:phoenix_live_view, "~> 1.0"}`, and `{:bandit, "~> 1.6"}` from `synapsis_core/mix.exs`.

**CV-5.3** — Any module in `synapsis_core` that imports or aliases Phoenix modules (other than `Phoenix.PubSub`) is refactored to remove the dep. If `Phoenix.Channel` or `Phoenix.LiveView` types appear in core specs, replace with generic types.

### CV-6: Session-Agent Bridge

**CV-6.1** — `Synapsis.Sessions.send_message/2` resolves the target agent:
- If the session has `agent_type: :general` → route through Worker/CodingLoop directly
- If the session has `agent_type: :global` → route through `GlobalAssistant.dispatch_work/1`
- Default (current behavior) → route through Worker/CodingLoop

**CV-6.2** — `GlobalAssistant` can spawn sessions. When it receives a work item that requires a coding agent, it creates a session (via `Synapsis.Sessions.create/1`) and starts a Worker with the CodingLoop graph.

**CV-6.3** — `ProjectAssistant` populates context for spawned General agents:
- Project file tree (from `ContextBuilder.build_context/1`)
- Recent git log
- Active diagnostics
- Relevant memory entries
- Skill prompts

**CV-6.4** — Agent-to-agent messaging uses existing PubSub typed envelopes:

```elixir
@type envelope :: %{
  from: agent_id(),
  to: agent_id(),
  ref: String.t(),
  type: :user_message | :agent_message | :delegation | :notification | :completion,
  payload: term(),
  timestamp: DateTime.t()
}
```

### CV-7: Frontend Boundary Contract

**CV-7.1** — LiveView surfaces (server-rendered, form-driven):
- Provider configuration (`/providers`, `/providers/:id`)
- LSP configuration (`/lsp`, `/lsp/:id`)
- MCP configuration (`/mcp`, `/mcp/:id`)
- Memory browser (`/memory`, `/memory/:id`)
- Workspace explorer (`/workspace`)
- Skill management (`/skills`, `/skills/:id`)
- Project management (`/projects`, `/projects/:id`)
- Settings (`/settings`)
- Model tier configuration (`/model-tiers`)
- Dashboard (`/`)

**CV-7.2** — React surfaces (client-rendered, real-time via Channel):
- Chat/session interaction (`/assistant`, `/assistant/:session_id`)
- Streaming text, tool calls, permission dialogs
- Agent status indicators
- Session list sidebar

**CV-7.3** — The boundary rule: **If it streams LLM output or requires sub-second reactivity, it's React. If it's CRUD or configuration, it's LiveView.**

**CV-7.4** — React components receive all data through Phoenix Channels. No REST polling for chat state.

**CV-7.5** — LiveView pages can embed React components via hooks (existing `packages/hooks` pattern). The inverse is not supported — React surfaces do not embed LiveView.

---

## 5. Non-Goals

- **Rewriting the graph runtime.** The existing `Runtime.Runner`, `Graph`, `Node`, checkpoint system are kept as-is. This PRD adds graph definitions and nodes, not runtime changes.
- **Multi-agent fan-out.** Committee-synthesis and fan-out patterns are deferred. This PRD connects the single-session coding loop to the graph runtime.
- **`synapsis_tool` extraction.** Tools remain in `synapsis_core` for now. The tool PRD's proposed `apps/synapsis_tool/` extraction is a separate effort.
- **Samgita integration.** The CLI-first process manager architecture for Samgita is out of scope.
- **Authentication/authorization.** No user auth system in this phase.

---

## 6. Implementation Phases

### Phase 1: Dependency Inversion

**Goal:** Fix the dependency graph so `synapsis_agent` can depend on `synapsis_core`.

**Requirements:** CV-1.1, CV-1.2, CV-1.3, CV-1.4, CV-1.5, CV-1.6, CV-5.1, CV-5.2, CV-5.3

**Steps:**

1. Remove `{:synapsis_agent, in_umbrella: true}` from `synapsis_core/mix.exs`
2. Add `{:synapsis_core, in_umbrella: true}` and `{:synapsis_provider, in_umbrella: true}` to `synapsis_agent/mix.exs`
3. Replace `{:phoenix, "~> 1.8"}` with `{:phoenix_pubsub, "~> 2.1"}` in `synapsis_core/mix.exs`. Remove `phoenix_live_view` and `bandit`.
4. Create `SynapsisAgent.Application` with supervision tree per CV-3.1
5. Split `SynapsisCore.Application`: move session registries and DynamicSupervisor to agent app
6. Update root `mix.exs` release config: `synapsis_agent: :permanent`
7. Update `synapsis_server/mix.exs` to add `{:synapsis_agent, in_umbrella: true}`
8. Fix all compilation errors from moved modules

**Tests:**

```
test/synapsis_agent/application_test.exs
├── describe "start/2"
│   ├── starts all registries
│   ├── starts DynamicSupervisor
│   ├── starts GlobalAssistant
│   ├── registers built-in tools
│   └── registers workspace tools
├── describe "supervision"
│   ├── restarts GlobalAssistant on crash
│   ├── restarts DynamicSupervisor on crash
│   └── rest_for_one strategy propagates

test/synapsis_core/application_test.exs
├── describe "start/2"
│   ├── starts Repo
│   ├── starts PubSub
│   ├── starts Provider.Registry
│   ├── starts Tool.Registry
│   ├── starts Memory.Supervisor
│   ├── does NOT start Agent.Supervisor
│   ├── does NOT start Session.DynamicSupervisor
│   └── does NOT start Server.Supervisor

test/synapsis_core/deps_test.exs
├── describe "dependency purity"
│   ├── no Phoenix module references in core source (except PubSub)
│   └── no synapsis_agent references in core source
```

**Checkpoint:** `mix compile --warnings-as-errors && mix test` — all green. No circular deps. `mix xref graph` confirms acyclic.

---

### Phase 2: Worker Decomposition — Extract Pure Functions

**Goal:** Extract the 12 concerns from Session.Worker into focused modules without changing behavior.

**Requirements:** CV-2.1, CV-2.5

**Modules created:**

| Module | Extracted From | Responsibility |
|--------|---------------|---------------|
| `Synapsis.Agent.StreamAccumulator` | `handle_stream_event/2` clauses | Pure function: `(event, acc) → acc`. No GenServer state. |
| `Synapsis.Agent.ResponseFlusher` | `process_tool_uses/1`, content block assembly | Persist accumulated text/tools/reasoning to DB, broadcast |
| `Synapsis.Agent.ToolDispatcher` | `execute_tool/2`, `execute_tool_async/2` | Permission check → async dispatch → result collection |

**Tests:**

```
test/synapsis_agent/stream_accumulator_test.exs
├── describe "accumulate/2"
│   ├── text_delta appends to pending_text
│   ├── tool_use_start creates pending_tool_use
│   ├── tool_input_delta appends to pending_tool_input
│   ├── tool_use_complete pushes to tool_uses list
│   ├── reasoning_delta appends to pending_reasoning
│   ├── content_block_stop flushes pending tool_use
│   ├── handles interleaved text and tool events
│   ├── handles multiple tool_use blocks in sequence
│   └── ignores :message_start, :message_delta, :done, :ignore

test/synapsis_agent/response_flusher_test.exs
├── describe "flush_text/3"
│   ├── creates assistant message with text part
│   ├── creates assistant message with reasoning part
│   ├── broadcasts text_complete event
│   └── handles empty text (no-op)
├── describe "flush_tool_uses/3"
│   ├── creates tool_use parts on assistant message
│   ├── broadcasts tool_call events per tool
│   └── handles empty tool_uses (no-op)

test/synapsis_agent/tool_dispatcher_test.exs
├── describe "dispatch/3"
│   ├── executes allowed tools immediately
│   ├── returns :needs_approval for write tools in interactive mode
│   ├── auto-approves in autonomous mode
│   ├── executes batch concurrently
│   ├── serializes file-conflicting tools
│   └── handles tool execution errors
├── describe "apply_result/3"
│   ├── persists tool_result to DB
│   ├── broadcasts tool_result event
│   └── records in Monitor
```

**Checkpoint:** `mix test` — Worker behavior is unchanged. Extracted modules have full unit test coverage. Worker LOC reduced to ~600.

---

### Phase 3: CodingLoop Graph Definition

**Goal:** Define the CodingLoop graph and implement all nodes. Worker delegates to Runner.

**Requirements:** CV-2.2, CV-2.3, CV-2.4, CV-2.6, CV-2.7

**Modules created:**

```
apps/synapsis_agent/lib/synapsis/agent/graphs/coding_loop.ex
apps/synapsis_agent/lib/synapsis/agent/nodes/receive_message.ex
apps/synapsis_agent/lib/synapsis/agent/nodes/build_prompt.ex
apps/synapsis_agent/lib/synapsis/agent/nodes/llm_stream.ex
apps/synapsis_agent/lib/synapsis/agent/nodes/process_response.ex
apps/synapsis_agent/lib/synapsis/agent/nodes/tool_dispatch.ex
apps/synapsis_agent/lib/synapsis/agent/nodes/approval_gate.ex
apps/synapsis_agent/lib/synapsis/agent/nodes/tool_execute.ex
apps/synapsis_agent/lib/synapsis/agent/nodes/orchestrate.ex
apps/synapsis_agent/lib/synapsis/agent/nodes/escalate.ex
apps/synapsis_agent/lib/synapsis/agent/nodes/complete.ex
```

**Tests:**

```
test/synapsis_agent/graphs/coding_loop_test.exs
├── describe "build/1"
│   ├── creates valid graph
│   ├── all nodes resolve
│   ├── all edge targets exist
│   ├── start node is :receive
│   └── reducers merge messages via :append

test/synapsis_agent/nodes/receive_message_test.exs
├── describe "execute/2"
│   ├── pauses and waits for input
│   ├── resumes with user message in patch
│   └── persists user message to DB

test/synapsis_agent/nodes/build_prompt_test.exs
├── describe "execute/2"
│   ├── loads messages from DB
│   ├── builds request via MessageBuilder
│   ├── injects failure context from PromptBuilder
│   ├── calls Compactor.maybe_compact before loading
│   └── includes agent system prompt

test/synapsis_agent/nodes/llm_stream_test.exs
├── describe "execute/2"
│   ├── starts provider stream
│   ├── pauses while streaming
│   ├── accumulates chunks via StreamAccumulator
│   ├── resumes on stream completion with accumulated state
│   ├── handles provider error with retry
│   ├── respects max retry count (3)
│   └── cancellation stops stream and returns partial state

test/synapsis_agent/nodes/process_response_test.exs
├── describe "execute/2"
│   ├── flushes text to DB via ResponseFlusher
│   ├── flushes tool_uses to DB via ResponseFlusher
│   ├── routes to :complete when no tool_uses
│   └── routes to :tool_dispatch when tool_uses present

test/synapsis_agent/nodes/tool_dispatch_test.exs
├── describe "execute/2"
│   ├── routes to :tool_execute when all tools auto-approved
│   ├── routes to :approval_gate when any tool needs approval
│   └── marks each tool with permission status

test/synapsis_agent/nodes/approval_gate_test.exs
├── describe "execute/2"
│   ├── pauses graph
│   ├── broadcasts permission_request events
│   ├── resumes with :approved → routes to :tool_execute
│   ├── resumes with :denied → injects denial result, routes to :build_prompt
│   └── handles mixed approve/deny for batch

test/synapsis_agent/nodes/tool_execute_test.exs
├── describe "execute/2"
│   ├── dispatches via ToolDispatcher
│   ├── persists all tool results
│   ├── broadcasts tool_result events
│   ├── records in Monitor
│   └── handles tool execution crash gracefully

test/synapsis_agent/nodes/orchestrate_test.exs
├── describe "execute/2"
│   ├── :continue → routes to :build_prompt
│   ├── :pause → routes to :receive (waits for user)
│   ├── :escalate → routes to :escalate
│   ├── :terminate → routes to :complete with reason
│   └── increments iteration_count

test/synapsis_agent/nodes/escalate_test.exs
├── describe "execute/2"
│   ├── invokes AuditorTask with context
│   ├── pauses while auditor runs
│   ├── resumes with :constraint → adds to FailedAttempt, routes to :build_prompt
│   ├── resumes with :abort → routes to :complete
│   └── resumes with :continue → prepends guidance, routes to :build_prompt

test/synapsis_agent/nodes/complete_test.exs
├── describe "execute/2"
│   ├── updates session status to idle
│   ├── broadcasts session_complete
│   ├── notifies parent agent if present
│   └── returns :end edge
```

**Checkpoint:** `mix test` — all node tests pass with mocked provider/tools. Graph validates. Runner can execute CodingLoop graph in isolation.

---

### Phase 4: Worker-Runner Integration

**Goal:** Session.Worker delegates to Runner. End-to-end flow works.

**Requirements:** CV-2.1, CV-6.1

**Changes:**

- `Session.Worker.init/1` creates a `Runtime.Runner` with the `CodingLoop` graph
- `send_message/3` sends input to Runner via `Runner.resume/2` (if paused at `:receive`) or queues
- `cancel/1` calls `Runner.cancel/1`
- `approve_tool/2` and `deny_tool/2` send decisions to Runner via `Runner.resume/2`
- Runner's `event_handler` broadcasts to PubSub (replacing Worker's direct broadcasts)
- `switch_agent/2`, `switch_model/3`, `switch_mode/2` update Runner context

**Tests:**

```
test/synapsis_agent/worker_integration_test.exs
├── describe "send_message/3"
│   ├── starts Runner if not running
│   ├── resumes Runner if paused at :receive
│   ├── rejects if Runner is mid-execution
│   └── persists user message and starts streaming
├── describe "cancel/1"
│   ├── cancels active stream
│   ├── stops Runner
│   └── broadcasts cancellation
├── describe "approve_tool/2"
│   ├── resumes Runner past approval gate
│   └── tool executes and results persist
├── describe "deny_tool/2"
│   ├── resumes Runner with denial
│   └── LLM receives denial result on next iteration
├── describe "retry/1"
│   ├── restarts Runner from checkpoint
│   └── resumes from last successful state
├── describe "end-to-end"
│   ├── user message → LLM stream → text response → idle
│   ├── user message → LLM stream → tool call → approve → execute → LLM → response
│   ├── user message → LLM stream → tool call → deny → LLM adapts → response
│   ├── tool loop triggers orchestrator escalation
│   ├── max iterations triggers termination
│   └── inactivity timeout shuts down worker

test/synapsis_agent/channel_integration_test.exs
├── describe "session channel"
│   ├── join loads messages and starts worker
│   ├── session:message triggers graph execution
│   ├── receives streaming chunks via PubSub
│   ├── receives tool_call events
│   ├── session:tool_approve resumes graph
│   ├── session:tool_deny resumes graph with denial
│   ├── session:cancel stops graph
│   └── session:retry restarts from checkpoint
```

**Checkpoint:** `mix test` — full round-trip works. Channel tests pass. UI interaction is unchanged from user perspective.

---

### Phase 5: Auditor Wiring

**Goal:** Escalation path invokes a real LLM call.

**Requirements:** CV-4.1, CV-4.2, CV-4.3, CV-4.4

**Tests:**

```
test/synapsis_agent/auditor_task_test.exs
├── describe "run/2"
│   ├── calls LLM with auditor prompt
│   ├── prompt includes failed attempts
│   ├── prompt includes monitor signals
│   ├── prompt includes orchestrator reason
│   ├── parses :constraint response
│   ├── parses :abort response
│   ├── parses :continue response
│   ├── handles LLM error gracefully (falls back to :continue)
│   └── respects auditor model override

test/synapsis_agent/nodes/escalate_integration_test.exs
├── describe "with mocked provider"
│   ├── constraint response adds FailedAttempt and continues
│   ├── abort response terminates session with message
│   └── continue response prepends guidance to next prompt
```

**Checkpoint:** `mix test` — auditor invocation is no longer a stub. Escalation path completes end-to-end with Bypass-mocked provider.

---

### Phase 6: Multi-Agent Activation

**Goal:** GlobalAssistant and ProjectAssistant can spawn coding sessions.

**Requirements:** CV-6.2, CV-6.3, CV-6.4

**Tests:**

```
test/synapsis_agent/global_assistant_integration_test.exs
├── describe "dispatch_work/1"
│   ├── creates session for coding work item
│   ├── starts Worker with CodingLoop graph
│   ├── passes context from ProjectAssistant
│   └── receives completion notification

test/synapsis_agent/project_assistant_integration_test.exs
├── describe "context injection"
│   ├── spawned session includes project file tree
│   ├── spawned session includes recent git log
│   ├── spawned session includes active diagnostics
│   ├── spawned session includes memory entries
│   └── spawned session includes skill prompts

test/synapsis_agent/agent_messaging_test.exs
├── describe "PubSub envelopes"
│   ├── user message reaches GlobalAssistant
│   ├── GlobalAssistant delegates to ProjectAssistant
│   ├── ProjectAssistant spawns General session
│   ├── General session reports completion to ProjectAssistant
│   └── ProjectAssistant reports to GlobalAssistant
```

**Checkpoint:** `mix test` — multi-agent delegation path works end-to-end with mocked provider. Agent archetypes activate correctly.

---

## 7. Migration Strategy

### 7.1 Feature Flag Approach

The convergence is gated behind a runtime flag: `config :synapsis_agent, :use_graph_worker, false`.

- `false` (default) — existing Session.Worker loop runs as-is
- `true` — new graph-based Worker is used

This allows incremental rollout and immediate rollback.

### 7.2 Phase Ordering Rationale

Phases 1–2 are safe refactors — no behavior change, just module relocation and extraction. Phase 3 builds new code alongside existing code. Phase 4 is the critical swap — gated by feature flag. Phases 5–6 build on the new foundation.

### 7.3 Rollback Plan

If graph-based execution introduces regressions:
1. Set `use_graph_worker: false` — immediate rollback to existing Worker
2. The old Worker code is preserved (renamed to `Session.LegacyWorker`) until Phase 6 is stable
3. Both paths share the same DB schema, PubSub topics, and channel protocol — no data migration needed

---

## 8. Acceptance Criteria

- [ ] `mix xref graph --format dot` shows no circular dependencies
- [ ] `synapsis_core/mix.exs` has zero Phoenix deps (only `phoenix_pubsub`)
- [ ] `synapsis_agent` starts as `:permanent` in release
- [ ] `Session.Worker` is < 200 LOC
- [ ] CodingLoop graph executes: message → stream → tool → approve → execute → respond
- [ ] Orchestrator escalation invokes real LLM call via AuditorTask
- [ ] GlobalAssistant can spawn a coding session via WorkItem dispatch
- [ ] All 142+ existing tests pass without modification (or with mechanical import path changes)
- [ ] Feature flag allows instant rollback to legacy Worker
- [ ] Channel protocol is unchanged — React frontend works without modification

---

## 9. Open Questions

None. All architectural decisions resolved during review.
