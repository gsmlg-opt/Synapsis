# Synapsis

An open-source AI coding agent built with Elixir/Phoenix. Inspired by [OpenCode](https://opencode.ai), reimagined with OTP's process model for superior concurrency, fault tolerance, and real-time streaming.

## Architecture

Phoenix umbrella project with 9 apps across a strict dependency hierarchy:

```text
apps/
|-- synapsis_data/       # Ecto schemas, Repo, migrations
|-- synapsis_provider/   # LLM provider transports (Anthropic, OpenAI, Google SSE)
|-- synapsis_core/       # OTP app: sessions, tools, memory, harness, Oban, PubSub
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
- **Memory system**: Working memory (in-process) + semantic memory (Postgres) + Oban-based summarizer
- **Heartbeat agents**: Oban-scheduled recurring agent runs for autonomous background work
- **MCP + LSP**: Plugin system with per-server GenServers over Port (stdio) or SSE (HTTP)
- **Phoenix LiveView UI**: Real-time web interface using `phoenix_duskmoon` component library

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language / Runtime | Elixir 1.18+ / OTP 28+ |
| Web framework | Phoenix 1.8+ (Bandit), Phoenix LiveView 1.0+ |
| UI components | `phoenix_duskmoon` 9.x, `@duskmoon-dev/core` |
| Database | PostgreSQL 16+ via Ecto (UUID PKs, JSONB) |
| HTTP client | Req + Finch (SSE streaming) |
| Background jobs | Oban 2.x |
| JS build | Bun + Tailwind CSS v4 |

## Getting Started

```bash
# Start PostgreSQL (or use docker-compose up postgres)
docker-compose up -d postgres

# Install and migrate
mix deps.get
mix ecto.setup
cd apps/synapsis_web && bun install && cd ../..

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
