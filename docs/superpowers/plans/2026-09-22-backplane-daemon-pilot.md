# Backplane daemon pilot: gates and acceptance checklist

Status: proposal and validation record; production integration blocked by open gates.

Latest dependency validation (2026-09-23): **runtime and MCP packages upgraded to published 1.7.9**, containing fixes for #42/#43. Six new consumer contracts pass; the combined regression run reports **564 agent tests passed and 144/145 MCP tests passed**, exit 2 due to a source-confirmed pre-existing MCP grant-fixture mismatch. See [upgrade evidence](#published-179-adoption-2026-09-23). ADR/profile acceptance and host integration remain open.

Related: [adoption plan](2026-09-22-backplane-agent-runtime-adoption.md), [proposed ADR-009](../../decisions/ADR-009-backplane-daemon-pilot-ownership.md).

## Completed handoff

- Commit `72cec7c`: `feat(agent): add Backplane runtime adapters and contract tests`.
- Published runtime pinned to `1.7.4`; provider, frozen catalog and module-tool adapters are implemented.
- Focused adapter validation before this commit: 102 passing tests (85 runtime and 17 core Gateway/skill/Executor lifetime), formatting and diff whitespace checks passed.
- No production routing, authenticated approval controller, MCP execution adapter or durable runtime Store was added.

## Historical full agent validation: failed gate

Executed on 2026-09-22 from the repository root at `72cec7c`:

```sh
mix test apps/synapsis_agent/test
```

Result: **505/530 passed; 25 failed; exit 2**, seed `430362`, elapsed test time 45.3 seconds. This is an agent-app suite run, not the full umbrella suite. Existing compiler warnings were also emitted.

Representative failure evidence:

| Area | Observed failure |
|---|---|
| `nodes/node_test.exs:132` | `KeyError` for atom `:model` on a string-keyed provider request |
| `nodes/node_test.exs:100`, `:212` | `KeyError` for missing `:pending_provider_states` in stream accumulator fixtures |
| `nodes/node_test.exs:155` | `BadMapError` when a test treats `{:ok, request}` as the request map |
| `query_loop_fork_test.exs:204`, `query_loop_context_test.exs:39` | Atom-key access to provider wire request fields |
| `daemon_test.exs:113`, `:151`, `:176` | Test process exits with `shutdown` |
| `daemon_recovery_test.exs:60`, `:214` | Recovery conditions do not become true before timeout |
| `daemon_submission_cancel_test.exs:355`, `:373`, `:409` | Caller timeout or reconciled run ID mismatch |
| `daemon_execution_test.exs:172`, `:224`, `:254`, `:373` | Missing terminal/CAS evidence or timed-out state transitions |
| `daemon_execution_test.exs:57` | Expected `offline`, received structured provider upstream error text |
| `session/worker_test.exs:78` | Atom `:model` access to a string-keyed provider request |

Paths above are relative to `apps/synapsis_agent/test/synapsis/agent/`, except `session/worker_test.exs`, which is relative to `apps/synapsis_agent/test/synapsis/`. This table groups representative symptoms, not a claim that all 25 failures share a cause.

### Baseline comparison completed

On 2026-09-22, the parent `e2ae52b` was extracted with `git archive` into `/tmp/synapsis-baseline-triage.VQv54j`. No worktree was created and no project source was reverted. Dependency sources and the test build were copied into the archive; `MIX_ENV=test MIX_TEST_PARTITION=baseline_triage mix compile --force` rebuilt umbrella source successfully (exit 0). The parent app manifest does not include the new runtime dependency/adapters. Separate test partitions isolated Concord/config/memory data.

Both suite runs used `mix test apps/synapsis_agent/test --seed 430362`:

| Revision | Test partition | Result | Exit |
|---|---|---|---:|
| Parent `e2ae52b` | `baseline_triage` | 432/457 passed, 25 failed, 41.9 seconds | 2 |
| Current `72cec7c` | `current_triage` | 505/530 passed, 25 failed, 43.2 seconds | 2 |

Comparison of complete test names and modules found **identical sets of 25 failures**, with no parent-only or current-only failures. The current agent suite adds 73 tests. This confirms that these failure identities predate the runtime adapter commit under the tested environment/seed; it does not make the suite green or prove there are no other defects.

### Failure disposition and causal evidence

