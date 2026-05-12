# ADR 0005 — Loop Interaction Protocol

- **Status:** Proposed
- **Date:** 2026-05-09
- **Deciders:** TBD
- **Related:** ADR 0004 (Streaming persistence), Phase 2 tasks A1–A5,
  Phase 4 (Session gen_statem)

## Context

`Synapsis.Core.Loop.step/2` is the keystone pure function of the
harness. Everything else in the system is either *producing* its
inputs (provider adapters, tool runners, user input handlers) or
*consuming* its outputs (the persistence layer, the PubSub broadcaster,
the gen_statem shell). The function is the contract.

A contract this central deserves an ADR rather than just docstrings,
because:

1. **Phase 4 (gen_statem) implements one side of it.** The state
   machine's states, transitions, and callback structure are derived
   from this protocol — get the protocol wrong and the state machine
   is wrong by construction.
2. **Phase 3 adapters implement another side of it.** Every provider
   adapter must produce inputs in this shape; new vendors plug in by
   conforming.
3. **Phase 5 persistence consumes its events.** The event ADT shape
   is what gets serialized.
4. **Test infrastructure (Phase 2 E1) speaks it as a vocabulary.**
   Scenario tests are sequences of `Input → step → assert next`.

When a contract is touched by four phases, it earns a document.

## Decision

**Lock the protocol as a five-channel function signature with strict
ordering rules.**

### Signature

```elixir
@spec step(Context.t(), Input.t()) ::
        {:ok, %{
           context:    Context.t(),
           next:       NextAction.t(),
           events:     [Event.t()],
           effects:    [Effect.t()],
           broadcasts: [Broadcast.t()]
         }}
        | {:error, reason :: term()}
```

### Inputs (one per call)

The shell calls `step/2` exactly once per incoming event. Inputs are
serial; the reducer never sees concurrent inputs.

**Variant catalogue** (locked):

| Variant            | Produced by                                     |
|--------------------|-------------------------------------------------|
| `UserPrompt`       | API handler when a user sends a message         |
| `UserAbort`        | API handler when a user clicks abort            |
| `ProviderEvent`    | Adapter, one per normalized stream chunk        |
| `ProviderError`    | Adapter, on stream failure                      |
| `ToolStarted`      | Tool runner, when the tool actually begins      |
| `ToolCompleted`    | Tool runner, on success                         |
| `ToolFailed`       | Tool runner, on failure                         |
| `PermissionGranted`| API handler when user approves                  |
| `PermissionDenied` | API handler when user rejects                   |
| `BudgetTick`       | A timer in the shell, periodic                  |

All input variants are structs in `Synapsis.Core.Loop.Input.*` with
explicit fields and typespecs. New variants require an ADR amendment.

### Next actions (one per call)

| Variant                 | Shell behaviour                                 |
|-------------------------|-------------------------------------------------|
| `:await_user`           | Session goes idle; no I/O pending               |
| `:await_provider`       | Provider stream is open; shell pipes events in  |
| `:await_tools`          | Tools are running; shell waits for results      |
| `:await_permission`     | Shell has surfaced a prompt; awaits user        |
| `{:halt, reason}`       | Session is terminal for this turn               |

`next` is the gen_statem state. The names match the Phase 4 state
names exactly (this is a hard constraint — do not invent parallel
vocabularies).

### Events (durable)

Everything the persistence layer must commit. Ordered. Each event
implies a fold transition via `apply_event/2`. See ADR 0001 for the
event catalogue; this ADR adds no new events.

### Effects (imperative side-effect descriptions)

Ordered list of instructions for the shell:

| Variant                 | Shell behaviour                                  |
|-------------------------|--------------------------------------------------|
| `StartProviderStream`   | Open a stream against the provider              |
| `CancelProviderStream`  | Tear down an active stream                      |
| `StartTool`             | Dispatch a tool to the runner                   |
| `CancelTool`            | Tell the runner to stop a tool                  |
| `RequestPermission`     | Surface a permission prompt to the user         |

Effects carry all data needed to execute — the shell does not consult
the context to interpret an effect.

### Broadcasts (transient, lossy)

See ADR 0004. Variants: `TextDelta`, `ReasoningDelta`,
`ToolArgsDelta`, `StatusChanged`. Pushed to PubSub, not persisted.

### Ordering rules

When the shell receives the return tuple, it processes the four
output channels in this order, in a single logical step:

1. **`events`** — persist to the event log. If persistence fails, the
   whole transition fails and the shell crashes (let it crash; the
   supervisor restarts from the last committed event).
2. **`context`** — adopt as the new in-memory context. (Step 1 must
   succeed first.)
3. **`effects`** — initiate in order. Failures here are isolated:
   each effect is its own concern, and a failed `StartTool` becomes
   a subsequent `ToolFailed` input on the next `step/2` call.
4. **`broadcasts`** — publish best-effort. Failures are logged and
   swallowed.
5. **`next`** — transition the gen_statem.

This ordering is what gives the harness its crash-safety property:
if the BEAM dies between steps 1 and 5, replay from the event log
arrives at the same `context` and the shell re-initiates any effects
the events imply. Broadcasts that didn't go out are lost (acceptable
per ADR 0004).

### Error semantics

`{:error, reason}` from `step/2` is **programmer error**, not user
error:

- `:invalid_input_for_state` — e.g. `ProviderEvent` arrived while
  state is `:await_user`. Means the shell sent an input that
  shouldn't have been possible.
