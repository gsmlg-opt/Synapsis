# Agent daemon operations

The daemon is a local, supervised execution boundary. It owns manual, heartbeat,
schedule, and dream runs and persists each run in the embedded session store.
Its status includes a periodically refreshed `last_seen_at`; each liveness tick
also asks the local scheduler to reconcile due routines without starting an LLM
run itself. Status snapshots continue to publish on `agent:daemon`.

Routine definitions are validated TOML-backed config maps. The scheduler writes
`next_run_at` when it calculates a schedule, then records `last_run_at` and
`last_status` only after the associated AgentRun reaches a terminal state.

Dream runs receive bounded recent AgentRun, Session-summary, memory, todo,
workspace, and project context. A successful result must be an exact six-field
JSON object (`recent_summary` plus five list-of-string fields); the validated
object is kept in AgentRun metadata. Memory candidates are persisted only when
the Dream uses its memory tools. Todo changes likewise require the explicitly
enabled `assistant_dream_todo` tool profile; the daemon does not apply either
candidate set automatically.

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
