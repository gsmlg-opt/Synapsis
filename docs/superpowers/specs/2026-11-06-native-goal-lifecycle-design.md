# Native Goal lifecycle and public activation

Status: **proposed; no production code delivered; public activation not approved**.
Repository: Synapsis root `main`, `0409e2bf5eadee52d2a2697d5ac18c0eae324524`
plus existing uncommitted alignment work. Source contract: installed, locked
`backplane_agent_runtime` **1.10.57**. This document refines the existing P6/175
ownership design using the public recovery contracts investigated in 282/284.
It does not replace the full P0–P15 plan or qualify a complete reference tool.

## Problem and intended result

Synapsis already has a durable native Goal.Store implementation, normalized
ordinary final provider usage, retained native run addresses, and trusted
per-incarnation user-mode provenance. SessionAdapter still starts Conversation
without a Goal owner or binding. Retained terminal Goal outboxes currently keep
recovery admission closed; nothing delivers and durably acknowledges them.

The next lifecycle component must connect the existing Worker, SessionAdapter,
GoalStore, Conversation, GoalBridge and MultiAgent through normal execution and
terminal recovery. A binding-only change or an unused recovery helper does not
meet that component's acceptance criteria.

Public tool semantics are a separate product decision. The recommendation is to
use the original native Goal descriptors and document the reference differences.
Keeping those descriptors disabled remains a supported implementation stage;
it does not count as public Goal support. No ordinary prompt implicitly creates
an objective, token budget or automatic continuation opportunity.

## Ownership and scope

| Existing owner | Responsibility |
| --- | --- |
| Session Worker | Ordinary input priority, resident admission state, generation and exact reservation/release gate |
| SessionAdapter | Stable Session Goal owner, owner-only native calls, asynchronous preparation phases and recovery coordination |
| Native Goal + GoalStore | Full-record persistence, transitions, receipt deduplication, accounting and native continuation policy |
| Native Conversation + GoalBridge | Provider/tool execution, original receipt outbox, normal delivery, checkpoint removal and binding cleanup |
| Native MultiAgent | Original child startup/follow-up and actual Goal delegation |
| Existing Runtime.Store | Original namespace/run aggregates and immutable correlated host facts |

Use the stable canonical Session UUID as native root thread and GoalStore address.
Keep the opaque native Goal ID distinct from that UUID and from random run-store
namespaces. Preserve the existing data-only GoalStore boundary. Do not introduce
a second executor, scheduler, accounting ledger, database or provider replay loop.

Expected production write boundary: SessionAdapter, Worker and the relevant
existing `worker/runtime.ex`/pending-input state owners; small nonprocess
GoalHost/recovery/attribution helpers in `synapsis_agent`; RunInventory or adjacent
immutable facts; selected native profile composition only when public activation
is approved. Include dedicated ordinary functional tests and scoped architecture/
plan updates. No dependency/lock, provider-normalization or opaque GoalStore
redesign is required by the inspected contracts. Freeze exact files separately
before each implementation batch; this document does not authorize adjacent work.

## Ordinary root and child lifecycle

1. Start/load one real native Goal with Adapter as `owner_pid`, stable Session
   `thread_id`, real GoalStore and a Goal.Host adapter routed to the real Worker.
   Loading may use an existing supervised preparation job with the explicit owner;
   adopt and monitor the process before exposing readiness. A fixture/no-op Host
   or an alternate Goal owner is not a production implementation.
2. Split existing root preparation into inputs/resources/authority, owner binding,
   and original Conversation startup. Perform slow work in existing monitored
   jobs. Call `Goal.bind` from Adapter itself between those phases: it is owner-only.
3. Use the same trusted frozen mode captured by the existing accepted-prompt path.
   Never infer native Plan from permission configuration, Agent name or model text.
   Keep model planning-intent tools unchanged. Set `usage_authoritative: false`;
   this proposal does not qualify or activate token-budgeted Goals.
4. Persist exact serializable attribution correlated to the immutable run locator
   before dispatch. Pass the real Goal/binding/thread/run/incarnation into the
   original Conversation options; do not confuse Codex Session binding with Goal
   binding. Adopt resources before prompting and fence late preparation results
   using the existing Adapter epoch plus exact run identity.
5. Leave actual child delegation to native MultiAgent. Its `child_options` call
   occurs **before** `attribute_child` issues the actual delegated binding. The
   host may retain its exact supplied child thread/run/incarnation and the actual
   validated parent's attribution as **intended provenance**, then corroborate
   committed receipts. Do not claim to have observed the child's live binding,
   call `Goal.delegate` a second time, or inspect private native process state.
6. Native Conversation performs normal delivery, attribution refresh, checkpoint
   removal and asynchronous unbind. Host terminal history collection must not
   charge totals again, redeliver live outboxes or unbind before that sequence.
7. Normal settled owner replacement reloads the same Goal record and retained old
   namespaces. It does not reopen Conversation or replay provider/tool effects.

