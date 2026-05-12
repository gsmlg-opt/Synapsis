# Phase 1 — Data Model: Task Breakdown

> Phase goal: define the data foundation (Message · Part · Event · Context)
> the entire harness reduces over. Everything downstream — Loop, Session,
> Store, API — depends on these types being right.
>
> Realistic effort: **4–6 working days** for one engineer (revising the
> headline plan's "2–3 days"; the polymorphic-Part spike alone tends to
> eat a day, and the property tests pay back interest only if written
> properly).

## Scope

In:
- `Synapsis.Core.Message` struct + Ecto schema
- `Synapsis.Core.Part` discriminated union + variants
- `Synapsis.Core.Session` Ecto schema (lightweight — no behaviour yet)
- `Synapsis.Core.Event` ADT + payload shapes
- `Synapsis.Core.Context` + `apply_event/2` pure fold
- Migrations, indexes, basic test infra, OpenCode contract fixtures

Out:
- `Loop`, `Provider`, `Tool`, `Session` gen_statem (later phases)
- Persistence layer (`Store`) — schemas exist, but no behaviour wraps
  them yet
- PubSub, telemetry beyond `:logger` calls

## Work streams

```
A. Part union & storage     ─┐
                             ├──▶ D. Context & fold ──▶ phase exit
B. Session/Message schemas ──┤
                             │
C. Event ADT ────────────────┘

E. Test infrastructure (parallel throughout)
```

A1 blocks A2..A5. A and B unblock C. C unblocks D. E starts day 1.

---

## Stream A — Part union & storage

### A1. Spike: Part storage strategy · **S** · **blocking**

**Goal:** decide how `Part` is persisted and queried.

**Options to evaluate:**
1. `polymorphic_embed` library (`embeds_one :data, polymorphic: [...]`)
2. Custom `Ecto.Type` over a JSON/JSONB column with a `:type` discriminator
3. One row per part with a discriminator column + sparse columns per variant
4. Hybrid: row per part + JSONB `data` column for variant payload

**Decision criteria (in priority order):**
- Query needs: list parts in order, filter by type, update tool state in place
- Ergonomics in changesets and pattern-match in the loop
- Migration cost when adding a new variant later
- Streaming append cost (parts are written hot)

**Acceptance:** ADR file `docs/adr/0001-part-storage.md` checked in,
recommendation locked, all of A2 is unblocked.

**Hint without prejudging:** option 4 is usually the FP-friendly local
optimum here — relational identity for parts (so the `messageID + partID`
PATCH/DELETE endpoints fall out naturally), structural variance in JSONB
(so the union stays open). But run the spike honestly.

---

### A2. `Part` variant definitions · **M**

**Goal:** define every variant as an Elixir struct with `@typespec`,
matching the OpenCode shape for shared fields.

**Variants to ship in v1:**
- `Text` — `{content, synthetic?, ignored?}`
- `Reasoning` — `{content}` (Claude extended thinking, DeepSeek-R1)
- `File` — `{source}` where source ∈ `FileSource | SymbolSource | ResourceSource`
- `Tool` — `{tool_name, args, state, result?}` (state machine — see A3)
- `Agent` — agent reference part
- `StepStart` / `StepFinish` — model-call boundary markers
- `Snapshot` — workspace snapshot ref

**Common fields across all parts:** `id`, `session_id`, `message_id`,
`ordinal`, `inserted_at`.

**Acceptance:**
- Every variant has a struct, typespec, and a builder function
- Pattern-matching on `%Part{type: :tool, data: %Tool{...}}` (or whatever
  shape A1 settled on) works in iex
- Doc string per variant describing when it's emitted

---

### A3. Tool-part state machine · **S**

**Goal:** model the `pending → running → completed | error` lifecycle as
data.

**Decisions:**
- States as atoms (`:pending | :running | :completed | :error`)
- Allowed transitions enforced in a single `Tool.transition/2` pure
  function — return `{:ok, new_state} | {:error, :invalid_transition}`
- Result/error payloads attached on terminal states only
- Cancellation: `error` with `reason: :cancelled`, not a fifth state

