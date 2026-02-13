# CLAUDE.md

## Mission

Build **Synapsis** — a complete AI coding agent in Elixir/Phoenix. Work through ALL phases below sequentially. After each phase, run `mix compile && mix test` to verify. Fix any errors before moving to the next phase. Do not stop until all phases are complete and the feature parity checklist at the bottom is fully checked off.

## Architecture Docs — Read First

Read every file in `docs/` before writing any code. These are the source of truth:

- `docs/architecture/00_SYSTEM_OVERVIEW.md` — supervision tree, data flow diagram
- `docs/architecture/01_DOMAIN_MODEL.md` — entities, state machines, relationships
- `docs/architecture/02_DATA_LAYER.md` — PostgreSQL schemas, Ecto types, query patterns
- `docs/architecture/03_FUNCTIONAL_CORE.md` — pure functions, message building, context window
- `docs/architecture/04_BOUNDARIES.md` — public APIs, channel protocol, REST endpoints, behaviours
- `docs/architecture/05_TOOLS.md` — tool system, execution flow, built-in tools
- `docs/architecture/06_PROVIDERS.md` — LLM provider streaming, registry, retry
- `docs/decisions/ADR-001-umbrella-structure.md`
- `docs/decisions/ADR-002-postgresql-storage.md`
- `docs/decisions/ADR-003-react-frontend.md`
- `docs/decisions/ADR-004-process-per-session.md`
- `docs/guardrails/GUARDRAILS.md` — NEVER DO / ALWAYS DO rules (follow strictly)
- `docs/HANDOFF.md` — phases, dependency wiring, task breakdown

## Tech Stack

- Elixir 1.18+ / OTP 28+
- Phoenix 1.8+ (Bandit, no LiveView, no Mailer, no HTML generators)
- PostgreSQL 16+ via Ecto (UUID PKs, JSONB)
- Bun (replaces esbuild as Phoenix asset bundler)
- React + Tailwind CSS
- Req + Finch for HTTP

## Critical Rules (from guardrails — never violate)

- Database is source of truth — no domain state in GenServers
- Never synchronous LLM calls — always stream async
- Use `Port` for shell execution, not `System.cmd`
- Persist to DB before broadcasting via PubSub
- Pure business logic in `synapsis_core` — zero Phoenix deps in core
- Every provider implements `Synapsis.Provider.Behaviour`
- Every tool implements `Synapsis.Tool.Behaviour`
- UUID for all primary keys
- Test with `Bypass` for HTTP — never hit real APIs
- Structured logging only: `Logger.info("event_name", key: value)`

## Code Conventions

- Module prefix: `Synapsis.*`
- Contexts: `Synapsis.Sessions`, `Synapsis.Providers`, `Synapsis.Tools`
- Behaviours: `Synapsis.Provider.Behaviour`, `Synapsis.Tool.Behaviour`
- GenServers: `Synapsis.Session.Worker`, `Synapsis.LSP.Server`
- Config: `~/.config/synapsis/{config,auth}.json`, project `.opencode.json`

---

## Phase 1: Umbrella Scaffold + Core Schemas

Generate the umbrella and all app skeletons per `docs/HANDOFF.md`:

```
apps/
├── synapsis_core/     # mix new synapsis_core --sup
├── synapsis_server/   # mix phx.new synapsis_server --no-html --no-assets --no-mailers
├── synapsis_lsp/      # mix new synapsis_lsp --sup
├── synapsis_cli/      # mix new synapsis_cli
└── synapsis_web/      # mix new synapsis_web
```

Wire deps exactly as specified in `docs/HANDOFF.md`. Then:

1. Write Ecto migrations for `projects`, `sessions`, `messages` (see `docs/architecture/02_DATA_LAYER.md` for exact SQL)
2. Implement schemas: `Synapsis.Project`, `Synapsis.Session`, `Synapsis.Message`
3. Implement `Synapsis.Part` custom Ecto type — JSONB ↔ tagged structs (`TextPart`, `ToolUsePart`, `ToolResultPart`, `ReasoningPart`, `FilePart`, `SnapshotPart`, `AgentPart`)
4. Implement `Synapsis.Config` — load/merge `.opencode.json` + `~/.config/synapsis/config.json` + env overrides
5. Write tests: part serialization round-trips, config merging, schema validations

