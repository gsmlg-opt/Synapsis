# Synapsis Harness Refactor Plan

> Status: draft · Owner: TBD · Target: `synapsis_core` and adjacent apps

## 1. Goal

Reshape `synapsis_core` into a proper **agent harness**: pure reducer at the
centre, OTP shell around it, behaviours for swappable adapters. The first
runnable milestone is functional parity with OpenCode's web-UI session
module, exposed over a Phoenix API the existing React frontend can consume.

Parity is **functional, not source-level**: same external schema and event
semantics, implemented in OTP-idiomatic Elixir.

## 2. Reference: OpenCode's session module

What we are copying first:

- **Domain triple**: `Session` → `Message` (role-tagged) → `Part`
  (discriminated union)
- **Part variants**: `text`, `reasoning`, `file`, `tool`, `agent`,
  `step_start`, `step_finish`, `snapshot`. Tool parts carry a state
  machine (`pending → running → completed | error`).
- **API surface** (the bits the web UI uses):
  - `POST /session`, `GET /session`, `GET /session/{id}`,
    `PATCH /session/{id}`, `DELETE /session/{id}`
  - `GET /session/{id}/children`, `POST /session/{id}/fork`,
    `POST /session/{id}/abort`
  - `GET /session/{id}/message` — list messages with parts
  - `POST /session/{id}/prompt` — send user message, stream parts back
  - `PATCH/DELETE /session/{id}/message/{mid}/part/{pid}`
- **Event bus**: clients subscribe to part/message lifecycle events for
  live updates
- **Hierarchy**: parent/child sessions via `parent_id`; the `task` tool
  spawns children

## 3. Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│         synapsis_server  (Phoenix: REST + SSE + Channels)       │
└────────────────────────────────┬────────────────────────────────┘
                                 │ PubSub / API calls