**Acceptance:** transition function with exhaustive tests; invalid
transitions are unrepresentable in correctly-built parts.

---

### A4. Validation & changesets · **S**

**Goal:** every variant has a changeset (or equivalent) that rejects
malformed input at the boundary.

**Decisions:**
- Ecto changesets vs Norm vs hand-rolled — pick one, apply uniformly.
  Recommendation: Ecto changesets for write-path parity with the rest of
  the schema layer.
- What's a hard error vs a soft warning? (e.g. empty text part: probably
  reject; missing optional metadata: accept.)

**Acceptance:** every variant rejects at least three concrete malformed
inputs in unit tests.

---

### A5. OpenCode schema contract test · **S**

**Goal:** prove our Part shape can round-trip a real OpenCode message
corpus.

**Approach:**
- Pull a handful of OpenCode session JSON exports (from their docs,
  `session export`, or hand-construct from their `message-v2.ts` Zod
  schemas)
- Decode → re-encode → diff. Failures point to schema drift.

**Acceptance:** at least one real-world message per variant decodes and
re-encodes to a structurally-equal JSON object.

**Why this matters:** schema parity is cheap to maintain if checked
continuously and expensive to retrofit. Lock it in now.

---

## Stream B — Session & Message schemas

### B1. `Session` Ecto schema + migration · **S**

**Goal:** the session row, no behaviour attached yet.

**Fields:**
- `id` (UUID v7 — sortable, useful for cursoring)
- `project_id` (UUID, FK to projects table — defer projects table to a
  later phase if not present yet; nullable for now is acceptable)
- `parent_id` (self-FK, nullable, for sub-sessions)
- `title` (string, nullable — derived later by an "AI rename" task)
- `status` (enum: `:active | :idle | :aborted | :archived`)
- `metadata` (JSONB — model id, agent id, system prompt ref, budget
  config; loose by design)
- `inserted_at`, `updated_at`
- `deleted_at` (soft delete — see B4)

**Indexes:** `project_id`, `parent_id`, `(project_id, inserted_at desc)`
for the list endpoint.

**Acceptance:** migration runs forward + backward; basic insert/read
test green.

---

### B2. `Message` Ecto schema + migration · **S**

**Fields:**
- `id` (UUID v7)
- `session_id` (FK, cascade delete)
- `role` (enum: `:user | :assistant | :system`)
- `ordinal` (integer, monotonic per session — gapless preferred for
  cursoring)
- `inserted_at`

**Indexes:** `(session_id, ordinal)` unique.

**Decision:** `ordinal` strictly monotonic and gapless, or just monotonic
with gaps allowed on aborted turns? Recommend gapless — simpler cursoring,
costs nothing in single-writer-per-session world (which we have via
the gen_statem in Phase 4).

---

### B3. `Part` table migration · **M**

Depends on A1. Schema follows the spike outcome.

Concrete suggestion if A1 lands on hybrid:
- `id` (UUID v7)
- `message_id` (FK, cascade)
- `session_id` (denormalised FK, for the session-scoped subscription
  topic and for cheap session-wide queries)
- `ordinal` (integer, monotonic per message)
- `type` (enum or string discriminator)
- `data` (JSONB)
- `inserted_at`, `updated_at`

**Indexes:** `(message_id, ordinal)` unique, `(session_id, inserted_at)`
for the event-stream catch-up query, partial index on
`type='tool' AND data->>'state' IN ('pending','running')` for "what's
in flight" dashboards.

---

### B4. Delete semantics · **S**

**Goal:** decide soft-delete vs hard-delete and apply consistently.

**Recommendation:** soft delete on `Session`, hard cascade on `Message`
and `Part`. Sessions are user-visible artifacts users sometimes want to
restore; messages/parts derive from sessions and don't need
independent recovery. Matches OpenCode's `Event.Deleted` semantics
roughly.

**Acceptance:** ADR `0002-delete-semantics.md`; all write paths
respect the rule.

---

## Stream C — Event ADT

### C1. Event variants · **M**

**Goal:** enumerate every event the fold needs to process and lock down
their payload shapes.

