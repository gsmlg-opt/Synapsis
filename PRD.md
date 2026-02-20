# PRD: Agent Orchestration & Loop Prevention — Feasibility Audit

## Objective

Audit the current Synapsis codebase through **static analysis AND live integration testing**. Boot the app, verify subsystems work (providers, MCP, LSP, sessions), run a real coding task end-to-end, then produce a gap analysis determining whether the Agent Orchestration & Loop Prevention design can be implemented.

**Deliverables:**
- `docs/architecture/ORCHESTRATION_AUDIT.md` — structured findings with file references
- `docs/architecture/INTEGRATION_TEST_RESULTS.md` — live test results from running the app

## Background

The proposed design introduces:

- **Orchestrator** — pure Elixir GenServer as rules engine (pattern-matched `handle_info` clauses), no ML. Decides continue/pause/escalate/terminate.
- **Monitor** — deterministic loop detection. Tool call hashing via `MapSet`, test regression tracking, stagnation counters.
- **Failure Log** — rolling negative constraints (max 5–7) injected into LLM system prompt. Each entry: description + result + lesson. Survives context window compression.
- **WorkspaceManager** — granular git patch tracking. Atomic revert-and-learn: reverting code simultaneously records the failure reason. Uses `git worktree` per session.
- **Dual-Model (Auditor-Worker)** — cheap fast model for code gen (high volume), expensive reasoning model for failure synthesis (2–3 calls per session on escalation triggers). API keys for all providers are stored in `.secrets.toml` at the project root.
- **Scratch Worktrees** — patches tested in isolation before touching main tree.

Target location: `apps/synapsis_core/lib/synapsis_core/sessions/` with modules `orchestrator.ex`, `monitor.ex`, `workspace_manager.ex`, `agent_loop.ex`, `auditor_task.ex`, `prompt_builder.ex`, `state.ex`, `token_budget.ex`, `patch.ex`.

## Approach

This audit has two phases:

1. **Static analysis (steps 1–8):** Read the codebase, map modules, identify gaps.
2. **Live integration testing (steps 9–13):** Boot the app, use **chrome-devtools MCP** to drive the web UI, test each subsystem, run a real coding session, and intentionally try to trigger the regression loop.

The integration tests provide ground truth that static analysis cannot — does the system prompt have room for injection? Can two models run in the same session? What does the tool call data look like for hashing?

## Steps

### Step 1: Read Project Structure

Map the current umbrella layout. Identify all apps, their dependencies, and supervision trees.

```bash
ls apps/
find . -name "mix.exs" -maxdepth 3 | sort
for app in apps/*/; do echo "=== $app ===" && head -30 "${app}mix.exs"; done
```

Record: which apps exist, dependency direction between them, any existing `Application.start` children.

### Step 2: Locate Existing Session Management

Find everything related to sessions, agent loops, and conversation state.

```bash
grep -r "Session\|session" apps/synapsis_core/lib/ --include="*.ex" -l
grep -r "GenServer\|use GenServer" apps/synapsis_core/lib/ --include="*.ex" -l
grep -r "Supervisor\|DynamicSupervisor" apps/synapsis_core/lib/ --include="*.ex" -l
grep -r "agent\|loop\|iterate\|step\|orchestrat" apps/synapsis_core/lib/ --include="*.ex" -l
```

For each file found, read it fully. Document:
- Current session lifecycle (how sessions start, run, stop)
- What state a session holds (GenServer state struct, ETS, DB)
- Whether there's an existing agent loop / LLM call cycle
- Any existing loop detection, failure memory, or retry logic

### Step 3: Check Tool System

The design depends on hashing tool calls. Find the current tool implementation.

```bash
grep -r "Tool\|tool_use\|tool_call\|function_call" apps/ --include="*.ex" -l
grep -r "execute\|side_effect\|file_edit\|file_write\|bash_exec" apps/synapsis_core/lib/ --include="*.ex" -l
find apps/ -path "*/tools/*" -name "*.ex"
```

Document:
- How tools are defined (behaviour? module? registry?)
- How tool calls are dispatched and results returned
- Whether tool call arguments are accessible for hashing
- Existing side effect declarations (`:file_changed` etc.)

