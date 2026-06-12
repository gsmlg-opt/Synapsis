# Synapsis

An open-source AI coding agent built with Elixir/Phoenix. Inspired by [OpenCode](https://opencode.ai), reimagined with OTP's process model for superior concurrency, fault tolerance, and real-time streaming.

## Architecture

Phoenix umbrella project with 9 apps across a strict dependency hierarchy:

```text
apps/
|-- synapsis_data/       # Concord session store, TOML config store (no SQL database)
|-- synapsis_provider/   # LLM provider transports (Anthropic, OpenAI, Google SSE)
|-- synapsis_core/       # OTP app: sessions, tools, memory, harness, PubSub
|-- synapsis_agent/      # OTP app: agent graph executor, session workers, heartbeats
|-- synapsis_plugin/     # LSP + MCP clients (started by synapsis_core)
|-- synapsis_workspace/  # Workspace/file management, blob store, path resolution
|-- synapsis_server/     # Phoenix OTP app: WebSocket channels, SSE, REST API
|-- synapsis_web/        # Phoenix LiveView UI (phoenix_duskmoon components)
`-- synapsis_cli/        # CLI escript (connects via WebSocket)
```

### Key Design Decisions

- **Process-per-session**: Each session is a supervised GenServer tree under `Synapsis.Session.DynamicSupervisor`
- **Graph-based agent execution**: Two graph types - `coding_loop` (build mode) and `conversational_loop` (chat mode) - with composable nodes (build_prompt, llm_stream, process_response, tool_dispatch, act, respond)
- **Provider-agnostic streaming**: SSE transport adapters per provider (Anthropic, OpenAI, Google), unified via `EventMapper`/`MessageMapper`
- **Tool system**: 30+ built-in tools (filesystem, search, bash, web, planning, orchestration, memory, agent communication, LSP diagnostics) implementing `Synapsis.Tool.Behaviour` with 5-level permissions and parallel batch execution
- **Storage without a database** (ADR-006): session transcripts as per-turn snapshots in an embedded Concord (`ra`-based) KV store, configs as TOML files with watchers, memory as Markdown files behind a memory port — no PostgreSQL, no migrations
- **Heartbeat agents**: node-local cron-scheduled recurring agent runs for autonomous background work
- **MCP + LSP**: Plugin system with per-server GenServers over Port (stdio) or SSE (HTTP)
- **Phoenix LiveView UI**: Real-time web interface using `phoenix_duskmoon` component library

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language / Runtime | Elixir 1.18+ / OTP 28+ |
| Web framework | Phoenix 1.8+ (Bandit), Phoenix LiveView 1.0+ |
| UI components | `phoenix_duskmoon` 9.x, `@duskmoon-dev/core` |
| Storage | Embedded Concord (`ra`-based KV) + TOML/Markdown files (UUID IDs) |
| HTTP client | Req + Finch (SSE streaming) |
| Background work | Supervised Tasks + node-local cron scheduler |
| JS build | Bun + Tailwind CSS v4 |

## Getting Started

```bash
# Install dependencies (no database needed — storage is embedded)
mix deps.get
bun install

# Start server (http://localhost:4657)
mix phx.server
```

Providers are loaded from environment variables at startup - set any of:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export OPENAI_API_KEY=sk-...
export GOOGLE_API_KEY=...
```

## Development

```bash
mix test                              # all tests
mix test apps/synapsis_core           # single app
mix test path/to/test_file.exs:42     # single test
mix compile --warnings-as-errors
mix format
```

## Architecture Docs

See `docs/` for detailed design documents:

- `docs/architecture/` - system overview, domain model, data layer, tool system, providers
- `docs/decisions/` - ADRs
- `docs/guardrails/GUARDRAILS.md` - invariants (never violate)
- `docs/prd/`, `docs/designs/`, `docs/superpowers/plans/` - active plans and implementation notes
