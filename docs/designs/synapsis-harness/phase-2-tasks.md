# Phase 2 — Loop Reducer: Task Breakdown

> Phase goal: implement `Synapsis.Core.Loop.step/2` — the pure reducer
> that drives the agent. Every interesting decision the harness makes
> happens here. The Session gen_statem in Phase 4 is a thin shell that
> turns I/O into inputs to this function and effects from this function
> into I/O.
>
> Realistic effort: **5–7 working days** for one engineer (revising the
> plan's 3–4 days; the input/output protocol design and the step-boundary
> handling each absorb a day if done honestly).

## Scope

In:
- `Synapsis.Core.Loop` — the reducer
- `Synapsis.Core.Loop.Input` — sum type for everything that drives a transition
- `Synapsis.Core.Loop.NextAction` — what the agent is waiting for after the transition
- `Synapsis.Core.Loop.Effect` — non-event side-effect descriptions
- `Synapsis.Core.Loop.Broadcast` — ephemeral live-stream signals
- `Synapsis.Core.ProviderEvent` — normalized provider-event ADT
- Pure helpers for "what's in flight", "what does the next provider call look like"

Out:
- `Provider` adapter implementations (Phase 3)
- `Session` gen_statem (Phase 4)
- Real tool execution (Phase 7) — but the loop must speak the protocol
- Persistence (Phase 5) — events are produced, not yet stored

## Mental model

```
                  ┌──────────────────────────────────┐
                  │           Session shell          │
                  │  (gen_statem, Phase 4)           │
                  │                                  │
   I/O events ────┤   normalize → Loop.Input         │
   (provider,     │                  │               │
    tool results, │                  ▼               │
    user input,   │           Loop.step/2  (PURE)    │
    permissions)  │            │       │             │
                  │            ▼       ▼             │
                  │         events   effects         │
                  │            │       │             │
                  │            ▼       ▼             │
                  │        persist   start I/O       │
                  │        broadcast                 │
                  └──────────────────────────────────┘
```

`Loop.step/2` does not know what a process is. It does not know what
JSON is. It does not know what HTTP is. It transforms `(Context,
Input)` into `(Context, NextAction, [Event], [Effect], [Broadcast])`.
That is the entire surface.

## Work streams

```
A. Protocol ADTs ──────┐
                       ├──▶ B. Reducer skeleton ──▶ C. Reducer cases
F. ADRs (parallel)─────┤                                   │
                       │                                   ▼
D. Provider-event ADT ─┘                            E. Test harness
                                                          │
                                                          ▼
                                                     phase exit
```

A and D unblock B. B unblocks C. E runs alongside C. F captures the
decisions that surface during A–D so they don't get lost in code
review.

---

## Stream A — Protocol ADTs

This is the load-bearing design work. Get it right and the reducer
writes itself; get it wrong and every later phase pays.

### A1. `Loop.Input` sum type · **M** · **blocking**

**Goal:** enumerate every input that can drive a transition.

**Variants:**
- `UserPrompt` — `{message_id, parts}` — new user message
- `UserAbort` — abort the active turn
- `ProviderEvent` — wraps a `ProviderEvent.t()` (normalized provider stream chunk)
- `ProviderError` — `{reason}` — provider stream failed
- `ToolStarted` — `{part_id}` — shell confirms tool is now running
- `ToolCompleted` — `{part_id, result}`
- `ToolFailed` — `{part_id, error}`
- `PermissionGranted` — `{request_id, scope}` — user said yes
- `PermissionDenied` — `{request_id}` — user said no
- `BudgetTick` — `{wall_clock_now}` — clock pulse so the reducer can enforce wall-clock budgets without owning a clock

**Decisions:**
- Inputs are structs in `Synapsis.Core.Loop.Input.*`
- Every input carries the minimum data the reducer needs — no
  back-references to processes or pids
- `BudgetTick` is the only "ambient" input; everything else is
  causally tied to a real event in the world. Document why this is
  necessary (it lets the reducer expire a stuck provider stream
  without owning a timer).

**Acceptance:** all variants defined with typespecs; doc string per
variant explaining when the shell should produce it.

---

### A2. `Loop.NextAction` sum type · **S**

