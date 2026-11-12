# Connecting Synapsis to Samgita (local)

Synapsis is a Samgita Agent. Samgita delivers `project_events.v1` events to
Synapsis at `/app-server`; Synapsis calls Samgita's `/api/agent/*` API to claim
and report Tasks. Two secrets are involved, both generated on the Synapsis
**Samgita** page (`/samgita`) and shown once:

| Secret | Direction | Where it goes in Samgita |
| --- | --- | --- |
| App-server token | Samgita → Synapsis | `SAMGITA_EVENT_CREDENTIALS` value |
| Agent credential | Synapsis → Samgita | Agent inbound credential |

## 1. Synapsis

1. Open `/samgita`, set **Samgita URL** (e.g. `http://10.100.10.28:4870`) and save.
2. Generate the **app-server token** and the **agent credential**; copy each when shown.

## 2. Samgita: register the Agent

In Samgita `/agents` (or `POST /api/agents` with the operator `x-api-key`):

- name `Synapsis (<hostname>)`, protocol `samgita`, protocol version `1.0`
- endpoint transport `websocket`, url `ws://127.0.0.1:4657/app-server`
- advertised and approved capabilities: `project_events.v1`
- `credential_ref`: `synapsis-local-v1`

Then add an inbound credential to the Agent with the **agent credential** value
(`POST /api/agents/:id/credentials`), bind the Agent to a Project with roles
`worker` and `manager`, and set the Project's event routing to this Agent.

## 3. Samgita: allow delivery to Synapsis

Samgita only dials approved destinations and allows plaintext only to loopback.
Set these in Samgita's runtime environment and restart Samgita:

```sh
SAMGITA_EVENT_DESTINATIONS='{"<agent_uuid>":{"url":"ws://127.0.0.1:4657/app-server","addresses":["127.0.0.1"],"allow_insecure":true}}'
SAMGITA_EVENT_CREDENTIALS='{"synapsis-local-v1":"<app-server token>"}'
```

## 4. Activate Samgita execution authority

Samgita dispatches deliveries and accepts claims only after platform activation.
It needs `SAMGITA_LEASE_KEYS` (JSON `{"<id>": "<base64 key, ≥32 bytes>"}`) and
`SAMGITA_LEASE_KEY_ID` in its environment, then `POST /api/platform/activate` with
`expected_version` and `evidence` (`legacy_fenced`, `effects_resolved`, `reference`).

## 5. Use it

- Click **Connect** on `/samgita`. The agent and connection ids appear.
- Events Samgita delivers appear under **Events received** as `durable` / `pending`.
  **Mark processed** completes them and reports the result on the Samgita
  delivery, which then shows `completed` (Samgita does not re-poll accepted deliveries).
- Tasks assigned to this Agent appear under **Assigned tasks**. **Claim**, then
  **Start**, **Progress** and **Report**. Samgita requires **Start** within 30 s
  of the claim (the row shows the "start by" time); a later start fails with
  `ownership_lost`. Synapsis renews the 120 s lease in the background while the
  attempt is open.

## Limits

- An open attempt is not recovered after a Synapsis restart; it stays in Samgita
  until its lease expires.
- Generating a secret again invalidates the previous one; update Samgita accordingly.
