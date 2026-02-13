# 00 — System Overview

## What This System Does

Synapsis.ex is an AI coding agent that runs as a local Phoenix server. Developers interact with it through a web UI (LiveView + React hybrid) or CLI to get AI assistance with coding tasks. The AI can read files, search code, execute commands, edit files, and manage LSP diagnostics — all through a permission-controlled tool system.

## High-Level Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                         Clients                              │
│  ┌──────────┐  ┌───────────────────┐  ┌──────────────────┐  │
│  │   CLI    │  │  Web UI           │  │  IDE Extension   │  │
│  │ (escript)│  │ (LiveView+React)  │  │  (future)        │  │
│  └────┬─────┘  └──────┬────────────┘  └────────┬─────────┘  │
│       │ WebSocket      │ LiveView+Channel       │ HTTP/WS    │
└───────┼────────────────┼────────────────────────┼────────────┘
        │                │                        │
┌───────▼────────────────▼────────────────────────▼────────────┐
│              synapsis_web (LiveView pages)                    │
│  ┌──────────────┐ ┌──────────────┐ ┌───────────────────────┐│
│  │ DashboardLive│ │ ProjectLive  │ │ SessionLive.Show      ││
│  │ SettingsLive │ │ ProviderLive │ │  └─ChatApp (React)    ││
│  │ MemoryLive   │ │ SkillLive    │ │    via phx-hook       ││
│  │ MCPLive      │ │ LSPLive      │ │    phx-update="ignore"││
│  └──────────────┘ └──────────────┘ └───────────────────────┘│
│                                                              │
│  Workspace packages: @synapsis/hooks, @synapsis/ui,          │
│                      @synapsis/channel                       │
├──────────────────────────────────────────────────────────────┤
│              synapsis_server (Phoenix infra)                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │  Endpoint    │  │  REST API    │  │  SSE Stream  │       │
│  │  Router      │  │  /api/...    │  │  /events     │       │
│  │  Plugs       │  └──────┬───────┘  └──────┬───────┘       │
│  ├──────────────┤  ┌──────────────┐                          │
│  │ SessionChannel│ │ Browser pipe │                          │
│  │ UserSocket   │  │ CSRF+Session │                          │
│  └──────┬───────┘  └──────────────┘                          │
│         │    PubSub                                          │
└─────────┼────────────────────────────────────────────────────┘
          │
┌─────────▼────────────────────────────────────────────────────┐
│                    synapsis_core (THE application)            │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐ │
│  │ Session.Sup  │  │ Provider.Reg │  │   Tool.Supervisor  │ │
│  │  ├─Worker    │  │ Tool.Reg     │  │    ├─FileEdit      │ │
│  │  ├─Stream    │  │              │  │    ├─BashExec      │ │
│  │  └─Context   │  │              │  │    ├─FileSearch    │ │
│  └──────────────┘  └──────────────┘  │    └─Diagnostics   │ │
│                                      └────────────────────┘ │
│  ┌──────────────┐                    ┌────────────────────┐ │
│  │ MCP.Supervisor│                   │ SynapsisLsp.Sup    │ │
│  │  ├─Server1   │                   │  ├─LSP.Server      │ │
│  │  └─Server2   │                   │  └─LSP.Server      │ │
│  └──────────────┘                    └────────────────────┘ │
├──────────────────────────────────────────────────────────────┤
│              synapsis_provider (library)                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │  Adapter     │  │ EventMapper  │  │ MessageMapper│       │
│  │ (unified)    │  │ (normalize)  │  │ (build req)  │       │
│  ├──────────────┤  ├──────────────┤  ├──────────────┤       │
│  │ Transport:   │  │ SSE.Parser   │  │ ModelRegistry│       │
│  │  Anthropic   │  │ (shared)     │  │              │       │
│  │  OpenAI      │  └──────────────┘  └──────────────┘       │
│  │  Google      │                                            │
│  └──────────────┘                                            │
├──────────────────────────────────────────────────────────────┤
│              synapsis_data (library)                          │
│  ┌──────────────┐  ┌──────────────────────────────────────┐ │
│  │ Synapsis.Repo│  │ Schemas: Project, Session, Message,  │ │
│  │ (PostgreSQL) │  │ MemoryEntry, Skill, MCPConfig,       │ │
│  │              │  │ LspConfig, Provider, Part (custom)   │ │
│  └──────────────┘  └──────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