┌────────────────────────────────┴────────────────────────────────┐
│                          synapsis_core                          │
│                                                                 │
│   ┌────────────┐      ┌────────────────────────────┐            │
│   │ Public API │─────▶│   Session  (gen_statem)    │            │
│   └────────────┘      │   per-session process      │            │
│                       │           │                │            │
│                       │           ▼                │            │
│   ┌────────────┐      │     ┌──────────┐           │            │
│   │ Behaviours │◀─────┤     │   Loop   │  (pure)   │            │
│   │ Provider   │      │     └──────────┘           │            │
│   │ Tool       │      └────────────────────────────┘            │
│   │ Memory     │                                                │
│   │ Store      │      ┌────────────────────────────┐            │
│   └────────────┘      │   Store (Ecto / Postgres)  │            │
│                       │   event-sourced            │            │
│   ┌────────────┐      └────────────────────────────┘            │
│   │ Adapters   │                                                │
│   │ Anthropic… │                                                │
│   └────────────┘                                                │
└─────────────────────────────────────────────────────────────────┘
```

Dependency direction is outer → inner only. `Session` calls into `Loop`;
both depend on behaviours; concrete adapters live at the edge.

## 4. Principles

1. **Pure functional core, effectful OTP shell.** `Loop.step/2` is a
   reducer; it never opens a socket, hits Postgres, or spawns a process.
2. **Parts are the streaming primitive.** Provider adapters yield
   part-deltas. Tools emit part-deltas. The UI subscribes to part-deltas.
   End-to-end uniform; no second representation.
3. **Event-sourced session state.** `context = Enum.reduce(events, %Context{}, &apply_event/2)`.
   Persistence, replay, debugging, crash recovery all fall out for free.
4. **Schema parity with OpenCode where free.** Same field names for
   `Message.role`, `Part.type`, `tool.state`, etc. Keeps the door open to
   reusing OpenCode's UI components or SDK clients later.
5. **`gen_statem` over `GenServer`.** Session states
   (`idle | generating | awaiting_permission | executing_tools | compacting | aborted`)
   are explicit; invalid transitions are caught at the state-machine
   layer instead of becoming `case`-spaghetti.
6. **Permissions as data, not control flow.** Tools declare an effect
   class; the loop returns `:await_permission` as a `next_action`; the
   shell publishes `PermissionRequested`; the UI prompts; user response
   re-enters the loop.

## 5. Module map (target end-state)

```
Synapsis.Core
├── Message            # struct + Ecto schema
├── Part               # discriminated union (custom Ecto type)
├── Event              # append-only ADT
├── Context            # fold result; pure
├── Permission         # decision record + effect class
│
├── Loop               # PURE reducer: step/2
│
├── Provider           # behaviour
├── Provider.Anthropic # adapter (Req/Finch SSE)
├── Provider.Mock      # for tests
│
├── Tool               # behaviour: spec/0, effect/0, run/2
├── Tool.Read | Write | Edit | Glob | Grep | Bash
├── ToolRegistry
│
├── Memory             # behaviour: compact/1
├── Store              # behaviour + Ecto impl
│
├── Session            # gen_statem
├── SessionSupervisor  # DynamicSupervisor
├── SessionRegistry    # Registry
│
└── Telemetry
```

PubSub topics: `session:{id}:events` (durable), `session:{id}:stream`
(transient part-deltas for UI).

## 6. Phased plan

Each phase ends with a green CI run, a runnable demo, and a doc update.

### Phase 0 — Audit & quarantine (1–2 days)

- Tag every existing module in `synapsis_core` as `keep | port | drop`.
- Lock the public API surface to the OpenCode endpoint set above. This
  is the contract every later phase negotiates against.
- Sketch Postgres schema: `sessions`, `messages`, `parts`, `events`.

**Deliverable:** this doc merged; schema ADR; module-disposition table.

### Phase 1 — Data model (2–3 days)

- `Message` struct + Ecto schema (`role`, `session_id`, timestamps).
- `Part` as polymorphic embed or tagged-union custom Ecto type. All
  variants from OpenCode. Spike this early — Ecto polymorphism is
  fiddly.
- `Event` ADT: `SessionCreated`, `MessageAppended`, `PartAppended`,
  `PartUpdated`, `ToolInvoked`, `ToolReturned`, `PermissionRequested`,
  `PermissionGranted`, `Aborted`, `Compacted`.
- `Context` and the pure `apply_event/2` fold.

**Deliverable:** structs, migrations, property tests on the fold.

### Phase 2 — Loop reducer (3–4 days)

```
Loop.step(context, provider_event) ::
  {next_action, context, [effect]}

next_action ::=
  :await_user
  | :await_permission
  | {:call_tools, [tool_call]}
  | {:respond_done}
  | {:halt, reason}

effect ::=
  {:emit_part, part}
  | {:persist_event, event}
  | {:request_permission, tool_call}
```

100% testable without processes, providers, or disk. Drive it with
recorded provider streams as fixtures.

**Deliverable:** `Loop` + exhaustive test suite. No IO. No processes.

### Phase 3 — Provider behaviour + Anthropic adapter (2–3 days)

```
@callback stream(Context.t(), keyword()) :: Enumerable.t(provider_event)

provider_event ::=
  {:text_delta, str}
  | {:reasoning_delta, str}
  | {:tool_call_start, tc}
  | {:tool_call_delta, tc}
  | {:tool_call_end, tc}
  | {:done, stop_reason}