- `:unknown_part_reference` — e.g. `ToolCompleted` for a `part_id`
  that doesn't exist. Means the tool runner is misbehaving.
- `:invariant_violation` — e.g. context fold disagrees with claimed
  state. Means the codebase is internally inconsistent.

The shell's response to any `{:error, _}`: log, raise, let supervisor
restart. The reducer is not the place to recover from bugs — replay
from the last committed event is.

User-facing failures (a tool that legitimately fails, a provider
that's down) are represented as **input variants** (`ToolFailed`,
`ProviderError`), not as reducer errors. The reducer handles those
gracefully and emits events.

### Purity guarantees

`Loop.step/2` and every function it transitively calls must:

- Not open a socket, file, or DB connection
- Not call `Process.*`, `:erlang.send/2`, `GenServer.*`, etc.
- Not call `:os.system_time/0` or any function that reads a clock
  (use `BudgetTick` inputs to receive time)
- Not call `Application.get_env/2` (config arrives through `Context`)
- Not raise on valid inputs (return `{:error, _}` instead)

These are enforced by `mix synapsis.lint.purity` in CI (a small grep
+ AST walk).

## Consequences

### Positive

- **The contract is the documentation.** Onboarding a new engineer
  means reading this ADR and the type definitions.
- **Phase 4 is mechanical.** The gen_statem maps `next` to a state,
  each state's callbacks marshal incoming events into `Input`
  variants. No design freedom needed.
- **Phase 3 adapters are mechanical.** A new provider means
  normalizing its stream to `ProviderEvent` variants. The reducer
  doesn't change.
- **The fold and the reducer are reconcilable.** Property test (Phase
  2 E3.1): `Enum.reduce(events, ctx, &apply_event/2) == new_context`.
- **Crash recovery is the same path as fresh start.** Events replay,
  context rebuilds, the gen_statem enters the state implied by the
  last event's downstream `next`.

### Negative

- **Five output channels is more than three.** Engineers will be
  tempted to collapse them. The ADR exists partly to prevent that.
  *Mitigation:* the doc, plus property tests that fail if e.g.
  events arrive in `broadcasts`.
- **Adding a new input variant requires an ADR amendment.** This is
  friction by design. We do not want input variants growing without
  deliberate thought; each one represents a new transition surface.
- **The shell carries more code than a GenServer-with-state would.**
  Translating I/O to `Input` and back is real overhead vs. just
  mutating state inside callbacks. *Mitigation:* the overhead pays
  for every property below.
- **Errors require disciplined separation.** "Tool failed (input)"
  vs. "tool reference was invalid (error)" is a real distinction
  engineers will sometimes get wrong. *Mitigation:* CI lint, code
  review, ADR reference in `Loop` module docs.

## Versioning

This protocol is versioned by ADR amendments, not by code-level
version numbers. The reducer ships exactly one version at a time;
adapters and the shell are deployed together with it.

If a future change is non-backward-compatible at the protocol level
(e.g. an `Input` variant changes shape), that change is itself an ADR
that explicitly says "amends ADR 0005" and goes through code review.

## Alternatives considered

### A. Returning a plain tuple

```elixir
{:ok, context, next, events, effects, broadcasts}
```

Rejected. Six-element tuples are unreadable at call sites. A map keys
itself by name and survives reordering during refactors.

### B. Returning effects only, deriving events from them

The shell observes effects and infers what to persist. Rejected:
events are first-class because the fold is first-class. Inferring
durable state from imperative actions inverts the dependency that
makes event sourcing work.

### C. Async / streaming return

`Loop.step/2` returns a stream of "things that happened" and the
shell consumes them in order. Rejected: streams introduce concurrency
into the reducer's contract. The whole point is that the reducer is
synchronous and the shell handles concurrency.

### D. Multiple inputs per call (batching)

`Loop.step(context, [input1, input2, ...])` for batch processing.
Rejected: the shell receives inputs one at a time anyway (PubSub
messages, gen_statem events). Batching would require buffering with
no clear benefit, and complicates property tests considerably.

### E. Free monad / effect interpreter pattern

Model effects as a free monad, with the reducer producing a program
the shell interprets. Rejected as over-engineered for Elixir's
ergonomics. The pattern works beautifully in Haskell; in Elixir it
produces code reviewers complain about. The plain effect ADT achieves
the same separation with a fraction of the cognitive overhead.

## Validation

This decision is correct iff:

- Phase 2 exits with all 10 scenarios green using this protocol.
- Phase 4's gen_statem implementation is ≤ 300 LOC (size correlates
  with whether the protocol is doing its job; bigger means callbacks
  are absorbing logic that belongs in the reducer).
- Phase 3's first adapter (Anthropic) maps to `ProviderEvent`
  variants with no per-variant special cases in the reducer.
- A property test confirms: for any input sequence, the events
  emitted satisfy `Enum.reduce(events, before, &apply_event/2) ==
  after`.

## Open questions

- Should `BudgetTick` carry a deadline rather than a wall-clock time,
  so the reducer doesn't have to subtract? Cosmetic; defer to
  implementation.
- Multi-input batching (alternative D) might become real for sub-agent
  result aggregation in Phase 8. Reopen then.
- The `:await_step_decision` variant from Phase 2 task A2 is not
  exposed here because it's transient within a single `step/2` call.
  If tests need to inspect it, expose it via a debug-only return
  channel; do not add it to `NextAction`.
