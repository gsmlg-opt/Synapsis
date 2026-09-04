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
- `GET /agent/routines` with optional `kind`, `POST /agent/routines`
- `PATCH /agent/routines/:id`, `POST /agent/routines/:id/trigger`
- `POST /agent/heartbeat/trigger` with an optional stored routine `name`
- `POST /agent/dream/trigger` when exactly one enabled dream routine exists
- `GET /agent/events` for daemon and Backplane lifecycle SSE
- Backplane CRUD under `/backplane/connections`, plus `/status`, `/test`, and `/refresh`.

Routine creation assigns an immutable UUID. PATCH and run-now operations use
that ID and execute only the persisted routine definition; request payloads
cannot replace its prompt or tool profile. The `agent:daemon` Phoenix Channel
and daemon SSE endpoint expose the same public lifecycle event names.

Credentials are encrypted at rest and are never returned by the API. Backplane
refresh is best-effort and keeps last-known-good capability artifacts when a
surface is unavailable.

## CLI

The escript provides `agent status|run|runs|cancel`, `heartbeat run [name]`,
`dream run`, `schedule list|run <name>`, and
`backplane list|add|test|sync`. Schedule and Backplane names resolve to exactly
one stable ID or fail as ambiguous. Backplane connections are keyless unless
`backplane add` is given `--credential-env VAR`; the credential is read from
that environment variable and is never printed. The CLI refuses to send that
credential through a non-loopback plaintext CLI host or to configure it for a
non-loopback plaintext Backplane endpoint.

Use `--host` to select the endpoint. For the production mTLS boundary, pass the
client certificate and private key as a pair; use `--ca-cert` when the server CA
is not in the system trust store:

```sh
synapsis agent status \
  --host https://synapsis.example.com \
  --client-cert /etc/synapsis/admin.pem \
  --client-key /etc/synapsis/admin.key \
  --ca-cert /etc/synapsis/server-ca.pem
```

The operational LiveView is available at `/agent/daemon`. It subscribes to the
daemon topic and provides runtime status, durable run history and controls,
routine management, and Backplane connection status and actions.

## Deployment boundary

Synapsis does not authenticate terminal users. Its HTTP API, SSE endpoint,
Phoenix Channel, and LiveView all share one external access boundary: Caddy
must authenticate the client certificate before proxying the request. Keep the
Phoenix endpoint on `127.0.0.1:4657` (the production default), and never expose
that listener directly to the public network.

Set the release environment explicitly:

```sh
PHX_HOST=synapsis.example.com
PHX_IP=127.0.0.1
PORT=4657
```

The following Caddyfile requires a client certificate signed by the configured
client CA and proxies all HTTP, SSE, WebSocket, and LiveView traffic to the
loopback listener:

```caddyfile
synapsis.example.com {
  tls {
    client_auth {
      mode require_and_verify
      trust_pool file /etc/caddy/synapsis-client-ca.pem
    }
  }

  reverse_proxy 127.0.0.1:4657
}
```

Caddy sets `X-Forwarded-For`, `X-Forwarded-Host`, and `X-Forwarded-Proto` for
the upstream by default and ignores spoofed incoming values when it is the
first proxy. Synapsis uses the forwarded protocol for its production HTTPS
rewrite. If another proxy sits in front of Caddy, configure Caddy's
`trusted_proxies` explicitly; do not trust arbitrary forwarded headers at the
Synapsis listener.

### Issue and verify an administration certificate

Keep the CA private key offline. The following example creates a dedicated
client CA and one administration certificate; adapt subjects and lifetimes to
the site's certificate policy:

```sh
umask 077
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out synapsis-client-ca.key
openssl req -new -sha256 \
  -key synapsis-client-ca.key \
  -subj '/CN=Synapsis Client CA' \
  -out synapsis-client-ca.csr
printf '%s\n' 'basicConstraints=critical,CA:TRUE' \
  'keyUsage=critical,keyCertSign,cRLSign' \
  'subjectKeyIdentifier=hash' > synapsis-client-ca.ext
openssl x509 -req -sha256 -days 3650 \
  -in synapsis-client-ca.csr \
  -signkey synapsis-client-ca.key \
  -extfile synapsis-client-ca.ext \
  -out synapsis-client-ca.pem

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out synapsis-admin.key
openssl req -new -sha256 \
  -key synapsis-admin.key \
  -subj '/CN=synapsis-admin' \
  -out synapsis-admin.csr
printf '%s\n' 'basicConstraints=critical,CA:FALSE' \
  'keyUsage=critical,digitalSignature' \
  'extendedKeyUsage=clientAuth' > synapsis-admin.ext
openssl x509 -req -sha256 -days 365 \
  -in synapsis-admin.csr \
  -CA synapsis-client-ca.pem \
  -CAkey synapsis-client-ca.key \
  -CAcreateserial \
  -extfile synapsis-admin.ext \
  -out synapsis-admin.pem
chmod 600 synapsis-admin.key synapsis-client-ca.key
openssl verify \
  -CAfile synapsis-client-ca.pem \
  -purpose sslclient \
  synapsis-admin.pem
```

Install only `synapsis-client-ca.pem` where the Caddy service can read it, then
reload Caddy. Keep `synapsis-admin.key` on the administrator host. Verify both
the rejection and acceptance paths:

```sh
# Must fail during the TLS handshake because no client certificate is supplied.
curl --fail https://synapsis.example.com/api/health

# Must return the Synapsis health JSON.
curl --fail \
  --cert synapsis-admin.pem \
  --key synapsis-admin.key \
  https://synapsis.example.com/api/health
```

A local service monitor may call `http://127.0.0.1:4657/api/health`. A remote
health monitor is an external client and must use the mTLS endpoint from a
trusted network with its own client certificate.

Backplane bearer credentials use the existing Backplane connection
`credential` field. They are encrypted at rest with `SYNAPSIS_ENCRYPTION_KEY`,
redacted from API responses and events, and should be supplied through the
trusted API/CLI configuration path. Do not place Backplane credentials in the
Caddyfile or expose them as URL query parameters.
