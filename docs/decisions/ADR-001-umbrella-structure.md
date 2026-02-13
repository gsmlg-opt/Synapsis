# ADR-001: Umbrella Project Structure

## Status: Accepted (revised)

## Context

Need to organize a multi-concern Phoenix application (core domain, data layer, provider integrations, HTTP server, CLI, LSP, web frontend). Options: monolith, Dave Thomas path-deps, or umbrella.

## Decision

Umbrella project with 7 apps organized in a strict acyclic dependency graph:

```
synapsis_data        (schemas, Repo, migrations — no umbrella deps, no application)
  ↑
synapsis_provider    (provider behaviour + implementations — depends on synapsis_data, no application)
  ↑
synapsis_core        (sessions, tools, agents, config — THE application, starts all supervision)
  ↑
synapsis_server      (Endpoint, Router, Controllers, Channels — depends on core, no application)
  ↑
synapsis_web         (LiveView pages, HEEx templates, React hooks — depends on server, no application)

synapsis_lsp         (LSP client management — depends on synapsis_core, no application)
synapsis_cli         (standalone escript — communicates via HTTP/WS, no umbrella deps)
```

### Single Application Rule

Only `synapsis_core` defines an OTP application with a supervision tree (`SynapsisCore.Application`). All other umbrella sub-apps are pure library packages — they define modules and supervisors but do NOT start their own application. Process supervision is centralized in `SynapsisCore.Application`.

### App Responsibilities

- **synapsis_data** — Ecto schemas (Project, Session, Message, Provider, MemoryEntry, Skill, MCPConfig, LSPConfig), Repo, migrations, custom types (Part). All PostgreSQL persistence goes through this package.
- **synapsis_provider** — `Synapsis.Provider.Behaviour`, unified Adapter, transport plugins (Anthropic, OpenAI, Google), SSE parser, EventMapper, MessageMapper, ModelRegistry.
- **synapsis_core** — Session system (Worker, Stream, Context, DynamicSupervisor), Tool system (Behaviour, Registry, Executor, built-in tools), Agent resolver, Config, MCP Supervisor. Starts all supervision trees.
- **synapsis_server** — Phoenix Endpoint, Router, Plug pipelines, REST controllers (Session, Provider, Config, SSE), Channels (UserSocket, SessionChannel), Telemetry. Supervisor started by synapsis_core at runtime.
- **synapsis_web** — 15 LiveView pages, HEEx templates, CoreComponents, Layouts, Gettext. Workspace packages (`@synapsis/hooks`, `@synapsis/ui`, `@synapsis/channel`) for React chat widget. Bun build pipeline for JS/CSS.
- **synapsis_lsp** — LSP client management, JSON-RPC protocol, language server lifecycle. Supervisor started by synapsis_core.
- **synapsis_cli** — Standalone escript, connects over HTTP/WS to running server.

## Rationale

- Clear deployment boundaries: data+provider+core+server+lsp+web = one release, CLI = separate binary
- Enforced dependency direction via Mix project config — violations are compile errors
- Data layer isolation: all schemas and persistence in `synapsis_data`, enforcing the package policy
- Provider layer isolation: provider implementations don't pull in session/tool complexity
- Frontend uses LiveView for page structure with React via `phx-hook` for the chat widget — bun build pipeline for JS/CSS assets
- CLI connects over the network, not in-process — enables remote server operation

## Alternatives Considered

**Dave Thomas path-deps**: Better for large teams, but this is a focused tool with clear app boundaries. Umbrella's shared config/deps is an advantage here.

**Monolith Phoenix app**: Simpler, but conflates CLI packaging, LSP lifecycle, and web serving. Would need discipline to maintain boundaries.

**5-app structure (original)**: The original design had 5 apps with synapsis_core owning schemas and providers. Splitting into 7 apps improved separation of concerns and made the dependency graph cleaner.

## Consequences

- Must maintain dependency direction discipline (lower layers never import from higher layers)
- Shared test infrastructure via umbrella root
- Single `mix release` for server components, separate `mix escript.build` for CLI
- `synapsis_server` compiles before `synapsis_web` — router references to LiveView modules require `@compile {:no_warn_undefined, ...}` annotation
