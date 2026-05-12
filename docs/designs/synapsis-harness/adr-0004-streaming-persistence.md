# ADR 0004 — Persistence Model for Streaming Parts

- **Status:** Proposed
- **Date:** 2026-05-09
- **Deciders:** TBD
- **Related:** ADR 0001 (Part storage), Phase 2 task A4

## Context

A model turn produces output in two granularities:

1. **Deltas** — text fragments, reasoning fragments, partial tool-arg
   JSON. They arrive at ~10–100/sec from the provider, are
   meaningful only as a stream, and individually carry no semantic
   value (a half-token is not a thing the model "decided").
2. **Completed parts** — text blocks, reasoning blocks, tool calls,
   tool results, step markers. These are the model's actual outputs.
   The transcript of a turn is the ordered sequence of these.

The harness has two audiences for this output:

- **Live UI subscribers** — humans watching the cursor blink. They
  need deltas, in order, as fast as possible.
- **Everyone else** — the projection layer, replay tooling, the
  fold inside `Loop.step/2`, any future eval harness, any client
  that reconnects after disconnect. They need the *completed* parts
  and can reconstruct everything semantic from them.

Three forces shape the decision:

1. **Write amplification.** Persisting every delta as an event means
   ~50 INSERTs per second per active session per turn. With N
   concurrent sessions, this is the dominant DB write load for no
   semantic gain. Aggregating into completed parts cuts this by ~99%.
2. **Replay correctness.** The fold (`apply_event/2`) must produce
   semantically correct context. Half-finished parts are not part of
   the agent's state at any commit boundary; persisting them would
   put the fold in the business of garbage collection.
3. **Reconnect UX.** A user who reloads mid-stream loses the
   in-progress paragraph. This is the cost of the split.

## Decision

**Split the output stream into two channels with different durability
guarantees.**

### Broadcasts — transient, lossy, fast

`Loop.Broadcast.t()` variants are pushed to PubSub topic
`session:{id}:stream`. Subscribers receive them best-effort. They are
**not** persisted, **not** replayed, **not** part of any event log.

Variants (from Phase 2 task A4):
- `TextDelta {part_id, fragment}`
- `ReasoningDelta {part_id, fragment}`
- `ToolArgsDelta {part_id, fragment}`
- `StatusChanged {status}`

A subscriber that joins mid-turn sees subsequent broadcasts but not
prior ones for the same in-progress part. To rehydrate the
already-streamed portion, the client must read the projection — and
the projection only contains completed parts. Therefore: **mid-turn
reload shows no in-progress text**. This is intentional. (See
"Consequences" for the escape hatch.)

### Events — durable, ordered, lossless

`Synapsis.Core.Event.t()` variants are appended to the event log and
drive projection updates. They mark the *completion* of meaningful
units:

- `PartAppended` — a new part exists; if streaming, its `data` field
  carries an empty body and `state: :streaming`.
- `PartUpdated` — a part transitioned to a new state (e.g. tool
  `running → completed`) or its body is now finalized.
- `PartFinalized` — a streaming part is now complete; carries the
  full finalized body.

The reducer emits `PartAppended` at stream start (so reconnect
clients see *that the part exists*) and `PartFinalized` at stream
end (carrying the finalized text). Between those, only broadcasts
flow.

### The two-phase part lifecycle

```
                    deltas (broadcasts only)
                    ┌──────────────────────┐
                    │   …                  │
                    ▼                      │
provider_event   ┌──────┐   provider_event ┴───   provider_event
:tool_call_start │      │ :text_delta             :step_finish
       │         │      │      │                       │
       ▼         │      │      ▼                       ▼
  PartAppended   │      │  (broadcast only)      PartFinalized
  state:         │      │                        state:
  :streaming     │      │                        :completed
                 ▼      ▼
              (no event)
              accumulating_parts[part_id] grows
                 in Context (in-memory)
```

The in-flight body lives in `Context.accumulating_parts`, which is
process-local state — not persisted, not in projections. On a session
crash, the in-flight body is lost; supervisor restart replays events
and arrives at a context with no in-flight parts. Any active provider
stream is restarted from the last `PartFinalized` boundary.

### Why two phases (not just `PartFinalized`)

`PartAppended` at stream start is the contract that makes the
projection a useful read model. A subscriber that polls "what parts
exist in this message" sees the empty-bodied streaming part
appear immediately, and can render a "Claude is typing…" indicator
without having to subscribe to the broadcast channel separately. The
event log carries a true causal history.

## Consequences

### Positive

