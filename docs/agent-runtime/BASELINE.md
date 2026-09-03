# Agent Runtime Implementation Baseline

**Status:** Active for PR-00 / Track A onward  
**Reviewed baseline commit:** `0d6cc714ec16b34c8c191f158fe82c8a6ef08cf8`  
**Review date:** 2026-09-03  
**Authority:** [SYNAPSIS_AGENT_RUNTIME_PLAN_PRD_IMPLEMENTATION_TASKS.md](../SYNAPSIS_AGENT_RUNTIME_PLAN_PRD_IMPLEMENTATION_TASKS.md)

## Preserved architecture (ADR-006)

This program must preserve [ADR-006](../decisions/ADR-006-in-process-sessions-and-concord-storage.md):

- sessions remain node-local;
- Concord remains the embedded coordination store;
- PostgreSQL and Oban must not be reintroduced;
- graph/runtime transitions remain reducer-oriented;
- schedules remain node-local;
- current session supervision and per-session task supervision remain the execution foundation.

## Corrections vs older daemon design

Earlier material (including the removed `SYNAPSIS_AGENT_DAEMON_DESIGN_FOR_CODEX.md`) is superseded by the runtime plan above. Current-code corrections include:

- extend the existing embedded `Synapsis.AgentRun` / Concord model — do not add an Ecto `agent_runs` table;
- do not restore an Ecto `Heartbeats` context; remove obsolete DB fallback from the local scheduler;
- do not introduce Oban; evolve the node-local scheduler instead;
- the daemon is a logical control plane, not a serial LLM/tool executor;
- reuse session / graph / QueryLoop — do not build a second agent loop.

## Explicit non-goals

- OpenClaw channels, gateway protocol, device pairing, voice, Canvas, or mobile nodes;
- chat-channel aggregation (Slack, Telegram, WhatsApp, Discord, etc.);
- multi-node run ownership or distributed singleton election;
- PostgreSQL, Ecto persistence for runs/routines, or Oban;
- a second agent engine parallel to the existing graph/QueryLoop runtime;
- autonomous destructive mutation before a real OS isolation sandbox (R2).

## Delivery gates

| Gate | Capability |
|---|---|
| **R0** | Reliable manual daemon runs, typed outcomes, cancellation, restart reconciliation (read-only tools) |
| **R1** | Heartbeat, dream, scheduled routines (read-only + scoped reflection writes) |
| **R2** | Sandboxed autonomous file/shell mutation |

## Start order

1. **PR-00 / Track A** — deterministic test harness and interactive-session characterization (this baseline).
2. **Wave 1** — Tracks B (typed events), C (capability policy), D (run facts/reducer) in parallel after contracts freeze.
3. **PR-04 / Track E** — Daemon + RunCoordinator only after B/C/D merge.
