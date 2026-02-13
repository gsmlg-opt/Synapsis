# HANDOFF — Implementation Plan

## Project: Synapsis.ex

### Quick Start

```bash
mix new synapsis --umbrella
cd synapsis/apps

# Core domain
mix new synapsis_core --sup
# Phoenix server (1.8 — Bandit default, no HTML)
mix phx.new synapsis_server --no-html --no-assets --no-mailers
# LSP client
mix new synapsis_lsp --sup
# CLI
mix new synapsis_cli
# Web frontend (Phoenix app with LiveView + React hybrid, bun managed)
mix new synapsis_web --app synapsis_web
```

### Dependency Wiring (mix.exs)

```elixir
# apps/synapsis_server/mix.exs
defp deps do
  [{:synapsis_core, in_umbrella: true},
   {:synapsis_lsp, in_umbrella: true},
   {:phoenix, "~> 1.8"},
   {:phoenix_live_dashboard, "~> 0.8"},  # optional, for monitoring
   {:jason, "~> 1.4"},
   {:bandit, "~> 1.6"},
   {:cors_plug, "~> 3.0"}]
end

# apps/synapsis_core/mix.exs
defp deps do
  [{:ecto_sql, "~> 3.12"},
   {:postgrex, "~> 0.19"},
   {:req, "~> 0.5"},
   {:finch, "~> 0.18"},
   {:jason, "~> 1.4"}]
end

# apps/synapsis_lsp/mix.exs
defp deps do
  [{:synapsis_core, in_umbrella: true},
   {:jason, "~> 1.4"}]
end

# apps/synapsis_cli/mix.exs  (standalone, no umbrella deps)
defp deps do
  [{:req, "~> 0.5"},
   {:jason, "~> 1.4"},
   {:owl, "~> 0.12"}]        # terminal UI (optional)
end

# apps/synapsis_web/mix.exs
defp deps do
  [{:synapsis_core, in_umbrella: true},
   {:synapsis_lsp, in_umbrella: true},
   {:phoenix, "~> 1.8"},
   {:phoenix_html, "~> 4.2"},
   {:phoenix_live_view, "~> 1.0"},
   {:gettext, "~> 1.0"},
   {:jason, "~> 1.4"},
   {:bandit, "~> 1.6"},
   {:cors_plug, "~> 3.0"},
   {:bun, "~> 1.6", runtime: Mix.env() == :dev},
   {:tailwind, "~> 0.2", runtime: Mix.env() == :dev}]
end
# package.json: react, react-dom, phoenix, phoenix_html, phoenix_live_view
```

---

## Implementation Phases

### Phase 1: Foundation (Week 1-2)

**Goal**: Umbrella scaffold, core schemas, single provider streaming

Tasks:
1. Generate umbrella + all app skeletons
2. Run `mix ecto.create` and initial migrations
3. Create Ecto schemas: `Session`, `Message` with `Part` custom type
4. Configure `Synapsis.Repo` with PostgreSQL, project scoped via `project_id` column
5. Implement `Synapsis.Config` — load/merge `.opencode.json` + user config
6. Implement `Synapsis.Provider.Behaviour` + `Synapsis.Provider.Anthropic`
7. Implement `Synapsis.Session.Worker` GenServer — basic send/receive loop
8. Write unit tests for message building, config merging, part serialization

**Deliverable**: Can start a session, send a message, get streaming response from Anthropic in IEx.

### Phase 2: Tool System (Week 3)

**Goal**: AI can use tools to read/write files and run commands

Tasks:
1. Implement `Synapsis.Tool.Behaviour` + `Synapsis.Tool.Registry`
2. Implement core tools: `FileRead`, `FileEdit`, `FileWrite`, `Bash`, `Grep`, `Glob`
3. Implement `Synapsis.Tool.Permission` — auto-approve vs ask
4. Implement `Synapsis.Tool.Executor` with `Task.Supervisor`
5. Wire tool results back into the agent loop (Session.Worker)
6. Test: full agent loop — user asks to edit file → AI proposes tool use → execute → respond

