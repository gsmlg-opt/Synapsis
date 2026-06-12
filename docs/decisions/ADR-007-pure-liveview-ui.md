# ADR-007: Pure LiveView UI (Removes the React ChatApp)

## Status: Accepted

Partially supersedes [ADR-005 (LiveView + React Hybrid)](ADR-005-liveview-react-hybrid.md):
the LiveView-owns-pages decision stands; the "mount React via `phx-hook` for the
ChatApp" half is removed.

## Context

ADR-005 kept one React island: the ChatApp (streaming chat, tool permissions),
mounted via `phx-hook="ChatApp"` inside `SessionLive.Show`. That integration was
never completed — the hook was registered but no template ever mounted it, and
`SessionLive.Show` no longer exists. The chat UI grew instead as a pure LiveView
(`SynapsisWeb.AgentLive.Sessions`) using two small DOM hooks (`ScrollBottom`,
`StreamingText`) plus a Preact-based `AgentModelPicker`.

The dead React path still had real costs: `@synapsis/ui` and `@synapsis/channel`
were built and shipped, React/ReactDOM were bundled into `app.js` (24.2 MB), and
ADR-005 misled readers into believing a hybrid architecture existed.

## Decision

The web UI is **pure Phoenix LiveView** (with `phoenix_duskmoon` components and
small TypeScript hooks). No React.

Removed:

- `packages/ui` (`@synapsis/ui`) — React chat components, never mounted
- `packages/channel` (`@synapsis/channel`) — channel client, only consumed by the dead hook
- Dead hooks in `packages/hooks`: `chat-app`, `markdown-renderer`,
  `markdown-submit`, `send-button`, `diff-viewer`, `terminal-output`,
  `textarea-submit`, `agent-model-cascader` (zero `phx-hook` references)
- `react` / `react-dom` dependencies

Kept in `@synapsis/hooks`: `ScrollBottom`, `StreamingText`, `AgentModelPicker`
(Preact, mounted in `AgentLive.Agents`).

## Consequences

- `app.js` bundle: 24.2 MB → 6.2 MB.
- New rich client UI (diff viewers, terminals, markdown) should be built with
  DuskMoon elements/LiveView first; reintroducing a JS-framework island requires
  a new ADR.
- `packages/*` now contains only `@synapsis/hooks`.
