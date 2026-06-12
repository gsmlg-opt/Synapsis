# 00 — System Overview

## What This System Does

Synapsis is an AI coding agent that runs as a local Phoenix server. Developers interact with it through a Phoenix LiveView web UI or the CLI to get AI assistance with coding tasks. The AI can read files, search code, execute commands, edit files, and use LSP/MCP integrations — all through a permission-controlled tool system.

Storage follows [ADR-006](../decisions/ADR-006-in-process-sessions-and-concord-storage.md): there is **no SQL database**. Session transcripts live in an embedded Concord (`ra`-based) KV store as per-turn snapshots, configs are TOML files, and workspace documents/memory are files behind a memory port.

## High-Level Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                         Clients                              │
│  ┌──────────┐  ┌───────────────────┐                         │
│  │   CLI    │  │  Web UI           │                         │
│  │ (escript)│  │ (LiveView)        │                         │
│  └────┬─────┘  └──────┬────────────┘                         │
│       │ HTTP/WS/SSE    │ LiveView + Channel                  │
└───────┼────────────────┼─────────────────────────────────────┘
        │                │
┌───────▼────────────────▼─────────────────────────────────────┐
│  synapsis_web   — LiveView pages (AgentLive.Sessions chat,   │
│                   AgentLive.Agents, Workspace, MCP, LSP, …)  │
│  synapsis_server — Endpoint, Router, SessionChannel,         │
│                   REST + SSE controllers, telemetry          │
├──────────────────────────────────────────────────────────────┤
│  synapsis_agent — per-session supervision trees:             │
│                   Session.Worker owns the graph Engine       │
│                   inline (coding_loop / conversational_loop) │
│  synapsis_plugin — MCP + LSP client GenServers               │
│  synapsis_workspace — file-backed workspace docs, blob       │
│                   store, projections, search                 │
├──────────────────────────────────────────────────────────────┤
│  synapsis_core  — PubSub, Tool.Registry/Executor,            │
│                   Provider.Registry, Memory port,            │
│                   heartbeat scheduler, git/worktree          │
│  synapsis_provider — Adapter + transports (Anthropic,        │
│                   OpenAI-compatible, Google), Event/Message  │
│                   mappers, model registry                    │
├──────────────────────────────────────────────────────────────┤
│  synapsis_data  — Session.Store (Concord), Config.Store      │
│                   (TOML + watchers), embedded Ecto types     │
└──────────────────────────────────────────────────────────────┘
```

### Dependency Graph (acyclic, strictly enforced)

```
synapsis_data        (Concord session store, TOML config store — OTP app)
  ↑
synapsis_provider    (provider adapters/transports — library)
  ↑
synapsis_core        (shared services, tools, memory, PubSub — OTP app)
  ↑
synapsis_workspace   (workspace resources — library)
  ↑
synapsis_agent       (session/agent runtime — OTP app)
  ↑
synapsis_plugin      (MCP/LSP protocol — library, supervised from core)
  ↑
synapsis_server      (Phoenix infrastructure — OTP app)
  ↑
synapsis_web         (LiveView UI — library)

synapsis_cli         (standalone escript — talks HTTP/WS/SSE)
```

Four umbrella apps define OTP applications with supervision trees: `synapsis_data`, `synapsis_core`, `synapsis_agent`, and `synapsis_server`. The rest are library packages.

## Supervision Tree

```
SynapsisData.Application
└── Synapsis.Config.Store.Supervisor     — TOML loaders + ETS cache + file watchers
    (Concord/:ra is brought up at core boot via Session.Store.ensure_started/0)

SynapsisCore.Application (one_for_one)
├── Phoenix.PubSub (name: Synapsis.PubSub)
├── Task.Supervisor (Synapsis.Provider.TaskSupervisor)
├── Synapsis.Provider.Registry           — ETS-backed provider lookup
├── Task.Supervisor (Synapsis.Tool.TaskSupervisor)
├── Synapsis.Tool.Registry               — ETS-backed tool lookup
├── Registry (Synapsis.FileWatcher.Registry)
├── Synapsis.Session.Quarantine          — poison-session isolation
├── Synapsis.Memory.Supervisor           — memory port (file / service adapters)
├── Synapsis.Workspace.GC                — blob/scratch cleanup
├── Synapsis.Agent.Heartbeat.LocalScheduler — node-local cron (heartbeats.toml)
└── SynapsisPlugin.Supervisor            — MCP/LSP plugin processes (optional)

SynapsisAgent.Application (rest_for_one)
├── Registries: Session.Registry, Session.SupervisorRegistry,
│               Session.TaskSupervisorRegistry, Agent.Registry
├── Synapsis.Session.DynamicSupervisor
│   └── Session.Supervisor (rest_for_one, one per session)
│       ├── Task.Supervisor              — survives a Worker-only restart
│       └── Synapsis.Session.Worker      — owns the graph Engine inline;
│                                          epoch-fenced I/O (ADR-006)
└── Synapsis.Agent.Supervisor

SynapsisServer.Application
├── SynapsisServer.Telemetry
└── SynapsisServer.Endpoint              — Bandit, LiveView, channels, REST/SSE
```

## Storage Model (ADR-006)

| Tier | What lives there |
|------|------------------|
| Process memory | The live turn. `Session.Worker` is the read authority; readers use `Synapsis.Session.Read.live_snapshot/1`. |
| Concord (embedded, node-local, `tmp/concord/`) | `sessions/<id>/meta` + `sessions/<id>/turns/<n>` per-turn snapshots; agent events and summaries under `coord/…`. |
| Files | TOML configs (agents, providers, MCP, LSP, heartbeats, toolsets) loaded by `Config.Store` with watchers; Markdown workspace documents; Markdown memory entries (file adapter + ETS index). |

Writes are append-per-turn, fire-and-forget, atomic per turn. A crash can lose at most the whole last turn — never half a turn; files/git are the agent's real ground truth. On restart the Worker rehydrates from Concord's last turn, bumps its epoch (stale task results are fenced off), and waits for input.

## Data Flow: User Message → AI Response

1. User sends a message from the LiveView chat (`AgentLive.Sessions`) or via `SessionChannel`/CLI.
2. `Synapsis.Sessions.send_message/2` → `Synapsis.Session.Worker.send_message/3`.
3. `Session.Worker` (GenServer) steps the pure graph **Engine** inline (`coding_loop` for build mode, `conversational_loop` for chat mode) until the graph waits on I/O.
4. I/O nodes delegate to the Worker's `IOHandler`: provider streaming runs as a supervised Task using `Synapsis.Provider.Adapter` (SSE); tool calls are classified by `ToolDispatcher` (permission check) and executed via `Tool.Executor` under `Tool.TaskSupervisor`.
5. Streaming deltas broadcast live over `Synapsis.PubSub`; LiveView/Channel/SSE subscribers render incrementally.
6. At the turn boundary the Worker writes the whole turn to Concord as one transaction (fire-and-forget) and the engine loops or completes.

## Performance Targets

- Session startup: <50ms (Concord is node-local and synchronously available)
- First token to client: <200ms after provider responds
- Tool execution timeout: configurable, default 30s
- Concurrent sessions: 100+ per node (process-isolated)
- Memory per idle session: <1MB