| Group | Count | Evidence and disposition |
|---|---:|---|
| Provider contract/fixture drift | 9 | Four NodeTest failures, two QueryLoopContextTest failures, one QueryLoopForkTest failure, one WorkerTest failure and one daemon provider-error assertion. Tests still use atom-keyed requests, untagged `build_request` results, legacy accumulator maps or raw upstream error text. The current provider contract is tagged results with string-keyed wire maps and structured errors. Update fixtures/assertions while retaining semantic checks; explicitly decide whether legacy accumulator maps need compatibility support. |
| Cancellation cleanup reports `shutdown` | 7 | Three DaemonTest cases, one heartbeat deadline case, two submission/cancel cases and one execution crash case. A traced parent `daemon_test.exs:113` run proves Bypass returns `{:exit, {:exit, :shutdown, []}}` to the ExUnit on-exit runner after the cancelled HTTP handler exits. `Bypass.Instance.handle_info/2` records handler DOWN reasons and `Bypass.do_verify_expectations/2` re-raises them, including stubbed handlers. This is verified for that representative case; verify the other six before applying a shared fixture repair. Do not weaken cancellation or task-cleanup assertions. |
| Submission reconciliation loses its supplied ID | 3 | SubmissionCancelTest lines 355, 373 and 409. Daemon supplies an atom-keyed `:id`, but `Runs.normalize_attrs/1` excludes it from `@updatable_fields`; `do_create/1` therefore generates another ID. Reconciliation fetches the pre-generated ID rather than the stored record. A direct parent probe confirmed `requested != created.id`. This is a production defect, not a timing threshold problem. |
| Persistence fault/CAS contract mismatch | 5 | Two RecoveryTest cases and ExecutionTest lines 224, 254 and 373 configure `:agent_runs_kv_adapter` and expect `put_if`/scan failures. `Runs` directly aliases `Concord.Turso`, ignores that adapter, uses unconditional `put`, and turns scan failures into an empty list. A configured always-failing adapter still produced `:ok` from `list_by_status_result/1`. Restoring meaningful fault injection alone is insufficient: production conditional-write/error propagation guarantees need repair. |
| Finalizer-owner reconciliation | 1 | ExecutionTest line 172: after killing the finalizer during an observational terminal event, active ownership never clears before the timeout. Reproduced in both full suites; precise causal isolation remains open. Preserve its requirement that a durable terminal result survives owner loss without replay. |

An isolated parent persistence probe also demonstrated the underlying terminal race without timing dependencies:

```elixir
{:ok, running} = Runs.mark_running(created)
{:ok, _completed} = Runs.mark_completed(running, "probe complete")
{:ok, _cancelled} = Runs.mark_cancelled(running) # deliberately stale snapshot
Runs.get(running.id).status # => "cancelled"
```

Both transitions returned success. The reducer validates the supplied snapshot, while persistence unconditionally writes it; there is no atomic current-revision check spanning event/projection updates. This is a concrete pre-existing consistency defect. Do not paper over CAS tests, merely increase waits, or treat the matching failure sets as permission to activate the pilot.

Local evidence is retained in `/tmp/synapsis-baseline-triage.VQv54j`: `compile.log`, `baseline-test.log`, `current-test.log`, `persistence_probe.exs`, `persistence-probe.log`, `trace_shutdown.exs`, and `shutdown-trace-3.log`. These are local diagnostic artifacts, not CI or live-provider evidence. Probes used only isolated test storage and Bypass.

### Repair order

1. **Implemented and scoped-tested:** preserve caller-supplied run IDs on creation (including atom/string input contracts), without allowing later transitions to change identity. Duplicate/concurrent creation and the three reconciliation regressions pass; see below.
2. **Implemented and scoped-tested:** conditional lifecycle transitions, atomic creation/event/index writes, retry reconciliation, tagged scan/read/write failures, and fault fixtures at the real transaction boundary. See the consistency increment below.
3. **Completed:** repair stale provider fixtures and abort-aware Bypass fixtures without suppressing unexpected handler failures. Provider failure semantics, tool-scope assertions and actual cancellation evidence remain checked.
4. Recheck finalizer-owner reconciliation and the full agent suite after scoped repairs. The existing finalizer-owner test now passes with the persistence increment; this is test evidence, not a claim that every owner-loss scenario has been proved.

The baseline comparison above records the pre-repair state. The following records distinguish the identity increment from the subsequent consistency repair. No daemon cutover until the gate is satisfied.

### Identity repair: completed scoped increment

`Runs.create/1` now accepts caller-supplied `:id` and `"id"` only at creation, validates supplied UUIDs, and still generates an ID when omitted. Lifecycle updates cannot replace the ID. An already-resolved idempotency key continues to return its original run.

`Synapsis.AgentRun.Store.insert_new/1` in `synapsis_data` uses a Concord transaction with an absent-key comparison and a five-second timeout. Duplicate IDs return `{:error, :already_exists}` without resetting the existing run or appending another creation event. Concurrent creates of the same ID have one winner. Validation, reduction and lifecycle events remain in `synapsis_agent`.

Validation on 2026-09-22, with separate test partitions:

```sh
MIX_TEST_PARTITION=identity_green mix test \
  apps/synapsis_agent/test/synapsis/agent/runs_identity_test.exs \
  apps/synapsis_agent/test/synapsis/agent/runs_test.exs \
  apps/synapsis_agent/test/synapsis/agent/run_lifecycle_fault_test.exs
# 24 passed; exit 0; seed 442867

MIX_TEST_PARTITION=identity_reconciliation mix test \
  apps/synapsis_agent/test/synapsis/agent/daemon_submission_cancel_test.exs:355 \
  apps/synapsis_agent/test/synapsis/agent/daemon_submission_cancel_test.exs:373 \
  apps/synapsis_agent/test/synapsis/agent/daemon_submission_cancel_test.exs:409
# 3 passed, 14 excluded; exit 0; seed 816457
```

