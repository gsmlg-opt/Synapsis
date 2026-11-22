# Remembered Samgita Agent connections

Configure the Samgita address on `/samgita`, then select the configured Synapsis,
Codex or Sigma identity to expose. Each selection opens its own WebSocket to
Samgita `/app-server`. Confirm each new device in Samgita; project roles and
capacity remain configured there. Selecting one identity does not register other
Agents or grant them its permissions. The existing server-initiated connection
mode remains available under the optional server connection settings.

The inbound contract is available in Samgita v0.4.4. Synapsis uses the existing
`samgita_protocol` client for native initialization and project events, with
`HTTP.WebSocket` for transport and keepalive. It does not call REST `/connect`
after the inbound handshake, which would replace the socket's generation.

## Identity and connection lifetime

`Synapsis.Samgita.Devices` owns the persistent configuration through
`Synapsis.Config.Store`. A device token is generated and encrypted before the
first connection. Each device binds a server address and a configured local
identity to one Samgita Agent UUID. Reconnect reuses the token and accepts a new
connection generation while retaining that Agent UUID. Public device projections,
UI state and logs exclude the plaintext token.

`SynapsisSamgita.Inbound` supervises a separate client for each selected identity.
New devices wait for confirmation before native initialization; management APIs
become available only after initialization completes. Socket loss triggers bounded
backoff. Disconnection disables automatic restoration while preserving the token.
A policy close stops automatic reconnect. Samgita v0.4.4 uses the same close code
for device rejection, ingress restart and connection expiry, so Synapsis cannot
classify that close as revocation. Automatic recovery for that branch is blocked
by [Samgita#6](https://github.com/gsmlg-opt/Samgita/issues/6). Forgetting removes
the token and retires that device record; reconnect cannot silently replace it.

## Events and operator actions

The data layer scopes inbox records by device and event identity. A durable
receive acknowledgment means the event has been stored, not that its Task has
completed. Duplicate delivery and status lookup use the same device scope.
The page preserves that scope when displaying events or marking them processed.

The Task view selects one identity at a time. Project sessions are scoped to that
device and connection, and Attempt actions verify device ownership. REST calls
use the selected device bearer and current connection UUID; they do not borrow
the legacy coordinator credential. Local Codex/Sigma processes continue to be
owned by Synapsis through their existing adapters.

## Assigned Task execution

`task.assigned` events reserve a durable execution record in
`Synapsis.Samgita.Executions` before dispatch. The handler checks this reservation
on first and duplicate deliveries, so losing a receive response does not authorize
another execution. The runtime checks the current Task assignment, then performs
session creation, claim, start, progress and report with persisted command IDs.
Local thread/turn acknowledgments are only dispatch acknowledgments; successful
reporting requires an observed terminal runtime result.

The journal stores execution phases, the local runtime identity and encrypted
lease proof in Concord through the data layer. Only a record still in `queued`
may begin automatically after restoration. A lost response or interrupted started
execution becomes `recovery_required`; reconnect does not replay it. The selected
identity's Task view displays these records, including uncertain outcomes.
An independent execution guard monitors the manager and worker, retains the exact
local runtime handle and revokes the journal owner token on owner loss. Stale
workers cannot checkpoint with that token, and runtime cleanup does not depend
only on the failed worker's termination callback. A successful internal Agent
result also requires its child roster to have settled.
`SynapsisSamgita.Execution.reconcile/3` reads the local journal and current server
Task without sending another mutation. It does not resolve every lost command
response or automatically rebind an Attempt.

## Verification limits

Loopback tests exercise real WebSocket framing, native negotiation and durable
event responses against a controlled protocol host. They do not establish live
operator confirmation, deployed server compatibility or real Codex/Sigma model
execution. These require a running supported Samgita deployment and the configured
local runtimes. Connection restoration must never be used as evidence that an
uncertain Task or mutation may safely be replayed.
