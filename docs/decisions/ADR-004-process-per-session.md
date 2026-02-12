# ADR-004: Process-Per-Session Architecture

## Status: Accepted

## Context

Need to manage concurrent coding sessions with streaming LLM responses, tool execution, and real-time client updates.

## Decision

Each session is a supervision subtree under a DynamicSupervisor:

```
DynamicSupervisor
└── Session.Supervisor (per session, :one_for_all)
    ├── Session.Worker    — state machine, orchestrates the agent loop
    ├── Session.Stream    — manages provider HTTP connection
    └── Session.Context   — token counting, compaction decisions
```

## Rationale

- Crash isolation: one session's provider timeout doesn't affect others
- Natural concurrency: 100 sessions = 100 independent process trees
- Clean shutdown: stopping a session kills its stream and context processes
- `:one_for_all` strategy: if stream crashes, worker restarts fresh (no stale state)
- State is in DB, not processes: Worker reads from Ecto on init, processes are ephemeral

## Key Principle

Processes hold **transient operational state** (current streaming connection, accumulated chunks, pending tool permissions). **Persistent state** (messages, session config) lives in PostgreSQL. On crash/restart, Worker rehydrates from DB.

## Consequences

- Must handle race conditions between DB writes and process state
- Session.Worker is the single point of coordination (serializes operations)
- Idle sessions can be hibernated or terminated after timeout to free memory
