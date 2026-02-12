# ADR-003: React Frontend via Phoenix Channels

## Status: Accepted

## Context

Need a web UI for the coding agent. Options: LiveView, React SPA via Channels, or hybrid.

## Decision

React SPA communicating with Phoenix via Channels (WebSocket). Phoenix serves static assets and provides the Channel/REST API. Built with Bun and styled with Tailwind CSS.

## Rationale

- Rich terminal rendering (xterm.js), diff viewers (Monaco/CodeMirror), and file trees are mature React ecosystem components
- Streaming LLM output maps naturally to Channel pushes — React renders incrementally
- Phoenix manages state and connections on the server; React owns rendering
- Enables multiple client types (web, CLI, IDE extension) sharing the same Channel protocol
- Developer ergonomics: CSS/animation tooling is superior in React ecosystem

## Alternatives Considered

**LiveView**: Excellent for form-heavy CRUD. Less suited for:
- High-frequency streaming updates (LLM token-by-token)
- Complex client-side interactions (terminal emulator, code editor)
- Offline-capable UI state

**Hybrid (LiveView + React hooks)**: Adds complexity of two rendering models. No clear benefit when the entire UI is interactive.

## Consequences

- Need bun run build pipeline in `synapsis_web`
- Channel protocol becomes a public API contract (documented in 04_BOUNDARIES.md)
- Server-side rendering not available (acceptable for a dev tool)
- Testing requires both ExUnit (server) and JS test runner (client)
