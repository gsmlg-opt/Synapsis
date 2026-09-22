# ADR-009: Backplane Daemon Pilot Ownership

## Status: Proposed

Date: 2026-09-22. Implementation baseline: `72cec7c`.

This proposes a limited exception to [ADR-006](ADR-006-in-process-sessions-and-concord-storage.md) and [ADR-008](ADR-008-gen-statem-session-shell.md) for explicitly selected daemon executions. It is not an accepted change to the default session architecture and does not enable routing.

## Context

The adapters introduced with `backplane_agent_runtime` 1.7.4 now use published 1.7.9. `Conversation` is a stateful execution owner with a private effect supervisor, finite budgets and a temporary child lifecycle. Running it alongside the current Worker graph or QueryLoop for the same work item would create competing execution owners.

Current `Daemon.Execution.execute_configured_session/7` submits through `sessions.send_message/2`. `Session.Read.live_snapshot/1` reads Worker state, while `Session.Supervisor` uses `rest_for_one` so host tasks survive Worker restart. Backplane cancellation intentionally stops its effect tasks. These are different lifecycle contracts, requiring an explicit mode boundary.

The baseline's 25 agent-suite failures were resolved by the local identity, atomic persistence and fixture increments. After upgrading both runtime and MCP packages to 1.7.9 on 2026-09-23, 564 agent tests pass, including three new catalog contracts. Three new MCP handle contracts also pass; the MCP suite has one source-confirmed pre-existing grant-fixture mismatch (144/145 passed). Backplane [#42](https://github.com/gsmlg-opt/backplane/issues/42) and [#43](https://github.com/gsmlg-opt/backplane/issues/43) are closed and their published APIs are available. Host integration, discovery eligibility and product cutover remain unapproved. See the [pilot checklist and validation record](../superpowers/plans/2026-09-22-backplane-daemon-pilot.md#published-179-adoption-2026-09-23).

## Proposed decision

### Admission and one execution owner

Select the backend once when a daemon run is admitted, record that selection in run metadata, and carry it through execution and recovery. The default remains the existing backend. Only explicitly opted-in manual daemon runs are pilot candidates; heartbeat, scheduled, dream and interactive sessions retain their current paths.

Before any provider/tool effect, resolve the complete host-selected tool profile, compare requested and resolved names, validate bound registrations and schemas, freeze the skill catalog and policy, and create the runtime authority. Missing or unsupported tools reject admission with a specific reason. No partial catalog, silent tool removal or automatic fallback is allowed.

The pilot branch must create a session shell in an explicit Backplane mode before admitting its prompt. That shell must never start graph execution or QueryLoop. `Conversation` alone owns provider attempts, tool dispatch, interaction state, canonical messages and execution termination. Daemon remains the owner of queue capacity, work-item state and finalization.

### Live reads and event projection

| State | Authority | Host-facing behavior |
|---|---|---|
| In-flight canonical transcript, queues and tool execution | Conversation | Worker projects domain messages and existing session events |
| Transient streaming display | Worker projection of runtime events | Existing session PubSub shapes, fenced to the active execution |
| Daemon queue and terminal run record | Daemon and its existing stores | Existing run APIs and terminal transition checks |
| Completed durable session turns | Session.Store | Existing append-per-turn snapshots; no runtime recovery claim |

Keep `Session.Read.live_snapshot/1` as the public read entry point. For the pilot, Worker is a view/control shell, not an independently advancing engine. Its projection may lag the canonical runtime at an event boundary; it must never report success, grant approval or start a tool based on a display delta alone.

Use `{session_id, run_id, incarnation}` to fence every projected event and control result. Preserve Worker epoch fencing separately; it is not interchangeable with a runtime incarnation. Assign a monotonic sequence to projected events in Worker and include the same cursor in its snapshot. Reconnecting clients subscribe first, fetch the snapshot, then discard buffered events through that cursor. Missing sequence or changed execution identity triggers a fresh snapshot rather than replaying effects.

Backplane subscriber events are transient and have no reconnect replay contract. Therefore the first pilot does not attempt to reattach a restarted shell to an independently surviving Conversation. This avoids claiming lossless reconstruction of streamed deltas from `Conversation.status/1`, which exposes committed state.

### Supervision and failure behavior

The legacy session subtree retains its current `rest_for_one` semantics. Pilot sessions use a distinct execution subtree whose shell and Conversation are temporary, significant children; `auto_shutdown: :any_significant` terminates the subtree when either exits. The subtree itself must be temporary under its parent. This proposal must be tested against the actual supervisor implementation before activation.

Keep a terminal Conversation alive until Worker has projected the outcome and requested the normal host snapshot. Teardown is an explicit host lifecycle action, not an automatic restart opportunity. Daemon monitors the execution subtree independently of the shell.

