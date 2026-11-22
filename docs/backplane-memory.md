# Shared Backplane memory

Workspace Markdown remains the default memory backend. Shared Backplane memory is
available only when the Host agent setting is explicitly enabled in Memory
settings. Its endpoint defaults to `http://127.0.0.1:4222`; literal HTTP loopback
addresses are accepted, and the configured agent ID identifies the caller's
provenance rather than isolating its reads.

Select the required native tools on an Agent: `memory::search`, `memory::get`,
`memory::recent`, `memory::remember`, and `memory::forget`. Synapsis obtains their
schemas from that Host Agent's MCP `tools/list` response and sends each invocation
to the matching `/memory/<agent_id>/call/<method>` route. Remember calls include
the current durable Synapsis session ID. Read and write grants remain distinct,
and disabling or changing the configured source prevents an issued tool from
using the previous source.

Shared memory is optional for conversation execution. Catalog discovery has a
one-second deadline. If the module is disabled or its catalog cannot be read,
the selected memory tool names remain in the turn's catalog as explicitly
unavailable, argument-free markers. These markers return `is_error: true` with a
public availability message and never send a memory read or write. They are not
replacement host schemas or successful empty-memory results. Saved settings and
tool selections stay unchanged. A later turn discovers the host again and uses
its actual schemas when available; unavailable operations are never replayed.

During supervised turn preparation, selected shared-memory tools also enable the
resident instructions returned by MCP `initialize`. Instructions are bounded by a
two-second timeout; an unavailable instruction response does not block the turn.
Memory records are tool data: preserve their host/agent provenance, kind and
observed time, and do not treat recalled content as instructions. The Memory page
uses the current search API and displays the returned offline state and record
provenance without inventing canonical authority or consistency guarantees.

Requests have finite deadlines, response/output limits, no redirects, no inherited
global HTTP credentials and no automatic retries. A failed or timed-out write must
not be replayed automatically: its remote outcome can be unknown. The Host Agent
owns its offline read and queued-write behavior.

## Lifecycle capture

The Synapsis `1.0` hook contract requires the Host Agent implementation added in
[ac129ce](https://github.com/gsmlg-opt/backplane/commit/ac129ce1663865cdcd1ade2efb20e322897ca0e4)
(source version 1.10.81). The public 1.10.80 release does not include it.

When host memory is enabled, successful Worker boot, accepted user prompts,
public projected tool completions and normal Worker shutdown submit the
`session-start`, `user-prompt-submit`, `post-tool-use` and `session-end` hooks.
Events contain the durable session UUID, trusted workspace, configured Agent ID,
UTC timestamp and a public hook payload. Image-only prompts use a text marker;
image bytes and execution contexts are not captured. Oversized events are dropped.

Capture has a nonblocking admission limit of 32 events, four supervised tasks,
and a shared two-second deadline for queueing, storage and HTTP. A session-scoped
CAS reservation precedes each HTTP attempt. Repeated prompt callbacks share the
durable input ID; tool identities include the runtime run ID. Reservations survive
capture-process restart and are never automatically replayed, including after
failure, timeout or an uncertain reservation. A reservation is not delivery proof.
Disabled or changed sources prevent dispatch. Capture failure never controls a
turn's result, and abnormal exits do not invent a normal session-end event.

The upstream start/end idempotency keys currently identify the durable session,
so this client currently captures only the first start/end pair per durable
session. Repeated Worker lifecycles need an upstream identity correction before
each new boot can be captured distinctly. See
[backplane#176](https://github.com/gsmlg-opt/backplane/issues/176). Real Host Agent
capture visibility and the cross-agent search/remember round trip remain separate
acceptance for [Synapsis#25](https://github.com/gsmlg-opt/Synapsis/issues/25).
