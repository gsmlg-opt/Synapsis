# Synapsis

A resident personal agent built with Elixir/Phoenix and the Backplane agent runtime. Each machine runs one instance with a Web UI; it manages local devices, data, software upgrades and code projects, and delegates development work to Codex and Sigma, under [Samgita](https://github.com/gsmlg-opt/Samgita) for project-level management. See [the design](docs/design.md).

## Architecture

Phoenix umbrella with 10 apps and a strict acyclic dependency graph:

```text
apps/
|-- synapsis_data/       # Concord session store, TOML config store (no SQL)
|-- synapsis_provider/   # Anthropic / OpenAI-compatible / Google transports
|-- synapsis_core/       # tools, PubSub, memory, git/worktree, file watching
|-- synapsis_workspace/  # workspace resources, blob store, projections, search
|-- synapsis_agent/      # Backplane runtime, tool catalog, session workers, heartbeats
|-- synapsis_mcp/        # MCP client (backplane_mcp_protocol)
|-- synapsis_sandbox/    # JSON-RPC stdio bridge for sandbox runtimes
|-- synapsis_server/     # Phoenix endpoint, channels, REST/SSE
|-- synapsis_web/        # Phoenix LiveView UI (duskmoon_phoenix)
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

Phoenix LiveView owns the pages. The `@synapsis/hooks` workspace connects DuskMoon React forms and chat to LiveView. Install workspace dependencies with `mix npm.install`. See [ADR-010](docs/decisions/ADR-010-react-form-islands.md) and [ADR-011](docs/decisions/ADR-011-react-chat-islands.md).

### Key Design Decisions

- **Process-per-session**: each session is a supervised tree under `Synapsis.Session.DynamicSupervisor`. `Synapsis.Session.Worker` is a `:gen_statem` (ADR-008) that owns the graph engine inline.
- **Backplane execution**: each turn is executed by a Backplane `Conversation`; the tool catalog is assembled from Backplane native bundles plus Synapsis host descriptors.
- **Provider-agnostic streaming**: SSE transports for Anthropic, OpenAI-compatible APIs, and Google, unified via `EventMapper` / `MessageMapper`.
- **Tools**: local commands and patches, filesystem, web fetch/search, memory, skills, MCP, subagents, questions and automations (scope in `docs/design.md`). Permissions default to yolo.
- **Storage without a database** (ADR-006): session transcripts as per-turn snapshots in an embedded Concord 3.x (node-local Turso) KV store, configs as TOML files with watchers, memory as Markdown files — no PostgreSQL, no migrations.
- **Heartbeat agents**: node-local cron-scheduled recurring agent runs for autonomous background work.
- **MCP**: dedicated `synapsis_mcp` app over stdio, Streamable HTTP, or SSE. MCP server config uses `mcp.toml` (`Synapsis.MCPConfigs`), not the `.opencode.json` MCP contract. Agents and providers remain `.opencode.json`-compatible.
- **Phoenix LiveView UI**: real-time web interface using `duskmoon_phoenix` and DuskMoon packages.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language / Runtime | Elixir 1.18+ / OTP 28+ |
| Web framework | Phoenix 1.8+ (Gaoxy), Phoenix LiveView 1.0+ |
| UI components | [`duskmoon_phoenix`](https://github.com/duskmoon-dev/duskmoon-web) 2.0 RC, `@duskmoon-dev/core` |
| Storage | Embedded Concord 3.x (Turso KV) + TOML/Markdown files (UUID IDs) |
| HTTP client | `http_fetch` (SSE streaming) and `http_web_socket` |
| Data formats | Formata (JSON, TOML, YAML and JSON Schema validation) |
| Background work | Supervised Tasks + node-local cron scheduler |
| JS build | DuskmoonBundler + Tailwind CSS v4 (`@duskmoon-dev/core`) |

## Getting Started

```bash
# Install dependencies (no database needed — storage is embedded)
mix deps.get
mix npm.install

# Start server (http://localhost:4657)
mix synapsis.run
```

`mix synapsis.run` prepares Backplane's QuickBEAM Code Mode runner on first
startup, including the process helper on macOS. To use a separately built
runner, set `BACKPLANE_CODE_MODE_RUNNER` to its absolute executable path.

On Linux, `mix compile` builds Backplane's first-party PTY helper with the
packaged `mix backplane.pty.build` task. A C11 compiler and Linux headers are
required; Devenv provides the compiler. Selected `exec_command` calls with
`tty: true` use this native terminal with its default 24 rows and 80 columns,
and `write_stdin` continues the same session. Calls with `tty: false` retain
pipe output. This does not provide the separate operator shared-terminal UI
or terminal resize/attach controls.

Configs default to `~/.config/synapsis/` (override with `SYNAPSIS_CONFIG_DIR`). Concord data defaults under the system temp dir.

MCP tool calls have a 300-second client timeout by default. To override it, set
`tool_timeout_sec = 480` in the server's `[[mcps]]` entry in `mcp.toml`. The
setting accepts whole seconds from 1 to 600 and applies to new calls after the
config reloads. MCP initialization and tool discovery have separate timeouts.

### Docker Compose state

Compose mounts the named `app_data` volume at `/app/data`. The default
Concord, configuration, file memory, workspace and workspace blob paths are
`concord`, `config`, `memory`, `workspace` and `blobs` under that mount.
Set the corresponding environment variables in `docker-compose.yml` to use an
existing mount.

Before recreating an older container, record its effective paths and mounts.
Stop the old service to quiesce writes, then copy its full Concord directory
(including any Turso/SQLite sidecar files), TOML config, memory, workspace and
blobs from the old container or their mounts. Back up any existing destination
first. Restore to the configured volume paths with the original encryption key,
then read back a known session before retiring the old container. A new
container starts with empty state wherever the configured paths contain no
data.

`bash scripts/test-compose-persistence.sh` builds the local checkout and
checks session, TOML and file memory recovery using a separate Compose project
and volume.

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

Before running Code Mode functional tests, build the QuickBEAM runner once
with `MIX_ENV=test mix backplane.code_mode.build`, or point
`BACKPLANE_CODE_MODE_RUNNER` at an existing build from the same dependencies.

```bash
mix test                              # all tests
mix test apps/synapsis_core           # single app
mix test path/to/test_file.exs:42     # single test
mix compile --warnings-as-errors
mix format
cd apps/synapsis_web && mix assets.build
```

## Architecture Docs

- `docs/design.md` — product scope, tool scope, delegation, permissions and phases
- `docs/decisions/` — ADRs (notably ADR-006 storage, ADR-007 LiveView UI, ADR-008 session shell)
- `docs/guardrails/GUARDRAILS.md` — invariants (never violate)