### Step 4: Check Provider / LLM Layer

The design needs: system prompt injection, multi-model support, streaming. API provider keys are stored in `.secrets.toml` at the project root (not in the database).

```bash
grep -r "system_prompt\|system_message\|messages\|prompt" apps/synapsis_provider/lib/ --include="*.ex" -l 2>/dev/null
grep -r "system_prompt\|system_message\|messages\|prompt" apps/req_llm/lib/ --include="*.ex" -l 2>/dev/null
grep -r "stream\|Stream\|chunk\|SSE" apps/synapsis_provider/lib/ --include="*.ex" -l 2>/dev/null
grep -r "secrets\|toml\|api_key\|TOML\|Toml" apps/ --include="*.ex" -l
cat .secrets.toml 2>/dev/null || echo "File not found"
```

Document:
- How the system prompt is assembled (is there a builder module?)
- Can we inject a `## Failed Approaches` block into the system prompt per-turn?
- Does the provider layer support calling different models in the same session? (Needed for Worker + Auditor dual-model pattern — each may use a different provider/key from `.secrets.toml`)
- How streaming events reach the session process
- How `.secrets.toml` is loaded and which providers are configured
- Whether the current config structure supports selecting different provider/model pairs per role (Worker vs Auditor)

### Step 5: Check Git / Workspace Operations

The design uses `git worktree`, `git apply`, and patch tracking.

```bash
grep -r "git\|Git\|System.cmd.*git\|worktree\|patch\|diff" apps/ --include="*.ex" -l
grep -r "File.write\|File.read\|Path.join" apps/synapsis_core/lib/ --include="*.ex" -l | head -20
```

Document:
- Any existing git integration
- How file edits are currently applied (direct write? transactional?)
- Whether there's any concept of rollback or undo

### Step 6: Check PubSub / Channel Integration

The Orchestrator broadcasts status events. Check what exists.

```bash
grep -r "PubSub\|broadcast\|subscribe\|Phoenix.PubSub" apps/ --include="*.ex" -l
grep -r "Channel\|channel\|SessionChannel" apps/synapsis_server/lib/ --include="*.ex" -l
grep -r "topic\|\"session:" apps/ --include="*.ex"
```

Document:
- Current PubSub topic structure
- What events are currently broadcast
- Whether `SessionChannel` exists and what it handles
- Gap between current events and proposed events (`:auditing`, `:paused`, `:constraint_added`, `:budget_update`)

### Step 7: Check Schema / Data Layer

The design adds `FailedAttempt` and `Patch` structs. Check what's in `synapsis_data`.

```bash
find apps/synapsis_data/lib/ -name "*.ex" | sort
grep -r "schema\|embedded_schema\|defstruct" apps/synapsis_data/lib/ --include="*.ex" -l
```

Document:
- Existing session schema fields
- Whether there's a messages table and its structure
- Any existing failure/error tracking schemas
- Where `FailedAttempt` and `Patch` structs should live (embedded schemas in core? data layer?)

### Step 8: Check Test Infrastructure

```bash
find apps/synapsis_core/test/ -name "*.exs" | sort 2>/dev/null
grep -r "Bypass\|Mock\|mock\|bypass" apps/ --include="*.exs" -l
```

Document:
- Existing test patterns and helpers
- Whether there's infrastructure for testing GenServer message flows without LLM calls

### Step 9: Boot & Compile Check

Start the application and verify it compiles and runs.

```bash
mix deps.get
mix compile --warnings-as-errors
mix ecto.setup  # or mix ecto.create && mix ecto.migrate
```

If JS assets are needed:
```bash
cd apps/synapsis_web && bun install && cd ../..
```

Start the server:
```bash
mix phx.server
# or: iex -S mix phx.server
```

Document:
- Compile errors or warnings
- Missing dependencies
- Database setup issues
- The URL and port the app starts on

### Step 10: Test Provider Configuration

Verify providers can be configured and connected. Use chrome-devtools MCP to interact with the running web UI.