```

These map 1:1 to part-deltas — the harness's streaming uniformity falls
out of this design choice.

- `Provider.Anthropic` over Req/Finch SSE.
- `Provider.Mock` replaying recorded fixtures.

**Deliverable:** real streaming completion against Anthropic, fixture
replay for tests.

### Phase 4 — Session process + supervision (2–3 days)

- `Session` as `gen_statem` consuming provider events, calling
  `Loop.step/2`, interpreting effects (publish to PubSub, request
  permission, run tools).
- `SessionSupervisor` + `SessionRegistry` (`:via` tuples).
- Events still in memory at this point.

**Deliverable:** `iex` demo: `start_session → send_prompt → stream parts`
end-to-end.

### Phase 5 — Persistence (event-sourced) (2 days)

- `Store` Ecto impl: `append/2`, `load/1`, `snapshot/2`.
- Session start: load events → fold to context → enter gen_statem.
- Session crash: supervisor restart → identical recovery.

**Deliverable:** sessions survive BEAM restart; conversations resume.

### Phase 6 — HTTP API + event stream (2–3 days) — **OpenCode parity slice lands here**

In `synapsis_server`:

- REST: `POST /session`, `GET /session`, `GET /session/{id}`,
  `PATCH /session/{id}`, `DELETE /session/{id}`,
  `GET /session/{id}/message`.
- Streaming: `POST /session/{id}/prompt` returns SSE of part-deltas.
- Phoenix.Channel exposing the same event stream over WS for the React
  UI.
- `POST /session/{id}/abort` sends `:abort` to gen_statem.
- OpenAPI spec generated; matches OpenCode's schema for shared fields.

**Deliverable:** browser opens, user sends prompt, sees streaming
assistant text. **This is the v1 parity demo.**

### Phase 7 — Minimal tool set + permissions (3–4 days)

- `Tool` behaviour finalised.
- Built-ins: `read`, `write`, `edit` (search-replace patches), `glob`,
  `grep`, `bash` (Port sandbox).
- ToolRegistry. Loop emits `:request_permission` for `:write | :exec`
  effects; UI prompts; user response advances the state machine.

**Deliverable:** model can drive a real coding session through the React
UI with permission prompts.

### Phase 8 — Sub-sessions, fork, task tool (2 days)

- `parent_id` on sessions; cascade delete.
- `POST /session/{id}/fork`: copy events up to a cut point, new session
  id.
- `task` tool spawns a child session under the same `SessionSupervisor`;
  parent awaits child completion as a tool result.

### Phase 9 — Compaction + budgets (1–2 days)

- `Memory.compact/1`: replace verbose tool results with file refs;
  summarise oldest turns. For a coding agent, prefer **file refs over
  content** since content is reproducible from disk.
- Budget enforcement (tokens, depth, wall-clock, tool-call count) in
  `Loop`.

### Out of scope for v1 parity

MCP server connections (`synapsis_lsp`-adjacent work), LSP-as-tools,
multi-agent coordination beyond the `task` pattern, public sharing
(OpenCode's Durable Object equivalent). Each becomes a follow-up; the
harness shape supports them without further refactor.

## 7. Sequencing & dependencies

- Phases 1 → 2 are blocking for everything else. Take them seriously —
  test the union types and the fold exhaustively. Cutting corners here
  costs 10× later.
- Phase 3 and 4 can overlap once the `Loop` signature is stable.
- Phase 6 is the visible-progress moment — UI lights up.
- Phase 7 is when it stops being a chat and starts being a coding agent.

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Ecto polymorphism for `Part` is fiddly | Spike day 1 of Phase 1; fall back to JSON column + custom type if `polymorphic_embed` is too restrictive |
| Streaming backpressure on slow WS clients | Per-channel buffer with drop-or-coalesce policy in Phase 6; coalesce text-delta runs |
| gen_statem callbacks accumulating logic | Hard rule: callbacks marshal events to `Loop.step/2` and interpret effects, nothing else |
| Schema drift from OpenCode breaking UI reuse | Generate OpenAPI; contract test against OpenCode's published schema for shared fields |
| Provider event shape varies across vendors | Normalise at adapter boundary into our internal `provider_event` ADT; Loop never sees vendor specifics |

## 9. Definition of done — v1 parity

A user opens the React UI, creates a session, sends:

> "list files in this repo and summarise the largest one"

…and sees, in order: streamed assistant text → a `tool` part for `glob`
→ a `tool` part for `read` with a permission prompt → user grants → read
completes → more streamed text. Reload page: conversation intact.
Restart BEAM: conversation still intact.

That's Phase 7 done. Everything past that is incremental.
