# HANDOFF — Implementation Plan

## Project: Synapsis.ex

### Umbrella Structure (7 apps)

```
apps/
├── synapsis_data/       # Ecto schemas, Repo, migrations (no application)
├── synapsis_provider/   # Provider behaviour + implementations (no application)
├── synapsis_core/       # THE application — sessions, tools, agents, config
├── synapsis_server/     # Phoenix Endpoint, Router, Controllers, Channels (no application)
├── synapsis_web/        # LiveView pages, HEEx templates, React hooks (no application)
├── synapsis_lsp/        # LSP client management (no application)
└── synapsis_cli/        # Standalone escript
```

### Dependency Wiring (mix.exs)

```elixir
# apps/synapsis_data/mix.exs — no umbrella deps
defp deps do
  [{:ecto_sql, "~> 3.12"},
   {:postgrex, "~> 0.19"},
   {:jason, "~> 1.4"}]
end

# apps/synapsis_provider/mix.exs
defp deps do
  [{:synapsis_data, in_umbrella: true},
   {:req, "~> 0.5"},
   {:finch, "~> 0.18"},
   {:jason, "~> 1.4"}]
end

# apps/synapsis_core/mix.exs
defp deps do
  [{:synapsis_data, in_umbrella: true},
   {:synapsis_provider, in_umbrella: true},
   {:phoenix_pubsub, "~> 2.1"},
   {:jason, "~> 1.4"}]
end

# apps/synapsis_server/mix.exs
defp deps do
  [{:synapsis_core, in_umbrella: true},
   {:synapsis_provider, in_umbrella: true},
   {:synapsis_lsp, in_umbrella: true},
   {:phoenix, "~> 1.8"},
   {:phoenix_html, "~> 4.2"},
   {:phoenix_live_view, "~> 1.0"},
   {:jason, "~> 1.4"},
   {:bandit, "~> 1.6"},
   {:cors_plug, "~> 3.0"}]
end

# apps/synapsis_web/mix.exs
defp deps do
  [{:synapsis_server, in_umbrella: true},
   {:phoenix, "~> 1.8"},
   {:phoenix_html, "~> 4.2"},
   {:phoenix_live_view, "~> 1.0"},
   {:gettext, "~> 1.0"},
   {:jason, "~> 1.4"},
   {:bun, "~> 1.6", runtime: Mix.env() == :dev},
   {:tailwind, "~> 0.2", runtime: Mix.env() == :dev}]
end
# Workspace packages: @synapsis/hooks, @synapsis/ui, @synapsis/channel

# apps/synapsis_lsp/mix.exs
defp deps do
  [{:synapsis_core, in_umbrella: true},
   {:jason, "~> 1.4"}]
end

# apps/synapsis_cli/mix.exs (standalone, no umbrella deps)
defp deps do
  [{:req, "~> 0.5"},
   {:jason, "~> 1.4"},
   {:owl, "~> 0.12"}]
end
```

---

## Implementation Phases

### Phase 1: Foundation ✅

**Goal**: Umbrella scaffold, core schemas, single provider streaming

Completed:
- [x] Generated umbrella + all 7 app skeletons
- [x] Created Ecto migrations and schemas: Project, Session, Message with Part custom type
- [x] Implemented Synapsis.Config — load/merge .opencode.json + user config
- [x] Implemented Synapsis.Provider.Behaviour + Anthropic provider
- [x] Implemented Synapsis.Session.Worker GenServer — basic send/receive loop
- [x] Unit tests for message building, config merging, part serialization

### Phase 2: Tool System ✅

**Goal**: 27-tool system with 5-level permissions, parallel execution, and plugin integration

Completed:
- [x] Implemented `Synapsis.Tool` behaviour contract with `permission_level/0`, `category/0`, `version/0`, `enabled?/0` callbacks
- [x] Implemented `Synapsis.Tool.Registry` (ETS-backed GenServer) with `list_for_llm/1` filtering by agent mode, category, deferred state
- [x] Implemented `Synapsis.Tool.Executor` with parallel batch execution (`execute_batch/2`) via `Task.async_stream/3`
- [x] Implemented `Synapsis.Tool.Permission` — 5-level model (`:none`, `:read`, `:write`, `:execute`, `:destructive`) with per-tool glob overrides and autonomous mode
- [x] Implemented 27 built-in tools across 10 categories:
  - Filesystem (7): file_read, file_write, file_edit, multi_edit, file_delete, file_move, list_dir
  - Search (2): grep, glob
  - Execution (1): bash_exec (persistent Port session)
  - Web (2): web_fetch, web_search
  - Planning (2): todo_write, todo_read
  - Orchestration (3): task (sub-agents), tool_search (deferred loading), skill
  - Interaction (1): ask_user (structured questions)
  - Session (3): enter_plan_mode, exit_plan_mode, sleep
  - Swarm (3): send_message, teammate, team_delete
  - Disabled stubs (3): notebook_read, notebook_edit, computer
