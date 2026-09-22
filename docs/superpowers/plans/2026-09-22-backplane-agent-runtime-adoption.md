# Backplane Agent Runtime adoption research and plan

Status: published 1.7.4 adopted; provider and module-tool adapters implemented and fixture-tested, including skill loading, scoped approval and cancellation. Production routing remains proposed.

## Recommendation

Adopt `:backplane_agent_runtime` incrementally, beginning with provider and tool adapter contract tests using `EphemeralStore`. Target one bounded daemon execution as the first product integration after compatibility and ownership gates pass. Keep interactive graph sessions on the existing runtime initially.

Do not replace `Session.Worker`, QueryLoop, daemon orchestration, and persistence together. The package provides a bounded conversation/effect engine; Synapsis still owns product sessions, provider transport, permissions, tools, skills, collaboration, and presentation.

The prototype remains internal. The built-in tool-schema blocker is resolved in 1.7.4. Production daemon cutover still requires authenticated host approval resolution, dynamic MCP catalog handling, and an explicit decision about live state ownership. Durable runtime recovery is an optional later architecture change, not a prerequisite for testing or using the package in memory.

## Research baseline and evidence

| Item | Verified baseline |
|---|---|
| Synapsis | `main`, `e2ae52b204f24cb6bb941868d946ead32f8659fa` |
| Published package | `backplane_agent_runtime` `1.7.4`, published 2026-09-22 |
| Hex release checksum | `69f0cd011df3e8a10138135a7da2c709f3b1d24013a68bd52b6026b6e05e9d0e` |
| GitHub release target | `40b886d101881045f302764474ba1a621806761e`, tag `v1.7.4` |
| Package requirements | Elixir `~> 1.18`, no runtime dependencies, MIT |
| Local validation | Elixir 1.20.1 / OTP 29 |
| Repository CI configuration | Elixir 1.18 / OTP 28 |

