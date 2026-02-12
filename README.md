# Synapsis.ex

An open-source AI coding agent built with Elixir/Phoenix. Inspired by [OpenCode](https://opencode.ai), reimagined with OTP's process model for superior concurrency, fault tolerance, and real-time streaming.

## Architecture

Phoenix umbrella project with a client/server architecture:

```
apps/
├── synapsis_core/     # Domain logic: sessions, agents, providers, tools
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
- **Tool execution**: Sandboxed via Ports, permission-controlled
- **MCP support**: JSON-RPC over stdio/SSE, GenServer per MCP server connection

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
