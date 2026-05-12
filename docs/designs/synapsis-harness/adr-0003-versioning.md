# ADR 0003 — Event & Payload Schema Versioning

- **Status:** Proposed
- **Date:** 2026-05-09
- **Deciders:** TBD
- **Related:** ADR 0001 (Part storage), ADR 0002 (Delete semantics),
  Phase 1 task C4 + D4

## Context

Events are the source of truth (Phase 0). The `events` table is
append-only and never rewritten (ADR 0002). Therefore every byte we
write today, we will still be reading in five years.

Three things will evolve over the lifetime of the harness:

1. **Event variants.** New events (e.g. `SubAgentSpawned` in Phase 8)
   will join the ADT. Existing events will gain fields, lose some,
   rename others.
2. **Part variant payloads.** The JSONB `data` column on `parts` (per
   ADR 0001) carries variant-specific shapes. These evolve faster than
   the event envelope — every new tool, every new content type, every
   provider quirk pushes on this surface.
3. **Snapshots.** Snapshot blobs (Phase 5) are tied to the in-memory
   `Context` shape, which is itself derived from the variant set.

Without an explicit versioning strategy, the first schema change that
ships breaks replay for every conversation that came before it.

## Decision

**Two version namespaces, evolved independently. Forward-only
upcasting on read. Writers always write current.**

### Two namespaces

| Namespace | Lives in | Rate of change |
|---|---|---|
| Event envelope | `events.data->>'schema_version'` | Slow — adds when an event variant's structure changes |
| Variant payload | embedded in the variant's `data` (e.g. `parts.data->>'version'`, `events.data->'tool_args'->>'version'`) | Fast — adds when a tool's args change, a part's payload grows, etc. |

Separation matters because the event envelope and the payloads it
carries belong to different teams and different release cadences.
Coupling them means every tool tweak bumps every event reader.

### Versioning rules

Every versioned record carries an integer `schema_version` (envelope)
or `version` (payload), default `1`, mandatory on write.

```elixir
%Synapsis.Core.Event.PartAppended{
  schema_version: 1,
  event_id: ...,
  aggregate_id: ...,
  version: ...,        # this is the per-aggregate sequence, NOT schema
  inserted_at: ...,
  data: %{...}
}
```

The aggregate-version field (event-sourcing sequence number) and the
schema-version field share a name namespace problem; we resolve it by
calling the schema field `schema_version` everywhere. Painful once,
clear forever.

### Field evolution rules

| Change | Allowed? | How |
|---|---|---|
| **Add field, optional with default** | Yes | No bump required if old readers can ignore it; bump if they can't |
| **Add field, required** | Yes | Bump version; upcaster supplies the value for old records |
| **Remove field** | No | Mark deprecated, ignore on read, never delete from the type |
| **Rename field** | Yes | Bump version; upcaster maps `old → new`; both names tolerated for one release cycle, then deprecation |
| **Change field type** | Yes | Bump version; upcaster transforms |
| **Change semantics of existing field** | No | Add a new field with the new semantics; deprecate the old one |

The "no remove" rule is the load-bearing one. A removed field that
shows up in old log data has nowhere to go. Tolerate dead fields.

### Upcasters

```elixir
defmodule Synapsis.Core.Part.Tool do
  @current_version 2

  defstruct [:tool_name, :args, :state, :result, :version]

  @spec from_json(map()) :: {:ok, t()} | {:error, term}
  def from_json(%{"version" => v} = data), do: data |> upcast(v) |> build()
  def from_json(data), do: data |> Map.put("version", 1) |> from_json()

  defp upcast(data, @current_version), do: data
  defp upcast(data, 1), do: data |> rename("toolName", "tool_name") |> upcast(2)
end
```

Conventions:

- Upcasters are **pure functions**, located in the variant module.
- They form a chain: `v1 → v2 → v3 → … → current`. Each step bumps by
  one. No skipping, no parallel paths.
- Writers always write `@current_version`. Old versions exist only on
  read.
- Missing `version` field is treated as `1`. (Phase 1 records will
  predate this rule by a few days; the implicit-1 path covers them.)
- No framework. A `case` per variant until pain demands otherwise.
  When the third variant grows a fourth upcaster step we can revisit.

### Forward-only

There is no downcasting. If a v3 reader wants to write back to a v2
column, it doesn't — it writes v3 and the next reader upcasts. This
implies:

- **Deploy events together with code that produces them.** Standard
  event-sourcing constraint; no surprise.
- **Consumers across services must roll forward in lockstep or the
  older one breaks.** Synapsis is a single deployable today, so this
  is moot; if `synapsis_lsp` ever consumes events directly, this
  becomes a real constraint and warrants its own ADR.