Primary sources: [Hex package](https://hex.pm/packages/backplane_agent_runtime), [release metadata](https://hex.pm/api/packages/backplane_agent_runtime/releases/1.7.4), [published tarball](https://repo.hex.pm/tarballs/backplane_agent_runtime-1.7.4.tar), and [GitHub release](https://github.com/gsmlg-opt/backplane/releases/tag/v1.7.4). Contract research used the downloaded artifact's `README.md`, `EMBEDDING.md`, `SCHEMAS.md`, `PERSISTENCE.md`, and implementation. The current upstream repository is `gsmlg-opt/backplane`.

The initial 1.7.3 research found unsupported `anyOf` and four warnings on Elixir 1.20. These were reported as upstream #40/#41, now closed and verified against the published 1.7.4 artifact. No local dependency patch, schema stripping, or warning suppression is used.

### Executed checks

| Check | Result | Evidence boundary |
|---|---|---|
| Fetch and force-compile published `1.7.4` | Passed | Locked Hex artifact; only the runtime package lock entry changed |
| `MIX_ENV=prod mix compile --force --warnings-as-errors` on Elixir 1.20.1 / OTP 29.0.2 | Passed, exit 0 | Standalone published artifact, no warning suppression |
| Same strict package compile on Elixir 1.18.4 / OTP 28.5 | Passed, exit 0 | Separate artifact build path; not a GitHub CI run |
| Actual skill schema and invocation | Passed | Locator/name/both validation, invalid inputs, real Gateway and skill body loading |
| HTTP conversation proof | Passed | Bypass OpenAI tool round trip; Anthropic signed reasoning/image replay and affinity rejection |
| Provider/runtime/Gateway/skill regression run | Passed: 344 tests | 274 provider, 55 runtime, 15 Gateway/skill; before final additional lifecycle/reasoning cases |
| Provider increment focused revalidation | Passed: 120 tests | 49 HTTP adapter tests (including both link policies), 56 runtime, 15 Gateway/skill |
| Tool adapter increment focused revalidation | Passed: 102 tests, exit 0 | 85 runtime (including production HTTP/skill, catalog and backend), 17 Gateway/skill/Executor lifetime tests; cancellation crash logs are deliberately induced |
| Scoped formatting, diff whitespace, document links | Passed | Changed files only; unrelated compiler warnings remain |
| Durable store conformance and crash tests | Not run | No host runtime store adapter exists yet |

The strict checks above apply to the package, not the entire umbrella: existing unrelated Synapsis compiler warnings remain. No live provider API, production daemon cutover, or durable recovery was exercised.

## Existing architecture to preserve

Required design reading:

- [ADR-006: in-process sessions and Concord storage](../../decisions/ADR-006-in-process-sessions-and-concord-storage.md), especially live read authority, task supervision, and turn-boundary snapshots.
- [ADR-008: gen_statem session shell](../../decisions/ADR-008-gen-statem-session-shell.md), especially input queues, advisory steering, and cancellation.
- [Guardrails](../../guardrails/GUARDRAILS.md).
- [Codex skills catalog context research](../../codex-skills-catalog-context-implementation.zh-CN.md). Preserve the implemented catalog/loader separation; runtime adoption is not a new skills design.

Current daemon execution is `Daemon` → `Daemon.Execution.start_inner` → `execute_session` → tool-profile resolution/session creation → `execute_configured_session` → `sessions.send_message` → `Session.Worker`. Replacing a coordinator alone would not replace this execution engine. Never dispatch both the existing session loop and a Backplane conversation for the same work item.

`Session.Worker` is a `:gen_statem`; graph mode is the default and assistant mode uses QueryLoop. The existing session supervision tree allows tasks to survive a Worker restart and fences messages by epoch. Backplane `Conversation` has a private linked task supervisor and a temporary child lifecycle. These restart semantics are materially different.

The current Concord dependency uses the embedded Turso engine. Some older architecture text mentions Raft; do not use that text as evidence of the installed engine. Storage remains behind `synapsis_data`, with no PostgreSQL dependency.

## Responsibility and proposed interfaces

Runtime-dependent adapters live in `apps/synapsis_agent/lib/synapsis/agent/runtime/`; retain existing app dependency direction. Provider mapping, frozen catalog admission, and the module-tool backend are implemented. Presentation integration remains proposed.

| Concern | Owner and integration boundary |
|---|---|
| Bounded provider/tool loop | Backplane `Conversation`, exactly one owner per execution; do not also start `ExecutionController` |
| Daemon admission, queue, cancellation request, finalization | Existing `Daemon` / `Daemon.Execution`; one selected execution backend |
| User session identity, configuration, API/UI contracts | Synapsis; explicit projection/ownership decision before product cutover |
| Provider bridge | `Runtime.ProviderAdapter`, implementing `ConversationAdapter` over `Synapsis.Provider.Adapter.stream/3`; `ProviderMessages` and `ProviderEvents` preserve domain history/events |
| Provider wire formats, credentials, HTTP and retries | Existing `synapsis_provider` and `backplane_ai_protocol` |
| Tool dispatch and host authorization | `Runtime.ToolBackend` uses Gateway authorization and `execute_authorized/5` with the admitted registration |
| Run-local tool catalog and authority | `Runtime.ToolRegistry.admit/3` maps frozen approved registrations and explicit safety metadata |
| Skills | Existing assigned catalog, prompt renderer, `skill` tool, and `backplane_skill_protocol` |
| Live output/event translation | Proposed `Runtime.EventMapper`; Synapsis PubSub/API payload compatibility |
| Collaboration and work-item scheduling | Existing Synapsis implementations; package collaboration wrappers are unsupported |
| Optional durable runtime storage | Data-only atomic APIs in `synapsis_data`; Backplane `Store` adapter in `synapsis_agent` |

### Provider contract

- `ConversationAdapter.stream(request, context)` returns a lazy Enumerable. Bridge Synapsis mailbox events with a monitored stream resource; keep HTTP/provider execution asynchronous.
- Obtain credentials, provider configuration, system instructions, and frozen tool schemas from trusted context. The runtime request supplies serializable history and execution identities, not an automatically populated provider tool catalog.
- Map text, reasoning, tool-start/argument/completion, usage, and terminal events to the documented runtime vocabulary. Assemble the terminal assistant message with stable tool IDs, names, and parsed argument maps. Reject duplicate tool IDs and EOF without a terminal event.
- Preserve images, multimodal history, and `Part.Reasoning.provider_states` with their protocol/model/endpoint affinity in canonical content. Provider-state events are not arbitrary extra runtime events; retain their data in the terminal representation. Do not reuse `StreamAccumulator` as a lossless bridge without addressing its usage handling.
- Carry `run_id`, `incarnation`, `turn_id`, `step_id`, and `attempt_id` through tracing and stale-event checks. Keep runtime work limits separate from token limits and QueryLoop turn limits.
- Cancel provider tasks on runtime effect cancellation, consumer death, and timeout. A `Stream.resource` finalizer alone is insufficient when its consumer is killed; provider tasks live under a separate supervisor. Test owner monitoring and absence of orphan HTTP/stream tasks.

### Tools, permissions, and skills

- Freeze approved registry entries for each run and pass expected entries to the Gateway to reject registration replacement. Preserve project root, working directory, session/run identity, policy snapshot, skill catalog, and skill loader in trusted backend context.
- Runtime descriptor revisions are positive integers. Runtime policy has one `tool_revision` for all grants. Use one explicitly defined per-run catalog revision consistently across descriptors and authority; do not parse unrelated host tool version strings as revisions.
- Define `read_only`, `retry_safe`, and `parallel_safe` explicitly, defaulting conservatively. Host `permission_level: :none` does not prove an operation is read-only or retry-safe. Runtime tool execution is sequential even when `parallel_safe` is true.
- Keep Gateway permission checks authoritative for the first integration; runtime allowlists impose an additional bound. Route any interaction through one correlated host approval flow, preserving grant argument scope/MAC, expiry, cancellation, and permission rechecks. Never auto-resolve runtime approval using model-provided fields or display duplicate prompts.
- Inventory every selected built-in and MCP schema before admission. Runtime `1.7.4` supports the required object `anyOf` alongside constrained `oneOf`, but still has a strict schema subset. Do not strip unsupported constraints or mechanically rewrite `anyOf` to `oneOf`.
- Every built-in daemon profile inherits `skill` from `Daemon.Toolsets.@basic`. The unchanged skill schema allows locator or compatibility name through `anyOf`; all 10 built-in profile schema checks now pass. This does not establish configured MCP schema compatibility or dynamic discovery behavior.
- Preserve metadata-only skill catalog context and on-demand full-body loading. Freeze the session's assigned catalog, honor exact locators and visibility rules, and never preload every skill body as a runtime workaround.
- Account for `tool_search` and MCP discovery. A fixed catalog must not advertise successful discovery of a tool that the runtime cannot subsequently call. Before selecting a production profile, prove required tools are admitted up front or obtain an approved registry-update design. Do not silently remove tools from an existing profile.

### Lifecycle and user-visible semantics

- `prompt`, `steer`, `follow_up`, and `resolve` use infinite GenServer call timeouts internally. Call them from supervised host tasks with explicit operation deadlines and reconciliation; never block `Session.Worker` or a request process. A caller timeout is not evidence that the operation was rejected.
- Backplane steering appends a durable user message after a complete provider/tool batch. ADR-008 steering is advisory input to the next system prompt and must not become transcript history. Do not map the APIs directly. Keep interactive steering on the current engine in the first pilot.
- A completed root run cannot accept another prompt. Start a new runtime run from canonical committed history for the next host turn; preserve the host session identity independently.
- Cancellation acknowledgement means accepted, not fully stopped. Wait for effect shutdown/cleanup before finalizing the host work item. Represent interrupted side effects as unknown where necessary, rather than success or safely retriable failure.
- Subscriptions are transient, and `status/1` returns last committed state, not all live partial output. A host reconnect path must reconstruct the existing live UI contract without claiming committed status includes every delta.

## Ownership and persistence decision

Use `EphemeralStore` for adapter validation. It provides runtime transition commits in memory and makes no restart-durability claim. This avoids adding a durable journal merely to evaluate the package.

For a daemon pilot, the recommended proposed design is that `Conversation` owns the bounded execution and `Session.Worker` is the session-facing shell/projection for that mode. This is an explicit exception to ADR-006's current live read authority and requires an ADR amendment before cutover. Define authoritative reads, reconnect snapshots, event sequencing, shell restart, and engine death behavior there. An in-memory store alone does not resolve the ownership conflict.

If preserving the Worker as the sole live execution authority is mandatory, evaluate embedding the package's lower-level kernel/execution primitives inside that owner instead. That is a larger integration, with host-owned effect scheduling and recovery responsibilities; it is not the same adapter plan and should not be implemented implicitly. Default to leaving the current production path in place until the ownership decision is accepted.

Durable runtime recovery is a separate later phase. Backplane requires acknowledged atomic commits containing run state, transitions, effects/outbox information, CAS revision checks, and incarnation fencing. ADR-006's asynchronous turn snapshot is not a conforming runtime Store implementation.

For durable mode, expose a generic atomic data-layer operation and implement the runtime behavior above it. Concord Turso already supplies transaction predicates such as existence/modification revision; `{:ok, result}` with `result.succeeded == false` must become a conflict. Separate runtime aggregate revision from Concord's global modification revision and preserve timeout/idempotency reconciliation.

Do not rely on `Kernel.execute`'s empty transition `effects` list to conclude no effect metadata needs retention: execution intents reside in the run, and outbox metadata must survive the commit. Tool-result commit and conversation-message commit are separate; reconcile retained `run.tool_results` without redispatching the tool. Restored nonterminal runs enter `recovery_required`, with no automatic effect replay.

Before enabling durable mode, amend ADR-006, evaluate full-run/transcript write amplification, define retention and secret handling, and run `StoreConformance` against the actual Turso-backed adapter. Preserve existing host turn snapshots as a separate contract.

## Phased implementation plan

Each phase is a separate reviewable change. The first increment established the test-only proof; the second adopted 1.7.4 and implemented the provider adapter; the third implements module-tool admission, approval and cancellation. Full Phase 1 exit criteria remain open for complete suite validation and product-facing approval integration.

### Completed first increment — test-only proof

- The first increment pinned `== 1.7.3` with `only: :test`; the second supersedes that pin with `== 1.7.4` as a normal dependency so adapter modules compile in all environments. No session/daemon routing or supervisor changes.
- `test/support/backplane_runtime_proof.ex` provides an ephemeral Conversation harness, deterministic provider, inert echo tool, and test-only Gateway backend. Runtime calls are made through a bounded supervised test task, following the OTP ownership/cancellation review.
- `test/synapsis/agent/runtime/backplane_contract_test.exs` covers a provider/tool/provider turn, execution identities, usage/text events, host context, runtime grant denial, host denial, unattended approval rejection, stale registration, malformed/duplicate calls, invalid arguments, missing terminal, provider failure, and cancellation of the runtime-owned fake provider.
- `test/synapsis/agent/runtime/backplane_schema_compatibility_test.exs` audits the built-in schemas in all 10 daemon profiles through the published validator. All are now schema-compatible. Schema acceptance is not evidence that arbitrary arguments are valid or the tools execute correctly. MCP names are explicitly excluded from this built-in inventory; configured and deferred MCP schemas remain an admission gate.
- The previous skill-blocker characterization is replaced with successful real skill loading, and a separate HTTP conversation test verifies the provider receives the returned body.

### Completed second increment — provider stream adapter

- `Runtime.ProviderAdapter.stream/2` returns a lazy stream. Trusted context supplies atom-keyed `request_options`, plus `provider_config` and `tools`; provider credentials and schemas are never taken from model-generated history. Codec affinity comes from the same config used for decoding.
- The adapter starts a supervised relay under the existing provider Task.Supervisor. Each relay isolates untagged provider messages, uses a unique forwarding token, monitors its consumer, and starts the HTTP task with the new opt-in `Synapsis.Provider.Adapter.stream/3` `link: true`. Default `stream/2` stays unlinked. The link covers the startup window that a later watchdog/finalizer could miss.
- Absolute attempt deadlines (default 30 seconds) and cumulative host event byte limits (default 1 MiB) bound the bridge. Stream finalization, timeout, consumer death, relay crash, and provider crash stop the paired processes. These checks prove BEAM task cleanup, not a remote service rolling back work.
- `ProviderEvents` preserves text, reasoning, indexed tool IDs/arguments, usage mode/source, and signed provider state in canonical terminal blocks. Missing terminals, incomplete tools, duplicate IDs, and unsupported events fail explicitly. `ProviderMessages` converts host domain parts/history including images and tool results without adding provider wire formats to agent code.
- Bypass tests cover HTTP failures, truncated streams, lazy dispatch, tool definitions, a complete HTTP → real skill Gateway → HTTP turn, signed Anthropic reasoning replay without duplication, image history, and model-affinity mismatch rejection. No live LLM endpoint is used.

### Completed third increment — frozen catalog and module-tool backend

- `Runtime.ToolRegistry.admit/3` accepts host-selected bound registrations, trusted context and an explicit positive catalog revision/caller. It returns the runtime registry, provider tool definitions and matching authority together. Admission is all-or-nothing; duplicate, missing, stale, unavailable, unsupported-schema and mismatched-definition entries fail before dispatch. Schemas are checked unchanged using the pinned validator. Safety defaults are all false.
- The admitted context freezes the host policy snapshot and preserves project/session/run and assigned skill context. Snapshot scope must match. Preexisting approval flags, capability grants and input are removed. Schema and description must match the bound module registration; approval fields never come from model arguments.
- `Runtime.ToolBackend` checks operation identity/revision, arguments and the live registration, then authorizes through Gateway. Attended approval uses one runtime interaction with a fresh `approval_id`. Resolution requires a MAC-valid, unexpired operator grant for the exact tool, arguments, run and session. Boolean approval, wrong correlation, forged/expired/unbound grants and scope mismatches are rejected. Registration and the frozen policy are checked again before dispatch. This is not a mid-turn policy refresh.
- Approval expiry prevents late dispatch. Waiting itself is bounded by Conversation's effect/run deadline; the shorter approval expiry does not independently wake the runtime waiter. The eventual host resolver must authenticate the operator, mint the scoped grant and reconcile bounded `resolve` calls. No UI/controller resolver is wired here.
- Gateway remains the only execution path. The host Executor adds opt-in `tool_task_link: true`; existing callers retain unlinked lifetimes. The backend enables that option, applies a finite tool deadline and disables retries. Tests observe actual tool PID termination after cancellation, effect timeout and Conversation owner death, and verify the default unlinked behavior still survives owner death. This proves BEAM task cleanup, not rollback of external effects or OS grandchildren.
- Host tool timeout/exit becomes `unknown_outcome`. Backplane effect deadlines also produce `run_cancelled` with `unknown_outcome` and `deadline_exceeded`; the approval test asserts that published contract. Pending interaction state is cleared and late resolution is rejected. No timed-out tool is automatically retried.
- The Bypass HTTP → actual assigned skill → HTTP test now uses the production catalog/backend. The earlier proof-only Gateway backend remains confined to the initial package contract tests.
- Process-backed tools, deferred registrations and `tool_search` are explicitly rejected. Their shared-process cancellation and catalog-update contracts remain open; existing daemon profiles must not be silently trimmed to fit this subset.

Next: settle the daemon pilot's live-owner/restart ADR and profile/catalog requirements, implement authenticated host interaction resolution, and finish MCP/dynamic catalog contracts before production routing. Full agent-suite validation remains a later gate. This increment changes neither daemon/session routing nor persistence.

### Phase 0 — compatibility and ownership decisions

Allowed scope: this plan, an ADR proposal, schema inventory/report, and upstream request preparation.

1. Audit complete resolved daemon tool schemas, including configured MCP tools and deferred discovery requirements. Record each unsupported construct and affected profile.
2. Required `skill` schema support is verified in 1.7.4. Request upstream support for any additional unsupported constructs found in MCP admission; do not locally fork or weaken schemas.
3. The 1.7.4 package passes strict compilation on Elixir 1.18/OTP 28 and 1.20.1/OTP 29 and is pinned. Recheck these gates on future upgrades.
4. Decide the bounded pilot profile and accept its ownership ADR before routing production work to it. Explicitly document restart and live-read behavior.

Exit: exact package/version and schema gates documented; architecture choice accepted before product cutover. Test-only adapter work may proceed independently of unresolved production gates.

### Phase 1 — adapter contract proof, no production routing

Allowed scope: `apps/synapsis_agent/mix.exs`, `mix.lock`, runtime adapters under `synapsis_agent`, and focused tests. Host API gaps addressed by the adapter increments are opt-in linked task lifetimes in provider `Adapter` and core `Executor`; existing callers retain their defaults.

1. Add the published runtime dependency; initially pin the selected release exactly so later patch changes are deliberate.
2. Build a test-only `Conversation` harness using `EphemeralStore`, a fake provider, and inert tools. Establish terminal event and identity mapping before real host dispatch.
3. Implement provider stream and tool Gateway adapters with explicit lifecycle cleanup and conservative catalog authority.
4. Test host permission interaction, cancellation, stale registration, skill context, and canonical history conversion. Use existing provider fixtures/Bypass; never call live LLM APIs.

Exit: focused tests pass for successful completion, provider error, missing terminal, malformed/duplicate tool calls, usage/reasoning preservation, permission deny/expiry, cancellation races, owner death, and absence of orphan tasks. Known unsupported schemas must fail before backend invocation. The real `skill` round trip is required before claiming daemon-profile compatibility.

### Phase 2 — bounded daemon pilot

Allowed scope: accepted ADR amendment, runtime adapters, `Daemon.Execution`, relevant session shell/projection code, focused tests, and operator documentation. This is a coupled lifecycle change and should be reviewed as one unit.

1. Add an explicit opt-in execution backend at the actual daemon dispatch boundary. Keep the legacy default until pilot acceptance.
2. Route each admitted work item to exactly one engine. Preserve daemon IDs, admission policy, finalization, cancellation, skill catalog, and existing session API/PubSub contracts.
3. Apply the accepted state-authority/restart design, including reconnect snapshots and stale-incarnation fencing. Do not have the shell start its existing graph/QueryLoop for a Backplane-owned execution.
4. Define observable states for clean failure, cancelled completion, and unknown side-effect outcome. Under ephemeral mode, owner loss must not trigger blind restart/replay.

Exit: deterministic daemon integration tests cover dispatch-once, tool-profile parity, streaming UI/API projection, approval, cancellation, worker/runtime crash, queued work, and finalization. Rollback selects legacy only for newly admitted work; never rerun a partly dispatched work item on the legacy engine.

### Phase 3 — optional durable recovery, then broader adoption

Allowed scope: separate storage ADR, data-layer atomic API, runtime Store adapter, and crash/conformance tests. Do not bundle this with the pilot cutover.

Exit for durable mode: real-store conformance, concurrent CAS conflict, stale incarnation rejection, uncertain commit reconciliation, provider/tool crash windows, and no duplicate tool dispatch all pass. Only then claim restart recovery.

Consider interactive graph/QueryLoop migration afterward, with separate acceptance for advisory steering, follow-up queues, compaction, collaboration, multimodal history, and existing UI behavior. The daemon pilot does not establish those capabilities.

## Upstream requests and validation commands

Upstream issues were created during the first implementation increment under the repository's dependency-routing instructions:

- [#40: anyOf object constraints](https://github.com/gsmlg-opt/backplane/issues/40), type Feature, `internal request` / `enhancement`, severity High for adoption (recorded in body). Includes the actual skill schema and acceptance of locator, name, or both; rejection of neither, wrong types, and extra fields.
- [#41: strict compilation on Elixir 1.20](https://github.com/gsmlg-opt/backplane/issues/41), type Bug, `internal request` / `bug`, severity Medium (recorded in body). Includes the four warnings and passing 1.18.4/OTP 28.5 versus failing 1.20.1/OTP 29.0.2 matrix. No dependency patch or suppression added.

Both #40 and #41 are closed. The 1.7.4 consumer checks confirm the schema and compiler fixes; TODO references for the resolved schema blocker were removed. The existing enum-support issue #36 is also closed.

Proposed implementation validation, from the repository root:

```sh
mix deps.get
MIX_ENV=test mix deps.compile backplane_agent_runtime --force
mix test apps/synapsis_agent/test/synapsis/agent/runtime
mix test apps/synapsis_core/test/synapsis/tool/gateway_test.exs apps/synapsis_core/test/synapsis/tool/skill_test.exs apps/synapsis_core/test/synapsis/tool/executor_lifetime_test.exs
mix test apps/synapsis_provider/test
mix test apps/synapsis_agent/test
mix format --check-formatted
git diff --check
```

The runtime directory also contains existing graph/runner/checkpoint tests. The provider adapter increment validated the runtime directory, provider suite, and relevant Gateway/skill tests. The tool adapter increment revalidated the runtime directory and Gateway/skill/Executor lifetime tests; the entire agent suite is a later Phase 1 gate. Add focused session/server tests when those interfaces change; run storage conformance only in Phase 3. Report baseline/environment failures separately and do not repair unrelated suites as part of this migration.