| Event | Required result |
|---|---|
| Browser disconnect | Execution continues within its original deadline; reconnect reads the live shell |
| Shell or Conversation death | Stop the paired subtree and linked effects; mark interrupted/uncertain as appropriate; never recreate the same execution automatically |
| User cancellation | Acknowledge acceptance separately from settlement; await terminal cleanup within a finite deadline |
| Provider/tool effect deadline | Preserve Backplane's `unknown_outcome` when effects may have started; stopping a BEAM task does not prove external rollback |
| Node restart | Reconcile previously running daemon records as interrupted through existing recovery; do not replay ephemeral runtime work |
| Completion races cancellation | Exactly one host terminal transition wins; stale events cannot change it or drain the queue twice |
| Terminal persistence/cleanup uncertainty | Keep a degraded reconciliation state visible; do not claim completion or dispatch a replacement execution |

Use supervised host tasks for runtime control calls. `prompt/2` and `resolve/3` have infinite internal call timeouts; host deadlines must bound waiting, and a caller timeout must be reconciled before any retry. Cancellation acceptance alone is not finalization evidence.

### Permissions and interaction resolution

Preserve the existing daemon admission policy deliberately, including its destructive-action denial; do not accidentally substitute an interactive `ask` policy or infer policy from a profile's name. An unattended run that needs approval fails closed. Explicitly attended operation additionally requires an authenticated resolver.

The resolver must authorize the requester against the session/run, look up the still-pending runtime interaction, and bind the decision to its `interaction_id`, `approval_id`, invocation, registration revision and argument scope. Only trusted host code mints the scoped operator grant. Never accept a serialized client-provided grant or copy model-supplied approval flags. Denial, expiry, duplicate resolution, cancellation and stale incarnation must have explicit outcomes.

The tool backend already validates the grant MAC, source, tool, arguments, run/session, expiry and matching approval ID, then rechecks the admitted policy and live registration. This does not implement caller authentication. Until the resolver is integrated, attended product approval remains unavailable. Approval expiry prevents late dispatch; the runtime effect/root deadline bounds the wait itself.

### Persistence and supported input

Use EphemeralStore only for runtime transitions. Completed host turns still go through Session.Store and existing asynchronous atomic turn snapshots. Do not serialize capability grants, credentials or backend context into session messages. Do not treat host snapshots as a conforming Backplane runtime Store.

The first pilot accepts one admitted daemon prompt. Do not expose steering, follow-up queueing, retry or engine switching for its session until their host contracts are separately implemented; return a clear unsupported operation rather than silently routing through the legacy engine. Existing interactive sessions retain their current API behavior.

Rollback changes backend selection only for newly admitted runs. An already-dispatched work item is never rerun on the legacy engine as fallback. A later human-requested attempt receives a new execution identity after uncertainty is reviewed.

## Pilot profile gate

Recommend evaluating the existing `read_only` profile first, preserving its exact contents and existing policy. Its name does not prove every operation has no side effects: it includes discovery, inbox consumption and session summarization. All ten built-in profiles currently include `tool_search`; the production runtime catalog rejects it. Trusted non-deferred read/none MCP tools may also be appended, and these are process-backed registrations currently rejected by the backend.

Consequently no existing profile is presently eligible unchanged. First resolve catalog updates and per-invocation MCP cancellation, or explicitly approve a separately named static pilot profile as a changed product contract. This ADR does not create such a profile or authorize trimming an existing one.

The [source/API audit and proposed contracts](../superpowers/plans/2026-09-22-backplane-daemon-pilot.md#catalog-and-mcp-contract-audit-2026-09-22) distinguish legacy discovery from the desired pilot behavior. Legacy ToolSearch changes global loaded flags, but daemon QueryLoop retains its bound definitions and dispatch map. Coherent per-run activation is therefore a proposed behavior change, not established legacy parity. The admission rule for discovered names outside the selected profile must be accepted before implementing activation; discovery text alone never widens authority. Keep the session-start skill catalog frozen independently of tool catalog revisions.

## Consequences and acceptance

- Accepting this ADR would make Conversation the execution authority only for the opt-in pilot and would deliberately stop pilot work on shell loss. Legacy task-survival behavior remains unchanged.
- Before implementation, update the applicable architecture/guardrail text to describe the limited exception; leave current accepted ADRs intact while this document is proposed.
- Activation requires the [pilot checklist](../superpowers/plans/2026-09-22-backplane-daemon-pilot.md), including failure triage, profile parity, authenticated approval, reconnect sequencing and supervisor crash tests.
- Durable runtime recovery, interactive migration, collaboration, compaction and MCP protocol redesign remain separate work.