1. Open the app in browser via chrome-devtools
2. Navigate to provider settings (likely `/settings/providers`)
3. Verify `.secrets.toml` keys are loaded — check if providers appear pre-configured or need manual setup
4. If there's a "Test Connection" button, use it for each configured provider
5. Verify at least one provider can list available models

```bash
# Also test from the API if it exists
curl -s http://localhost:4000/api/providers 2>/dev/null | head -50
```

Document:
- Which providers are configured and reachable
- Whether the UI for provider management works
- Any connection errors
- Whether the provider layer can handle multiple providers simultaneously (needed for Worker + Auditor)

### Step 11: Test MCP & LSP Integration

Verify plugin subsystems are functional.

**MCP:**
1. Navigate to MCP settings via chrome-devtools (likely `/settings/mcp`)
2. Check if any MCP servers are configured
3. If configured, test connect/disconnect
4. Verify discovered tools appear in the UI

**LSP:**
1. Navigate to LSP settings (likely `/settings/lsp`)
2. Check if any language servers are configured
3. Verify status indicators show correct state

```bash
# Check if MCP/LSP processes are running
# From iex:
# Process.list() |> Enum.filter(fn pid -> match?({:registered_name, name} when is_atom(name), Process.info(pid, :registered_name)) end)
```

Document:
- MCP server configuration status and connectivity
- LSP server status
- Any errors in the plugin supervision tree
- Whether tools from MCP/LSP appear in the tool registry

### Step 12: Test Session Lifecycle — Real Coding Task

This is the critical test. Create a project, start a session, and have the agent perform a simple task. Use chrome-devtools MCP to drive the entire flow through the web UI.

**Setup:**
1. Create or select a test project directory with a `README.md`
2. Navigate to the app via chrome-devtools
3. Create a new project pointing to the test directory

**Execute a real task:**
1. Create a new session within the project
2. Select a provider and model
3. Send a simple message: `"Read the README.md and add a 'Getting Started' section with basic setup instructions"`
4. Observe:
   - Does the message appear in the chat UI?
   - Does the LLM respond with streaming text?
   - Does the agent invoke tools (file_read, file_write/file_edit)?
   - Do tool approval cards appear if permissions require it?
   - Does the final file edit get applied?
5. Verify the README.md was actually modified on disk

**Test session controls:**
1. Try sending a follow-up message
2. Try cancelling a response mid-stream (if supported)
3. Navigate away and back — does the session restore?