**Goal:** describe what the agent is waiting for after a transition.

**Variants:**
- `:await_user` — turn is over, ready for next prompt
- `:await_provider` — provider stream is open, more events coming
- `:await_tools` — one or more tools are executing
- `:await_permission` — blocked on user decision
- `:await_step_decision` — provider step finished; reducer is deciding whether to start another step (transient; usually advances within the same `step/2` call, exposed for tests)
- `{:halt, reason}` — terminal: `:completed | :aborted | :budget_exhausted | {:error, term}`

**Decisions:**
- `NextAction` is what the gen_statem in Phase 4 maps to a state. Pick
  names that match the gen_statem states exactly (do not invent
  parallel vocabularies).
- Multiple awaits are not a thing. If the agent is waiting on tools
  *and* permission, that's `:await_permission` (permission gates
  tools).

**Acceptance:** documented as the canonical state names; Phase 4 uses
the same atoms.

---

### A3. `Loop.Effect` sum type · **M**

**Goal:** describe non-event side effects the shell must perform.

**Variants:**
- `StartProviderStream` — `{request}` — open a stream against the chosen provider with the prepared request
- `CancelProviderStream` — when aborting mid-stream
- `StartTool` — `{part_id, tool_name, args}` — execute a tool
- `CancelTool` — `{part_id}`
- `RequestPermission` — `{request_id, tool_call, effect_class}` — surface to user

**Decisions:**
- Effects are imperative, ordered. The shell processes them in
  sequence (see A5 for ordering rules).
- An effect carries enough data to execute without consulting the
  context. The shell should not have to read context state to
  interpret an effect.
- Effects are *not* events. Events go to the durable log; effects go
  to the shell's I/O dispatcher.

**Acceptance:** all variants defined; doc string per variant
describing the shell's obligation when it sees one.

---

### A4. `Loop.Broadcast` sum type · **S**

**Goal:** describe ephemeral live-stream signals — the things that get
pushed to UI subscribers but are not persisted.

**Variants:**
- `TextDelta` — `{part_id, fragment}`
- `ReasoningDelta` — `{part_id, fragment}`
- `ToolArgsDelta` — `{part_id, fragment}` — streaming JSON tool args
- `StatusChanged` — `{status}` — generating, idle, etc.

**Decisions:**
- Broadcasts are not durable. A reconnecting client catches up via
  the projection (Phase 1 ADR 0001), which only carries committed
  parts.
- This split is what makes streaming cheap: 50 deltas/sec broadcast
  is fine; 50 events/sec persisted is not.
- Calls out an ADR — see F1.

**Acceptance:** variants defined; doc string explaining
broadcast-vs-event semantics.

---

### A5. Return-tuple shape & ordering rules · **S**

**Goal:** lock down the function signature.

```elixir
@spec step(Context.t(), Input.t()) ::
        {:ok, %{
           context:    Context.t(),
           next:       NextAction.t(),
           events:     [Event.t()],
           effects:    [Effect.t()],
           broadcasts: [Broadcast.t()]
         }}
        | {:error, reason}
```

**Decisions:**
- A map, not a tuple. Five fields is over the threshold where
  positional tuples become unreadable.
