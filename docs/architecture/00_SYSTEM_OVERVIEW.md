# 00 — System Overview

## What This System Does

Synapsis.ex is an AI coding agent that runs as a local Phoenix server. Developers interact with it through a web UI (React) or CLI to get AI assistance with coding tasks. The AI can read files, search code, execute commands, edit files, and manage LSP diagnostics — all through a permission-controlled tool system.

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Clients                               │
│  ┌──────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │   CLI    │  │  Web UI      │  │  IDE Extension   │   │
│  │ (escript)│  │ (React/WS)   │  │  (future)        │   │
│  └────┬─────┘  └──────┬───────┘  └────────┬─────────┘   │
│       │ WebSocket      │ Channel           │ HTTP/WS     │
└───────┼────────────────┼───────────────────┼─────────────┘
        │                │                   │
┌───────▼────────────────▼───────────────────▼─────────────┐
│                synapsis_server (Phoenix)                   │
│  ┌────────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ SessionChannel │  │  REST API    │  │  SSE Stream  │  │
│  │ (per-client)   │  │  /api/...    │  │  /events     │  │
│  └────────┬───────┘  └──────┬───────┘  └──────┬───────┘  │
│           │    PubSub       │                  │          │
└───────────┼─────────────────┼──────────────────┼──────────┘
            │                 │                  │
┌───────────▼─────────────────▼──────────────────▼──────────┐
│                  synapsis_core                             │
│  ┌──────────────┐  ┌──────────┐  ┌────────────────────┐  │
│  │ Session.Sup  │  │ Provider │  │   Tool.Supervisor  │  │
│  │  ├─Worker    │  │  Manager │  │    ├─FileEdit      │  │
│  │  ├─Stream    │  │  ├─Anthropic│  │    ├─BashExec   │  │
│  │  └─Context   │  │  ├─OpenAI│  │    ├─FileSearch   │  │
│  └──────────────┘  │  ├─Google │  │    └─Diagnostics  │  │
│                    │  └─Local  │  └────────────────────┘  │
│  ┌──────────────┐  └──────────┘  ┌────────────────────┐  │
│  │   Ecto/DB    │                │   MCP.Supervisor   │  │
│  │ (PostgreSQL) │                │    ├─Server1        │  │
│  └──────────────┘                │    └─Server2        │  │
│                                  └────────────────────┘  │
└───────────────────────────────────────────────────────────┘
            │
┌───────────▼───────────────────────────────────────────────┐
│                    synapsis_lsp                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│  │ LSP.Manager  │  │ LSP.Server   │  │ LSP.Server   │    │
│  │ (supervisor) │  │ (gopls)      │  │ (ts-server)  │    │
│  └──────────────┘  └──────────────┘  └──────────────┘    │
└───────────────────────────────────────────────────────────┘
```

## Supervision Tree

```
Synapsis.Application
├── Synapsis.Repo (Ecto — PostgreSQL)
├── Synapsis.PubSub (Phoenix.PubSub)
├── Synapsis.Session.DynamicSupervisor
│   └── (per session)
│       ├── Synapsis.Session.Worker      — state machine, orchestrates agent loop
│       ├── Synapsis.Session.Stream      — manages provider SSE connection
│       └── Synapsis.Session.Context     — token counting, compaction
├── Synapsis.Provider.Registry           — ETS-backed provider lookup
├── Synapsis.Tool.TaskSupervisor         — Task.Supervisor for tool execution
├── Synapsis.MCP.DynamicSupervisor       — one GenServer per MCP connection
├── Synapsis.Config.Server               — watches .opencode.json for changes
└── Synapsis.LSP.Manager                 — DynamicSupervisor for LSP servers
    ├── Synapsis.LSP.Server (gopls)
    ├── Synapsis.LSP.Server (typescript-language-server)
    └── ...
```

## Data Flow: User Message → AI Response

1. Client sends message via Channel `"session:lobby"` → `push("user_message", %{content: "..."})`
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
