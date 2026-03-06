# 07 — Agent System

## What This System Does

The agent system provides a persistent orchestration layer for coordinating long-running development workflows across multiple projects. It implements a LangGraph-inspired state machine runtime for composing LLM-driven workflows in Elixir.

The agent system lives in `synapsis_agent` — a **pure library package** (no OTP application). All its processes are supervised by `synapsis_core`.

## Dependency Position

```
synapsis_data        (schemas, Repo — no deps)
  ↑
synapsis_agent       (orchestration, graph runtime — depends on synapsis_data, no application)
  ↑
synapsis_provider    (LLM transports — depends on synapsis_data, no application)
  ↑
synapsis_core        (THE application — starts agent supervision, wires providers/tools)
  ↑
synapsis_web/server  (presentation layers)
```

`synapsis_agent` depends only on `synapsis_data` for persistence. It knows nothing about providers, tools, or sessions. Those are injected at runtime by `synapsis_core`.

---

## Agent Hierarchy

Three layers with clearly defined responsibilities:

```
Global Assistant          (singleton — system control center)
        |
        | dispatch work
        v
Project Assistant         (per project — task executor)
        |
        | routing decisions
        v
Specialist Agents         (reusable system services)
```

---

## Global Assistant

Singleton GenServer acting as the system control center.

### Responsibilities

- **Project Registry** — maintain registry of all active projects (id, status, PID, recent activity)
- **Task Dispatch** — receive work requests, convert to WorkItems, dispatch to appropriate Project Assistant
- **Global Memory** — track system events, configuration changes, project summaries

### API

```elixir
GlobalAssistant.start_project(project_id, metadata)
GlobalAssistant.dispatch_work(work_item)
GlobalAssistant.list_projects()
GlobalAssistant.project_status(project_id)
```

### State

```elixir
%{
  projects: %{
    project_id => %{
      project_id: String.t(),
      pid: pid(),
      status: :idle | :busy,
      current_work_id: String.t() | nil,
      queue_length: non_neg_integer(),
      recent_activity_at: DateTime.t(),
      metadata: map()
    }
  }
}
```

---

## Project Assistant

Per-project GenServer responsible for all work inside a project.

### Responsibilities

- **Task Queue** — sequential execution, write operation serialization, long-running task supervision
- **Routing Decisions** — determine workflow, skill, and specialist agents for each WorkItem
- **Execution Supervision** — step tracking, error handling, retry decisions, cancellation
- **Project Memory** — task events, tool calls, file modifications, failure diagnostics

### Provider & Tool Injection

The Project Assistant receives a provider config at startup and can update it at runtime:

```elixir
# Provider is passed in when starting the project
GlobalAssistant.start_project("my-project", %{
  provider: %{module: Synapsis.Provider.Anthropic, config: %{model: "claude-sonnet-4-20250514"}},
  tools: [:file_read, :file_edit, :bash, :grep]
})

# Provider can be updated while running
ProjectAssistant.update_provider(pid, %{module: Synapsis.Provider.OpenAI, config: %{model: "gpt-4o"}})
```

Tool execution is dispatched via `GenServer.call` — the agent sends a tool request message to a tool dispatcher process (provided by `synapsis_core` at startup), which executes the tool and returns the result synchronously.

```elixir
# Inside a graph node, tool dispatch happens via the injected dispatcher
tool_result = GenServer.call(tool_dispatcher, {:execute, :file_read, %{path: "lib/app.ex"}})
```

### State

```elixir
%{
  project_id: String.t(),
  behaviour: module(),
  behaviour_state: term(),
  provider: %{module: module(), config: map()},
  tool_dispatcher: pid() | atom(),
  queue: :queue.queue(WorkItem.t()),
  current_work: WorkItem.t() | nil
}
```

### API

```elixir
ProjectAssistant.enqueue(pid, work_item)
ProjectAssistant.status(pid)
ProjectAssistant.update_provider(pid, provider_config)
```

---

## Specialist Agents

Reusable system services executed as graph nodes or standalone GenServers. Each specialist implements the `Synapsis.Agent.Runtime.Node` behaviour.

### Contract