`Goal.attribution/2` returns a validated **capability-bearing binding**, including
authority/reference. Persist only a closed projection: correlated Session/locator
identity, thread/run/incarnation, trusted mode, expected Goal ID and applicable
root thread/Goal IDs. Never persist the entire returned binding or reconstruct
authority from its historical fields. Issue fresh authority from current trusted
host rules. Keep already persisted locators immutable; use a separate immutable
attribution fact when a later observation is needed.

Root attribution may refresh after an objective mutation. Retain immutable
observations for each relevant Goal identity epoch rather than rewriting the
original locator. A child observation cannot inherit a newly created root Goal
identity merely because it is current at recovery time.

## Real Worker Host and continuation

`Goal.Host.start_turn_if_idle` must call the existing Worker with a finite timeout.
Worker checks resident acknowledged readiness and atomically reserves the native
token/generation together with its run/incarnation/logical turn identity. It does
no storage, hooks, provider/tool work or synchronous Adapter/Goal lookup in that
callback. Reuse ordinary pending-input/automation/interaction/readiness facts;
do not create an alternative readiness predicate.

Keep a serializable Worker-owner UUID plus increasing generation sequence, the
native reservation token, and one exact slot. Native idle acknowledgement is
not a durable release intent. After that acknowledgement, persist the existing
design's immutable release intent in an asynchronous job; only its known ACK
permits Worker to recheck the exact slot and make one atomic release decision.
The existing ordinary Runtime.start_turn path must consume the preallocated
identity rather than mint a second run for the reservation.

Preserve external seals and native withdrawal/settlement contracts when ordinary
input or session operations invalidate a slot. Unknown writes or startup outcomes
retain the recovery barrier. No absence-of-record inference, private native
message, discarded receipt, automatic replay or local settlement workaround is
allowed. Those branches require source review under the current test exclusions;
ordinary successful admission alone cannot qualify exceptional recovery.

Worker never synchronously waits on an Adapter owner operation that can callback
through Goal into Worker. Native owner APIs themselves remain synchronous; this
proposal does not promise a continuously responsive Adapter mailbox during them.

Automatic idle release stays inactive in a lifecycle-only stage. Activation must
include the complete real reservation → native ACK → durable intent ACK → atomic
release → original runtime → canonical terminal commit → pending-input handoff
path. Do not call a reserved-only or bind-only patch complete continuation.

## Terminal retained-outbox recovery

This is a production startup consumer, not a standalone helper demonstration.
Keep admission closed while loading every retained original namespace/run and
the trusted attribution needed to interpret its receipts. Fresh Goal startup
already loads durable state. `Goal.restore` invalidates live capabilities and
reservations; do not call it per locator or while live runs hold bindings.

For each known terminal run with retained receipts:

1. Check that retained thread/Goal/mode identity matches the actual accounting
   destination. A replaced or cleared Goal is not permission to redirect usage.
2. Adapter reconstructs fresh authorized original-identity bindings. Descendant
   recovery may reconstruct a root capability and delegate the original child
   identity after old live owners are gone; this is distinct from ordinary native
   child delegation. Release recovery capabilities after their bounded job.
3. Preserve exact receipt maps and original order. Consecutive homogeneous groups
   get separate fresh bindings when source incarnations differ. Do not globally
   sort/regroup or substitute the current aggregate incarnation into a receipt.
4. Deliver with public `GoalBridge.deliver(goal, binding, exact_group)`; use
   `redeliver` only for a homogeneous whole outbox. Descendants are usage-only:
   explicitly select eligible usage maps and ACK only maps actually submitted.
   Legacy nonusage remnants remain retained and keep recovery closed.
5. After known successful delivery, use public Runtime Store.stage and
   acknowledge_commit with the original context/namespace and **current**
   aggregate run/fence:

   ```elixir
   command =
     {:goal_outbox_acknowledged, timestamp,
      %{run_id: run.run_id, incarnation: run.incarnation, receipts: exact_delivered_maps}}

   with {:ok, staged} <-
          Backplane.AgentRuntime.Store.stage(
            Synapsis.Agent.Runtime.Store, original_context, run, %{command: command}
          ),
        {:ok, _ack} <-
          Backplane.AgentRuntime.Store.acknowledge_commit(
            Synapsis.Agent.Runtime.Store, original_context, staged.stage, %{}
          ) do
     :ok
   end
   ```

6. Stage is pure Kernel execution; only actual acknowledge_commit confirms
   persistence. Reload the aggregate between ACK groups so subsequent CAS uses
   the new revision. Empty outboxes require no ACK command.
7. Reload inventory and re-evaluate all existing uncertainty/readiness barriers
   after acknowledged removal. Successful delivery of one group alone does not
   open admission. Unexplained intents, missing/nonterminal records, missing
   attribution or remaining outbox entries retain the barrier.

If delivery partially succeeds and returns no exact partial-success list, retain
the group. Unknown ACK outcomes require readback reconciliation before another
ACK. Do not claim these branches tested or add failure injection under the
current exclusions. Recovery never dispatches providers or tools.

## Public Goal decision and limits

