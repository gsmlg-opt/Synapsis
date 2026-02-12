# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Synapsis.ex is an AI coding agent — a Phoenix umbrella app that provides a web UI and CLI for developers to use LLMs to read, write, and modify code. It is a functional reimplementation of [OpenCode](https://github.com/anomalyco/opencode) in Elixir.

**Status**: Greenfield project — design docs are complete, implementation is starting from scratch. See `docs/` for full architecture specs.

## Development Environment

Uses [devenv](https://devenv.sh) (Nix-based) for reproducible setup. Entering the directory with `direnv` auto-provisions:
- Elixir 1.18+ / OTP 28+ (BEAM 27)
- Bun (frontend build + package manager)
- Tailwind CSS 4
- PostgreSQL 16 (Unix socket, auto-started)

Database is pre-configured: user `synapsis`, password `synapsis`, database `synapsis` via Unix socket at `$DEVENV_STATE/postgres`.

## Commands

```bash
# Dependencies
mix deps.get
cd apps/synapsis_web && bun install && cd ../..

# Database
mix ecto.create && mix ecto.migrate    # or: db-setup (devenv script)

# Run
mix phx.server

# Test
mix test                               # all apps
mix test apps/synapsis_core            # single app
mix test apps/synapsis_core/test/path_test.exs          # single file
mix test apps/synapsis_core/test/path_test.exs:42       # single test (line)

# Lint / Format
mix format --check-formatted
mix format                             # auto-fix
```

## Umbrella Structure

```
apps/
├── synapsis_core/     # Domain logic (leaf — no umbrella deps)
│                      # Sessions, messages, agents, providers, tools, config
├── synapsis_server/   # Phoenix API: Channels, REST, SSE (depends on core + lsp)
├── synapsis_lsp/      # LSP client management (depends on core)
├── synapsis_cli/      # Standalone escript, connects via WebSocket (no umbrella deps)
└── synapsis_web/      # React + Tailwind frontend, built with Bun (build artifact only)
```

Dependency direction is strictly enforced: `synapsis_core` imports nothing from other umbrella apps.

## Design Philosophy

- **Functional core, imperative shell** — Pure domain logic in `synapsis_core`, side effects at boundaries
- **Process-per-session** — Each session is a supervision subtree (Worker + Stream + Context), crash-isolated
- **Database as source of truth** — Sessions/messages in PostgreSQL via Ecto; GenServers hold only transient operational state (current stream, pending chunks)
- **Let it crash** — Supervisor restarts for transient failures; Worker rehydrates from DB on restart
- **Provider-agnostic** — Behaviour modules (`Synapsis.Provider.Behaviour`) for each LLM provider

## Key Architecture Patterns

### Naming Conventions
- Contexts: `Synapsis.Sessions`, `Synapsis.Providers`, `Synapsis.Config`
- Behaviours: `Synapsis.Provider.Behaviour`, `Synapsis.Tool.Behaviour`
- Implementations: `Synapsis.Provider.Anthropic`, `Synapsis.Tool.FileEdit`
- GenServers: `Synapsis.Session.Worker`, `Synapsis.LSP.Server`

### Message Parts
Messages use a polymorphic part-based structure stored as JSONB array, discriminated by `type` field:
```elixir
%Message{role: :assistant, parts: [%TextPart{}, %ToolUsePart{}, %ReasoningPart{}]}
```

### Tool Execution
Tools implement `Synapsis.Tool.Behaviour` with `call/2` returning `{:ok, result} | {:error, reason}`. Always async via `Task.Supervisor`. Permission checks happen before execution. Bash tool uses `Port` (not `System.cmd`) for streaming + kill control.

### Provider Streaming
LLM responses stream as `{:provider_chunk, data}` messages to Session.Worker -> PubSub topic `"session:#{session_id}"` -> Channel -> Client.

### Config
Project config: `.opencode.json` in project root (backward-compatible with OpenCode). User config: `~/.config/synapsis/config.json`. Merge order: defaults < user < project < env.

### Runtime Registries (ETS)
Provider.Registry, Tool.Registry, Config.Cache — these are caches, not source of truth. All rebuild from config + DB on restart.

## Guardrails

- **Never store persistent state in GenServer** — DB is source of truth
- **Never make synchronous LLM calls** — always stream async
- **Never use `System.cmd`** — use `Port` for tool execution
- **Never hardcode provider formats in core** — providers implement `format_request/3`
- **Never block Session.Worker** — delegate slow work to Task.Supervisor
- **Never skip permission checks** — policy decides, not the caller
- **Always persist before broadcasting** — write to DB, then PubSub
- **Always validate file paths against project root** — prevent `../` escapes
- **Always use structured logging** — `Logger.info("event", key: val)`, never string interpolation
- **Always test provider integration with Bypass** — never hit real APIs in tests

## Documentation Map

```
docs/
├── design/
│   ├── 00_SYSTEM_OVERVIEW.md    # Architecture diagrams, supervision tree, data flow
│   ├── 01_DOMAIN_MODEL.md       # Entity schemas, state machines, relationships
│   ├── 02_DATA_LAYER.md         # Ecto schemas, SQL, JSONB patterns, ETS usage
│   ├── 03_FUNCTIONAL_CORE.md    # Pure functions: message building, context window, permissions
│   ├── 04_BOUNDARIES.md         # Public APIs, Channel protocol, REST endpoints, PubSub topics
│   ├── 05_TOOLS.md              # Tool system: built-in tools, execution flow, MCP delegation
│   └── 06_PROVIDERS.md          # Provider behaviour, streaming architecture, retry logic
├── adr/                         # Architecture Decision Records
├── GUARDRAILS.md                # Full guardrails with rationale
└── HANDOFF.md                   # Implementation phases and task breakdown
```