```elixir
# Every specialist agent is a Node that can be composed into graphs
@behaviour Synapsis.Agent.Runtime.Node

@callback run(workflow_state :: map(), context :: map()) ::
  {:next, selector :: atom(), workflow_state :: map()}
  | {:end, workflow_state :: map()}
  | {:wait, workflow_state :: map()}
```

### Defined Specialists

| Agent | Responsibilities | Node Module |
|---|---|---|
| MCP Manager | Tool registry, connection pools, lease management, health checks | `Synapsis.Agent.Nodes.MCPManager` |
| Tool Runtime | Command execution, filesystem interaction, git operations | `Synapsis.Agent.Nodes.ToolRuntime` |
| Patch Manager | Applying diffs, conflict detection, rollback management | `Synapsis.Agent.Nodes.PatchManager` |
| Test Runner | Test execution, diagnostics collection, structured failure reporting | `Synapsis.Agent.Nodes.TestRunner` |
| Indexer | Code indexing, symbol lookup, dependency navigation | `Synapsis.Agent.Nodes.Indexer` |

### Lifecycle

Specialist agents are **stateless graph nodes** — they receive workflow state, perform work (possibly via injected tool dispatcher), and return updated state with a transition selector. They do not manage their own processes.

For long-running specialist work (e.g., test execution), the node can return `{:wait, state}` to pause the graph and resume when results are available.

---

## WorkItem

Standardized dispatch unit from Global to Project Assistants.

```elixir
%WorkItem{
  work_id: String.t(),
  project_id: String.t(),
  task_type: atom(),          # :command_execution | :skill_invocation | :maintenance | :ad_hoc_prompt
  payload: map(),
  priority: :low | :normal | :high | :critical,
  constraints: map(),
  origin: :user | :webhook | :system | :scheduled,
  inserted_at: DateTime.t()
}
```

---

## Runtime Graph Engine

A LangGraph-inspired state machine runtime. Core execution model:

```
state -> node -> state -> node -> ... -> END
```

### Graph Definition

```elixir
%Graph{
  nodes: %{atom() => module()},                           # node_name => Node behaviour module
  edges: %{atom() => atom() | %{atom() => atom()}},       # static or conditional edges
  start: atom()
}
```

Edge types:
- **Static**: `%{planner: :executor}` — always transition
- **Conditional**: `%{executor: %{ok: :finish, error: :retry}}` — branch by selector

### Node Behaviour

```elixir
@callback run(workflow_state :: map(), context :: map()) ::
  {:next, selector :: atom(), workflow_state :: map()}  # transition via edge
  | {:end, workflow_state :: map()}                      # terminate run
  | {:wait, workflow_state :: map()}                     # pause for external input
```

### Runner (Execution Engine)

GenServer executing one graph run. State machine:

```
:running -> execute node -> update state -> resolve next -> loop
:running -> {:wait, state} -> :waiting (checkpoint saved to DB)
:waiting -> resume(ctx_updates) -> :running
:running -> {:end, state} -> :completed
:running -> error -> :failed
```

API:

```elixir
Runner.run(graph, state, opts)              # synchronous: start + await + stop
Runner.start_link(opts)                     # async: start linked runner
Runner.await(pid_or_run_id, timeout)        # block until terminal state
Runner.snapshot(pid_or_run_id)              # query current state
Runner.resume(pid_or_run_id, ctx_updates)   # unpause waiting runner
Runner.start_from_checkpoint(run_id)        # restore from DB checkpoint
```

### ProjectGraph Adapter

Maps the `Behaviour` contract into a runtime graph:

```
route -> execute -> summarize -> END
```

Each node delegates to the project's `Behaviour` module callbacks.

---

## Behaviour Contract

Pluggable project workflows via callback modules:

```elixir
@callback init(project_id :: String.t(), opts :: map()) :: {:ok, behaviour_state()}

@callback route(work_item :: WorkItem.t(), state :: behaviour_state()) ::
  {:ok, route_plan(), behaviour_state()} | {:error, term(), behaviour_state()}

@callback execute(work_item :: WorkItem.t(), route_plan :: map(), state :: behaviour_state()) ::
  {:ok, execution_result(), behaviour_state()} | {:error, term(), behaviour_state()}

@callback summarize(work_item :: WorkItem.t(), execution_result :: map(), state :: behaviour_state()) ::
  {:ok, summary(), behaviour_state()} | {:error, term(), behaviour_state()}
```