- `{:error, _}` means the *input itself* was invalid for the current
  state (e.g., `ToolCompleted` for a part that doesn't exist). It is
  a programmer-error signal, not a user-facing one. The shell logs
  and crashes.
- Ordering convention: shell processes `events` first (persist),
  `effects` next (start I/O), `broadcasts` last (best-effort). This
  is the order that survives a crash mid-processing without losing
  durable state.
- The new `context` is pre-computed for callers that want it. It must
  equal `Enum.reduce(events, old_context, &apply_event/2)`. This is a
  property test (E3).

**Acceptance:** ADR 0005 (interaction protocol) drafted; signature
locked.

---

## Stream B — Reducer skeleton

### B1. Module layout & dispatch · **S**

**Goal:** structural skeleton for `Loop`.

**Decisions:**
- Single `step/2` entry point. Pattern-matches on input variant and
  dispatches to per-input private functions.
- Per-input handlers return the same map shape A5 defined.
- A small builder module — `Loop.Builder` — accumulates events,
  effects, broadcasts during a transition, then materializes the
  final return map. Avoids passing 5-tuple accumulators through every
  helper.
- No private state. No process dictionary. No `Application.get_env`.
  If a handler needs configuration, it comes through `context`.

**Acceptance:** skeleton compiles; all input variants have a stub
handler that returns `{:error, :unimplemented}`; dispatch is
exhaustive (Dialyzer happy).

---

### B2. `Context` extensions for in-flight state · **M**

**Goal:** the loop needs to track what's currently happening, not just
the historical record.

**Add to `Context` (from Phase 1):**
- `current_step` — `nil | %Step{id, parts_in_progress, model_id, started_at}`
- `pending_tools` — map of `part_id → %ToolInFlight{state: :awaiting_permission | :running}`
- `pending_permission` — `nil | %PermissionRequest{request_id, tool_call_ref}`
- `accumulating_parts` — map of `part_id → partial part` for streaming text/reasoning/tool-args

**Decisions:**
- `accumulating_parts` is the only place "incomplete" parts live. They
  get committed to `messages → message → parts` only on completion.
  This directly implements the broadcast/event split from A4.
- All these fields update through `apply_event/2` like everything
  else. Stream-delta inputs produce no events but mutate
  `accumulating_parts` via dedicated pure helpers (B3 will use these).
- Property test obligation: at any `:await_user` transition, all four
  fields are empty/cleared. Loop never leaks in-flight state across
  turn boundaries.

**Acceptance:** struct fields defined with typespecs; helper functions
to manipulate `accumulating_parts` (`start_part/3`, `append_delta/3`,
`finalize_part/2`); unit tests on each helper.

---

### B3. Provider-event handlers · **L**

**Goal:** handle every variant of `ProviderEvent` (defined in Stream D).

**Cases to implement:**
- `:step_start` — record a new step in `current_step`; emit
  `StepStarted` event; broadcast `StatusChanged{generating}`.
- `:text_delta` — append to `accumulating_parts[part_id]`; broadcast
  `TextDelta`; no event.
- `:reasoning_delta` — same shape, different part type.
- `:tool_call_start` — record a tool part in `accumulating_parts`;
  broadcast `ToolArgsDelta` (empty); emit `PartAppended` with state
  `:pending`.
- `:tool_call_args_delta` — append to args buffer; broadcast.
- `:tool_call_complete` — finalize the tool part; if its `effect_class`
  requires permission and isn't pre-granted, emit
  `PermissionRequested` event + `RequestPermission` effect, set
  `pending_permission`, return `:await_permission`. Otherwise emit
  `StartTool` effect, return `:await_tools`. (For multiple parallel
  tool calls, batch the effects.)
- `:step_finish` — finalize text/reasoning parts; emit `StepFinished`
  event; if step ended with `stop_reason: :tool_use`, transition
  governed by tool/permission logic above; if `stop_reason: :end_turn`,
  return `:await_user`.
- `:provider_error` — emit `Aborted` event with reason; return
  `{:halt, {:error, reason}}`.

**Decisions:**
- This is the meat. Take it slowly; one variant per commit; each
  variant gets a scenario test in E2.
- Permission logic lives here, not in a separate module. The reducer
  already has all the context.
- Pre-granted permissions: a `Context.permissions` set carries
  scopes already approved this session. The check is a pure
  set-membership test.

**Acceptance:** every provider event variant has a handler; every
handler has at least one scenario test green; permission flow tested
both with pre-grant and without.

---

### B4. Tool-result & permission handlers · **M**

**Goal:** drive the loop forward when external events arrive.

**Cases:**
- `ToolStarted` — update `pending_tools[part_id].state = :running`;
  emit `PartUpdated` event with new state; broadcast.
- `ToolCompleted` — finalize tool part with result; emit `PartUpdated`
  + `ToolReturned` event; check if all pending tools are done; if so,
  start next provider step (`StartProviderStream` effect); else stay
  `:await_tools`.
- `ToolFailed` — same as completed but with error state.
- `PermissionGranted` — add scope to `Context.permissions`; emit
  `PermissionGranted` event; for each waiting tool covered by the new
  scope, emit `StartTool`.
- `PermissionDenied` — emit `PermissionDenied` event; cancel the
  affected tool part with state `:error, reason: :denied`; treat as
  if the model received a "permission denied" tool result; start next
  provider step.

**Decisions:**
- Permission scopes are coarse-grained intentionally. Examples:
  `{:fs_write, "/path/prefix"}`, `{:exec, :any}`. Fine-grained
  scoping is a Phase 7 conversation; the loop just needs the
  set-membership API.
- `PermissionDenied` re-enters the model's loop with a structured
  tool result; it does *not* halt the agent. The agent decides what
  to do without that capability.

**Acceptance:** scenario tests covering: tool succeeds, tool fails,
permission granted, permission denied, parallel tools all complete,
parallel tools partial completion.

---

### B5. User-input handler · **M**

**Goal:** handle `UserPrompt`.

**Cases:**
- `Context.status == :idle` — normal new turn. Emit `MessageAppended`
  + `PartAppended` events for each user part; build provider request;
  emit `StartProviderStream` effect; return `:await_provider`.
- `Context.status == :generating` — this is a *mid-turn* user input.
  Two sub-cases: queue (default) vs. interrupt (if input includes an
  abort flag). Document both; start with queue-only and explicitly
  reject interrupt-style for v1 with a clear error. Note in the ADR
  it's a Phase-7+ extension.
- `Context.status in [:aborted, :completed]` — `{:error, :inactive_session}`.

**Acceptance:** all three cases tested; queueing behavior locked
behind a separate config flag (default off in v1, just to make the
shape obvious for later).

---

### B6. Abort, budget, and halt logic · **M**

**Goal:** the reducer must terminate gracefully under every failure
mode.

**Cases:**
- `UserAbort` — emit `Aborted` event; emit `CancelProviderStream`
  effect; emit `CancelTool` for every in-flight tool; return
  `{:halt, :aborted}`.
- `BudgetTick` — re-evaluate budgets against `Context.budgets`. If
  exceeded, identical effect chain to `UserAbort` but with reason
  `:budget_exhausted`.
- Any handler may early-return `{:halt, reason}` if it detects an
  invariant violation.

**Decisions:**
- The reducer never silently truncates. Budget enforcement halts
  loudly; the shell decides whether to start a new turn or surface
  the halt to the user.
- Wall-clock budgets are checked only on `BudgetTick`. The reducer
  does not call `:erlang.system_time/0` — it's pure.

**Acceptance:** abort tested against every `Context.status`; budget
tested against each budget dimension (tokens, tool calls, depth, wall
clock).

---

### B7. Provider-input view · **S**

**Goal:** the pure function that renders `Context` into a provider
request.

```elixir
@spec next_provider_input(Context.t()) :: ProviderRequest.t()
```

**Decisions:**
- Lives in `Loop` but is not part of `step/2`. It is called by
  `step/2` when emitting `StartProviderStream`, and by tests.
- Includes: system prompt, message history, available tools (filtered
  by current permissions and budgets), generation config.
- Compaction (`Memory.compact/1`, Phase 9) hooks here later. For now
  it's identity.

**Acceptance:** function exists; tested against a realistic context
including reasoning parts, tool parts, file refs.

---

## Stream C — Reducer cases (covered by B3-B6)

This stream is the implementation work for the handlers; it has no
separate tasks because it tracks B3–B6 commit by commit. Tracked here
as a placeholder so the project board reflects it.

---

## Stream D — Provider-event ADT

### D1. Normalized `ProviderEvent` ADT · **M** · **blocking for B3**

**Goal:** define the *internal* event vocabulary every adapter
produces. Vendors don't see this; the loop only sees this.

**Variants:**
- `:step_start` — `{step_id, model_id}`
- `:text_delta` — `{part_id, fragment}`
- `:reasoning_delta` — `{part_id, fragment}`
- `:tool_call_start` — `{part_id, tool_name}`
- `:tool_call_args_delta` — `{part_id, fragment}`
- `:tool_call_complete` — `{part_id, args :: map()}`
- `:step_finish` — `{step_id, stop_reason, usage}`
- `:done` — terminal, no more events
- `:error` — `{reason, retriable?}`

**Decisions:**
- `part_id`s are minted by the adapter at the boundary. The adapter
  is responsible for stable per-stream ids so the reducer can
  correlate deltas. (UUID v7 for these is fine.)
- `usage` carries `{input_tokens, output_tokens}` at minimum; per
  vendor extras go in a `metadata` map.
- This ADT is the *contract* between Phase 3 adapters and Phase 2
  loop. Lock it down here.

**Acceptance:** ADT defined; doc per variant; explicit non-goal
list (this is not the wire format; it is the post-normalization
shape).

---

### D2. Adapter contract document · **S**

**Goal:** write the prose obligation any provider adapter must meet.

**Content:**
- Order: `step_start` precedes any deltas; `step_finish` precedes any
  later `step_start`.
- Atomicity: `tool_call_complete` carries the *parsed* args; partial
  args during streaming go through `tool_call_args_delta`. The adapter
  is responsible for parsing the streamed JSON.
- Errors: any exception during streaming becomes a single `:error`
  event; the adapter never throws.
- Idempotency: duplicate events with the same `part_id` are
  programmer error; the adapter must not produce them.

**Acceptance:** `docs/architecture/provider-adapter-contract.md`
checked in; Phase 3 task list will reference this verbatim.

---

## Stream E — Test harness

### E1. Pure test harness · **S**

**Goal:** ergonomic helpers for driving the reducer through scenarios.

```elixir
ctx
|> Loop.Test.given_status(:idle)
|> Loop.Test.send(%Input.UserPrompt{...})
|> Loop.Test.assert_next(:await_provider)
|> Loop.Test.send(%Input.ProviderEvent{event: ...})
|> ...
```

**Decisions:**
- Pure helpers; no ExUnit-isms beyond `assert/1`.
- Returns the latest context + a log of every transition for
  inspection.
- Used by every test in E2 and E3.

**Acceptance:** helpers exist with @doc examples; one example test
green using them.

---

### E2. Scenario tests · **L**

**Goal:** end-to-end transitions through the reducer for realistic
flows.

**Required scenarios:**
1. Single-turn, text-only: prompt → text deltas → step_finish:end_turn → idle.
2. Single-turn, single tool call, auto-approved: prompt → text → tool → tool result → text → end_turn → idle.
3. Single-turn, single tool call, permission required: prompt → text → tool → permission requested → granted → tool runs → tool result → text → end_turn.
4. Single-turn, permission denied: same up to permission, then denied → tool returns error → text → end_turn.
5. Single-turn, parallel tool calls: prompt → text → 3 tools dispatched → tools complete in arbitrary order → text → end_turn.
6. Multi-step turn (tool result triggers another step): prompt → step1 (tool) → tool result → step2 (text) → end_turn.
7. User abort mid-stream: prompt → some deltas → abort → halt:aborted; verify cancel effects.
8. Provider error mid-stream: prompt → some deltas → provider error → halt; verify accumulated state cleaned up.
9. Budget exhausted mid-stream: prompt → deltas → budget tick exceeds → halt:budget_exhausted.
10. Reasoning + text + tool in one step (Claude extended thinking flow).

**Acceptance:** every scenario green; each runs in <50ms; total suite
<2s.

---

### E3. Property tests · **M**

**Goal:** invariants over arbitrary input sequences.

**Properties:**
1. **Apply-event consistency:** the new context returned by `step/2`
   equals `Enum.reduce(events, old_context, &apply_event/2)`. Run on
   1k random valid input sequences.
2. **Idle invariant:** at every `:await_user` transition,
   `accumulating_parts == %{}`, `pending_tools == %{}`,
   `pending_permission == nil`, `current_step == nil`.
3. **Determinism:** `step/2` is a function. Same `(context, input)`
   yields equal `(events, effects, broadcasts, next, context)`.
4. **Effect ordering:** `events` precede `effects` precede
   `broadcasts` in the return; reorderings of any handler's internal
   accumulation must not change the final ordering.
5. **No leakage on halt:** any input sequence ending in `:halt`
   leaves `pending_tools == %{}` and emits `CancelTool` for every
   tool that was in flight.

**Acceptance:** five properties green at 1k iterations; nightly run
at 10k.

---

### E4. Recorded provider-stream fixtures · **S**

**Goal:** real-world `ProviderEvent` sequences captured from actual
providers, used in scenario tests.

**Approach:**
- Capture sequences during early Phase 3 development (via a
  pass-through adapter that logs).
- Store in `test/fixtures/provider_streams/{vendor}/{scenario}.exs`
  as plain Elixir terms.
- One fixture per scenario in E2 minimum.

**Acceptance:** fixtures exist; scenario tests use them where
realistic; CI fails on schema drift between fixture format and the
current `ProviderEvent` ADT.

---

## Stream F — ADRs surfaced during this phase

These are decisions worth committing to writing because they will be
referenced by future phases.

### F1. ADR 0004 — Persistence model for streaming parts · **S**

Captures the broadcast/event split (A4): text deltas are ephemeral
broadcasts; full parts are durable events. Document why, document the
UX cost (mid-stream reload sees no in-progress text), document the
escape hatch if we want it later (periodic part snapshots).

### F2. ADR 0005 — Loop interaction protocol · **S**

Captures the input/output contract (A1–A5). The reference doc Phase 4
will read to build the gen_statem.

### F3. ADR 0006 — Mid-turn user input · **XS**

Captures the queueing decision from B5. Even though the v1 behavior
is "reject mid-turn input", documenting the alternatives now means
Phase 7 doesn't relitigate.

---

## Phase exit criteria

Before opening Phase 3:

- [ ] ADRs 0004, 0005, 0006 merged
- [ ] All Stream A ADTs defined with typespecs and doc strings
- [ ] `Loop.step/2` handles every input variant; no `{:error, :unimplemented}` returns
- [ ] All 10 scenarios in E2 green
- [ ] All 5 properties in E3 green at 1k iterations
- [ ] `Provider.Adapter.Contract` document checked in (D2)
- [ ] iex demo: hand-construct a `Context`, feed it a recorded provider stream end-to-end, inspect the final context showing a multi-step turn with tool results
- [ ] `mix dialyzer` clean
- [ ] Nothing in `Loop.*` opens a socket, hits a database, or calls `Process.*`. Grep enforces this in CI (a small `mix synapsis.lint.purity` task).

When this is done, Phase 3 is *just* writing an HTTP+SSE adapter that
produces `ProviderEvent.t()`. There is no design left.

---

## Cross-cutting expectations

- Every public function: `@spec`, `@doc`, doctest where it clarifies.
- Every handler in `Loop` is ≤ 30 LOC. If one grows past that, extract
  a pure helper. The reducer reads as a flat dispatch.
- No conditional logic on `Mix.env/0` anywhere in `Loop.*`.
- No "TODO: handle this case" — either handle it or `{:error, reason}`
  with a documented reason.
- Naming discipline: `event` means a domain event (durable);
  `provider_event` means a stream chunk (input); `effect` means a
  side-effect description (output); `broadcast` means a transient
  signal (output). Do not blur these.

## Risks specific to Phase 2

| Risk | Mitigation |
|---|---|
| Protocol ADTs churn after Phase 3 starts | Lock them via ADRs 0005 + the adapter contract doc before any adapter work begins; treat post-lock changes as ADR amendments |
| Reducer accumulates incidental complexity (many flags, long handlers) | 30-LOC handler rule; extract pure helpers; if a single handler resists, it's a sign the input is too coarse — split it |
| "Mid-turn user input" gets relitigated in code review | F3 ADR; reject the topic and link to it |
| Property tests too slow → people skip them locally | Cap at 1k iterations locally, 10k nightly; budget ≤ 2s for full property suite |
| Adapter authors smuggle vendor concepts into ProviderEvent | D2 contract doc; CI assertion that `ProviderEvent` definition has no vendor names in identifiers or docs |

## A note on what comes next

After Phase 2, **the agent's behavior is fully specified** as pure
code with property-tested invariants. Phase 3 is plumbing (HTTP).
Phase 4 is process lifecycle (gen_statem). Phase 5 is durability
(Postgres). None of those phases require revisiting Phase 2's
decisions — that's the whole point of doing the design work here.
