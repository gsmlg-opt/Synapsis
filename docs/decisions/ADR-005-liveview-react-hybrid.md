# ADR-005: LiveView + React Hybrid (Supersedes ADR-003)

## Status: Accepted (revised)

## Context

ADR-003 chose a pure React SPA served by a catch-all `SPAController`. All routing, session management, sidebar rendering, and chat UI lived in React, communicating with Phoenix only via Channels and REST.

In practice this created problems:

- **Non-idiomatic Phoenix**: A catch-all SPA route bypassed Phoenix's router, plugs, and CSRF protection. The server was reduced to a static file host plus API — none of Phoenix's rendering strengths were used.
- **Redundant client-side routing**: React managed URL routing for what amounted to two pages (session list and chat view), duplicating logic Phoenix handles natively.
- **No server rendering**: The sidebar and session list required client-side fetch-on-mount with loading states for data that was trivially available on the server at render time.
- **Deployment complexity**: The SPA needed a separate `index.html` in `priv/static/` and the `SPAController` to serve it — an unusual pattern for Phoenix apps.

## Decision

Replace the React SPA with Phoenix LiveView for all page structure. Mount React via `phx-hook` only for the ChatApp component (streaming text, tool permissions, channel interaction).

### Architecture Split

**`synapsis_server`** owns all Phoenix infrastructure:
- `SynapsisServer.Endpoint` — serves static assets, mounts sockets
- `SynapsisServer.Router` — defines both `:browser` (LiveView) and `:api` (REST) pipelines
- `SynapsisServer.UserSocket` + `SynapsisServer.SessionChannel` — WebSocket for chat streaming
- REST controllers: `SessionController`, `ProviderController`, `ConfigController`, `SSEController`
- `SynapsisServer.Supervisor` — started by `SynapsisCore.Application` at runtime

**`synapsis_web`** owns all rendering:
- **15 LiveView pages** covering dashboard, projects, sessions, providers, memory, skills, MCP, LSP, and settings
- HEEx templates, `CoreComponents`, `Layouts`, Gettext
- React hooks via workspace packages

### LiveView Pages

```
DashboardLive            — landing page: projects list + recent sessions
ProjectLive.Index/Show   — project CRUD and detail views
SessionLive.Index/Show   — session list and core chat view
ProviderLive.Index/Show  — LLM provider configuration
MemoryLive.Index         — persistent memory entries with scope filtering
SkillLive.Index/Show     — agent skill definitions
MCPLive.Index/Show       — MCP server configuration
LSPLive.Index/Show       — LSP server configuration
SettingsLive             — settings hub linking to all config pages
```

### React Chat Widget

`SessionLive.Show` is the core chat view. LiveView owns the page chrome (sidebar, header, agent mode toggle). The React `ChatApp` is mounted into:

```heex
<div id={"chat-#{@session.id}"}
     phx-hook="ChatApp"
     phx-update="ignore"
     data-session-id={@session.id}
     data-agent-mode={@agent_mode}
     class="flex-1 overflow-hidden">
</div>
```

React manages its own Channel connection for streaming chat — LiveView does not participate in the message flow.

### Workspace Packages

Three Bun workspace packages in `packages/` provide the JS layer:

- **`@synapsis/hooks`** — LiveView hooks that mount React components: `ChatApp`, `MarkdownRenderer`, `DiffViewer`, `TerminalOutput`. Exported as a `Hooks` object for `LiveSocket` registration.
- **`@synapsis/ui`** — React components (`ChatApp`, `MessageList`, `MessageItem`, `StreamingText`, `ToolCallCard`, `ThinkingBlock`, `MessageInput`) and widgets (`MarkdownView`, `DiffViewer`, `TerminalOutput`). Redux Toolkit store with `chatSlice`, `uiSlice`, `sessionSlice`.
- **`@synapsis/channel`** — Phoenix Socket singleton (`createSocket`), session channel factory (`createSessionChannel`), Redux middleware that bridges channel events to store dispatches.

```
packages/
├── channel/    # @synapsis/channel — Socket + Redux middleware
├── hooks/      # @synapsis/hooks — LiveView phx-hook bridges
└── ui/         # @synapsis/ui — React components + Redux store
```

Root `package.json` defines workspaces: `["packages/*", "apps/synapsis_web"]`.

## Rationale

- **Server-rendered pages**: All CRUD/config pages load from DB in `mount/3` — no loading spinner, no client-side fetch. LiveView patches the DOM on mutations with zero JS.
- **Idiomatic Phoenix routing**: `live "/projects/:id", ProjectLive.Show` — URL changes handled by `handle_params/3`, browser back/forward works natively.
- **CSRF protection**: The `:browser` pipeline provides `protect_from_forgery` and the root layout injects a CSRF meta tag.
- **React where it matters**: The chat view genuinely benefits from React — high-frequency streaming updates, complex component state (message list, streaming text, tool permission dialogs), and the Channel lifecycle.
- **Redux for chat state**: The chat widget has complex state (messages, streaming status, tool calls, permissions) that maps naturally to Redux slices with the channel middleware bridging server events.
- **Workspace packages**: Bun workspaces keep the JS organized without a monorepo tool. `@synapsis/hooks` is the only package imported by `app.ts` — it re-exports hooks that mount `@synapsis/ui` components.

## Implementation

### Server side

- `SynapsisServer` module provides `router`, `channel`, `controller` macros with shared helpers
- `SynapsisWeb` module provides `live_view`, `live_component`, `html` macros with shared `html_helpers/0`
- `SynapsisWeb.Layouts` provides `root.html.heex` (HTML shell with CSRF, assets) and `app.html.heex` (flash + content)
- `SynapsisServer.Endpoint` adds `/live` socket for LiveView, `/socket` for channels
- Router defines `:browser` pipeline (LiveView routes scoped to `SynapsisWeb`) and `:api` pipeline (REST controllers scoped to `SynapsisServer`)

### Client side

- `app.ts` imports `{ Hooks }` from `@synapsis/hooks`, creates `LiveSocket` with hooks registered
- `@synapsis/hooks/chat-app.ts` — `mounted()` creates Redux store with channel middleware, creates React root, renders `<ChatApp>`; `destroyed()` unmounts
- `@synapsis/ui/chat/store.ts` — Redux store factory with `chatSlice` (messages, streaming), `uiSlice` (theme, sidebar), `sessionSlice` (metadata)
- `@synapsis/channel/middleware.ts` — Redux middleware that joins a Phoenix channel and maps inbound events to dispatched actions

## Alternatives Considered

**Keep pure React SPA (ADR-003)**: Works but wastes Phoenix's strengths. Every page load requires a full JS bundle parse, client-side fetch, and render cycle for content the server already has.

**Full LiveView (no React)**: Would eliminate JS complexity entirely, but LiveView is not well-suited for the chat view's high-frequency streaming updates (token-by-token LLM output) and complex interactive state (Channel lifecycle, tool permission queues, streaming text accumulation).

## Consequences

- `phoenix_live_view` and `phoenix_html` are dependencies of both `synapsis_server` and `synapsis_web`
- LiveView signing salt required in endpoint config
- `.formatter.exs` updated with `Phoenix.LiveView.HTMLFormatter` plugin for `.heex` files
- The Channel protocol and REST API are unchanged — CLI and future IDE extensions are unaffected
- Test support gains `Phoenix.LiveViewTest` import for LiveView integration tests
- Router in `synapsis_server` references `SynapsisWeb.*` LiveView modules that compile later — requires `@compile {:no_warn_undefined, ...}` annotation
- Three workspace packages add JS complexity, but keep concerns separated (hooks vs components vs transport)