Default implementation: `Synapsis.Agent.Behaviours.DefaultProject`.

For more complex workflows (tool loops, reflection cycles), use the graph engine directly instead of the Behaviour contract:

```elixir
# Example: tool-calling agent loop
%Graph{
  nodes: %{
    plan: PlannerNode,
    call_llm: LLMNode,
    execute_tool: ToolRuntimeNode,
    review: ReviewNode
  },
  edges: %{
    plan: :call_llm,
    call_llm: %{tool_use: :execute_tool, done: :review},
    execute_tool: :call_llm,       # feed tool result back to LLM
    review: %{ok: :end, retry: :plan}
  },
  start: :plan
}
```

---

## Persistence (through synapsis_data)

All agent state is persisted to PostgreSQL. Database is the source of truth.

### Event Store

Append-only event log. Ecto schema in `synapsis_data`.

```elixir
# Schema: Synapsis.Data.AgentEvent
%AgentEvent{
  id: Ecto.UUID,
  event_type: String.t(),       # "task_received" | "routing_decision" | "tool_invoked" | "task_completed"
  project_id: String.t() | nil,
  work_id: String.t() | nil,
  payload: map(),               # JSONB
  inserted_at: DateTime.t()
}
```

API (in `synapsis_agent`, calls through `Synapsis.Data.AgentEvents`):

```elixir
Agent.append_event(attrs)       # => {:ok, event}
Agent.list_events(filters)      # => [event]
```

### Summary Store

Keyed summaries for reporting and knowledge accumulation.

```elixir
# Schema: Synapsis.Data.AgentSummary
%AgentSummary{
  id: Ecto.UUID,
  scope: String.t(),            # "global" | "project" | "task"
  scope_id: String.t(),
  kind: String.t(),             # "task_result" | "daily" | "weekly"
  content: String.t(),
  metadata: map(),              # JSONB
  inserted_at: DateTime.t(),
  updated_at: DateTime.t()
}
```

Unique constraint on `{scope, scope_id, kind}` — upsert on conflict.

### Checkpoint Store

Durable snapshots for resumable graph execution.

```elixir
# Schema: Synapsis.Data.AgentCheckpoint
%AgentCheckpoint{
  id: Ecto.UUID,
  run_id: String.t(),
  graph_data: map(),            # JSONB — serialized graph definition
  node: String.t() | nil,
  status: String.t(),           # "running" | "waiting" | "completed" | "failed"
  state: map(),                 # JSONB — workflow state
  ctx: map(),                   # JSONB — context
  error: map() | nil,           # JSONB
  inserted_at: DateTime.t(),
  updated_at: DateTime.t()
}
```

Unique constraint on `run_id` — upsert on each state transition.

### Runtime Events

Lifecycle events emitted during graph execution (broadcast via PubSub, persisted as AgentEvents):

```
:agent_started | :agent_waiting | :agent_resumed |
:agent_finished | :agent_failed | :node_started | :node_finished
```

---

## Supervision (within synapsis_core)

`synapsis_agent` defines supervisor modules but does **not** start them. `SynapsisCore.Application` starts all agent processes:

```
SynapsisCore.Application
├── ... (existing: Repo, PubSub, Sessions, Tools, MCP, LSP, etc.)
│
├── Registry (name: Synapsis.Agent.ProjectRegistry)
├── Registry (name: Synapsis.Agent.Runtime.RunRegistry)
├── DynamicSupervisor (name: Synapsis.Agent.ProjectSupervisor)
│     └── ProjectAssistant * N (per project, spawned on demand)
├── GlobalAssistant
└── ...
```

Startup order: Registries -> DynamicSupervisor -> GlobalAssistant (after Repo is available for persistence).

---

## Integration with Existing Systems

### Agent <-> Session

The agent system and session system serve different purposes:

| | Session | Agent |
|---|---|---|
| **Scope** | Single conversation | Multi-task project workflow |
| **Lifetime** | User-initiated, ephemeral | System-managed, persistent |
| **LLM calls** | Direct via Session.Stream | Via injected provider in graph nodes |
| **Tool use** | Inline in conversation loop | Dispatched via GenServer.call to tool dispatcher |

