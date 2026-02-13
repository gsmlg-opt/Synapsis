# ADR-001: Umbrella Project Structure

## Status: Accepted

## Context

Need to organize a multi-concern Phoenix application (core domain, HTTP server, CLI, LSP, web frontend). Options: monolith, Dave Thomas path-deps, or umbrella.

## Decision

Umbrella project with 5 apps:
- `synapsis_core` — domain logic, zero external deps on other apps
- `synapsis_server` — Phoenix endpoints, depends on core
- `synapsis_lsp` — LSP client management, depends on core
- `synapsis_cli` — standalone escript, communicates via HTTP/WS (no Elixir deps)
- `synapsis_web` — Phoenix app with LiveView + React hybrid frontend (see [ADR-005](ADR-005-liveview-react-hybrid.md))

## Rationale

- Clear deployment boundaries: core+server+lsp = one release, CLI = separate binary
- Enforced dependency direction via Mix project config
- Frontend uses LiveView for page structure with React via `phx-hook` for the chat widget — bun build pipeline for JS/CSS assets
- CLI connects over the network, not in-process — enables remote server operation

## Alternatives Considered

**Dave Thomas path-deps**: Better for large teams, but this is a focused tool with clear app boundaries. Umbrella's shared config/deps is an advantage here.

**Monolith Phoenix app**: Simpler, but conflates CLI packaging, LSP lifecycle, and web serving. Would need discipline to maintain boundaries.

## Consequences

- Must maintain dependency direction discipline (core imports nothing from server)
- Shared test infrastructure via umbrella root
- Single `mix release` for server components, separate `mix escript.build` for CLI
