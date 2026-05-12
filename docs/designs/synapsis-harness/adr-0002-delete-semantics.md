# ADR 0002 — Delete Semantics

- **Status:** Proposed
- **Date:** 2026-05-09
- **Deciders:** TBD
- **Related:** ADR 0001 (Part storage), Phase 1 task B4

## Context

The harness has four entities with distinct lifecycles:

- **Events** — append-only log; the source of truth (per Phase 0 plan).
- **Sessions** — user-visible aggregates; sometimes regretted, sometimes
  restored, sometimes legally required to be purged.
- **Messages** — derive from sessions; have no meaning outside one.
- **Parts** — addressable individually by the OpenCode-parity API
  (`DELETE /session/{sid}/message/{mid}/part/{pid}`).

Three forces shape the decision:

1. **Event sourcing invariants.** If events are the source of truth,
   they are immutable. Anything that mutates or deletes events
   forfeits replay correctness and crash recovery.
2. **User mental model.** Users delete *sessions*; they sometimes
   delete or edit a *part* (e.g. retracting a tool call); they don't
   reason about "deleting a message" independently of its session.
3. **Compliance.** Real hard delete must exist for legal requests. It
   should be rare, explicit, audited, and decoupled from the
   user-facing delete path.

## Decision

**Three different mechanisms for three different things.**

### 1. Events: never deleted, never modified

