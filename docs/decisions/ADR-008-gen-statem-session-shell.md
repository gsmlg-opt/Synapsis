# ADR-008: `:gen_statem` Session Shell with Derived States

## Status: Accepted

Realizes the harness redesign's Phase 4 ("Session as `:gen_statem`", see
`docs/designs/synapsis-harness/refactor-harness.md` decision #5 and
`adr-0006-mid-turn-input.md`) — but against the **graph Engine** of
[ADR-006](ADR-006-in-process-sessions-and-concord-storage.md), which is the
reducer that actually runs, not the orphaned `Synapsis.Harness.Loop`.

## Context

The harness plan chose `:gen_statem` over `GenServer` so that session states
are explicit and invalid transitions are caught at the state-machine layer
instead of becoming case-spaghetti. That plan stalled after Phase 2; ADR-006
then delivered the same architecture (pure reducer + single process shell) as
`Synapsis.Session.Worker`, a plain GenServer where execution state was implied
by data fields (`stream_ref`, `pending_tool_count`, `pending_approvals`,
`query_loop_task`) and the busy check was a scattered `engine_ready?/1`.

## Decision

`Synapsis.Session.Worker` is a `:gen_statem` (`handle_event_function` mode)
with explicit states:

```
:booting → :idle → :busy → :generating → :executing_tools ↘
              ↑__________________________________________ :awaiting_approval
:query_loop   (assistant mode: turn delegated to a QueryLoop task)
```

Key properties:

- **States are derived, not tracked.** After every event the next state is
  computed by `derive_state/1` from the same data fields the GenServer already
  maintained. The machine can never disagree with the engine; the migration
  introduced no second source of truth.
- **The mid-turn-input policy lives in one clause.** Normal `send_message` starts
  immediately while the graph is idle. While a graph turn or QueryLoop turn is
  running it is persisted to Concord's `pending_inputs` queue and starts
  automatically after the current turn reaches a safe input wait. This keeps
  transcript ordering correct because queued prompts are not appended as durable
  user messages until the worker starts them.
- **Steer is explicit and advisory.** `steer_message` is a separate current-step
  action. In graph-running states it records a steer input that `BuildPrompt`
  injects into the next LLM system prompt for the same turn; it does not interrupt
  streams/tools and does not create a durable user message. When the graph is
  idle, or when the session is in QueryLoop mode where there is no prompt-build
  injection point, the worker rejects steer with `:no_active_turn`. The web UI
  hides steer outside running graph turns and treats normal Send as the way to
  start or queue durable user prompts.
- **IOHandler is process-agnostic.** Its handlers take and return the worker
  data struct; each shell (the gen_statem Worker, GlobalAgent's GenServer)
  wraps results in its own behaviour return shape.
- **Public API unchanged.** `send_message/3`, `cancel/1`, `retry/1`,
  `approve_tool/2`, `deny_tool/2`, `switch_*`, `get_status/1`, `snapshot/1`
  keep their signatures; `steer_message/2` is added as the explicit steer API.
  External status remains `:waiting | :running`.
- **Epoch fencing, inactivity timeout, poison-quarantine boot, and the
  per-turn Concord snapshot are retained** (event timeout replaces the
  GenServer timeout; semantics identical).

### Bug fixed by the conversion

`cancel` previously reset the engine but never re-parked it at `:receive`, so
a cancel→resend returned `{:error, {:engine_not_ready, :receive}}`. Cancel now
performs the same parking maneuver as boot and lands the machine in `:idle`.

## Consequences

- New per-state policies (e.g. queueing prompts instead of rejecting,
  approval-specific timeouts) become single clauses on `handle_event/4`.
- `Synapsis.Harness.Loop` and the harness Phase 4 docs are superseded by this
  ADR; the harness reducer remains unwired and is a deletion candidate.
- Tests assert state transitions directly (`derive_state/1`,
  `handle_event/4`) without spawning processes.
- Cancel clears queued/inflight steer records for the interrupted turn but
  preserves queued normal prompts. Provider stream messages for graph sessions
  are fenced with a worker-local stream reference, so late chunks or terminal
  messages from a cancelled stream cannot complete a newer stream or consume
  preserved queued prompts.
