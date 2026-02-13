# ADR-005: LiveView + React Hybrid (Supersedes ADR-003)

## Status: Accepted

## Context

ADR-003 chose a pure React SPA served by a catch-all `SPAController`. All routing, session management, sidebar rendering, and chat UI lived in React, communicating with Phoenix only via Channels and REST.

In practice this created problems:

- **Non-idiomatic Phoenix**: A catch-all SPA route bypassed Phoenix's router, plugs, and CSRF protection. The server was reduced to a static file host plus API — none of Phoenix's rendering strengths were used.
- **Redundant client-side routing**: React managed URL routing for what amounted to two pages (session list and chat view), duplicating logic Phoenix handles natively.
- **No server rendering**: The sidebar and session list required client-side fetch-on-mount with loading states for data that was trivially available on the server at render time.
- **Deployment complexity**: The SPA needed a separate `index.html` in `priv/static/` and the `SPAController` to serve it — an unusual pattern for Phoenix apps.

## Decision

Replace the React SPA with Phoenix LiveView for page structure. Mount React via `phx-hook` only for the ChatView component (streaming text, tool permissions, channel interaction).

Architecture:

- **LiveView (`SessionLive`)** owns the page layout, sidebar, session list, session creation/deletion, and URL routing via `live` routes and `handle_params`.
- **React (`ChatView`)** is mounted into a `phx-hook="ChatView"` div with `phx-update="ignore"`. It manages the Phoenix Channel connection, streaming message rendering, tool permission dialogs, and input form.
- **Phoenix router** uses a `:browser` pipeline with session, CSRF, and LiveView flash. API routes remain in the `:api` pipeline unchanged.

## Rationale

- **Server-rendered sidebar**: Session list loads from DB in `mount/3` — no loading spinner, no client-side fetch. LiveView patches the DOM on create/delete with zero JS.
- **Idiomatic Phoenix routing**: `live "/", SessionLive` and `live "/sessions/:id", SessionLive` — URL changes handled by `handle_params/3`, browser back/forward works natively.
- **CSRF protection**: The `:browser` pipeline provides `protect_from_forgery` and the root layout injects a CSRF meta tag for the LiveView socket.
- **React where it matters**: The chat view genuinely benefits from React — high-frequency streaming updates, complex component state (message list, streaming text, tool permission dialogs), and the existing `useSession` hook managing Channel lifecycle.
- **Minimal JS footprint**: `app.ts` bootstraps LiveView and registers a single hook. No client-side router, no global state management, no SPA shell.

## Implementation

### Server side

- `SynapsisWeb` module gains `live_view`, `live_component`, `html` macros with shared `html_helpers/0`
- `SynapsisWeb.Layouts` provides `root.html.heex` (HTML shell with CSRF, assets) and `app.html.heex` (flash + content)
- `SynapsisWeb.Endpoint` adds `/live` socket for LiveView
- Router adds `:browser` pipeline; SPA catch-all removed
- `SPAController` and `priv/static/index.html` deleted

### Client side

- `app.ts` (replaces `app.tsx`) — imports `phoenix_html`, creates `LiveSocket`, registers `ChatView` hook
- `hooks/chat_view_hook.tsx` — `mounted()` creates a React root, fetches initial messages via REST, renders `<ChatView>`; `destroyed()` unmounts
- `App.tsx` and `Sidebar.tsx` deleted (replaced by LiveView template)
- `ChatView.tsx`, `MessageBubble.tsx`, `ToolPermission.tsx`, `useSession.ts`, `api.ts`, `socket.ts` retained

### JS dependencies

- `phoenix_html` and `phoenix_live_view` added to `package.json` as `file:` references to Hex deps
- Bun entry point changed from `app.tsx` to `app.ts` in config

## Alternatives Considered

**Keep pure React SPA (ADR-003)**: Works but wastes Phoenix's strengths. Every page load requires a full JS bundle parse, client-side fetch, and render cycle for content the server already has.

**Full LiveView (no React)**: Would eliminate JS complexity entirely, but LiveView is not well-suited for the chat view's high-frequency streaming updates (token-by-token LLM output) and complex interactive state (Channel lifecycle, tool permission queues, streaming text accumulation).

## Consequences

- `phoenix_live_view` and `phoenix_html` added as dependencies to `synapsis_web`
- LiveView signing salt required in endpoint config
- `.formatter.exs` updated with `Phoenix.LiveView.HTMLFormatter` plugin for `.heex` files
- The Channel protocol and REST API are unchanged — CLI and future IDE extensions are unaffected
- Test support gains `Phoenix.LiveViewTest` import for LiveView integration tests
- `synapsis_web` is no longer a plain Mix project — it is a full Phoenix app with LiveView