### Snapshots are versioned by code, not by data

Snapshots (Phase 5) are an optimization over event replay. They are
**not** part of the source of truth. Therefore:

- Each snapshot row carries a `code_version` field (a Mix project
  version or git SHA, picked at boot).
- On startup, snapshots whose `code_version` doesn't match the running
  binary are **discarded**. The session reproject from events.
- Cost: occasional cold restore on deploys that touch the variant
  shape. Benefit: zero snapshot-migration code, ever. Worth it.

### Tooling

Three pieces, in order of ROI:

1. **Pinned JSON fixtures per variant per version.** `test/fixtures/
   schema/{variant}/v{n}.json`. Every version that has ever shipped
   has a fixture. CI asserts every old fixture upcasts cleanly to
   `@current_version`. This is the single highest-value test in the
   codebase — it makes "did I break replay" a green/red signal.
2. **Property test on round-trip at current version.**
   `from_json(to_json(value)) == {:ok, value}` for every variant.
   Catches accidental writer/reader drift.
3. **Mix task** (later, low priority): `mix synapsis.gen.upcast Variant`
   scaffolds the next version stub. Skip until at least three real
   bumps have happened — premature scaffolding bakes in patterns we
   haven't lived with yet.

## Consequences

### Positive

- **Replay correctness across schema changes** is a property the test
  suite enforces, not a vibe.
- **Event log is a permanent asset.** It outlives every refactor.
- **Tools and parts evolve independently of events.** A new tool args
  shape doesn't touch the event reader.
- **Snapshots are disposable.** No multi-version snapshot machinery
  ever ships.
- **Failure mode is loud.** Missing upcaster or unknown version raises
  on read; we hear about drift before it corrupts.

### Negative

- **Discipline tax on writers.** Every change to a versioned shape is
  a deliberate act, not a refactor. *Mitigation:* fixture tests fail
  loudly when the discipline lapses.
- **Dead fields accumulate.** Removed-but-tolerated fields make
  variant types noisier over time. *Mitigation:* periodic cleanup
  ADRs that bump versions and prune; cost is finite and predictable.
- **No framework day 1.** Per-variant `case` chains are repetitive.
  *Mitigation:* this is a feature for the first 6–12 months; abstract
  only when the shape of the abstraction is obvious from real usage.
- **Cold restores after deploy.** Snapshot invalidation means the
  first request after a variant-changing deploy reprojects from
  events. *Mitigation:* keep `apply_event/2` fast (it's pure); for
  long histories, tune the snapshot-frequency knob; in extremis, the
  per-`code_version` filter could be relaxed to a per-variant fingerprint
  in a future ADR. Not today.

## Alternatives considered

### A. Single version namespace

One `schema_version` covering the entire event payload, including
nested variants. Rejected: every tool-args tweak bumps every event
that carries a tool args, including ones that didn't actually change.
Couples release cadences that should be independent.

### B. No versioning, "we'll figure it out when needed"

Rejected: works until it doesn't. The first time an event log can't
be replayed, the cost dwarfs the cost of having added a version field
from day 1. Version fields are cheap; absent version fields are
expensive.

### C. Schema registry service (Avro/Protobuf-style)

Centralized versioned schema definitions, code generation, runtime
compatibility checking. Rejected as massively disproportionate to
needs. Worth revisiting when (a) more than one service consumes the
event log, *and* (b) the team is large enough to justify the
indirection. Neither holds today.

### D. JSON Schema validation on every read

Validate `data` against a JSON Schema document at read time, fail on
mismatch. Rejected: doubles the read cost, reproduces information that
already lives in the variant struct's typespec, and doesn't help with
*evolution* — only with *enforcement*. Changesets at write time give
us enforcement at lower cost (Phase 1 task A4).

## Validation

This decision is correct iff:

- Every fixture in `test/fixtures/schema/**/v{n}.json` upcasts to
  current and decodes into a valid struct, on every CI run.
- Every variant has the round-trip property at current version
  (`from_json ∘ to_json == id`), green with at least 1k iterations.
- A deliberate v1→v2 bump on a single variant ships without breaking
  any other test, and old v1 events in a development DB read back
  correctly.

## Open questions

- Should we capture an `app_version` on every event row for
  observability (separate from `schema_version`)? Probably yes —
  cheap, debuggable. Defer to an op tooling phase, not blocking.
- When a downstream consumer (e.g. a `synapsis_lsp` event subscriber)
  arrives, do we want a "minimum compatible reader version" advertised
  on each event? Reopen this ADR then.
- Do tool-args versions belong here or in a per-tool ADR? Recommend
  here for now (one place to look); split when individual tools have
  enough history to warrant their own document.
