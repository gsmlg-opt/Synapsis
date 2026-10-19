# Session subagents

Subagents are enabled by default for new sessions and existing sessions without
an explicit setting. Set `session.config["subagents"] = false` to opt out, using
the **Subagents** button in the session header or
`Synapsis.Session.Worker.set_subagents/2`. An explicit opt-out remains effective
after reconnect or restart. The setting can change only while the root and
children are settled. Unknown outcomes require recovery; toggling the setting
cannot bypass them.

## Execution ownership

`Session.Worker` remains the session/UI host. For an enabled turn it delegates
provider and tool execution exclusively to a real
`Backplane.AgentRuntime.Conversation` through
`Synapsis.Agent.Runtime.SessionAdapter`. The legacy graph and QueryLoop do not
advance that turn. This uses the published `backplane_agent_runtime` 1.10.26.

One `Codex.Session` and `Codex.MultiAgent` manager own the root binding, children,
mailboxes, cleanup and followups. A new root Conversation is bound for each user
turn; successful turns retain the manager and resident child histories. Nested
children and parent result delivery use the native collaboration protocol.

The enabled catalog exposes the six `collaboration_v2` tools:

- `spawn_agent`
- `send_message`
- `followup_task`
- `interrupt_agent`
- `list_agents`
- `wait_agent`

The legacy `task` and team wrappers are excluded from this catalog. Other selected
host tools use the existing registry/backend and Gateway. This feature does not
replace the complete Synapsis tool system.

MCP registrations expose caller-owned runtime dispatch through the existing
Gateway and Executor. Native effect tasks own the published MCP tool-call
handles; timeout or owner death cancels that call without blocking the MCP server
or cancelling sibling calls. A timeout retains an unknown-outcome recovery fence
because local cancellation does not establish the remote outcome. Other process
registrations require the same explicit caller-owned dispatch contract.

Children inherit the actual parent's provider, model, selected tools, reasoning
setting and immutable permission snapshot. Following up an old child after a new
root turn cannot grant that child the new root's broader permissions. Each
invocation, including collaboration, checks Gateway policy; child tool approvals
retain their exact runtime interaction/invocation identity. Pending child
approvals remain actionable after the root finishes, and appear with Allow/Deny
controls in the session panel.

## Persistence and recovery

The transcript and execution journal have different contracts:

| State | Owner and durable boundary |
| --- | --- |
| Streaming text, roster and pending approvals | Live process snapshot and PubSub |
| Accepted user message | Appended before prompting the root |
| Completed root history | One acknowledged atomic suffix append plus metadata through `Session.Store.commit_turns/4`, in a supervised task |
| Runtime transitions, effects and outbox | Opaque aggregate through the agent Store adapter and data-only `Synapsis.Runtime.Store`, with Concord revision/incarnation CAS |
| Root admission, child intents/receipts and roster | Acknowledged journal facts/projections under `coord/runtime/` |

Root admission is durable before its first provider dispatch. Child admission
intent is durable before process creation, and the native admission receipt is
durable before acknowledgement. Failed writes do not authorize dispatch.
Transcript snapshots are not a substitute for this execution journal.

The Worker stays active through the terminal transcript acknowledgement, so a
queued turn cannot overwrite or race the preceding turn's append. Repeated native
history events do not append messages twice. Oversized snapshot batches fail
atomically instead of writing a partial suffix.

Every adapter generation has a separate observer token and journal namespace.
Confirmed cancellation closes the session tree before acknowledging completion;
its terminal history retains completed tool calls and results. The next prompt
starts a fresh generation. Late observer events cannot modify it. Fatal prompt
or terminal-observation failures close the runtime and settle the visible turn;
unavailable canonical history preserves a recovery fence across restart.
Worker/owner loss does not replay effects. An unresolved root or child admission,
active saved run, or unconfirmed cleanup becomes `unknown_outcome` /
`recovery_required` and blocks new native admission. The UI displays this state.

## Current limits

- Default native concurrency is four executing threads **including the active
  root**, allowing three concurrent executing children while it runs.
- `fork_turns` supports the native `all` and `none` modes. Child model, reasoning
  and agent-type overrides accept inherited/default values only; unsupported
  values return an explicit admission error.
- Selected unavailable, deferred or process-backed registrations without a
  caller-owned dispatch contract fail admission.
  The session `tool_search` searches the selected admitted host catalog only; it
  does not load deferred or plugin tools.
- Restart does not reconstruct child processes or replay their work. Saved
  completed rows are historical; their old followup handles are unavailable in
  the new runtime generation. Uncertain work needs explicit investigation and
  recovery rather than automatic retry.
- Legacy retry, regenerate and graph checkpoints are unavailable while the
  feature is enabled. Send a new prompt to continue. Mode/model/agent changes
  during an active native turn return `session_busy`.

## Verification

The focused suites cover real Concord store conformance/CAS/fencing and atomic
appends; real root/child/nested Conversations; followup policy inheritance;
approval and denial; capacity refusal; owner loss and failed admission storage;
real Bypass HTTP root-to-child execution; cancellation followed by another turn;
assistant-mode queueing; and LiveView toggle/reconnect/approval/recovery display.
No live model API is used in these tests.

The implementation passed 356 scoped tests. Isolated browser smoke checks
verified the default-enabled panel, an explicit opt-out after refresh, connected
LiveView, successful built JS/CSS responses and no browser console errors.