The eight new identity tests cover atom/string IDs, immutable transition identity, UUID validation, generated IDs, duplicate terminal records, concurrent creation and existing idempotency lookup. The three unchanged daemon tests verify reconciliation after submit-task death, repeated reconciliation/read failures, and create/fetch timeouts while preserving FIFO. Logs: `/tmp/synapsis-identity-green.log` and `/tmp/synapsis-identity-reconciliation.log`.

At this identity-only checkpoint, insertion was atomic but event/idempotency writes remained separate and terminal writes remained unconditional. The subsequent consistency increment below supersedes those limitations. The historical 25 failures describe the pre-repair revision.

### Terminal consistency: reviewed contract and implemented increment

Preserve [Wave 1 Track D](../../agent-runtime/WAVE1_CONTRACTS.md): a pure reducer, critical storage failures returned to callers, observational events allowed to degrade, and no blind side-effect replay. Extend the existing run/event storage boundary; do not add a second runtime journal.

Source review identified four write paths, all addressed by the consistency increment:

| Path | Pre-repair gap | Implemented repair |
|---|---|---|
| `Runs.apply_event/2` | Reducer checks the supplied snapshot, then event append and projection write happen separately | Conditionally commit the new projection, critical event and event-ID index together |
| `RunEvents.append_critical/2` | Event and index are separate writes; same-run event-ID reuse ignores body differences | Compare durable event identity/content; reject conflicting reuse; losing transitions append nothing |
| `Runs.transition/3` | Attribute merge can perform another unconditional write after `apply_event/2` | Merge permitted attributes before the atomic commit |
| `Runs.persist/1` and non-queued creation | Raw projection writes can bypass transition fencing | Raw persistence only acknowledges identical stored state; non-queued creation records its initial status in the atomic creation fact |

Implemented commit protocol:

1. Keep event construction and reduction in the agent layer. Pass expected/proposed `AgentRun` values and a serialized critical event to a data-layer API; data must not depend on agent event modules, PubSub or execution policy.
2. Read the stored run with errors preserved, normalize legacy maps for comparison with the expected run, and reject a stale snapshot. Use a transaction comparison against the exact stored value read to fence races between this read and the commit. Commit the projection, event and index in one success branch. Concord's current Turso engine supports decompressed `:value` comparisons; `:field` comparison is also available but uses exact atom/string field keys and does not supply legacy defaults.
3. Resolve duplicate event IDs against the durable event body and index, not only the capped `recovery_state.applied_event_ids` set. An exact retry returns the durable outcome without another write or observational publication; changed run, sequence, type or payload is a conflict. Preserve the original event identity across an uncertain commit, and read back before retrying. If readback also fails, report unresolved storage failure; do not invent success or re-execute tools.
4. Publish observational events only after the durable commit succeeds. Transaction comparison failure is distinct from storage failure: Concord returns `{:ok, %{succeeded: false}}` for the former. Tagged read/scan APIs must preserve storage errors instead of converting them to absence or an empty list.

Compatibility decisions are recorded in the Track D persistence amendment. `persist/1` keeps its result shape but rejects raw mutation with `:lifecycle_event_required`; its scheduler fixture now uses lifecycle transitions. Non-queued creation validates and records `initial_status` in `run.created`, with no later projection-only write. Creation atomically claims both the run ID and any idempotency key, so concurrent requests with different IDs and one key converge without an orphan run.

Legacy stored atom/string maps, compressed values and missing revision defaults remain readable. Before a transition, the store checks existing run events for facts ahead of the expected projection; unresolved history returns `:incomplete_event` even with a fresh event ID. Retrying a legacy event index without an atomic commit revision also fails closed. These records require explicit reconciliation; this increment performs no automatic migration or history repair. The per-run history check is linear in stored event count.

Twenty new `runs_atomic_test.exs` cases exercise real-store stale writes and barrier-controlled terminal/duplicate races, lost commit replies and failed readback, event-ID conflicts, retries beyond the reducer's 64-ID cache, immutable raw persistence, creation/idempotency races, tagged read/scan errors and legacy partial records. The existing projection-failure test now asserts that neither the fact nor the projection advances. Observational events follow successful commits; duplicates do not append them again. Lost commit acknowledgement may lose an observational event, which remains best effort.

Daemon fixtures now inject faults through the data-layer `get/2`, `prefix_scan/2`, and `txn/2` API instead of unused `put_if` hooks. Terminal counters count successful transactions. Existing readiness, degraded ownership, timeout, finalizer-owner and no-replay assertions remain intact.

