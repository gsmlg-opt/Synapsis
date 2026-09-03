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

## Track D — Run facts / reducer (next)

- Extend embedded `Synapsis.AgentRun` (Concord); no Ecto `agent_runs` table.
- `Synapsis.Agent.Runs.persist/1` must return `{:ok, run} | {:error, reason}` — never report success after a failed write.
- Critical lifecycle events block transitions on storage failure; observational events may degrade with telemetry.
- Pure `reduce(run_state, run_event) -> {:ok, new_state} | {:error, invalid_transition}` with no store/PubSub/clock side effects inside the reducer.
- Restart reconciliation must classify `unknown_outcome` rather than blindly replaying uncertain side effects.