An agent node **may** create a session for complex tasks that require conversational LLM interaction, but most agent work uses direct provider calls through the injected provider config.

### Agent <-> Tools

Tools are not called directly by `synapsis_agent` (it has no dependency on `synapsis_core`). Instead:

1. `synapsis_core` starts a tool dispatcher process
2. The dispatcher PID is passed to ProjectAssistant at startup
3. Graph nodes send `GenServer.call(dispatcher, {:execute, tool_name, params})` to run tools
4. The dispatcher executes through `Synapsis.Tool.Registry` and returns results

### Agent <-> Providers

Providers are injected, not imported:

1. Provider module + config are passed to ProjectAssistant at startup
2. Graph nodes that need LLM calls receive provider info via workflow context
3. Provider can be updated at runtime via `ProjectAssistant.update_provider/2`
4. The calling node is responsible for invoking the provider's streaming/request API

### Agent <-> Web UI

`SynapsisWeb.AssistantLive` provides the UI:

1. On mount, starts the `__global__` project via `Agent.start_project/2`
2. User prompts are dispatched as `:ad_hoc_prompt` WorkItems
3. Status queries use `Agent.list_projects/0` and `Agent.list_events/1`
4. Runtime events broadcast via PubSub for real-time updates

---

## Data Flow: User Request -> Agent Execution

```
1. User sends prompt via AssistantLive
         |
         v
2. Agent.dispatch_work(%{project_id: "proj-1", task_type: :ad_hoc_prompt, ...})
         |
         v
3. GlobalAssistant routes to ProjectAssistant (creates if needed)
         |
         v
4. ProjectAssistant enqueues WorkItem, starts execution
         |
         v
5. ProjectGraph runs: route -> execute -> summarize
         |
         |  (inside execute node)
         v
6. Node calls LLM via injected provider
         |
         v
7. LLM responds with tool_use -> node dispatches tool via GenServer.call(dispatcher, ...)
         |
         v
8. Tool result fed back to LLM -> repeat until done
         |
         v
9. Summarize node persists summary to DB
         |
         v
10. Events persisted, PubSub broadcast, UI updates
```

---

## Failure Handling

- Agent processes restart via supervisor (`:permanent` strategy)
- On restart, GlobalAssistant rebuilds project registry from DB (query active projects)
- In-progress tasks become interrupted — their checkpoint status is `:running` in DB
- Interrupted tasks with status `:waiting` can be resumed from DB checkpoint
- Interrupted tasks with status `:running` require manual retry (no auto-retry of potentially destructive work)
- All events are persisted before execution — no data loss on crash

---

## Public API

All access goes through `Synapsis.Agent`:

```elixir
# Project lifecycle
Agent.start_project(project_id, metadata)
Agent.list_projects()
Agent.project_status(project_id)

# Work dispatch
Agent.dispatch_work(attrs_or_work_item)

# Memory
Agent.append_event(attrs)
Agent.list_events(filters)
Agent.put_summary(attrs)
Agent.get_summary(scope, scope_id, kind)

# Graph execution
Agent.run_graph(graph, state, opts)
Agent.start_runner(opts)
Agent.resume_run(pid_or_id, ctx_updates)
Agent.await_run(pid_or_id, timeout)
Agent.run_snapshot(pid_or_id)
Agent.restore_run(run_id)

# Checkpoints
Agent.get_checkpoint(run_id)
Agent.list_checkpoints(filters)
```

---

## Future Work

Priority order:

1. **Specialist Agent Implementations** — MCPManager, ToolRuntime, PatchManager, TestRunner nodes
2. **Tool-Calling Agent Loop** — graph that implements plan -> LLM -> tool -> LLM -> review cycle
3. **Parallel Nodes** — `Task.Supervisor.async_stream` for concurrent node execution
4. **Graph DSL** — `use Synapsis.Agent.Graph` macro for declarative graph definition
5. **Telemetry** — `:telemetry` integration for metrics (queue length, task duration, failure rates)
6. **Distributed Agents** — multi-node execution via Phoenix cluster