Document:
- Full timeline of what happened (message sent → tools invoked → result)
- Which tools were called and their arguments (this is what the Monitor would hash)
- How the system prompt was assembled (check if there's an injection point for failure log)
- Streaming behavior — latency, chunk rendering
- Any errors or unexpected behavior
- Screenshot or description of the UI at each stage

### Step 13: Stress Test — Identify Loop Behavior

If step 12 succeeded, attempt to trigger the regression loop problem intentionally.

1. Start a new session on the same project
2. Send a message that requires a code change: `"Add a function called hello/1 to lib/example.ex that returns a greeting. Make sure it compiles."`
3. If the agent succeeds, send: `"Actually, change hello/1 to accept a keyword list instead of a single argument, and update any callers"`
4. Observe whether the agent:
   - Retries the same edit if compilation fails
   - Rolls back changes (git checkout or similar)
   - Shows any sign of loop detection or failure memory
   - Gets stuck repeating the same approach

Document:
- How many iterations the agent took
- Whether any form of loop detection exists
- Whether rollbacks are amnesiac (loses the lesson) or tracked
- The exact gap this reveals — this is the evidence for why the Orchestrator design is needed

### Step 14: Write Audit Report

Create `docs/architecture/ORCHESTRATION_AUDIT.md` with these sections:

```markdown
# Agent Orchestration Design — Feasibility Audit

## 1. Structural Fit
[Can the proposed modules live under synapsis_core/sessions/?]
[Supervision tree conflicts?]

## 2. Existing Agent Loop
[Current implementation description]
[What exists vs what needs building]

## 3. Tool System Compatibility
[Can tool calls be hashed?]
[Is the tool registry accessible?]

## 4. Provider Integration
[System prompt injection point?]
[Multi-model support?]
[.secrets.toml loading mechanism?]

## 5. Git / Workspace
[Current state vs design requirements]

## 6. PubSub / Channels
[Current events vs proposed events]
[Breaking changes?]

## 7. Data Layer
[Where new structs go]
[Schema migrations needed?]

## 8. Test Infrastructure
[Existing patterns applicable?]

## 9. Recommendation
One of:
- **Ready to implement** — minimal changes needed, list them
- **Feasible with modifications** — list specific prerequisite changes
- **Needs redesign** — identify fundamental conflicts

## Appendix: Files Examined
[Full list of files read during audit]
```

Create `docs/architecture/INTEGRATION_TEST_RESULTS.md` with these sections:

```markdown
# Integration Test Results

## Environment
[Elixir/OTP version, OS, database, Node/Bun version]

## 1. Boot & Compile
[Compile result, warnings, startup log]

## 2. Provider Tests
[Which providers configured, connection test results, model listing]

## 3. MCP & LSP Tests
[MCP servers status, LSP servers status, discovered tools]

## 4. Session Lifecycle — Real Task
[Full timeline: message → tools → result]
[Tool calls observed (names + arguments — these are what Monitor would hash)]
[System prompt structure observed (injection point for failure log?)]
[Streaming behavior notes]

## 5. Loop Behavior Test
[Did the agent loop? How many iterations?]
[Rollback behavior (amnesiac or tracked?)]
[Evidence of existing loop detection: YES/NO]
[Gap analysis: what the Orchestrator would have done differently]

## 6. Blockers Found
[Anything that prevents the orchestration design from working]

## 7. Subsystem Readiness Matrix

| Subsystem | Status | Notes |
|---|---|---|
| Provider (Worker model) | ✅/⚠️/❌ | ... |
| Provider (Auditor model) | ✅/⚠️/❌ | ... |
| Tool Registry | ✅/⚠️/❌ | ... |
| Tool Call Hashing (feasible?) | ✅/⚠️/❌ | ... |
| System Prompt Injection | ✅/⚠️/❌ | ... |
| PubSub Events | ✅/⚠️/❌ | ... |
| Channel Streaming | ✅/⚠️/❌ | ... |
| Git Operations | ✅/⚠️/❌ | ... |
| Session Persistence | ✅/⚠️/❌ | ... |
| MCP Plugin | ✅/⚠️/❌ | ... |
| LSP Plugin | ✅/⚠️/❌ | ... |
```

## Constraints

- **Static analysis is read-only** — do NOT modify any source files during steps 1–8.
- **Integration tests may create test data** — steps 9–13 will create projects, sessions, and file edits. Use a dedicated test directory (e.g., `/tmp/synapsis-audit-test/`). Clean up after.
- **Do NOT read `.secrets.toml` values** — check its structure and how it's loaded, but do NOT output any API keys or secrets in the report.
- **Use chrome-devtools MCP for UI testing** — interact with the running app through the browser, not by calling internal functions directly. This tests the real user path.
- **Reference specific files** — every static analysis finding must cite the file path and relevant line numbers.
- **Do NOT guess** — if a module doesn't exist, say so explicitly. Don't assume based on naming conventions.
- **Do NOT skip apps** — check all umbrella apps, even if they seem unrelated. Cross-cutting concerns hide in unexpected places.
- **Read fully before concluding** — don't stop at `grep` output. Open and read each relevant file to understand the actual implementation, not just the file name.
- **If the app doesn't boot, document why and skip to the audit report** — the static analysis is still valuable. Note the boot failure as a blocker.

## Verification

```bash
# Confirm both reports were created
test -f docs/architecture/ORCHESTRATION_AUDIT.md && echo "PASS: audit" || echo "FAIL: audit"
test -f docs/architecture/INTEGRATION_TEST_RESULTS.md && echo "PASS: integration" || echo "FAIL: integration"

# Confirm no source files were modified (docs/ changes are expected)
git diff --name-only | grep -v "docs/" && echo "FAIL: source files modified" || echo "PASS: read-only"

# Clean up test data
rm -rf /tmp/synapsis-audit-test/
```
