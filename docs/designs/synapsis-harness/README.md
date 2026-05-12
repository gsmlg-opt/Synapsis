# Synapsis Harness Design Package

This directory contains the May 2026 harness refactor design package imported
from `synapsis-harness.zip`.

The package proposes reshaping the agent runtime around a pure
`Synapsis.Core.Loop.step/2` reducer, an OTP `gen_statem` session shell,
event-sourced context reconstruction, and OpenCode-compatible
session/message/part semantics.

## Start Here

1. [Refactor plan](refactor-harness.md) - top-level goal, architecture, phases,
   risks, and v1 parity definition.
2. [ADR 0000](adr-0000-harness-architecture.md) - core harness architecture
   decision.
3. [Phase 0 audit](phase-0-audit.md) - current repo boundary translation,
   module disposition, API gaps, and the narrow Phase 1 entry point.
4. [Phase 1 tasks](phase-1-tasks.md) - data model, part storage, event ADT,
   and context fold.
5. [Phase 1 implementation plan](../../superpowers/plans/2026-05-12-synapsis-harness-phase-1.md)
   - repo-specific additive data/fold plan derived from the audit.
6. [Phase 2 tasks](phase-2-tasks.md) - loop reducer protocol, ADTs, handlers,
   provider events, and tests.
7. [Phase 2 stream B](phase-2-stream-b.md) - deep dive on reducer handler
   behavior.

## ADRs

- [ADR 0000 - Harness Architecture](adr-0000-harness-architecture.md)
- [ADR 0001 - Part Storage Strategy](adr-0001-part-storage.md)
- [ADR 0002 - Delete Semantics](adr-0002-delete-semantics.md)
- [ADR 0003 - Event & Payload Schema Versioning](adr-0003-versioning.md)
- [ADR 0004 - Persistence Model for Streaming Parts](adr-0004-streaming-persistence.md)
- [ADR 0005 - Loop Interaction Protocol](adr-0005-loop-protocol.md)
- [ADR 0006 - Mid-Turn User Input](adr-0006-mid-turn-input.md)

## Placement Note

These ADRs are kept under `docs/designs/synapsis-harness/` instead of
`docs/decisions/` because their numbering overlaps the existing accepted ADRs.
Promote or renumber individual decisions only when they are accepted into the
main architecture record.

## Compatibility Note

The imported documents are a design proposal and have not been reconciled with
the current umbrella boundaries. In particular, some text references an older
`synapsis_lsp` app; the current repo has `synapsis_plugin` and
`synapsis_workspace` instead. Treat those references as implementation notes to
translate during Phase 0 audit work.
