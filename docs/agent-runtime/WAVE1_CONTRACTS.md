# Wave 1 Cross-Track Contracts

Frozen for Track B (typed completion). Tracks C and D implement against these
contracts; they are **not** implemented in the Track B PR.

## Track C — Capability policy (implemented in PR-02)

- Single evaluation boundary: `CapabilityPolicy.evaluate(tool_call, policy_snapshot, execution_context)` → `{:allow, grant} | {:approval_required, req} | {:deny, reason}`.
- Execution accepts a scoped grant via `Tool.Gateway.execute/3` / `execute_authorized/4`.
- `Executor.execute_approved/3` requires `:capability_grant`; bare calls return `:grant_required`.
- Missing session / policy context **fail closed**.
- Corrected `ask` semantics: read → allow; write/execute → approval_required; destructive → deny unless explicitly granted; unknown → deny.
- Unattended runs map approval needs to `:approval_unavailable` (never unbounded wait).

## Track D — Run facts / reducer (implemented in PR-03)

- Extend embedded `Synapsis.AgentRun` (Concord); no Ecto `agent_runs` table.
- `Synapsis.Agent.Runs.persist/1` returns `{:ok, run} | {:error, reason}` — never report success after a failed write.
- Critical lifecycle events (`RunEvents.append_critical/2`) block transitions on storage failure; observational events may degrade with telemetry.
- Pure `RunReducer.reduce(run_state, run_event) -> {:ok, new_state} | {:error, reason}` with no store/PubSub/clock side effects.
- Restart reconciliation via `RunReconciler.classify/2` maps incomplete runs to `failed` / `timed_out` / `unknown_outcome` (never blind side-effect replay).

Persistence amendment (2026-09-22):

- `Synapsis.AgentRun.Store` in `synapsis_data` atomically commits a critical event, its event-ID index and the run projection, conditioned on the expected stored snapshot. Creation also includes the idempotency index. Lifecycle reduction and observational publication stay in `synapsis_agent`.
- `Runs.persist/1` retains its tagged result shape but only acknowledges an identical stored snapshot; attempted raw creation or mutation returns `{:error, :lifecycle_event_required}`. Use lifecycle APIs for writes. `RunEvents.append_critical/2` delegates to `Runs.apply_event/2`, so it cannot append a fact without its projection.
- Typed-event retries require an identical envelope. Convenience transitions with an explicit `event_id` reuse the committed envelope when run, type and normalized attributes match. Duplicate retries return the current durable projection without another write or observational append. Conflicting reuse returns `:event_id_conflict`; stale snapshots return `:stale_run`.
- Non-queued creation remains supported and records `initial_status` in the creation fact. A legacy critical event ahead of its projection, an orphan event, or a retry through an index lacking an atomic commit revision returns `:incomplete_event`; no automatic history rewrite or tool replay is attempted.
- `Runs.fetch/1` distinguishes `:not_found` from storage errors. `list_by_status_result/2` propagates scan failures. Untagged compatibility read/list helpers retain their existing nil/empty fallbacks; coordination must use tagged APIs.
- Store fault fixtures use `:synapsis_data, :agent_run_store_adapter` with the actual `get/2`, `prefix_scan/2` and `txn/2` boundary. Operations have a five-second timeout. This stores existing host coordination records; it does not implement the Backplane runtime Store behaviour.

## Track E — Daemon / RunSupervisor (implemented in PR-04)

- `RunSupervisor` + `RunRegistry`: one temporary `RunCoordinator` per `run_id`.
- Permanent `Daemon`: admission, idempotent `submit/2`, `cancel/2`, `reconcile/0`, liveness pulse, bounded `status/0`.
- Manual submit forces `tool_profile: "read_only"` (R0 gate).
- Coordinators create sessions, consume typed `session.*` terminals, persist via `Runs`; never block the daemon mailbox on model/tool work.
- `trigger/3` for heartbeat/dream/schedule returns `:not_implemented` until Track F.

## Track F — Heartbeat via Daemon (implemented in PR-05)

- `Daemon.trigger(:heartbeat, …)` creates `AgentRun(kind: heartbeat, tool_profile: heartbeat)` and starts a coordinator.
- `LocalScheduler` loads **only** TOML/`Config.Store`; load failure → `degraded?` (no Ecto fallback).
- Execution terminal is authoritative; `Heartbeat.Delivery` is optional and never rewrites run status.
- Daemon liveness pulse remains separate from `last_heartbeat_success_at` / `heartbeat_failure_streak`.
- False `heartbeat_completed` on timeout/error is removed.

## Track G — Durable Routine Engine (implemented in PR-06)

- Normalized `Routine.Definition` with heartbeat TOML adapter (defaults: `Etc/UTC`, `misfire_policy: :skip`, `no_overlap: true`, `tool_profile: "heartbeat"`).
- Concord state/occurrence stores under `coord/routines/<id>/state` and `coord/routine_occurrences/<id>/<key>`; persist is fail-closed.
- Deterministic occurrence key `<routine_id>:<scheduled_for-UTC-iso>`; claim before `Daemon.trigger`.
- Controllable `Routine.Clock`; `Routine.Scheduler` persists `next_run_at` and reconciles on boot. `LocalScheduler` delegates (same process name for health).
- Policies: no-overlap skip, misfire `skip` / `run_once`, retry backoff + failure streak on routine state.
- Timezone fold policy: ambiguous → earlier UTC; gap → after-gap instant.
- Dream/schedule `Daemon.trigger` kinds remain `:not_implemented` until Track H / later.