### Dependency Graph (acyclic, strictly enforced)

```
synapsis_data        (schemas, Repo, migrations — no umbrella deps, no application)
  ↑
synapsis_provider    (provider behaviour + implementations — depends on synapsis_data, no application)
  ↑
synapsis_core        (sessions, tools, agents, config — THE application, starts all supervision)
  ↑
synapsis_server      (Endpoint, Router, Controllers, Channels — no application)
  ↑
synapsis_web         (LiveView pages, HEEx templates, React hooks — no application)

synapsis_lsp         (LSP client management — depends on synapsis_core, no application)
synapsis_cli         (standalone escript — communicates via HTTP/WS)
```

Only `synapsis_core` defines an OTP application with a supervision tree. All other umbrella sub-apps are pure library packages.

## Supervision Tree

All processes are started by `SynapsisCore.Application` (the only OTP application):

```
SynapsisCore.Application
├── Synapsis.Repo (Ecto — PostgreSQL)
├── Phoenix.PubSub (name: Synapsis.PubSub)
├── Task.Supervisor (name: Synapsis.Provider.TaskSupervisor)
├── Synapsis.Provider.Registry           — ETS-backed provider lookup
├── Task.Supervisor (name: Synapsis.Tool.TaskSupervisor)
├── Synapsis.Tool.Registry               — ETS-backed tool lookup
├── Registry (name: Synapsis.Session.Registry)
├── Registry (name: Synapsis.Session.SupervisorRegistry)
├── Registry (name: Synapsis.MCP.Registry)
├── Registry (name: Synapsis.FileWatcher.Registry)
├── Synapsis.Session.DynamicSupervisor
│   └── (per session)
│       ├── Synapsis.Session.Worker      — state machine, orchestrates agent loop
│       ├── Synapsis.Session.Stream      — manages provider SSE connection
│       └── Synapsis.Session.Context     — token counting, compaction
├── Synapsis.MCP.Supervisor              — one GenServer per MCP connection
├── SynapsisLsp.Supervisor               — DynamicSupervisor for LSP servers
│   ├── Synapsis.LSP.Server (gopls)
│   ├── Synapsis.LSP.Server (typescript-language-server)
│   └── ...
└── SynapsisServer.Supervisor            — Phoenix infrastructure (runtime reference)
    ├── SynapsisServer.Telemetry
    └── SynapsisServer.Endpoint
```

Note: `SynapsisServer.Supervisor` is referenced at runtime (an atom), not a compile-time dependency. This avoids a circular dependency since `synapsis_server` depends on `synapsis_core`.

## Data Flow: User Message → AI Response

1. User types in the ChatView (React, mounted via LiveView hook). React sends message via Phoenix Channel `push("user_message", %{content: "..."})`.
2. `SessionChannel` looks up or creates session, calls `Session.Worker.send_message/2`
3. `Session.Worker` (GenServer):
   - Persists user message to Ecto/PostgreSQL
   - Builds provider request (system prompt + messages + tools)
   - Starts streaming via `Session.Stream`
4. `Session.Stream` opens HTTP SSE connection to provider (Anthropic/OpenAI/etc)
   - Receives chunks, sends `{:chunk, part}` to `Session.Worker`
5. `Session.Worker` processes parts:
   - `TextPart` → broadcast to PubSub
   - `ToolUsePart` → check permission → execute via `Tool.TaskSupervisor` → feed result back
   - `ReasoningPart` → broadcast to PubSub
6. On stream completion, `Session.Worker` persists assistant message
7. PubSub → Channel → Client renders incrementally

## Performance Targets

- Session startup: <50ms
- Message persistence: <10ms
- First token to client: <200ms after provider responds
- Tool execution timeout: configurable, default 30s
- Concurrent sessions: 100+ per node (process-isolated)
- Memory per idle session: <1MB