**Variants:**
- `SessionCreated` — `{session_id, project_id, parent_id?, metadata}`
- `MessageAppended` — `{session_id, message}`
- `PartAppended` — `{session_id, message_id, part}`
- `PartUpdated` — `{session_id, message_id, part_id, patch}` (patch =
  partial map, applied via `Map.merge/2`-style update)
- `ToolInvoked` — `{session_id, message_id, part_id, tool_name, args}`
- `ToolReturned` — `{session_id, message_id, part_id, result | error}`
- `PermissionRequested` — `{session_id, tool_call_ref, effect_class}`
- `PermissionGranted` / `PermissionDenied` — `{session_id, tool_call_ref}`
- `Aborted` — `{session_id, reason}`
- `Compacted` — `{session_id, replaced_message_ids, summary_part}`

**Decisions:**
- Each event is a struct in its own module (`Synapsis.Core.Event.SessionCreated`)
- Every event has `event_id`, `aggregate_id` (= `session_id`),
  `version` (per-aggregate monotonic), `inserted_at`
- `version` is gapless per session — concurrency control falls out

**Acceptance:** all variants defined, typespecs in place, doc string per
variant describing when it's emitted and what fold transition it drives.

---

### C2. Event persistence schema · **S**

**Decision needed:** are events the source of truth, or a derivative
log?

**Recommendation:** events are the source of truth. `messages`/`parts`
tables are **projections** maintained transactionally with event
append. This means:
- Append event → update projection in same DB transaction
- Read path uses projections (cheap)
- Replay path uses events (correct)
- Tests hammer the fold to prove projection ≡ fold result

This is more work than projections-only but it's what makes Phase 5
(crash recovery) trivial.

**Schema:**
- `events` table: `event_id`, `aggregate_id`, `version`, `type`, `data`
  (JSONB), `inserted_at`. Unique `(aggregate_id, version)`.

**Acceptance:** migration + insert/read tests; concurrency test that
appending two events with the same version fails.

---

### C3. Serialization · **S**

**Decision:** JSON in JSONB columns. Reasons: queryable, debuggable in
psql, plays well with the existing `metadata` JSONB elsewhere. Cost:
slightly larger than `:erlang.term_to_binary/1`. Worth it.

**Acceptance:** every event variant has a `to_json/1` and `from_json/1`
that round-trip.

---

### C4. Versioning · **S**

**Decision:** every event variant has an integer `schema_version` field,
default `1`. No upcaster framework yet — just a `case` in `from_json/1`
when v2 lands. Punt the framework until you need it.

**Acceptance:** documented; default value present in all variants.

---

## Stream D — Context & fold

### D1. `Context` struct · **S**

**Fields:**
- `session_id`
- `messages` — ordered list of `%Message{}` with `:parts` populated
- `project_state` — `{cwd, tracked_files, open_files, lsp_servers}`
- `budgets` — `{tokens_used, tokens_max, tool_calls_used, tool_calls_max,
  wall_clock_max, depth_used, depth_max}`
- `permissions` — granted permission tokens (so the loop knows what's
  pre-approved)
- `status` — `:active | :awaiting_permission | :aborted | :completed`
- `version` — last event version applied (for replay assertions)

**Acceptance:** typespec; `new/1` builder; `:erlang.phash2/1`-stable
(important for snapshot equality testing).

---

### D2. `apply_event/2` pure fold · **M**

```
@spec apply_event(Context.t(), Event.t()) ::
        {:ok, Context.t()} | {:error, reason}
```

**Goal:** the keystone pure function. Takes a context + event, returns
the next context. No IO. No process state. No exceptions on valid
input.

**Implementation guidance:**
- One `apply_event/2` clause per event variant — exhaustive `case`
- `version` mismatch → `{:error, :version_skip}` (events must be
  applied in order)
- Idempotent re-application of an already-applied event → `{:ok,
  same_context}` is acceptable; re-applying a different event at the
  same version → `{:error, :version_conflict}`
- Operations on parts/messages reuse pure helpers — `Message.append_part/2`,
  `Part.update/2`, etc.

**Acceptance:** every event variant has at least one positive and one
negative test; `Enum.reduce(events, Context.new(...), &apply_event/2)`
is the canonical construction.