Recommended public contract: compose the original native `create_goal/get_goal/
update_goal` descriptors through the existing selected-only Catalog/Profiles and
real ExtensionRuntime backed by the real Goal. Select only the Goal family;
ExtensionRuntime also advertises unrelated ephemeral extension families. Its
generic capability report is not evidence of this real GoalStore's durability.

Record these deliberate reference differences:

| Behavior | Pinned OpenClaw | Native contract proposed for Synapsis |
| --- | --- | --- |
| Create when a completed Goal exists | Requires explicit clear first | Permits replacement after completion |
| Model update status | complete / blocked | complete / blocked / paused |
| Model update note | Exposed | No note field |
| Explicit request, full completion, repeated blocked condition | Prompt obligations | Prompt obligations; arbitrary calls do not prove user intent or compliance |

No hidden schema rewrite, replacement policy or invented note persistence is
proposed. The alternative is to keep public Goal tools disabled and deliver only
the lifecycle component until a different public contract is explicitly chosen.

Host-only set/clear/resume controls remain outside this activation proposal.
Their canonical typed instruction source/UI has not been selected. Do not parse
general prompt text into those operations or accept model-supplied provenance.
The real Host instruction callback must never fabricate acknowledged evidence;
no host mutation is admitted without a separately approved, actually persisted
canonical instruction path. This does not replace model committed-invocation
provenance with a dummy callback.

Budgeted operations remain inactive/unqualified. Native bindings must continue
to reject token budgets without authoritative usage; ordinary EOF normalization
does not establish that authority. No new flag or silent capability promotion is
authorized here. Progress-card placement and independent child-owned Goals also
remain outside scope. Public activation cannot be called complete P6/reference
alignment while these named requirements remain open.

## Permitted acceptance and implementation stages

First freeze and implement the **complete ordinary lifecycle/recovery component**
above with the real Worker Host boundary and public descriptors/idle release
inactive. Then, only after the public decision, implement original selected Goal
descriptors and the complete successful continuation lifecycle together. Neither
stage may use a dummy Host. Do not expand the test exclusions for either stage.

Dedicated ordinary checks must cover:

- Actual Adapter + real GoalStore/Concord + local deterministic provider: root1,
  native child/follow-up and root2, exact mode/parent/intended-child provenance,
  genuine native receipts, usage counted once and normal terminal outbox removal.
- Normal settled Worker/Adapter replacement: stable Goal record, unchanged old
  aggregates/history/effect counts, and a fresh ordinary run/binding.
- A positive terminal-recovery component fixture: valid terminal aggregate built
  through public Kernel/Store with genuine GoalBridge receipts; invoke the same
  production startup recovery consumer, observe real Goal accounting, real CAS
  ACK/readback and unchanged terminal outcome/history/effects with zero provider/
  tool replay. Label this a component fixture, not crash or lost-ACK qualification.
- Readiness observed only after actual ACK and reloaded inventory. If heterogeneous
  source-incarnation fixtures fall outside the current exclusions, retain grouping
  as a source-reviewed boundary rather than silently executing them.
- For later public activation, actual native descriptors in the next fixture
  provider catalog, committed unbudgeted model mutation, durable readback and
  successful real reservation/release/continuation through existing Worker paths.

Do not run security/permission/auth/TLS, negative/error/failure/cancel/crash,
mixed-outcome, budget exhaustion/eviction or real-provider tests. No synthetic
successful ACK, dropped reply, shortened deadline or weakened readiness assertion.
Serialize Mix/Devenv work. Review the integrated diff and perform required actual
managed process replacement, old-process exit/root cwd/ready confirmation and two
health HTTP200/`ok=true` observations after a changed batch. Keep full alignment
active and all unqualified reference gates open.

## Source evidence

- `deps/backplane_agent_runtime/lib/backplane/agent_runtime/goal.ex`: public
  owner/capability APIs, startup/load, attribution, committed receipt identity.
- `deps/backplane_agent_runtime/lib/backplane/agent_runtime/goal/host.ex`:
  atomic reservation, release, seals and canonical instruction callback contract.
- `deps/backplane_agent_runtime/lib/backplane/agent_runtime/goal_bridge.ex`:
  binding validation, outbox queue/delivery and descendant usage filtering.
- `deps/backplane_agent_runtime/lib/backplane/agent_runtime/conversation.ex`:
  normal delivery/checkpoint/refresh/unbind lifecycle.
- `deps/backplane_agent_runtime/lib/backplane/agent_runtime/codex/multi_agent.ex`:
  child_options before actual native attribute_child delegation.
- `deps/backplane_agent_runtime/PERSISTENCE.md`: retained outbox recovery and
  public terminal ACK, separate from Goal restore.
- `apps/synapsis_agent/lib/synapsis/agent/runtime/{session_adapter,run_inventory,goal_store,store}.ex`
  and `apps/synapsis_agent/lib/synapsis/session/worker/pending_inputs.ex`:
  current production owners and readiness boundaries.
- Existing ownership investigation `/tmp/synapsis-goal175-architecture.md`;
  current public-contract qualification `/tmp/synapsis-goal-activation-282.md`
  and `/tmp/synapsis-goal-recovery284.md`. These are investigation evidence,
  not implemented runtime acceptance.