The first full-suite check after implementation exposed three additional heartbeat timeouts. A read-only test formatter traced the preceding idempotency test returning with an active run and queued work, then the next setup deleting that run while the daemon still owned it (`Runs.fetch(active_run_id) == :not_found`). The completion test passed in isolation. The fixture now uses Bypass, asserts completion instead of ignoring a racing raw transition's result, and waits for ownership to drain before the shared-store cleanup. The diagnostic run was stopped after capturing this evidence; it is not passing test evidence. Trace: `/tmp/synapsis-atomic-order-probe.log`.

Final scoped validation: **75 passed, 14 excluded; exit 0**, seed `430362`, 2.5 seconds. It includes identity, atomic storage, lifecycle faults, reducer and scheduler tests, the complete daemon recovery file, four targeted execution cases (including finalizer-owner loss), and four heartbeat cases. Log: `/tmp/synapsis-atomic-review2.log`. All HTTP tests use Bypass; no live providers or production routing were exercised.

Final agent-suite revalidation:

```sh
MIX_TEST_PARTITION=atomic_suite_final mix test apps/synapsis_agent/test --seed 430362
# 542/558 passed; 16 failed; exit 2; 20.1 seconds
```

All 16 remaining complete test/module names match the pre-repair baseline: nine provider contract/fixture failures and seven cancellation-cleanup `shutdown` failures. There are no new failure identities in this run. The nine resolved cases comprise the three identity/reconciliation cases from the prior increment, five persistence-fault cases, and the finalizer-owner case. The terminal-timeout test was renamed from `put_if` to `transaction` and separately verified passing; failure-name comparison alone is not evidence for that rename. The three intermediate heartbeat timeouts no longer occur after the fixture-lifetime correction. Log: `/tmp/synapsis-atomic-suite-final.log`.

Changed-file formatting and whitespace checks passed. At that checkpoint the full agent gate remained failed; the following fixture increment closes it. No umbrella-suite, live-provider, production-cutover or Backplane durable-runtime-store claim follows from these checks.

### Provider and cancellation fixture repair: completed

The nine provider failures used obsolete assertions or incomplete stream fixtures. Tests now unwrap `{:ok, request}`, inspect string-keyed wire payloads (including Anthropic text blocks), preserve fallback tool-schema equality, and check the structured upstream error kind and HTTP status. Fork-scope rejection, assembled/static prompt content, fallback selection, model refresh and failed-run readiness assertions remain intact.

The two stream-resume fixtures now include `pending_provider_states`. The legacy-state test still removes the graph state's reasoning-signature field, but supplies the current accumulator shape. This is a fixture correction, not a promise to resume arbitrary legacy accumulator maps or replay originless signed provider state. Production codec and runtime behavior did not change in this increment.

The seven cancellation failures came from the shared hanging/controlled Bypass handlers. Cowboy sends their request process `:shutdown` when the client disconnects; Bypass records a callback that dies before returning as a failed invocation. The test-only `AbortableHTTP` helper arms exit trapping before the handler advertises request arrival, then recognizes only `{:EXIT, owning_connection_pid, :shutdown}` during its bounded wait. That path notifies the test and returns normally to Bypass. Unexpected exit senders/reasons still fail, callback exceptions remain uncaught, and an unreleased controlled request still times out as an error. Hanging scenarios now use `Bypass.expect`, replacing the ineffective stub exception. No dependency patch or expectation-verification bypass is used.

All seven lifecycle cases now explicitly observe the handler disconnect in addition to their existing cancellation, timeout, crash, drain and backpressure assertions. Three helper tests verify accepted connection shutdown and rejection of an unexpected connection reason or unrelated sender. Production processes and supervision are unchanged.

Validation:

| Check | Result | Local evidence |
|---|---|---|
| Provider fixture files plus daemon upstream-error case | 81 passed, 14 excluded; exit 0 | `/tmp/synapsis-fixture-provider.log` |
| Daemon, execution, submission/cancel and heartbeat files | 47 passed; exit 0 | `/tmp/synapsis-fixture-cancel2.log` |
| Complete agent suite, including three new helper checks | **561 passed; exit 0**, seed `430362`, 20.6 seconds | `/tmp/synapsis-fixture-gate.log` |

```sh
MIX_TEST_PARTITION=fixture_gate mix test apps/synapsis_agent/test --seed 430362
```

All 16 failures remaining after the persistence increment now pass, so all 25 original baseline failures are resolved across the scoped increments. Existing compiler warnings and deliberately induced fault logs remain; the result is an agent-suite check, not the full umbrella suite or CI. Next resolve ADR-009 and the unchanged pilot profile's dynamic catalog/MCP requirements before host integration.

## Source-level profile audit

Source: `apps/synapsis_agent/lib/synapsis/agent/daemon/toolsets.ex`, `Synapsis.Tool.ToolSearch`, `Synapsis.MCP.Server`, and `Runtime.ToolRegistry` at the implementation baseline.