---

### D3. Property tests · **M**

**Properties to assert (StreamData):**
1. **Replay-equivalence:** for any valid event sequence `es`,
   `Enum.reduce(es, c0, &apply!/2)` equals
   `Enum.reduce(Enum.concat(prefix, suffix), c0, &apply!/2)` when
   `prefix ++ suffix == es`. (Trivially true if D2 is correct, but
   catches accidental mutation if anyone reaches for the process
   dictionary.)
2. **Version monotonicity:** rejecting out-of-order events.
3. **Projection equivalence:** for any event sequence, the context's
   `messages` field equals the result of querying the projections (set
   up by C2). This single property test catches 90% of bugs in the
   write path.
4. **Idempotency at the version boundary:** applying the same event
   twice yields the same context.

**Acceptance:** four properties, each with at least 1k iterations
green.

---

### D4. Snapshot strategy · **S**

**Decision:** snapshot every N events (start with `N=200`), or when
`Context.estimate_size/1 > threshold`. Defer real implementation to
Phase 5 — but the `Context` struct must be designed today so it's
serializable with `:erlang.term_to_binary/1` (no PIDs, no refs,
no anonymous functions).

**Acceptance:** ADR `0003-snapshot-strategy.md`; assertion test that a
freshly-built context round-trips through `term_to_binary` and back.

---

## Stream E — Test infrastructure

### E1. Builders · **S**

Test helpers for constructing valid events/messages/parts with sensible
defaults. These get used by every property test and every fixture.

**Acceptance:** `build(:session)`, `build(:message)`, `build(:part, :text)`,
etc. — one entry per variant.

---

### E2. StreamData generators · **S**

Custom generators producing valid event sequences (respect version
order, reference real session/message/part ids). The hard part: events
must form a coherent narrative (no `PartUpdated` on a non-existent
part).

**Acceptance:** generator produces 1k sequences without `apply_event/2`
returning `:error`.

---

### E3. OpenCode fixture loader · **S**

Pulls a small corpus of OpenCode message JSON, decodes through our
schema, asserts no data loss. Lives in `test/fixtures/opencode/`.

**Acceptance:** at least one fixture per part variant; CI fails on
schema drift.

---

## Phase exit criteria

Before opening Phase 2:

- [ ] All ADRs (0001 part-storage, 0002 delete-semantics, 0003 snapshot)
      merged
- [ ] `mix test apps/synapsis_core` green, including the four property
      tests from D3
- [ ] OpenCode fixture round-trip green (E3)
- [ ] `iex -S mix` demo: hand-construct an event sequence, fold it,
      inspect the resulting `Context` showing a multi-turn conversation
      with a tool part in `:completed` state
- [ ] Type check clean (Dialyzer or Gradient — pick one and run it in
      CI)
- [ ] `Context` and all event structs are `term_to_binary`-safe (no
      stray PIDs)

When this is done, Phase 2 (Loop) becomes a focused exercise: take
`Context` and a `provider_event`, return `{next_action, context,
[effect]}`. No data-shape questions left to answer.

---

## Cross-cutting expectations

- Every public function: `@spec`, `@doc`, doctest where it clarifies
- No process-dictionary, no `Application.get_env/2` in pure modules
- All Phase 1 modules under `Synapsis.Core.*` — no leakage into
  `synapsis_server`
- Module boundary discipline: `Part` doesn't know about `Session`;
  `Message` doesn't know about `Event`; `Event` knows about
  `Message`/`Part` (it produces them); `Context` knows about
  everything (it's the aggregate root)

## Risks specific to Phase 1

| Risk | Mitigation |
|---|---|
| Polymorphic Part fights Ecto | Spike A1 day 1; budget the second day for fallback to JSONB+custom-type |
| OpenCode schema evolves underneath us | Pin to a specific OpenCode commit in the fixture loader; bump deliberately |
| Property tests too slow → people skip them | Cap shrinks; budget ≤30s per property; run full suite nightly only |
| "We'll fix Part later" temptation | Don't. Adding a variant is cheap; reshaping the union is brutal |
