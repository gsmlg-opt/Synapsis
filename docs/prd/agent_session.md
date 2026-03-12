# PRD: Synapsis Agent Session — Loki-Mode Execution Plan

## Objective

Take Synapsis from "compiles + tests pass" to a **working end-to-end AI coding agent** — boot the app, create a session, send a message, get streaming AI responses with tool calls, and verify the full agent loop completes. Then validate remaining feature gaps.

## Pre-requisites

```bash
# 1. Start devenv (provides Elixir, PostgreSQL, Bun, Tailwind)
devenv up

# 2. Verify database
mix ecto.setup   # or: mix ecto.create && mix ecto.migrate

# 3. Set at least one provider API key
export ANTHROPIC_API_KEY="sk-ant-..."
# and/or:
export OPENAI_API_KEY="sk-..."
export GOOGLE_API_KEY="AI..."

# 4. Install JS deps + build assets
cd apps/synapsis_web && bun install && cd ../..

# 5. Verify clean build
mix compile --warnings-as-errors
mix test
```

---

## Phase 1: Critical Bug Fixes (DONE)

Three bugs that collectively prevented the agent loop from functioning:

### Bug 1: Provider Type Missing in Env Var Fallback

**File:** `apps/synapsis_core/lib/synapsis/session/worker.ex:887`

**Problem:** When providers are configured via env vars (most common path), `resolve_provider_config/1` returned `%{api_key: ..., base_url: ...}` without a `:type` key. The Adapter reads `config[:type]` → `nil` → `resolve_transport_type(nil)` → `:openai`. All providers got routed through OpenAI transport, causing Anthropic/Google to fail.

**Fix:** Added `:type` key to the env var fallback map:
```elixir
%{api_key: api_key, base_url: default_base_url(provider_name), type: provider_name}
```

### Bug 2: Permissions Always Require Approval

**File:** `apps/synapsis_core/lib/synapsis/tool/permissions.ex:42-49`

**Problem:** `check/2` ignored session config — always returned `:requires_approval` for non-read tools. Every file_edit/write/bash invocation stalled waiting for WebSocket approval.

**Fix:** Rewrote `check/2` to consult session config `permissions.autoApprove` + application-level `default_auto_approve` config. Added `config :synapsis_core, default_auto_approve: [:read, :write, :execute]` to `config/dev.exs`.

### Bug 3: ProviderConfig Valid Types Incomplete

**File:** `apps/synapsis_data/lib/synapsis/provider_config.ex:8`

**Problem:** `@valid_types` only included `anthropic`, `openai_compat`, `google`. Creating a provider with type `"openai"` via UI failed changeset validation.

**Fix:** Expanded to `~w(anthropic openai openai_compat google local openrouter groq deepseek)`.

---

## Phase 2: Boot-Time Env Provider Registration (DONE)

**File:** `apps/synapsis_core/lib/synapsis_core/application.ex`

**Problem:** Only DB-persisted providers were loaded into the ETS Registry. Env var providers (`ANTHROPIC_API_KEY` etc.) were never registered, so `Provider.Registry.get("anthropic")` returned `{:error, :not_found}`.

**Fix:** Added `register_env_providers/0` after `load_all_into_registry()` in application startup. Checks `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY` env vars and registers them in ETS (skipping any already registered from DB).

---

## Phase 3: E2E Verification (chrome-devtools)

Boot the app and verify the full agent loop via browser:

### 3.1 Boot

```bash
mix phx.server
# App starts at http://localhost:4657
```

**Verify:** No compile errors, endpoint starts, postgres connected.

### 3.2 Provider Configuration

1. Navigate to `http://localhost:4657`
2. Go to Settings → Providers
3. **Verify:** Env-detected providers appear in the list (anthropic, openai, etc.)
4. Click "Test Connection" for each — verify models list returns

### 3.3 Session Lifecycle

1. Create a project (or use auto-detected project)
2. Create a new session
3. Select a provider + model (e.g., `anthropic` / `claude-sonnet-4-20250514`)
4. Send message: `"Hello, what tools do you have available?"`
5. **Verify:**
   - Message appears in chat
   - Streaming text response renders token-by-token
   - Response completes without error
   - Message persisted to DB