**Checkpoint**: `mix compile && mix test` — all green. Schemas insert/query correctly in test DB.

## Phase 2: Provider System

Implement the provider abstraction per `docs/architecture/06_PROVIDERS.md`:

1. Define `Synapsis.Provider.Behaviour` (callbacks: `stream/2`, `cancel/1`, `models/1`, `format_request/3`)
2. Implement `Synapsis.Provider.Anthropic` — streaming SSE via Req/Finch, parse chunks into Part structs
3. Implement `Synapsis.Provider.OpenAICompat` — covers OpenAI, local models, OpenRouter (configurable `base_url`)
4. Implement `Synapsis.Provider.Google` — Gemini streaming
5. Implement `Synapsis.Provider.Registry` — ETS-backed provider lookup
6. Implement `Synapsis.Provider.Retry` — exponential backoff for 429/5xx
7. Implement `Synapsis.Provider.Parser` — pure functions for parsing each provider's SSE format
8. Write tests with `Bypass`: mock SSE streams, verify chunk parsing, test retry logic

**Checkpoint**: `mix test` — can mock-stream from all 3 providers. Parser tests cover all part types.

## Phase 3: Session System

Implement the process-per-session architecture per `docs/architecture/00_SYSTEM_OVERVIEW.md`:

1. Implement `Synapsis.Session.Worker` GenServer — state machine (idle → streaming → tool_executing → idle)
2. Implement `Synapsis.Session.Stream` — manages provider HTTP connection, sends `{:chunk, part}` to Worker
3. Implement `Synapsis.Session.Context` — token counting, compaction decisions (see `docs/architecture/03_FUNCTIONAL_CORE.md`)
4. Implement `Synapsis.Session.Supervisor` — `:one_for_all` per session (Worker + Stream + Context)
5. Implement `Synapsis.Session.DynamicSupervisor` — starts/stops session trees
6. Implement `Synapsis.Sessions` context — public API: `create/2`, `get/1`, `list/2`, `send_message/2`, `cancel/1`, `retry/1`
7. Implement `Synapsis.MessageBuilder` — builds provider request from session history + agent config
8. Implement `Synapsis.Agent.Resolver` — merges default agent with project config overrides
9. Set up `Phoenix.PubSub` in core app for event broadcasting
10. Write tests: session lifecycle, message persistence, streaming flow with mock provider

**Checkpoint**: `mix test` — full agent loop works. Send message → stream response → persist → broadcast. Test in IEx: `Synapsis.Sessions.create("/tmp/test") |> then(fn {:ok, s} -> Synapsis.Sessions.send_message(s.id, "hello") end)`.

## Phase 4: Tool System

Implement tools per `docs/architecture/05_TOOLS.md`:

1. Define `Synapsis.Tool.Behaviour` (callbacks: `name/0`, `description/0`, `parameters/0`, `call/2`)
2. Implement `Synapsis.Tool.Registry` — register/lookup tools by name
3. Implement `Synapsis.Tool.Executor` — permission check → Task.Supervisor execution → timeout handling
4. Implement `Synapsis.Tool.Permission` — auto-approve vs ask (configurable)
5. Implement built-in tools:
   - `Synapsis.Tool.FileRead` — read file contents
   - `Synapsis.Tool.FileEdit` — search/replace edits (validate path within project root)
   - `Synapsis.Tool.FileWrite` — write new files
   - `Synapsis.Tool.Bash` — execute shell via Port with streaming output + timeout
   - `Synapsis.Tool.Grep` — ripgrep-style search (shell out to `rg` if available, fallback to `grep`)
   - `Synapsis.Tool.Glob` — file pattern matching
