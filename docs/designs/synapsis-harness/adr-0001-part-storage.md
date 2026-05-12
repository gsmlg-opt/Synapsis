# ADR 0001 — Part Storage Strategy

- **Status:** Proposed
- **Date:** 2026-05-09
- **Deciders:** TBD
- **Related:** Phase 1 task A1 (`docs/architecture/phase-1-tasks.md`)

## Context

`Part` is the discriminated union that carries every kind of content
inside a `Message`: streamed text, model reasoning, file references,
tool invocations with state, agent references, step boundaries,
snapshots. It is the streaming primitive the entire harness reduces
over.

Three forces shape the storage decision:

1. **Streaming write pattern.** Parts arrive incrementally during a
   model turn. Tool parts are updated in place as their state machine
   advances (`pending → running → completed | error`). The hot path is
   *append a part* and *mutate one field of one part*, with multiple
   parts concurrently in flight per message.

2. **OpenCode parity API.** Our v1 milestone exposes
   `PATCH /session/{sid}/message/{mid}/part/{pid}` and
   `DELETE …/part/{pid}`. These endpoints assume each part has a
   stable, externally-addressable identifier. PubSub events
   (`PartAppended`, `PartUpdated`) reference parts by id over the wire.

3. **Open variant set.** The eight v1 variants will grow. Future MCP
   servers may surface parts whose payloads we cannot enumerate at
   compile time. Adding a new variant must not require a column
   migration.

Constraints inherited from elsewhere in the system:

- Postgres + Ecto (already chosen for Synapsis).
- Events are the source of truth (ADR 0001-event-sourcing — pending);
  the `parts` table is a **projection** maintained transactionally with
  event append.
- `Loop.step/2` operates on domain values, not Ecto schemas. The
  storage layer translates at its boundary.

## Decision

**Adopt a hybrid representation: one row per part with common fields as
columns and the variant payload in a JSONB `data` column.**

```sql
CREATE TABLE parts (
  id           UUID         PRIMARY KEY,
  message_id   UUID         NOT NULL
                            REFERENCES messages(id) ON DELETE CASCADE,
  session_id   UUID         NOT NULL
                            REFERENCES sessions(id) ON DELETE CASCADE,
  ordinal      INTEGER      NOT NULL,
  type         TEXT         NOT NULL,
  data         JSONB        NOT NULL DEFAULT '{}'::jsonb,
  inserted_at  TIMESTAMPTZ  NOT NULL,
  updated_at   TIMESTAMPTZ  NOT NULL,
  UNIQUE (message_id, ordinal)
);

CREATE INDEX parts_session_recent
  ON parts (session_id, inserted_at);

-- partial index for "what tool calls are in flight right now"
CREATE INDEX parts_tool_inflight
  ON parts (id)
  WHERE type = 'tool'
    AND data->>'state' IN ('pending', 'running');
```

`session_id` is denormalised onto every part row deliberately: it makes
session-wide subscriptions and catch-up queries a single-table scan,
and it costs one UUID per row.

### Two representations, one boundary

The schema row is **not** the domain value. We keep them separate:

- **DB row** — `Synapsis.Core.Schema.Part`. `data :: map()`. Dumb;
  Ecto's job is round-tripping JSON.
- **Domain value** — `Synapsis.Core.Part.t()`. A tagged variant struct
  (`%Part.Text{}`, `%Part.Tool{state: :running, …}`, etc.). Smart;
  validated; pattern-matchable in `Loop.step/2`.

Boundary functions live in `Synapsis.Core.Part`:

```
@spec from_row(Schema.Part.t())  :: {:ok, t()} | {:error, term}
@spec to_row(t(), context_ids)   :: Schema.Part.t()
```

`Loop` and `Context` see only domain values. The `Store` translates at
ingress/egress. Pattern-match on the variant struct, never on
`%{"type" => …}`.

This is a deliberate anti-corruption layer between persistence and
domain — the price is one extra cast per read; the payoff is that
adding a variant never touches the `Loop`.

### Updates to tool parts

The tool state machine transitions hot (`pending → running →
completed`). Use `jsonb_set/3` for in-place mutation rather than full
replacement:

```sql
UPDATE parts
SET data = jsonb_set(data, '{state}', '"running"'),
    updated_at = NOW()
WHERE id = $1 AND data->>'state' = 'pending';
```

The `WHERE` clause's state predicate gives us optimistic concurrency
control on the transition for free; if two writers race, exactly one
succeeds. This eliminates a class of bug we'd otherwise hit when the
gen_statem and a streaming-delta handler both touch the same tool
part.

## Consequences

### Positive

- **Relational identity per part.** External APIs that address parts by
  id (the OpenCode parity routes) work without contortion.
- **Open variant set.** Adding a part type is a code change only — no
  migration, no schema review.
- **Cheap streaming append.** One `INSERT` per part, no array
  rewrites, no row-level lock contention across sibling parts.
- **In-place state transitions.** `jsonb_set` plus a `WHERE` predicate
  gives optimistic concurrency on the tool state machine.
- **Queryable variant payload.** Postgres GIN/expression indexes on
  `data->>'…'` keep the partial-index pattern (e.g. in-flight tools)
  available without bespoke columns.
- **Anti-corruption boundary.** Domain code is untainted by Ecto;
  storage code is untainted by variant logic. Each can evolve.

### Negative

- **No DB-level enforcement of variant payload shape.** A bug or a bad
  migration could insert structurally invalid `data`. *Mitigation:*
  changesets at every write boundary (Phase 1 task A4); contract tests
  round-tripping OpenCode fixtures (A5); a periodic projector audit
  task can be added later if drift becomes a real risk.
- **Two representations to maintain.** `Schema.Part` and the variant
  structs must stay in sync. *Mitigation:* the boundary functions are
  the *only* places that translate; everything else picks one side.
  Property test: `from_row(to_row(v)) == {:ok, v}` for every variant
  generator.
- **JSONB key renames are not free.** Renaming a field in a variant
  payload requires a backfill UPDATE. *Mitigation:* version the
  variant payload (ADR 0003 will cover event/payload versioning); add
  an upcaster when the rename actually happens.
- **Slight read overhead per part** (one decode call per row).
  Negligible vs. network and model latency.

## Alternatives considered

### Option B — `polymorphic_embed`

`embeds_one :data, polymorphic: [...]` per `messages` row, parts living
inside the message.

Rejected because parts lose stable individual identity (the OpenCode
PATCH endpoint becomes "load the whole message, mutate, save",
serialising every concurrent streaming update through one row), and
because tool-state transitions during streaming would contend with
sibling-part appends on the same message row. The library is fine for
*closed* unions inside an aggregate; ours is open and hot-write.

### Option C — Custom `Ecto.Type` over a single JSON column

A single column whose `cast/dump/load` callbacks dispatch on a
discriminator embedded in the JSON.

Rejected because the discriminator wants to be a queryable column
(partial indexes on `type = 'tool'` are valuable), and because the
custom type adds machinery that earns nothing the hybrid approach
doesn't already give us. We end up with the same outcome plus an extra
indirection.

### Option D — Wide table with sparse columns per variant

`parts` row has every possible field across all variants; most are
NULL on any given row.

Rejected on three grounds: (a) every new variant or every field tweak
becomes a migration; (b) the union is intentionally open and may admit
MCP-defined types whose fields we cannot anticipate; (c) the impedance
mismatch with OpenCode's JSON-native message format would force a
translation layer in *both* directions.

## Validation

This decision is correct iff:

- `from_row(to_row(v)) == {:ok, v}` holds for every variant generator
  (round-trip property, Phase 1 task D3).
- A real OpenCode message export round-trips through Ecto without data
  loss (A5).
- A streaming-tool-update micro-benchmark sustains ≥ 200 transitions
  per second per session against a local Postgres (sanity check, not
  production target).

If any of these fail, this ADR is reopened.

## Open questions

- Do we want a `parts.deleted_at` column for soft delete, or hard
  delete only? Decided in ADR 0002 (`delete-semantics`), not here.
- Should `data` carry an embedded `schema_version` integer for the
  variant payload? Recommended yes; the upcaster pattern then has a
  hook. Detailed in ADR 0003.