- [x] Implemented side effect system — `:file_changed` broadcast via PubSub
- [x] Implemented deferred tool loading for MCP/plugin tools
- [x] Implemented plan mode tool filtering (read-only in `:plan` mode)
- [x] Added 3 new database tables: `tool_calls`, `session_permissions`, `session_todos`
- [x] Wired tool results back into the agent loop (Session.Worker)

### Phase 3: Provider System ✅

**Goal**: Multi-provider support with unified internal API

Completed:
- [x] Unified Adapter with Anthropic-shaped internal event format
- [x] Transport plugins: Anthropic, OpenAI-compat, Google
- [x] EventMapper, MessageMapper, ModelRegistry
- [x] SSE parser (shared by all transports)
- [x] Provider.Registry (ETS-backed)
- [x] Retry logic for 429/5xx

### Phase 4: Phoenix Server + Web Frontend ✅

**Goal**: LiveView + React hybrid UI (see [ADR-005](decisions/ADR-005-liveview-react-hybrid.md))

Completed:
- [x] synapsis_server: Endpoint, Router, Supervisor, Telemetry
- [x] synapsis_server: REST controllers (Session, Provider, Config, SSE)
- [x] synapsis_server: SessionChannel + UserSocket
- [x] synapsis_web: SynapsisWeb module with live_view/live_component/html macros
- [x] synapsis_web: Layouts (root.html.heex, app.html.heex), CoreComponents
- [x] synapsis_web: 15 LiveView pages (Dashboard, Projects, Sessions, Providers, Memory, Skills, MCP, LSP, Settings)
- [x] Workspace packages: @synapsis/hooks, @synapsis/ui, @synapsis/channel
- [x] React ChatApp with Redux store + channel middleware
- [x] New schemas: MemoryEntry, Skill, MCPConfig, LSPConfig
- [x] Context APIs: Synapsis.Projects, Synapsis.Sessions extensions

### Phase 5: LSP + MCP (In Progress)

**Goal**: Language intelligence and external tool servers

Tasks:
1. Implement `Synapsis.LSP.Server` GenServer — manage LSP process via Port
2. Implement `Synapsis.LSP.Manager` — auto-detect languages, start servers
3. Wire diagnostics into tool system
4. Implement `Synapsis.MCP.Client` — JSON-RPC over stdio
5. MCP tool discovery and registration in Tool.Registry
6. MCP config in `.opencode.json`

### Phase 6: CLI

**Goal**: Terminal client that connects to running server

Tasks:
1. Implement CLI argument parsing
2. WebSocket client to connect to `synapsis_server`
3. Streaming output rendering in terminal
4. Non-interactive mode (`synapsis -p "explain this"`)
5. Package as escript or Burrito binary

### Phase 7: Polish (Ongoing)

- Context window management + compaction
- Session forking
- File watching (`FileSystem` package)
- Git integration (auto-commit, undo via git)
- Config file watching + hot reload
- OpenCode config compatibility (read existing `.opencode.json`)
- Nix flake for development + packaging
- Docker Compose for PostgreSQL

---

## OpenCode Feature Parity Checklist

- [x] Multi-provider support (Anthropic, OpenAI, Google, local/OpenAI-compat)
- [x] Session management (create, list, continue, delete, fork)
- [x] Agent modes (build, plan, custom with config override)
- [x] Tool system (27 tools: filesystem, search, execution, web, planning, orchestration, interaction, session, swarm)
- [x] Permission system (5-level: none/read/write/execute/destructive, per-tool glob overrides, autonomous mode)
- [x] Parallel tool execution (batch with file-level serialization)
- [x] Sub-agent support (foreground/background task tool)
- [x] Plan mode (enter/exit, read-only tool filtering)
- [x] Deferred tool loading (tool_search for MCP/plugin tools)
- [x] Tool call persistence (audit trail in tool_calls table)
- [x] Context compaction (summarize old messages when approaching window limit)
- [x] Streaming responses (token-by-token to web + CLI clients)
- [x] Web UI (LiveView + React — chat, tool display, session management, provider selector)
- [x] `.opencode.json` config compatibility (agents, providers, mcpServers, lsp)
- [ ] LSP integration (diagnostics for go, typescript, elixir)
- [ ] MCP support (discover + call tools from configured MCP servers)
- [ ] CLI (interactive + non-interactive `synapsis -p "..."`)
- [ ] File diff display (show edits before/after)
- [ ] Image input support
- [ ] Error recovery (provider disconnect, tool timeout, graceful degradation)
- [ ] Docker Compose for PostgreSQL
- [ ] All tests passing (`mix test` from umbrella root) — 258 tests, 0 failures currently