| Existing profiles | Built-in names before MCP additions | Current admission blocker |
|---|---:|---|
| `assistant_basic`, `read_only` | 12 | `tool_search` |
| `assistant_workspace`, `reflect`, `heartbeat` | 20 | `tool_search` |
| `assistant_coding`, `coding`, `maintenance` | 22 | `tool_search` |
| `assistant_dream` | 14 | `tool_search` |
| `assistant_dream_todo` | 15 | `tool_search` |

The common names are `file_read`, `list_dir`, `grep`, `glob`, `memory_search`, `todo_read`, `session_summarize`, `skill`, `tool_search`, `agent_status`, `agent_discover`, `agent_inbox`.

`ToolSearch.execute/2` searches the global registry and marks matching deferred tools loaded. Returning those names without admitting them into both the runtime authority and the next provider catalog would advertise tools the run cannot call. Legacy daemon QueryLoop also keeps its bound `ctx.tools` and dispatch map: the source does not establish same-run activation there. Coherent activation in the pilot is a proposed contract, not a proven legacy behavior to copy. Merely allowing ToolSearch through the static backend would preserve that mismatch and global side effect.

Every profile also appends available trusted, non-deferred MCP registrations with `:none`/`:read` permission. `Synapsis.MCP.Server` registers these against its shared process. Killing the runtime caller does not cancel the shared server's in-flight remote operation. The current module backend therefore rejects them explicitly.

This is a source-level audit, not an inventory of connected MCP servers. Actual deployment registrations, schemas, availability and cancellation capabilities must be captured at pilot admission. Existing `resolve_for_query_loop/1` can omit missing/unapproved entries; the new pilot admission must compare requested names against resolved entries so omissions cannot silently change the selected profile.

Candidate: evaluate `read_only` unchanged after the discovery/MCP gates close. Do not equate this profile label with a read-only safety proof or alter the daemon policy implicitly. A separate static profile is an explicit alternative requiring its own accepted contract, not a local workaround.

## Catalog and MCP contract audit (2026-09-22)