6. Wire tool results back into Session.Worker agent loop (tool_use → execute → tool_result → feed back to provider)
7. Write tests: tool execution, permission checks, path validation, timeout handling, full agent loop with tool use

**Checkpoint**: `mix test` — AI can propose file edits, bash commands. Tool results feed back into conversation. Permission system works.

## Phase 5: Phoenix Server

Implement the HTTP/WebSocket layer per `docs/architecture/04_BOUNDARIES.md`:

1. Configure Phoenix in `synapsis_server` — router, endpoint, CORS
2. Implement `SynapsisServer.SessionChannel` — join, push messages, tool approval/denial, agent switching
3. Wire PubSub: `Synapsis.Session.Worker` broadcasts → Channel intercepts → pushes to client
4. Implement REST controllers:
   - `GET /api/sessions` — list sessions for project
   - `POST /api/sessions` — create session
   - `GET /api/sessions/:id` — get session with messages
   - `DELETE /api/sessions/:id` — delete session
   - `POST /api/sessions/:id/messages` — send message
   - `GET /api/providers` — list providers + models
   - `POST /api/auth/:provider` — authenticate provider
   - `GET /api/config` — resolved config
5. Implement SSE endpoint `GET /api/sessions/:id/events` as alternative to channels
6. Add JSON:API or simple JSON serialization for responses
7. Write channel tests with `Phoenix.ChannelTest` and controller tests

**Checkpoint**: `mix test` — can connect via WebSocket, send messages, receive streaming responses. REST endpoints return correct data. Test with `curl` and `wscat`.

## Phase 6: React Frontend

Set up the web UI in `synapsis_web`:

1. Initialize with Bun: `cd apps/synapsis_web && bun init`
2. Install deps: `bun add react react-dom tailwindcss @tailwindcss/vite` and dev deps
3. Configure Bun as Phoenix watcher in `config/dev.exs` (replace esbuild)
4. Configure Phoenix to serve built assets from `apps/synapsis_web/dist/`
5. Implement Phoenix Channel JS client (use `phoenix` npm package)
6. Build UI components:
   - App shell: sidebar + main content area
   - Session list sidebar: create, switch, delete sessions
   - Chat view: message list with streaming text, markdown rendering
   - Tool use display: show tool invocations and results inline
   - Permission dialog: approve/deny tool use requests
   - Provider/model selector
   - Agent mode toggle (build/plan tab)
   - File diff viewer for file edits (simple before/after or CodeMirror)
7. Style with Tailwind CSS — clean, minimal, dark mode support
8. Handle WebSocket reconnection and error states

**Checkpoint**: `mix phx.server` — web UI loads, can create sessions, chat with AI, approve tool use, see streaming responses.

## Phase 7: LSP Integration

Implement per `docs/architecture/05_TOOLS.md` diagnostics section:

1. Implement `Synapsis.LSP.Server` GenServer — manage LSP process via Port, JSON-RPC protocol
2. Implement `Synapsis.LSP.Manager` DynamicSupervisor — auto-detect languages from project files, start appropriate servers
3. Implement `Synapsis.LSP.Protocol` — encode/decode JSON-RPC, handle `initialize`, `textDocument/didOpen`, `textDocument/publishDiagnostics`
4. Implement `Synapsis.Tool.Diagnostics` — queries LSP.Manager for current diagnostics, feeds to AI
5. Support at minimum: `gopls`, `typescript-language-server`, `elixir-ls`
6. Write tests: LSP protocol encoding, mock LSP server via Port

**Checkpoint**: `mix test` — LSP servers start for detected languages. Diagnostics tool returns file errors.

## Phase 8: MCP Support

1. Implement `Synapsis.MCP.Client` GenServer — JSON-RPC over stdio (Port) or SSE (HTTP)
2. Implement `Synapsis.MCP.Protocol` — encode/decode JSON-RPC, tool discovery (`tools/list`), tool execution (`tools/call`)
3. Implement `Synapsis.MCP.DynamicSupervisor` — one client per configured MCP server
4. On startup, discover MCP tools and register in `Synapsis.Tool.Registry` as `mcp:<server>:<tool>`
5. MCP config read from `.opencode.json` `mcpServers` section (OpenCode compatible)
6. Write tests: protocol encoding, mock MCP server