**Deliverable**: Full agent loop works in IEx with tool execution.

### Phase 3: Phoenix Server (Week 4)

**Goal**: WebSocket channel API for session interaction

Tasks:
1. Set up Phoenix in `synapsis_server` (no HTML, API only)
2. Implement `SessionChannel` — join, send_message, tool approval
3. Wire PubSub: Session.Worker broadcasts → Channel pushes to client
4. Implement REST endpoints: sessions CRUD, providers list, config
5. Add SSE endpoint as alternative to Channels (for CLI)
6. CORS config for local dev
7. Channel tests with `Phoenix.ChannelTest`

**Deliverable**: Can connect via `wscat` or simple HTML page, have a conversation with tool use.

### Phase 4: Web Frontend (Week 5-6)

**Goal**: LiveView + React hybrid UI (see [ADR-005](decisions/ADR-005-liveview-react-hybrid.md))

Architecture: LiveView manages page layout, sidebar, session list, and URL routing. React is mounted via `phx-hook` only for the ChatView component (streaming text, tool permissions, Channel interaction).

Tasks:
1. Add `phoenix_live_view` and `phoenix_html` to `synapsis_web` deps
2. Add LiveView macros (`live_view`, `live_component`, `html`) to `SynapsisWeb` module
3. Create layout components: `Layouts` module, `root.html.heex`, `app.html.heex`, `CoreComponents`
4. Add `/live` socket to endpoint, `:browser` pipeline to router with LiveView routes
5. Implement `SessionLive` — mount loads sessions, `handle_params` sets active session, events for create/delete
6. Create `ChatViewHook` (`phx-hook`) — mounts React `ChatView` into LiveView DOM with `phx-update="ignore"`
7. Rewrite JS entry point (`app.ts`) — LiveView bootstrap + hook registration
8. Chat UI (React): message list, streaming text rendering, markdown (retained from SPA)
9. Tool permission dialog (React, retained)
10. File diff viewer (CodeMirror or simple)
11. Provider/model selector
12. Agent mode toggle (build/plan)

**Deliverable**: Functional web UI — LiveView sidebar with server-rendered session list, React chat view with streaming.

### Phase 5: LSP + MCP (Week 7)

**Goal**: Language intelligence and external tool servers

Tasks:
1. Implement `Synapsis.LSP.Server` GenServer — manage LSP process via Port
2. Implement `Synapsis.LSP.Manager` — auto-detect languages, start servers
3. Wire diagnostics into tool system
4. Implement `Synapsis.MCP.Client` — JSON-RPC over stdio
5. MCP tool discovery and registration in Tool.Registry
6. MCP config in `.opencode.json`

### Phase 6: CLI (Week 8)

**Goal**: Terminal client that connects to running server

Tasks:
1. Implement CLI argument parsing
2. WebSocket client to connect to `synapsis_server`
3. Streaming output rendering in terminal
4. Non-interactive mode (`synapsis -p "explain this"`)
5. Package as escript or Burrito binary

### Phase 7: Polish (Ongoing)

- Context window management + compaction
- Multiple provider support (OpenAI, Google, local)
- Session forking
- File watching (`FileSystem` package)
- Git integration (auto-commit, undo via git)
- Config file watching + hot reload
- OpenCode config compatibility (read existing `.opencode.json`)
- Nix flake for development + packaging

---

## OpenCode Feature Parity Checklist

- [ ] Multi-provider support (Anthropic, OpenAI, Google, Copilot, local)
- [ ] Session management (create, list, continue, delete)
- [ ] Agent modes (build, plan, custom)
- [ ] Tool system (file ops, bash, search, diagnostics)
- [ ] Permission system (auto-approve, ask, deny)
- [ ] Context compaction
- [ ] LSP integration
- [ ] MCP support
- [ ] `.opencode.json` config compatibility
- [ ] Web UI
- [ ] CLI (interactive + non-interactive)
- [ ] Image input support
- [ ] Conversation sharing
- [ ] Git integration
- [ ] File watching