Historical audit of the pre-upgrade packages. The missing upstream APIs identified here were published and adopted in 1.7.9; the [2026-09-23 update](#published-179-adoption-2026-09-23) supersedes the dependency-blocked status, not the host integration gates.

This is a source-backed design increment, not an implementation or activation result. Inspected the pinned Hex sources (`backplane_agent_runtime` 1.7.4 and `backplane_mcp_protocol` 0.6.2), their public APIs, and upstream main (`d485764cc31b74b109eb167aa3f7831931f61b5a`). Checked existing upstream issues before opening the two requests below. MCP implementation and lockfile use Backplane; older repository guidance mentioning Anubis is not evidence of the installed API.

### Findings and ownership

| Boundary | Implemented behavior | Disposition |
|---|---|---|
| Conversation catalog | `begin_tools/2` and `Execution.prepare_tool/4` read startup registry/authority; `ToolRegistry.register/2` only returns a new immutable value | Upstream [#42](https://github.com/gsmlg-opt/backplane/issues/42): no public atomic catalog publication boundary |
| Provider definitions | `Runtime.ProviderAdapter` reads `context.tools`; Conversation supplies startup provider context | Publish definitions, dispatch registrations and authority as one revision; changing only the adapter would be inconsistent |
| Discovery | ToolSearch mutates global loaded flags; QueryLoop retains `ctx.tools` and its bound map | Explicit pilot discovery semantics and eligibility decision required; never infer grants from search results |
| MCP operation identity | `Client.call_tool/4` returns the eventual response/error; `State.add_request_from_operation/3` generates its ID internally | Upstream [#43](https://github.com/gsmlg-opt/backplane/issues/43): expose a stable caller-owned operation handle or equivalent race-safe cancellation contract |
| MCP cancellation | `cancel_request/4` exists and recognizes logical IDs across retries; ordinary request callers are not monitored | API exists but its required ID is not returned while call_tool waits; caller/task death is insufficient |
| MCP local settlement | Ordinary cancellation retains the pending request if notification sending fails; input-resolution cancellation cleans locally and notifies best effort | Require bounded, documented local settlement versus delivery/remote outcome; do not treat notification as rollback |
| Host MCP owner | `MCP.Server.handle_call/3` waits synchronously in `call_tool/4` and ignores caller context | Host must delegate and monitor per-invocation work after the dependency contract is available; the shared owner must remain responsive |

Source pointers: `apps/synapsis_agent/lib/synapsis/agent/runtime/{tool_registry,tool_backend,provider_adapter}.ex`, `apps/synapsis_agent/lib/synapsis/agent/query_loop.ex`, `apps/synapsis_core/lib/synapsis/tool/tool_search.ex`, `apps/synapsis_mcp/lib/synapsis/mcp/server.ex`; dependency modules `Backplane.AgentRuntime.{Conversation,Execution,ToolRegistry}` and `Backplane.McpProtocol.Client`, `Client.State`, `Client.Operation`.

Both requests have GitHub type **Feature**, labels `internal request` and `enhancement`, and severity **High for pilot adoption, no production incident** in their bodies. Consumer blockers are linked at the rejecting admission clauses and MCP callsite. No private-state mutation, dependency patch, telemetry-based request-ID inference, `cancel_all_requests`, or shared-client termination is an acceptable integration path.

### Proposed catalog contract

Keep the chosen profile's initial membership and the session-start skill catalog intact. The skill catalog is a separate frozen context contract; a tool revision must not reinject skills or change assigned skill bodies. Keep the admitted permission snapshot, including destructive-action denial.

Represent each tool catalog revision as one host-validated bundle: provider definitions, bound registrations/backend contexts and matching runtime authority. The revision belongs to `{session_id, run_id, incarnation}`; it is not the Worker epoch, event cursor or Concord revision. Only trusted host code may construct the bundle. Validate schemas unchanged, availability, registration identity and policy before staging it.

Use the following boundary semantics for upstream/host acceptance, subject to the published API:

1. A provider attempt and its complete sequential tool batch use one catalog revision. Discovery may stage additions, but cannot authorize another call from the same response retroactively.
2. After that batch settles and before the next provider attempt, publish the complete next bundle atomically using an expected revision. Do not start the provider between definition and authority updates. Discovery may not synchronously wait for a boundary that requires its own effect to finish.
3. Pending effects and approvals retain their original descriptor/argument/revision binding. Do not replace their registration or reinterpret an approval. Cancellation, stale incarnation, conflicting revision or failed validation must leave no partially published catalog.
4. Exact duplicate publication must be reconcilable from the active revision; acknowledgement timeout is not permission to retry blindly. A failed activation must not be reported to the next model request as successfully available. No new provider attempt after an unresolved publication outcome.
5. Global `mark_loaded` flags are not per-run authorization. No other session acquires authority through this run's discovery. Registration replacement or revocation is checked again before dispatch.

**Remaining product decision:** existing profile selection does not define which discovered tools outside its initial names may join a daemon run. Proposed default is to keep that admission ceiling closed until an explicit host eligibility rule is accepted; that means full discovery is not yet enabled. Do not silently invent a broader allowlist, describe search-only results as activation, remove ToolSearch, or pre-admit all global tools. Upstream #42 enables coherent publication but cannot decide this host policy.

### Proposed MCP contract

Keep transport/session ownership in `synapsis_mcp`. Runtime calls must continue through the core Gateway permission and bound-registration checks; agent code must not acquire a production dependency on MCP client internals (its present `synapsis_mcp` dependency is test-only).

The host execution owner must correlate `{run_id, incarnation, invocation_id}` with a stable logical MCP operation handle while the call is pending. Use supervised workers and monitor the requesting effect. The shared MCP Server must process owner death/cancel/result messages while other calls are running. Handle registration and cancellation as one ownership protocol: if cancellation or owner death wins before the handle arrives, cancel the late handle or fence dispatch; never forget it.

Only cancel the target operation. Follow any protocol retry to its current wire ID using the supported logical handle. Bound cancellation/cleanup independently, release local monitors/timers/reply ownership, and ignore late replies. A sibling call and the shared client remain usable. If cancellation delivery fails, local settlement and remote uncertainty must remain distinguishable. An interrupted dispatched tool maps to `unknown_outcome`; neither killing its worker nor sending `notifications/cancelled` proves the remote effect stopped. No retry of uncertain tool effects.

### Ownership review and acceptance cases

ADR-006 still defines live reads through the session process and asynchronous completed-turn snapshots. ADR-008 still defines the default Worker engine and epoch behavior. Proposed ADR-009 deliberately changes execution authority only for an opt-in manual daemon run: Conversation owns execution; Worker owns host projection/control. Keep ADR-009 **Proposed** until the profile/discovery contract is accepted, then update architecture/guardrail references as part of integration. This audit does not silently amend accepted ADRs.

The proposed temporary paired subtree is consistent with stopping one execution on shell/runtime loss, but remains unimplemented and needs actual supervisor crash tests. A bounded host control task limits waiting; it does not establish whether a timed-out runtime call was applied. Reconcile before retrying and keep existing terminal atomicity/no-replay guarantees.

| Gate | Required deterministic evidence after upstream publication | Current status |
|---|---|---|
| Catalog publication | Discovery/provider/new-tool round trip, exact revision agreement, one dispatch; rejected bundle leaves old catalog intact | Not run; #42 blocked |
| Catalog races/security | Same-batch new call denied, stale/conflicting publication, pending approval, cancellation, changed incarnation, acknowledgement loss; no cross-session grant | Not run; #42 and host eligibility decision blocked |
| MCP ownership | Two concurrent calls, cancel A while B succeeds; owner death before/after handle registration; late response and response/cancel races | Not run; #43 blocked |
| MCP cleanup | Input-resolution retry retains handle, resolver cleanup, failed/hung notification, bounded local settlement and explicit remote uncertainty | Not run; #43 blocked |
| Session ownership | No graph/QueryLoop in pilot mode; shell/runtime crash stops paired effects, no automatic replay; fenced reconnect snapshot/cursor | Not run; host integration gated |

Next dependency step: consume published fixes for #42/#43, force-recompile the fetched packages, and run their consumer contract tests before enabling either admission path. Settle the host discovery eligibility rule before implementing catalog activation. Retain unchanged `read_only` as the candidate, with complete requested-versus-resolved name checks; no alternate static profile has been approved.

Validation for this increment is source/API review, issue readback, changed-file formatting, documentation links and diff whitespace only. Production changes are TODO comments; no behavior, dependency version or test was changed. The earlier 561-pass agent-suite record remains the latest execution evidence; it was not rerun for this design increment. No live provider, connected MCP inventory, remote cancellation experiment, umbrella suite or CI result is claimed.

## Ordered implementation and acceptance

### A. Resolve validation and design gates

- [x] Commit the independently tested adapters.
- [x] Run the full agent suite and record the failed gate accurately.
- [x] Prepare ADR-009 with live read ownership, event fencing, supervision, cancellation and recovery semantics.
- [x] Audit all built-in profiles at source level and identify shared discovery/MCP blockers.
- [x] Reproduce the parent baseline and compare all failure identities.
- [x] Group the failures and record confirmed persistence/fixture causes and remaining uncertainties.
- [x] Repair creation identity and verify duplicate/concurrent creation plus all three affected reconciliation cases.
- [x] Review the terminal event/projection transaction boundary and record remaining compatibility decisions.
- [x] Implement atomic lifecycle storage, settle raw-write/creation compatibility and pass the scoped consistency/recovery checks.
- [x] Repair the remaining baseline fixtures and pass the full agent gate (561 tests, exit 0).
- [x] Audit pinned and upstream catalog/MCP APIs, correct legacy discovery assumptions, and file Feature/internal requests #42 and #43 with scoped acceptance criteria.
- [x] Specify proposed catalog revision, per-call MCP ownership and cancellation boundaries; retain ADR-009 as proposed.
- [ ] Accept ADR-009 and the pilot profile; update affected architecture/guardrail references.
- [ ] Accept the host eligibility rule for discovered tools outside initial profile membership; search text/global loaded flags never grant authority.
- [x] Adopt published fixes for #42/#43 and add scoped consumer tests for catalog publication and MCP call ownership (1.7.9, six passing cases).
- [ ] Complete host catalog/MCP integration and remaining race/cleanup acceptance cases before admitting affected tools. Do not patch dependencies locally.

### B. Implement host integration after A

- [ ] Select and record exactly one backend at admission; existing backend remains the default.
- [ ] Preserve existing daemon permission semantics, assigned skill catalog and complete profile membership.
- [ ] Add the explicit pilot shell mode and temporary execution subtree described in ADR-009.
- [ ] Implement runtime event-to-domain projection, identity fencing and snapshot/event cursor reconciliation.
- [ ] Authenticate approval decisions, mint grants in trusted code, and handle denial, expiry, duplicate/stale resolutions and control-call timeout reconciliation.
- [ ] Map completion, cancellation, deadline, interruption and unknown outcome into existing daemon transitions without collapsing uncertainty into success.
- [ ] Preserve host turn snapshots through Session.Store; add no runtime journal or implicit replay.

### C. Prove activation criteria

- [ ] Deterministic dispatch-once tests: duplicate submission, admission failure and cancellation during startup never start both engines.
- [ ] Profile/skill tests: missing, stale, disabled and unsupported registrations fail admission; unchanged skill bodies load on demand.
- [ ] Security tests: cross-session/run/actor approval, stale incarnation, forged grant, changed arguments and expiry cannot dispatch tools.
- [ ] Reconnect tests: subscribe/snapshot races, duplicate deltas and old incarnation events cannot corrupt the projected transcript.
- [ ] Lifecycle tests: shell/runtime/task death, completion versus cancel, timeout versus grant, and terminal-store uncertainty have one visible outcome and no replay.
- [ ] Compatibility tests: relevant session read, server and web contracts plus the full agent suite pass; use Bypass, never live provider APIs.
- [ ] Rollback tests: changing the default affects only new runs; no already-dispatched work item reruns on the legacy engine.

Stop after this checklist is complete. Durable recovery and interactive-session migration require separate plans and acceptance criteria.

## Published 1.7.9 adoption (2026-09-23)

Updated only the two relevant Hex dependencies and their manifest constraints:

| Package | Previous lock | Current constraint / lock | Published outer checksum |
|---|---|---|---|
| `backplane_agent_runtime` | 1.7.4 | `== 1.7.9` / 1.7.9 | `a21fb746130a61ce219da87899e77db0a057e6e39465ee443936bb6816a18b98` |
| `backplane_mcp_protocol` | 0.6.2 | `~> 1.7.9` / 1.7.9 | `fb7b5aa00a1d0e8de1c8f5f86cd27381ff0986da3e9d8277951b6437f0e8a00e` |

Verified both releases exist and are not retired through the Hex release APIs. GitHub release `v1.7.9` targets `712527e4de8fe4a402306936e8781df812c8007d`; ancestry checks include #42's closing commit `e825cfc31c9234eee624514583f2050d4fca39d6` and #43's closing commit `941cfe004c36339c3416eec91745de2d599689cc`. Both issues are closed. The fetched package sources and lock checksums match those published versions. AI/skill packages and all transitive locks remain unchanged.

### Verified APIs and integration implications

- `Conversation.stage_catalog/2` and the effect's `backend_context.stage_catalog/1` stage a complete trusted bundle. Provider requests carry `catalog_revision` and canonical `tools`. Catalog revisions are independent of descriptor `tool_revision`; the new consumer fixture deliberately uses catalog revisions 1/2 with descriptor revision 7. Publication happens after the old batch; receipt reconciliation is limited to the 16 retained receipts and remains ephemeral.
- `Client.start_tool_call/4`, `await_tool_call/2`, and `cancel_tool_call/3` provide caller-owned handles. Only the creating process may await/cancel. Registration and notification delivery have separate finite bounds; awaiting does not itself cancel. Cancellation reports distinguish local settlement, notification delivery, and `remote: :unknown`.
- The existing host provider adapter still reads frozen `context.tools`. Before dynamic activation, it must use the runtime's request catalog consistently. The host ToolSearch backend still needs an accepted eligibility rule and staging integration. This dependency update does not enable discovery or remove the admission rejection.
- The existing MCP Server still uses synchronous `call_tool/4`. Future host integration must delegate to monitored per-call owners; because handles are owner-bound, another process cannot cancel a transferred handle directly. Explicit cancellation must be routed to its live owner; abnormal owner death is handled by the client. This update does not claim that existing facade callers acquire the new cancellation semantics automatically.

### Consumer validation

`catalog_publication_test.exs` exercises the published Conversation using a test-only discovery backend, host-admitted descriptors and the production host tool backend/Gateway. It verifies publication before the next provider attempt, same-batch denial, one allowed invocation, exact duplicate receipt reconciliation, wrong run/incarnation/revision and incomplete/unauthorized bundle rejection, and discarding a staged catalog on cancellation. It does not use the production HTTP provider adapter for dynamic definitions.

`tool_call_contract_test.exs` uses Bypass with the actual Synapsis transport builder and its pinned `2025-06-18` protocol. It verifies targeted cancellation alongside a sibling call, the explicit unknown remote outcome, foreign-owner rejection, owner-death notification, shared-client survival and synchronous API compatibility. These are dependency consumer tests, not production MCP Server ownership tests. Modern input-resolution retries, cancellation before registration, failed/hung notifications and all response/cancel races remain host-integration acceptance work; the existing MCP suite also tests its current transports and connection behavior.

| Check | Result | Local evidence |
|---|---|---|
| Force-compile both downloaded packages | Passed, exit 0 | `/tmp/synapsis-backplane-179-compile.log` |
| Six new catalog/MCP consumer contracts | Passed, exit 0; seed 626505 | `/tmp/synapsis-backplane-179-contract.log` |
| Complete agent and MCP suites | Agent **564 passed**; MCP **144/145 passed**; combined exit 2, seed 430362 | `/tmp/synapsis-backplane-179-regression.log` |

```sh
MIX_ENV=test mix deps.compile backplane_agent_runtime backplane_mcp_protocol --force
MIX_TEST_PARTITION=backplane_179_contract mix test \
  apps/synapsis_agent/test/synapsis/agent/runtime/catalog_publication_test.exs \
  apps/synapsis_mcp/test/synapsis/mcp/tool_call_contract_test.exs
MIX_TEST_PARTITION=backplane_179_regression mix test \
  apps/synapsis_agent/test apps/synapsis_mcp/test --seed 430362
```

The one MCP failure is `ServerTest` “revokes trusted MCP read-only admission live when source trust is removed”, line 209. It calls `Executor.execute_approved(tool, %{}, %{})`, expecting `{:error, :tool_disabled}` but receiving `{:error, :grant_required}`. Both the test and Executor are identical to committed `72cec7c`; the committed `execute_approved/3` rejects missing grants before any registry/client/dependency dispatch. This is source-confirmed pre-existing test drift, not a result of the new MCP cancellation API. The old-package full suite was not rerun; do not describe the current MCP suite as green. Per repository scope rules, the unrelated fixture remains unchanged.

No dependency source was patched, no permission check was weakened, and no production routing, approval controller, connected MCP inventory or live-provider E2E was added. Validation used Elixir 1.20.1 / OTP 29; full umbrella, CI and the older toolchain were not run. Existing compiler warnings remain. Hex also reports advisories for unchanged `mint` 1.9.3 and `cowlib` 2.19.0; security upgrades are outside this dependency pair's scope.

Next: accept discovery eligibility and ADR-009, then wire host catalog definitions and per-invocation MCP ownership with the remaining failure/race checks. The upstream API blockers are resolved; host integration and activation are not complete.