**Checkpoint**: `mix test` — MCP tools discoverable and callable through the tool system.

## Phase 9: CLI

1. Implement `synapsis_cli` as escript
2. Argument parsing: `synapsis` (interactive), `synapsis -p "prompt"` (one-shot), `synapsis --model <model>`
3. WebSocket client to connect to running `synapsis_server`
4. Streaming output rendering in terminal (Owl or raw ANSI)
5. Non-interactive mode: send prompt, print response, exit
6. `synapsis serve` — start server in background

**Checkpoint**: `mix escript.build` — can run `./synapsis -p "explain this file"` and get a response.

## Phase 10: Polish + Feature Parity

1. Context window management — compaction when approaching limit
2. Session forking — branch a conversation at any point
3. File watching — `FileSystem` package, notify on project file changes
4. Git integration — auto-checkpoint before edits, undo via git
5. Config file watching — hot reload `.opencode.json` changes
6. Image input support — base64 encode images in messages
7. Conversation sharing — export session as shareable link/file
8. Error recovery — graceful handling of provider disconnects, tool crashes
9. Add `docker-compose.yml` with PostgreSQL for easy setup
10. Add `flake.nix` for Nix-based development environment

**Checkpoint**: All feature parity items checked off below.

---

## Feature Parity Checklist

Do not stop until every item is checked:

- [ ] Multi-provider support (Anthropic, OpenAI, Google, local/OpenAI-compat)
- [ ] Session management (create, list, continue, delete, fork)
- [ ] Agent modes (build, plan, custom with config override)
- [ ] Tool system (file read/edit/write, bash, grep, glob, diagnostics)
- [ ] Permission system (auto-approve, ask, deny — configurable per tool)
- [ ] Context compaction (summarize old messages when approaching window limit)
- [ ] LSP integration (diagnostics for go, typescript, elixir)
- [ ] MCP support (discover + call tools from configured MCP servers)
- [ ] `.opencode.json` config compatibility (agents, providers, mcpServers, lsp)
- [ ] Web UI (React + Tailwind — chat, tool display, session management, provider selector)
- [ ] CLI (interactive + non-interactive `synapsis -p "..."`)
- [ ] Streaming responses (token-by-token to web + CLI clients)
- [ ] File diff display (show edits before/after)
- [ ] Image input support
- [ ] Error recovery (provider disconnect, tool timeout, graceful degradation)
- [ ] Docker Compose for PostgreSQL
- [ ] All tests passing (`mix test` from umbrella root)

## Verification

After completing all phases, run:

```bash
mix compile --warnings-as-errors
mix test
mix format --check-formatted
```

All three must pass with zero errors.

---

## Package Policy: `synapsis_data`

### Scope

The `synapsis_data` package is responsible ONLY for:
- Defining data models
- Defining Ecto schemas
- Managing `Ecto.Repo`
- Persisting data to Postgres

### Hard Boundaries (Do NOT violate)

- Do NOT introduce business logic or orchestration logic
- Do NOT implement agent/runtime workflows
- Do NOT modify code outside `synapsis_data`
- Do NOT refactor other packages
- Do NOT change public APIs unless explicitly requested

### Persistence Rules

- All Postgres persistence MUST go through `synapsis_data`
- Other packages must NOT define their own Ecto schemas
- Other packages must NOT talk to Repo directly except through `synapsis_data` APIs

### Query & Transaction Discipline

- Encapsulate queries inside `synapsis_data` (no raw Ecto queries in other packages)
- Encapsulate transaction boundaries inside `synapsis_data`

### Failure Policy (Fail Closed)

If a task requires changes outside `synapsis_data`, new cross-package abstractions, or architecture redesign — STOP and explain the required changes instead of implementing them.