The `events` table is append-only. There is no `UPDATE` path, no
`DELETE` path, no soft-delete column. Migrations may add columns;
they may not rewrite event payloads. *(Schema evolution is ADR 0003's
problem, not this one's.)*

A user-facing "delete" is itself an event (`SessionDeleted`,
`PartDeleted`) — the *fact of deletion* joins the log rather than
erasing it.

### 2. Sessions: soft delete, user-facing

```sql
ALTER TABLE sessions
  ADD COLUMN deleted_at TIMESTAMPTZ NULL;

CREATE INDEX sessions_active
  ON sessions (project_id, inserted_at DESC)
  WHERE deleted_at IS NULL;
```

- `DELETE /session/{id}` records a `SessionDeleted` event and stamps
  `deleted_at`. The session and its descendants disappear from list
  endpoints.
- Sessions remain queryable by id (so a stale UI tab doesn't 404 in a
  scary way) but return with `deleted: true` and an empty message
  collection unless `?include_deleted=true` is passed.
- A `POST /session/{id}/restore` endpoint records `SessionRestored`
  and clears `deleted_at`. Restore window is unbounded by default;
  projects may impose a TTL via a scheduled job that promotes soft
  deletes to hard deletes after N days.

The `Context.status` field gains `:deleted` as a terminal state —
`Loop.step/2` refuses to advance a deleted session.

### 3. Messages: no independent delete

Messages have no soft-delete column and no API endpoint for deletion.
Their lifecycle is fully derived from the session:

- Session soft-deleted → messages remain in DB, hidden via the session
  filter.
- Session hard-deleted → messages cascade-delete via FK.

Rationale: nothing in the OpenCode parity surface or in our own
agent semantics treats a message as separately deletable. Adding a
mechanism we don't need is technical debt with interest.

### 4. Parts: soft delete, projection-only

The OpenCode-parity surface includes `DELETE /…/part/{pid}`. The
intended semantics: hide the part from the message's rendered history
without losing the audit trail.

```sql
ALTER TABLE parts
  ADD COLUMN deleted_at TIMESTAMPTZ NULL;
```

- `DELETE /…/part/{pid}` records a `PartDeleted` event and stamps
  `deleted_at` on the part row.
- The default message read API filters `deleted_at IS NOT NULL`
  parts. A query parameter (`include_deleted=true`) restores them.
- The fold (`apply_event/2`) processes `PartDeleted` by setting a
  `:deleted` flag on the part within `Context`. `Loop.step/2` ignores
  deleted parts when assembling the next provider call — this is what
  makes part-delete *meaningful* to the model rather than purely
  cosmetic.

### 5. Hard delete: admin path, compliance-driven

A separate code path, not exposed on the public API surface:

```
Synapsis.Core.Admin.purge_session(session_id, reason: binary())
```

Effect, in one transaction:
1. `DELETE FROM events WHERE aggregate_id = $1`
2. `DELETE FROM sessions WHERE id = $1` (cascades to messages, parts)
3. Insert a tombstone in `purge_audit` table:
   `{session_id, purged_at, reason, actor}`. This row is the only
   trace; it does not contain content.

Project-level purge composes the same operation across child
sessions. A `purge_audit` row remains forever and is itself a
compliance artifact.

This path is **never** invoked from `Loop`, `Session`, or any user
request handler. It is not idempotent across replays — by design,
because purge is a real-world side effect, not a domain event. The
compliance team operates it via a CLI task gated on
`SYNAPSIS_ADMIN_TOKEN`.

## Cascade matrix

| Operation              | Events       | Session row | Messages    | Parts        |
|------------------------|--------------|-------------|-------------|--------------|
| `DELETE /session/{id}` | `SessionDeleted` appended | `deleted_at` stamped | retained, hidden via filter | retained |
| Session restore        | `SessionRestored` appended | `deleted_at` cleared | re-visible | re-visible |
| `DELETE /…/part/{id}`  | `PartDeleted` appended | unchanged | unchanged | `deleted_at` stamped |
| `Admin.purge_session`  | **DELETED**  | DELETED     | DELETED     | DELETED      |
| Project hard-delete    | DELETED for all sessions | DELETED | DELETED | DELETED |

## Consequences

### Positive

- **Event log integrity preserved** in the 99% case. Replay correctness
  is not a debate.
- **User-facing delete is reversible** without engineering involvement.
- **Compliance escape hatch exists** but is hard to invoke
  accidentally — wrong default beats convenient default for
  irreversible operations.
- **Part deletion is semantically real.** The model's view of history
  matches the user's view, because the fold respects `:deleted`.
- **No special-case logic in `Loop`.** Deletion enters the loop as just
  another event variant.

### Negative

- **Storage grows unboundedly without retention policy.** Soft-deleted
  sessions accumulate. *Mitigation:* add a retention job in a later
  phase that promotes soft → hard delete after a per-project TTL;
  default TTL configurable, no default value forced today.
- **Two paths for "delete a session"** (soft via API, hard via admin
  CLI). *Mitigation:* the admin path is intentionally inconvenient to
  reach and audit-logged; the duplication is the point.
- **`PartDeleted` events are never garbage-collected.** A user
  spam-deleting parts grows the event log. *Mitigation:* same
  retention job; soft delete the parent session and the events go
  with it.
- **Restore semantics for parts are subtle.** If the user deletes a
  tool part mid-turn and restores it later, what does the model
  see? *Decision:* part restoration is allowed only on completed
  sessions (`status: :idle`). On active sessions, deletion is
  one-way until the turn ends.

## Alternatives considered

### A. Hard delete only

Simple. Rejected because the most common deletion (a user clicking
"delete this session") wants to be reversible, and because it
violates event sourcing dogma without compensating benefit.

### B. Soft delete events too

Add `deleted_at` to the `events` table; replay filters them out.
Rejected: this is mutation of the source of truth, period. If you
can soft-delete an event you can soft-delete *anything*, and
debugging "why did this session replay differently after the
deletion" becomes a forensic exercise.

### C. Full bitemporal model

Track both `valid_time` and `transaction_time` for every entity.
Rejected as massive over-engineering for v1. The hybrid above gives
us 90% of the value at 10% of the cost. Bitemporal can be added in a
future ADR if compliance ever demands "as-of" queries.

## Validation

This decision is correct iff:

- Soft-deleted session + restore round-trips with no observable
  difference vs. never-deleted session.
- Part deletion changes what `Loop.step/2` sends to the provider on
  the next turn (verifiable by snapshot test).
- `Admin.purge_session/2` followed by replay of the project produces
  no rows for the purged session and no event log entries —
  *and* leaves a `purge_audit` row.
- A property test confirms: for any event sequence ending in
  `SessionDeleted`, the projection matches the fold's view of
  `Context.status == :deleted`.

## Open questions

- Default retention TTL for soft-deleted sessions? Defer until we have
  a real project with real usage; pick a number then, not now.
- Should `PartDeleted` be allowed during an in-flight turn at all?
  Recommendation: yes for `:text` and `:reasoning` parts (cosmetic),
  no for `:tool` parts (semantically dangerous mid-execution). Lock
  in during Phase 7 when permissions land.
