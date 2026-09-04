# Agent daemon operations

The daemon is a local, supervised execution boundary. It owns manual, heartbeat,
schedule, and dream runs and persists each run in the embedded session store.

## HTTP API

All endpoints are under `/api`:

- `GET /agent/daemon/status`, `GET /agent/runs`, `GET /agent/runs/:id`
- `POST /agent/runs` with `{"prompt":"..."}`
- `POST /agent/runs/:id/cancel`
- `GET /agent/routines/:kind` and `POST /agent/routines/:kind/trigger`
- Backplane CRUD under `/backplane/connections`, plus `/status`, `/test`, and `/refresh`.

Credentials are encrypted at rest and are never returned by the API. Backplane
refresh is best-effort and keeps last-known-good capability artifacts when a
surface is unavailable.

## CLI

The escript provides `agent status|run|runs|cancel`, `heartbeat run`, `dream run`,
`schedule list|run`, and `backplane list|test|sync`. Use `--host` to select the
local HTTP endpoint.

## Deployment boundary

Synapsis does not add a user-authentication system in v1. Keep the Phoenix
endpoint bound to loopback for local use. For remote administration, terminate
TLS and client authentication at a reverse proxy (for example Caddy with mTLS)
and proxy only the API/UI to Synapsis; do not expose the local listener directly.
