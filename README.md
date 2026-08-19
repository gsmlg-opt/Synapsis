# Synapsis

An open-source AI coding agent built with Elixir/Phoenix. Inspired by [OpenCode](https://opencode.ai), reimagined with OTP's process model for concurrency, fault tolerance, and real-time streaming.

## Architecture

Phoenix umbrella with 10 apps and a strict acyclic dependency graph:

```text
apps/
|-- synapsis_data/       # Concord session store, TOML config store (no SQL)
|-- synapsis_provider/   # Anthropic / OpenAI-compatible / Google transports
|-- synapsis_core/       # tools, PubSub, memory, git/worktree, file watching
|-- synapsis_workspace/  # workspace resources, blob store, projections, search
|-- synapsis_agent/      # agent graph runtime, session workers, heartbeats
|-- synapsis_mcp/        # MCP client (backplane_mcp_protocol) → Tool.Registry
|-- synapsis_sandbox/    # JSON-RPC stdio bridge for sandbox runtimes
|-- synapsis_server/     # Phoenix endpoint, channels, REST/SSE
|-- synapsis_web/        # Phoenix LiveView UI (phoenix_duskmoon)
`-- synapsis_cli/        # escript CLI (HTTP + SSE)
```

```text
synapsis_data
 <- synapsis_provider
 <- synapsis_core
 <- synapsis_workspace
 <- synapsis_agent
 <- synapsis_mcp
 <- synapsis_sandbox
 <- synapsis_server
 <- synapsis_web
```

`synapsis_cli` is a standalone escript and does not depend on other umbrella apps.

TypeScript lives under `packages/*` as Bun workspaces — currently only `@synapsis/hooks` (LiveView DOM hooks). The UI is pure LiveView (ADR-007); there is no React.

### Key Design Decisions

- **Process-per-session**: each session is a supervised tree under `Synapsis.Session.DynamicSupervisor`. `Synapsis.Session.Worker` is a `:gen_statem` (ADR-008) that owns the graph engine inline.
- **Graph-based agent execution**: `coding_loop` (build mode) and `conversational_loop` (chat mode), with composable nodes (build_prompt, llm_stream, process_response, tool_dispatch, act, respond).
- **Provider-agnostic streaming**: SSE transports for Anthropic, OpenAI-compatible APIs, and Google, unified via `EventMapper` / `MessageMapper`.
- **Tool system**: 30+ built-in tools (filesystem, search, bash, planning, orchestration, memory, agent communication) implementing `Synapsis.Tool.Behaviour`, with a 5-level permission model and parallel batch execution. MCP tools are discovered at runtime and bridged into `Synapsis.Tool.Registry`.
- **Storage without a database** (ADR-006): session transcripts as per-turn snapshots in an embedded Concord 3.x (node-local Turso) KV store, configs as TOML files with watchers, memory as Markdown files — no PostgreSQL, no migrations.
- **Heartbeat agents**: node-local cron-scheduled recurring agent runs for autonomous background work.
- **MCP**: dedicated `synapsis_mcp` app over stdio, Streamable HTTP, or SSE. MCP server config uses `mcp.toml` (`Synapsis.MCPConfigs`), not the `.opencode.json` MCP contract. Agents and providers remain `.opencode.json`-compatible.
- **Phoenix LiveView UI**: real-time web interface using `phoenix_duskmoon` and DuskMoon packages.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language / Runtime | Elixir 1.18+ / OTP 28+ |
| Web framework | Phoenix 1.8+ (Bandit), Phoenix LiveView 1.0+ |
| UI components | `phoenix_duskmoon` 9.x, `@duskmoon-dev/core` |
| Storage | Embedded Concord 3.x (Turso KV) + TOML/Markdown files (UUID IDs) |
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

Configs default to `~/.config/synapsis/` (override with `SYNAPSIS_CONFIG_DIR`). Concord data defaults under the system temp dir.

Providers are registered from environment variables at startup. Set any of:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export OPENAI_API_KEY=sk-...
export GOOGLE_API_KEY=...
export OPENROUTER_API_KEY=...
export MOONSHOT_API_KEY=...
export ZHIPU_API_KEY=...
export MINIMAX_API_KEY=...
```

Anthropic also accepts `ANTHROPIC_AUTH_TOKEN`. Additional providers can be added in the LiveView settings UI or `providers.toml`.

### CLI

The CLI talks to a running server over HTTP and streams responses with SSE:

```bash
cd apps/synapsis_cli && mix escript.build
./synapsis_cli -p "explain this file"
./synapsis_cli --host http://localhost:4657
```

## Development

```bash
mix test                              # all tests
mix test apps/synapsis_core           # single app
mix test path/to/test_file.exs:42     # single test
mix compile --warnings-as-errors
mix format
cd apps/synapsis_web && mix assets.build
```

## Architecture Docs

See `docs/` for detailed design documents:

- `docs/architecture/` — system overview, domain model, data layer, tool system, providers
- `docs/decisions/` — ADRs (notably ADR-006 storage, ADR-007 LiveView UI, ADR-008 session shell)
- `docs/guardrails/GUARDRAILS.md` — invariants (never violate)
- `docs/prd/`, `docs/designs/`, `docs/superpowers/plans/` — plans and implementation notes
