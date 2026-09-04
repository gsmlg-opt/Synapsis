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

## Track E — Daemon / RunSupervisor (next)
