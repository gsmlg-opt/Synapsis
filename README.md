# Synapsis.ex

An open-source AI coding agent built with Elixir/Phoenix. Inspired by [OpenCode](https://opencode.ai), reimagined with OTP's process model for superior concurrency, fault tolerance, and real-time streaming.

## Architecture

Phoenix umbrella project with a client/server architecture:

```
apps/
├── synapsis_core/     # Domain logic: sessions, agents, providers, 27-tool system
├── synapsis_server/   # Phoenix API: WebSocket channels, SSE, REST
├── synapsis_cli/      # CLI escript for terminal interaction
├── synapsis_lsp/      # LSP client manager (GenServer per language server)
└── synapsis_web/      # React frontend (Phoenix static assets)
```

### Why Umbrella?

Each app maps to a deployment boundary — `synapsis_core` + `synapsis_server` run as the backend node, `synapsis_cli` is a standalone escript that connects via WebSocket, `synapsis_lsp` can be distributed to a separate node for isolation. The umbrella enforces dependency direction: core has zero deps on server/cli/web.

## Tech Stack

- **Elixir** 1.18+ / OTP 28+
- **Phoenix** 1.8+ — Channels for real-time, REST for CRUD, Bandit HTTP server
- **Ecto** + **PostgreSQL** 16+ — Session/message persistence
- **Req** + **Finch** — HTTP client for LLM provider streaming
- **React** + **Tailwind CSS** — Frontend UI (served by Phoenix, communicates via Channels)
- **Bun** — Frontend build toolchain and package manager

## Key Design Decisions

- **Process-per-session**: Each coding session is a supervised GenServer tree
- **Provider-agnostic**: Behaviour-based provider abstraction (Anthropic, OpenAI, Google, local)
- **Event bus**: Phoenix.PubSub for internal event propagation (replaces OpenCode's custom bus)
- **27-tool system**: Filesystem, search, execution, web, planning, orchestration, interaction, session control, and swarm tools — all implementing a uniform `Synapsis.Tool` behaviour with 5-level permission model (`:none` → `:read` → `:write` → `:execute` → `:destructive`), parallel batch execution, deferred loading for plugins, and plan mode filtering
- **MCP support**: JSON-RPC over stdio/SSE, GenServer per MCP server connection, tools registered via deferred loading

## Getting Started

```bash
# Ensure PostgreSQL is running
mix deps.get
mix ecto.setup
cd apps/synapsis_web && bun install && cd ../..
mix phx.server
```

## Development

```bash
mix test                    # all tests
mix test apps/synapsis_core # core only
mix format --check-formatted
```