- **DB write rate is bounded by part count, not token count.** Big
  win at scale.
- **Replay is trivial.** The fold sees only complete parts; no
  garbage-collection logic for half-finished state.
- **Live UI is cheap.** Broadcasts go through PubSub with no DB
  round-trip.
- **Crash recovery is simple.** In-flight state lives in one place
  (`accumulating_parts`); losing it on restart is acceptable because
  the provider stream is restartable from the last commit.
- **Subscriber API is uniform.** A client subscribes to `events` for
  durable state and `stream` for live updates. Each topic has clear
  semantics.

### Negative

- **Mid-stream reload shows no in-progress text.** The user reloads,
  sees the prior committed parts, sees a "generating…" indicator (if
  the UI implements one based on `PartAppended` with `state:
  :streaming`), and waits for the next finalized part. This is the
  cost we accept. *Mitigation if it becomes a real UX problem:*
  introduce periodic `PartCheckpoint` events that capture the
  in-flight body every N seconds or M tokens. Reduces the write
  amplification benefit but bounds the visible-loss window.
- **Two subscription topics to document and maintain.** *Mitigation:*
  the split is articulated in ADR 0005 (interaction protocol) and the
  API documentation; client SDKs expose them as separate methods.
- **A broadcast lost in transit is gone forever.** PubSub does not
  guarantee delivery. *Mitigation:* this is fine because broadcasts
  are cosmetic; the eventual `PartFinalized` event carries the full
  body, and clients reconcile to that. If a delta is lost, the user
  sees a momentary stutter, not data loss.
- **The reducer needs separate code paths for "emit broadcast" and
  "emit event."** *Mitigation:* this is a feature, not a cost — the
  type system distinguishes them and CI rejects accidental promotion
  of a broadcast into the event stream.

### Neutral

- The split slightly complicates the provider-adapter contract: the
  adapter must produce both stream deltas (which become broadcasts)
  and boundary markers (`step_finish`, `tool_call_complete`, which
  become events). But this distinction already exists in every
  provider's wire protocol, so the adapter is normalizing rather than
  inventing.

## Alternatives considered

### A. Persist every delta as an event

Every text-delta is a `TextDelta` event. The fold concatenates them
on read. Reconnect is perfect.

Rejected. Write amplification is brutal (50 INSERTs/sec/session). The
fold becomes the assembly point for partial state, which means
`apply_event/2` is no longer "process this commit"; it's "incrementally
build something that's still in motion." Two responsibilities, one
function. Bad split.

### B. Single channel, event-only

No broadcasts at all. Live UI reads the event log with a tailing
cursor. Latency is whatever the DB commit cycle is (~5–50ms).

Rejected. Coupling UI latency to DB commit latency means every
performance problem in Postgres becomes a typing-feels-slow problem
for users. The broadcast channel decouples them.

### C. Single channel, broadcast-only

No events. Everything is a transient broadcast. Persistence happens
in a separate batch job that consumes broadcasts and writes parts.

Rejected. The event log is the source of truth (Phase 0). Making
durability eventual rather than transactional invites every class of
bug we set out to avoid by going event-sourced in the first place.

### D. Per-part snapshots every N tokens

In-progress parts get a `PartCheckpoint` event every 100 tokens. Best
of both worlds: bounded write amplification, bounded reconnect loss.

Deferred, not rejected. Worth implementing if mid-stream reload UX
becomes a measured problem. Costs nothing today to leave the door
open by reserving the `PartCheckpoint` event variant for future use.

## Validation

This decision is correct iff:

- Broadcast topic load and event topic load are *measurably* different
  by ≥ 50× under load. A simple synthetic load test in CI suffices.
- A subscriber that joins mid-turn receives subsequent broadcasts and
  catches up to the message-final state via projection read +
  subsequent broadcasts, ending with no observable difference from a
  subscriber that joined before the turn started.
- Killing the session process mid-stream and letting the supervisor
  restart yields a Context with no `accumulating_parts` and no
  partial bodies in the projection.

## Open questions

- Do we want a `dropped_count` metadata field on broadcasts so clients
  can detect packet loss? Cheap to add; defer until the first
  reconciliation bug shows up.
- For very-long-running tool calls (minutes), do we want intermediate
  progress broadcasts? Probably yes, via a `ToolProgress` broadcast
  variant. Defer to Phase 7.
- Should we support a "rehydrate in-flight part" RPC for clients that
  really need it? Conceptually possible (the session process knows
  its `accumulating_parts`); deliberately leaving it out of v1 to
  keep the contract clean.