### 3.4 Tool Loop Test

1. In the same session, send: `"Read the README.md file and summarize its contents"`
2. **Verify:**
   - Agent invokes `file_read` tool
   - Tool executes automatically (auto-approved in dev)
   - Tool result feeds back to agent
   - Agent produces summary based on file contents
   - Full loop: user → LLM → tool_use → tool_result → LLM → response

### 3.5 Write Tool Test

1. Send: `"Create a file called /tmp/synapsis-test.txt with the text 'Hello from Synapsis'"`
2. **Verify:**
   - Agent invokes `file_write` tool
   - File created on disk
   - Agent confirms completion

### 3.6 Error Handling

1. Switch to a provider with an invalid API key
2. Send a message
3. **Verify:** Graceful error message, no crash, session remains usable

---

## Phase 4: Remaining Feature Work

### 4.1 MCP Client Integration

**Status:** Module structure exists (`SynapsisPlugin`), but needs live testing with real MCP servers.

**Tasks:**
- [ ] Configure an MCP server in `.opencode.json` `mcpServers` section
- [ ] Verify `Synapsis.MCP.Client` connects via stdio/SSE
- [ ] Verify `tools/list` discovers tools and registers them as `mcp:<server>:<tool>`
- [ ] Verify `tools/call` executes MCP tools through the agent loop

### 4.2 LSP Integration

**Status:** `Synapsis.LSP.Server` and `Synapsis.LSP.Manager` exist but need live testing.

**Tasks:**
- [ ] Start app in a project with TypeScript files
- [ ] Verify `typescript-language-server` auto-starts
- [ ] Verify `Synapsis.Tool.Diagnostics` returns file errors
- [ ] Test with `elixir-ls` in an Elixir project

### 4.3 CLI Completion

**Status:** `synapsis_cli` app exists with argument parsing.

**Tasks:**
- [ ] Build escript: `mix escript.build`
- [ ] Test non-interactive: `./synapsis -p "explain this file"`
- [ ] Test interactive mode
- [ ] Test `synapsis serve` (start server in background)

### 4.4 Context Window Management

**Tasks:**
- [ ] Verify compaction triggers when approaching token limit
- [ ] Verify compacted sessions retain key context
- [ ] Test with long conversations (20+ messages)

### 4.5 Docker Compose

**Tasks:**
- [ ] Create `docker-compose.yml` with PostgreSQL 16
- [ ] Add `Dockerfile` for the Elixir app
- [ ] Test `docker compose up` boots everything

---

## Phase 5: Feature Parity Verification

Check each item against the CLAUDE.md checklist:

| Feature | Status | Verification |
|---------|--------|-------------|
| Multi-provider support | Fixed | Test connection for each provider type |
| Session management | Exists | Create, list, continue, delete, fork via UI |
| Agent modes (build/plan) | Exists | Toggle modes, verify prompt changes |
| Tool system | Fixed | file_read, file_edit, file_write, bash, grep, glob |
| Permission system | Fixed | Auto-approve in dev, require approval in prod |
| Context compaction | Exists | Long conversation triggers compaction |
| LSP integration | Needs testing | Boot with TS/Go/Elixir project |
| MCP support | Needs testing | Configure MCP server, discover tools |
| .opencode.json compat | Exists | Load config, verify agents/providers/mcpServers |
| Web UI | Exists | Chat, tools, sessions, provider selector |
| CLI | Needs testing | Interactive + non-interactive modes |
| Streaming responses | Exists | Token-by-token in web + CLI |
| File diff display | Exists | Show before/after for file edits |
| Image input | Exists | Send image message |
| Error recovery | Partially | Provider disconnect, tool timeout |
| Docker Compose | TODO | Create docker-compose.yml |
| All tests passing | DONE | 889 tests, 0 failures |

---

## Verification Commands

```bash
# Compilation (zero warnings)
mix compile --warnings-as-errors

# Tests (all passing)
mix test

# Format check
mix format --check-formatted

# Boot and verify
mix phx.server
# Then use chrome-devtools MCP to run Phase 3 scenarios
```
