# Samgita Protocol Integration (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two independently demoable lines: (A) Synapsis registers with the local Samgita as a samgita_protocol host that durably receives `project_events.v1` events and, via the management API, lets an operator walk an assigned Task through claim → report; (B) a "Local Agents" page that starts/stops the local Codex app-server and chats with it through a unified local-agent interface.

**Architecture:** Two new umbrella apps. `synapsis_samgita` holds the protocol `Handler`, a wrapper Plug for `/app-server`, a Req-based management API client, a connection GenServer and per-attempt GenServers (lease renewal). `synapsis_local_agents` holds the `Adapter` behaviour, per-agent `Runner` GenServers, a facade, and the Codex adapter over `SamgitaCodexDriver.Session`. `synapsis_data` gets only data APIs: two config kinds and a Concord-backed event inbox. LiveViews live in `synapsis_web`, routes in `synapsis_server`'s router.

**Tech Stack:** Elixir 1.18 umbrella, Phoenix LiveView on Gaoxy, Concord (Turso engine), TOML `Synapsis.Config.Store`, Req, hex `samgita_protocol ~> 0.4.0`, `samgita_protocol_websocket ~> 0.4.0`, `samgita_codex_driver ~> 0.4.0`, `Gaoxy.Test`.

**Spec:** `docs/superpowers/specs/2026-11-12-samgita-protocol-integration-design.md`

## Global Constraints

- Run all Mix commands as `devenv shell -- bash -c '<cmd>'` from the repo root, serialized (no parallel Mix builds).
- Develop on `main` in the root checkout; no branches/worktrees. Conventional commits; no `Co-Authored-By: Claude` / "Generated with Claude Code".
- No database. Durable data only through `synapsis_data` store APIs; Concord keys under `coord/samgita/`; decompress `prefix_scan` values (`# WORKAROUND(upstream): gsmlg-dev/concord#23`, as in `apps/synapsis_data/lib/synapsis/agent_checkpoints.ex`).
- Secrets stored as `"enc:v1:" <> Base64(EncryptedBinary.dump(secret))` exactly like `Synapsis.Credentials` (`apps/synapsis_data/lib/synapsis/credentials.ex:145-160`); never logged, never broadcast, never rendered after the one-time reveal.
- Structured logs: `Logger.info("samgita_connected", ...)`; never interpolate tokens, proofs, or Codex native payloads.
- Every HTTP / Codex / Concord call has an explicit timeout. Req calls use `receive_timeout:` and `retry: false`.
- Monitored processes handle `:DOWN`; adapter/attempt processes are supervised.
- Tests never contact real Samgita, real Codex, or LLMs. HTTP via `Gaoxy.Test`; Codex via a scripted transport in test support.
- Do not modify `../Samgita`. Upstream defects → `upstream-issue-routing` skill; blockers stop the affected task.
- No approval UI / permission gates (yolo). Codex server approval requests are auto-accepted.
- Protocol facts (from samgita_protocol 0.4.0): `Handler.methods/0` must equal exactly `~w(project/event.receive project/event.report project/event.status)` for `capabilities/0 == ["project_events.v1"]`; `connection/initialize` is handled by `SamgitaProtocol.Server` itself; receive results must echo the event's `event_id` and `delivery_attempt_id`.
- Samgita management API facts: auth `authorization: Bearer <credential>` (32..4096 bytes); all routes except `/api/agent/connect` also need `x-agent-connection: <connection uuid>`; every write carries a UUID `"command_id"` in the JSON body; updates carry `"expected_version"`; success body `{"data": ...}`, error body `{"errors": {"code","detail","fields"}}`; attempt lease 120 s; proof must be re-read via `GET .../attempts/:id/proof` after every renew.

## Review Focus

1. Samgita redelivers the same event with a new `delivery_attempt_id` after Synapsis restarts → same single inbox entry, result echoes the *new* attempt id, acceptance `durable`. (Task 3, Task 4 tests)
2. Same `event_id` with different payload → protocol error `conflict`, stored entry unchanged. (Task 3, Task 4 tests)
3. Operator takes > 2 minutes between claim and report → lease is renewed in the background and the proof used by the next manual step is the fresh one. (Task 6 test with injected short interval)
4. Codex process exits unexpectedly mid-turn → Runner status `crashed` with reason, page shows it, Start works again. (Task 9 test)
5. Samgita returns 409 `stale_version` / 401 on a step → step fails visibly with the error code, attempt state is not advanced locally. (Task 5, Task 6 tests)

---

### Task 1: Scaffold `synapsis_samgita` and `synapsis_local_agents`, add hex deps

**Files:**
- Create: `apps/synapsis_samgita/mix.exs`, `apps/synapsis_samgita/lib/synapsis_samgita/application.ex`, `apps/synapsis_samgita/test/test_helper.exs`
- Create: `apps/synapsis_local_agents/mix.exs`, `apps/synapsis_local_agents/lib/synapsis_local_agents/application.ex`, `apps/synapsis_local_agents/test/test_helper.exs`
- Modify: `apps/synapsis_server/mix.exs` (dep `{:synapsis_samgita, in_umbrella: true}`), `apps/synapsis_web/mix.exs` (deps on both new apps), `Dockerfile:34-43` (two `COPY apps/<app>/mix.exs` lines), `mix.lock`

**Interfaces:**
- Produces: OTP apps `:synapsis_samgita` (supervisor `SynapsisSamgita.Supervisor`) and `:synapsis_local_agents` (supervisor `SynapsisLocalAgents.Supervisor`), both with empty children for now.

- [ ] **Step 1:** Create both `mix.exs` files copying `apps/synapsis_sandbox/mix.exs` project shape (`build_path: "../../_build"`, `config_path: "../../config/config.exs"`, `deps_path: "../../deps"`, `lockfile: "../../mix.lock"`, `elixir: "~> 1.18"`, `elixirc_paths(:test) == ["lib", "test/support"]`, `mod:` the app's Application). Deps:
  - `synapsis_samgita`: `{:synapsis_core, in_umbrella: true}`, `{:synapsis_data, in_umbrella: true}`, `{:samgita_protocol, "~> 0.4.0"}`, `{:samgita_protocol_websocket, "~> 0.4.0"}`, `{:req, "~> 0.7.5"}`, `{:jason, "~> 1.4"}`, `{:gaoxy_test, "~> 0.15.1", only: :test}`.
  - `synapsis_local_agents`: `{:synapsis_core, in_umbrella: true}`, `{:synapsis_data, in_umbrella: true}`, `{:samgita_codex_driver, "~> 0.4.0"}`, `{:jason, "~> 1.4"}`.
- [ ] **Step 2:** `test_helper.exs` in both: `Synapsis.Session.Store.ensure_started()` then `ExUnit.start(exclude: [:functional])`.
- [ ] **Step 3:** Run `devenv shell -- bash -c 'mix deps.get && mix compile --warnings-as-errors'`. Expected: resolves with existing `websock_adapter` override (gaoxy_websock_adapter 0.15.2) and `http_web_socket` rc.13; compiles clean. If resolution conflicts, stop and route upstream.
- [ ] **Step 4:** Commit: `chore(umbrella): scaffold synapsis_samgita and synapsis_local_agents`.

### Task 2: Config kinds `:samgita` and `:local_agent` in `synapsis_data`

**Files:**
- Modify: `apps/synapsis_data/lib/synapsis/config/store.ex` (`@types` at :22-36, `file_path/1` at :361-380 → `:samgita -> "samgita.toml"`, `:local_agent -> "local_agents.toml"`)
- Create: `apps/synapsis_data/lib/synapsis/samgita_config.ex`, `apps/synapsis_data/lib/synapsis/local_agent_config.ex`, `apps/synapsis_data/lib/synapsis/local_agent_configs.ex`
- Test: `apps/synapsis_data/test/synapsis/samgita_config_test.exs`, `apps/synapsis_data/test/synapsis/local_agent_configs_test.exs`

**Interfaces:**
- Produces:
  - `Synapsis.SamgitaConfig.get() :: %{base_url: String.t() | nil, app_server_token?: boolean, agent_credential?: boolean}` (single entry id `"default"`; booleans say whether a secret is set, never the value)
  - `Synapsis.SamgitaConfig.put_base_url(String.t()) :: :ok | {:error, term}` — accepts only `http`/`https` URLs with host
  - `Synapsis.SamgitaConfig.rotate_secret(:app_server_token | :agent_credential) :: {:ok, plaintext :: String.t()}` — generates `Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)` (43 bytes, within Samgita's 32..4096), stores encrypted as `app_server_token_encrypted` / `agent_credential_encrypted`, returns plaintext once
  - `Synapsis.SamgitaConfig.resolve_secret(:app_server_token | :agent_credential) :: {:ok, String.t()} | {:error, :not_configured | :credential_unavailable}`
  - `%Synapsis.LocalAgentConfig{id, name, kind :: "codex", executable, args :: [String.t()], cwd, codex_home, autostart :: boolean}` with defaults `args: ["app-server", "--listen", "stdio://"]`, `codex_home: Path.expand("~/.codex")`, `autostart: false`
  - `Synapsis.LocalAgentConfigs.list/0`, `get/1`, `create/1`, `update/2`, `delete/1`, `ensure_default_codex/0` (creates `name: "Codex"`, `executable: System.find_executable("codex")` when no codex entry exists and the executable is found; idempotent)

- [ ] **Step 1: Write failing tests** (`use ExUnit.Case, async: false`, `setup` calls `Synapsis.DataCase.clear_config_store(:samgita)` / `(:local_agent)`):
  - `rotate_secret(:app_server_token)` returns a 43-byte string; `resolve_secret(:app_server_token)` returns the same value; `File.read!(Store.file_path(:samgita))` does not contain it and contains `"enc:v1:"`.
  - `get()` after rotate → `app_server_token?: true`, map has no plaintext.
  - `put_base_url("ftp://x")` → `{:error, _}`; `put_base_url("http://10.100.10.28:4870")` → `:ok`.
  - `resolve_secret(:agent_credential)` with nothing set → `{:error, :not_configured}`.
  - `LocalAgentConfigs.create(%{name: "Codex", kind: "codex", executable: "/bin/true"})` round-trips with default args/codex_home; `kind: "nope"` → `{:error, %Ecto.Changeset{}}`; `ensure_default_codex/0` twice yields one entry.
- [ ] **Step 2:** Run `devenv shell -- bash -c 'mix test apps/synapsis_data/test/synapsis/samgita_config_test.exs apps/synapsis_data/test/synapsis/local_agent_configs_test.exs'` → FAIL (undefined modules).
- [ ] **Step 3:** Implement, following `Synapsis.Toolset`/`Synapsis.Toolsets` (embedded_schema + changeset + `Store.put`/`merge_existing` under `Store.with_write_lock`) and the `Synapsis.Credentials` encrypt/decrypt helpers.
- [ ] **Step 4:** Re-run → PASS. Also run `devenv shell -- bash -c 'mix test apps/synapsis_data/test/synapsis/config_store_isolation_test.exs'` → PASS.
- [ ] **Step 5:** Commit: `feat(data): add samgita and local agent config kinds`.

### Task 3: Durable event inbox `Synapsis.Samgita.Inbox`

**Files:**
- Create: `apps/synapsis_data/lib/synapsis/samgita/inbox.ex`
- Test: `apps/synapsis_data/test/synapsis/samgita/inbox_test.exs`

**Interfaces:**
- Produces (entries are string-keyed maps `%{"event" => event_without_delivery_attempt_id, "last_delivery_attempt_id", "acceptance" => "durable", "processing_status", "decision_id", "decision", "result", "note", "received_at", "updated_at"}`):
  - `Inbox.record(event :: map) :: {:ok, :new | :duplicate, entry} | {:error, :conflict} | {:error, term}` — key `"coord/samgita/inbox/" <> Base.url_encode64(event_id, padding: false)`; insert-if-absent via `Synapsis.Runtime.Store`-style `txn` with compare `[{:exists, key, :==, false}]`; on existing key compare `event` minus `delivery_attempt_id` (`SamgitaProtocol.Event.same?/2` semantics) → `:duplicate` (updates `last_delivery_attempt_id` with revision CAS) or `:conflict`. Returns only after the Concord write commits.
  - `Inbox.get(event_id) :: {:ok, entry} | {:error, :not_found}`
  - `Inbox.list(limit :: pos_integer) :: [entry]` — newest `received_at` first
  - `Inbox.mark_processed(event_id, note :: String.t()) :: {:ok, entry} | {:error, :not_found}` — sets `processing_status: "completed"`, `note`
  - `Inbox.record_report(event_id, %{"decision_id", "status", "decision", "result"}) :: {:ok, entry} | {:error, :not_found | :conflict}` — first report sets `processing_status := status` and fields; identical repeat is `{:ok, entry}`; different repeat `:conflict`
  - Broadcast is NOT done here (data layer); callers broadcast.

- [ ] **Step 1: Write failing tests** (`setup` → `Synapsis.DataCase.clear_coord("coord/samgita/inbox/")`), using a fixture event `%{"schema_version"=>"1.0","event_id"=>"evt-1","delivery_attempt_id"=>"att-1","created_at"=>"2026-11-12T00:00:00Z","correlation_id"=>"c-1","type"=>"task.updated","project_ref"=>"p-1","payload"=>%{"sequence"=>1}}`:
  - `record(event)` → `{:ok, :new, %{"processing_status" => "pending", "acceptance" => "durable"}}`.
  - `record(%{event | "delivery_attempt_id" => "att-2"})` → `{:ok, :duplicate, %{"last_delivery_attempt_id" => "att-2"}}`; `list(10)` has length 1.
  - `record(put_in(event["payload"]["sequence"], 2))` → `{:error, :conflict}`; `get("evt-1")` payload still sequence 1.
  - `mark_processed("evt-1", "noted")` → status `"completed"`, note `"noted"`; `mark_processed("missing", "x")` → `{:error, :not_found}`.
  - `record_report` first → status from report; same again → ok; different `decision_id` → `{:error, :conflict}`.
- [ ] **Step 2:** Run `devenv shell -- bash -c 'mix test apps/synapsis_data/test/synapsis/samgita/inbox_test.exs'` → FAIL.
- [ ] **Step 3:** Implement with `Concord.KV` / `Concord.Turso` calls as in `apps/synapsis_data/lib/synapsis/goal/store.ex` (revision read + `compare_and_swap`), timeout 5_000 ms.
- [ ] **Step 4:** Re-run → PASS.
- [ ] **Step 5:** Commit: `feat(data): add durable samgita event inbox`.

### Task 4: Protocol host — Handler, `/app-server` Plug, endpoint mount

**Files:**
- Create: `apps/synapsis_samgita/lib/synapsis_samgita/app_server/handler.ex`, `apps/synapsis_samgita/lib/synapsis_samgita/app_server/plug.ex`, `apps/synapsis_samgita/lib/synapsis_samgita/events.ex`
- Modify: `apps/synapsis_server/lib/synapsis_server/endpoint.ex` (insert `plug SynapsisSamgita.AppServer.Plug` before `Plug.Parsers` at :44)
- Test: `apps/synapsis_samgita/test/synapsis_samgita/app_server/handler_test.exs`, `apps/synapsis_server/test/synapsis_server/app_server_test.exs`

**Interfaces:**
- Consumes: `Synapsis.Samgita.Inbox` (Task 3), `Synapsis.SamgitaConfig.resolve_secret(:app_server_token)` (Task 2).
- Produces:
  - `SynapsisSamgita.AppServer.Handler` implementing `SamgitaProtocol.Handler`: `capabilities/0 == ["project_events.v1"]`, `methods/0 == ~w(project/event.receive project/event.report project/event.status)`. Receive result `%{"event_id", "delivery_attempt_id" => <incoming>, "acceptance" => "durable", "processing_status"}`; status result adds `decision_id`/`decision`/`result` when present; report result `%{"event_id","decision_id","report_status" => "recorded","management_acceptance" => "not_requested"}`. Inbox `:conflict` → `SamgitaProtocol.Error.new("conflict")`; `:not_found` → `Error.new("not_found")`; other store errors → `Error.new("handler_error")` (never `durable`).
  - `SynapsisSamgita.Events.subscribe/0` and `broadcast_inbox_changed(event_id)` on topic `"samgita:inbox"`, message `{:samgita_inbox_changed, event_id}`; Handler broadcasts after successful record/report.
  - `SynapsisSamgita.AppServer.Plug`: passes through unless `conn.request_path == "/app-server"`; otherwise delegates to `SamgitaProtocolWebSocket.Plug.call(conn, opts)` with `handler: SynapsisSamgita.AppServer.Handler`, `handler_state: nil`, `authenticate: &SynapsisSamgita.AppServer.Plug.authenticate/1`. `authenticate(token)` → `{:ok, :samgita}` iff `resolve_secret(:app_server_token)` is ok and `Plug.Crypto.secure_compare/2` matches; else `:error`.

- [ ] **Step 1: Handler tests** (drive `SamgitaProtocol.Server.new(Handler, nil)` + `Server.receive/2` with maps; send `connection/initialize` `{"versions"=>["1.0"],"capabilities"=>["project_events.v1"],"required_capabilities"=>["project_events.v1"]}` first):
  - initialize response has `"capabilities" => ["project_events.v1"]`.
  - receive (with `command_id`) → `acceptance "durable"`, `processing_status "pending"`, echoes `delivery_attempt_id`.
  - receive same event with `"att-2"` → result echoes `"att-2"`; `Inbox.list` length 1.
  - receive conflicting payload → response `error.code == "conflict"`.
  - status unknown id → `"not_found"`; after `Inbox.mark_processed` → `processing_status "completed"`.
  - report then status → status carries `decision_id`.
- [ ] **Step 2:** Run → FAIL. Implement Handler + Events. Re-run `devenv shell -- bash -c 'mix test apps/synapsis_samgita/test'` → PASS.
- [ ] **Step 3: Endpoint integration test** in `synapsis_server`: start `{Gaoxy.HTTP, Keyword.merge(SynapsisServer.Endpoint.config(:http), id: __MODULE__, plug: SynapsisServer.Endpoint, ip: {127,0,0,1}, port: 0)}` (pattern: `apps/synapsis_server/test/synapsis_server/websocket_transport_test.exs`), rotate the app-server token, then `SamgitaProtocolWebSocket.Client.connect("ws://127.0.0.1:#{port}/app-server", token: token, capabilities: ["project_events.v1"], allow_insecure: true)` → `Client.request(client, "connection/initialize", ...)` ok, `Client.request(client, "project/event.receive", %{"event" => ev}, command_id: "cmd-1")` → `{:ok, %{"acceptance" => "durable"}}`. Wrong token → connect fails (401). `GET /api/health` still 200 (router unaffected).
- [ ] **Step 4:** Mount plug in endpoint; run `devenv shell -- bash -c 'mix test apps/synapsis_server/test/synapsis_server/app_server_test.exs apps/synapsis_server/test/synapsis_server/router_test.exs'` → PASS.
- [ ] **Step 5:** Commit: `feat(samgita): host project_events.v1 at /app-server`.

### Task 5: Management API client `SynapsisSamgita.API`

**Files:**
- Create: `apps/synapsis_samgita/lib/synapsis_samgita/api.ex`
- Test: `apps/synapsis_samgita/test/synapsis_samgita/api_test.exs`

**Interfaces:**
- Produces (all functions take `conn :: %{base_url, credential, connection_id | nil}` first; all writes generate `command_id = Ecto.UUID.generate()` unless `opts[:command_id]` given; `receive_timeout: 10_000`, `retry: false`; return `{:ok, data}` (the `"data"` value) or `{:error, %{status: integer | nil, code: String.t(), detail: term}}` — transport errors use `status: nil, code: "transport_error"`):
  - `connect(conn) :: {:ok, %{"id", "agent_id", "generation", "expires_at"}}` — `POST /api/agent/connect`, no `x-agent-connection`
  - `list_projects(conn)` — `GET /api/agent/projects`
  - `list_tasks(conn, project_id, agent_id)` — `GET /api/agent/projects/:pid/tasks?assignee_agent_id=...&limit=100`
  - `create_session(conn, project_id, external_id)` — `POST .../sessions`
  - `claim(conn, project_id, task_id, expected_version, session_id)`
  - `proof(conn, project_id, attempt_id) :: {:ok, String.t()}`
  - `start(conn, pid, attempt_id, version, proof)`, `renew(conn, pid, attempt_id, version, proof)`, `progress(conn, pid, attempt_id, version, proof, summary)`, `report(conn, pid, attempt_id, version, proof, outcome :: "succeeded" | "failed", effects_resolved :: boolean, result :: map | nil)`
  - A retry of an uncertain write reuses the same `command_id` and body (caller passes `command_id:`).

- [ ] **Step 1: Failing tests** with `Gaoxy.Test.open()`: `connect` sends `authorization: Bearer <cred>`, body has a UUID `command_id`, no `x-agent-connection`; `list_tasks` sends `x-agent-connection` and `assignee_agent_id` query; `report` body has `outcome`, `effects_resolved`, `proof`, `expected_version`; 409 `{"errors":{"code":"stale_version","detail":...}}` → `{:error, %{status: 409, code: "stale_version"}}`; 401 → `code: "unauthorized"`; closed server → `code: "transport_error"`. Assert the credential never appears in `ExUnit.CaptureLog` output.
- [ ] **Step 2:** Run `devenv shell -- bash -c 'mix test apps/synapsis_samgita/test/synapsis_samgita/api_test.exs'` → FAIL; implement with `Req.request/1`; re-run → PASS.
- [ ] **Step 3:** Commit: `feat(samgita): add management api client`.

### Task 6: Connection and Attempt processes

**Files:**
- Create: `apps/synapsis_samgita/lib/synapsis_samgita/connection.ex`, `apps/synapsis_samgita/lib/synapsis_samgita/attempt.ex`, `apps/synapsis_samgita/lib/synapsis_samgita.ex` (facade)
- Modify: `apps/synapsis_samgita/lib/synapsis_samgita/application.ex` (children: `{Registry, keys: :unique, name: SynapsisSamgita.AttemptRegistry}`, `{DynamicSupervisor, name: SynapsisSamgita.AttemptSupervisor}`, `SynapsisSamgita.Connection`)
- Test: `apps/synapsis_samgita/test/synapsis_samgita/connection_test.exs`, `apps/synapsis_samgita/test/synapsis_samgita/attempt_test.exs`

**Interfaces:**
- Consumes: `SynapsisSamgita.API` (Task 5), `Synapsis.SamgitaConfig` (Task 2).
- Produces:
  - `SynapsisSamgita.connect() :: {:ok, status} | {:error, map}`; `status() :: %{state: :disconnected | :connected | :error, agent_id, connection_id, expires_at, last_error}`; `subscribe/0` on `"samgita:status"` (`{:samgita_status, status}`). Connection is not auto-started at boot (manual Connect button); `last_error` holds `code` only.
  - `SynapsisSamgita.list_projects/0`, `list_tasks(project_id)` — use current connection; `{:error, %{code: "not_connected"}}` when disconnected.
  - `SynapsisSamgita.claim(project_id, task) :: {:ok, attempt_view}` — creates a session with `external_id: "synapsis-#{task["id"]}-#{Ecto.UUID.generate()}"` (unique per claim; no session reuse this phase), claims, starts `SynapsisSamgita.Attempt` under the DynamicSupervisor registered by attempt id.
  - `SynapsisSamgita.attempt_start(attempt_id)`, `attempt_progress(attempt_id, summary)`, `attempt_report(attempt_id, outcome, effects_resolved, result)`, `list_attempts() :: [attempt_view]`.
  - `attempt_view :: %{id, project_id, task_id, state, version, lease_expires_at, last_error}` (no proof). Broadcast `{:samgita_attempt, attempt_view}` on `"samgita:attempts"` after every successful step or error.
  - `Attempt` GenServer: holds `version` and `proof` (fetched via `API.proof` after claim and after every renew); renews every `renew_interval_ms` (default 60_000, overridable via `opts` for tests) until terminal; after a successful renew re-reads proof; on renew error sets `last_error` and keeps trying until `lease_expires_at` passes, then marks `state: "lost"` and stops. A manual step that fails leaves `version/state` unchanged. Process stops `:normal` after `report` succeeds. Every Attempt sends `{:attempt_view, view}` to `SynapsisSamgita.Connection`, which keeps the latest view per attempt id in its state; `list_attempts/0` reads from there, so finished/lost attempts remain visible until Synapsis restarts.

- [ ] **Step 1: Failing tests** with `Gaoxy.Test` stubbing Samgita:
  - connect stores `agent_id`/`connection_id`, broadcasts `:connected`; 401 → `state: :error, last_error: "unauthorized"`.
  - claim → session POST then claim POST with `expected_version` = task version and the session id; proof GET follows.
  - With `renew_interval_ms: 50`: two renew POSTs observed (`Gaoxy.Test.requests/1`), each using the proof returned by the preceding proof GET (stub returns `"v1.k.p1"` then `"v1.k.p2"`); a subsequent `attempt_progress` uses the latest proof and latest version.
  - progress returning 409 `stale_version` → `{:error, %{code: "stale_version"}}`, `list_attempts` version unchanged, `last_error == "stale_version"`.
  - report succeeded/true → attempt process exits normally, view state `"succeeded"`.
- [ ] **Step 2:** Run `devenv shell -- bash -c 'mix test apps/synapsis_samgita/test'` → FAIL; implement; re-run → PASS.
- [ ] **Step 3:** Commit: `feat(samgita): connect and drive attempts with lease renewal`.

### Task 7: Samgita LiveView page + operator setup doc

**Files:**
- Create: `apps/synapsis_web/lib/synapsis_web/live/samgita_live/index.ex`, `docs/samgita-setup.md`
- Modify: `apps/synapsis_server/lib/synapsis_server/router.ex` (`live "/samgita", SamgitaLive.Index, :index` in scope at :98; add module to `no_warn_undefined` at :6-27), `apps/synapsis_web/lib/synapsis_web/components/layouts/app.html.heex:15-24` (appbar menu "Samgita", icon `mdi` `lan-connect`, same sr-only/hidden-sm pattern)
- Test: `apps/synapsis_web/test/synapsis_web/live/samgita_live_test.exs`

**Interfaces:**
- Consumes: `Synapsis.SamgitaConfig` (Task 2), `Synapsis.Samgita.Inbox` (Task 3), `SynapsisSamgita.Events`, `SynapsisSamgita` facade (Task 6).

- [ ] **Step 1: Failing LiveView tests** (`use SynapsisWeb.ConnCase`; clear `:samgita` config and `coord/samgita/inbox/`):
  - `live(conn, ~p"/samgita")` renders `h1` "Samgita"; base URL form saves `http://10.100.10.28:4870`.
  - Clicking "Generate app-server token" shows a 43-char token once in a `[data-role=revealed-secret]` element; after re-render (`live` again) the token is not in the HTML and status shows "configured".
  - With an inbox entry recorded via `Inbox.record/1`, the events table lists `event_id`, `type`, `acceptance`, `processing_status`; clicking "Mark processed" with note → row shows `completed`; a `{:samgita_inbox_changed, id}` broadcast triggers re-render of a newly recorded event.
  - When disconnected, the tasks section shows "Not connected" and the Connect button. Connected/attempt flows are covered in Task 6; here inject a `{:samgita_attempt, view}` broadcast and assert the row shows state and Start/Progress/Report buttons appropriate to state (`leased` → Start; `running` → Progress, Report).
- [ ] **Step 2:** Run → FAIL. Implement page with DuskMoon components (`dm_card`, `dm_btn`, `dm_form`, `dm_table` or div rows matching existing settings pages); load data in `handle_params`; subscribe in `mount` when `connected?`. Report form fields: outcome select (`succeeded`/`failed`), `effects_resolved` checkbox (default checked), optional result note (sent as `%{"note" => text}`).
- [ ] **Step 3:** Write `docs/samgita-setup.md` (operator steps, ≤1 page): register Agent via Samgita `/agents` (protocol `samgita`/`1.0`, transport `websocket`, url `ws://127.0.0.1:4657/app-server`, advertised+approved `project_events.v1`, `credential_ref` e.g. `synapsis-local-v1`); add inbound credential = Synapsis "agent credential"; membership roles `worker`, `manager`; event routing to this Agent; Samgita env `SAMGITA_EVENT_DESTINATIONS={"<agent_uuid>":{"url":"ws://127.0.0.1:4657/app-server","addresses":["127.0.0.1"],"allow_insecure":true}}` and `SAMGITA_EVENT_CREDENTIALS={"synapsis-local-v1":"<Synapsis app-server token>"}`; restart Samgita.
- [ ] **Step 4:** Run `devenv shell -- bash -c 'mix test apps/synapsis_web/test/synapsis_web/live/samgita_live_test.exs apps/synapsis_web/test/synapsis_web/live/dashboard_live_test.exs'` → PASS.
- [ ] **Step 5:** Commit: `feat(web): add samgita connection page`.

### Task 8: Local agent interface — Adapter behaviour, Event, Runner, facade

**Files:**
- Create: `apps/synapsis_local_agents/lib/synapsis_local_agents.ex` (facade), `.../adapter.ex`, `.../event.ex`, `.../runner.ex`
- Modify: `apps/synapsis_local_agents/lib/synapsis_local_agents/application.ex` (children: `{Registry, keys: :unique, name: SynapsisLocalAgents.Registry}`, `{DynamicSupervisor, name: SynapsisLocalAgents.RunnerSupervisor}`, a `Task` that calls `Synapsis.LocalAgentConfigs.ensure_default_codex/0` and starts runners for `autostart: true` configs)
- Create test support: `apps/synapsis_local_agents/test/support/fake_adapter.ex`
- Test: `apps/synapsis_local_agents/test/synapsis_local_agents/runner_test.exs`

**Interfaces:**
- Consumes: `Synapsis.LocalAgentConfigs` (Task 2).
- Produces:
  - `%SynapsisLocalAgents.Event{agent_id, type, thread_id, turn_id, item_id, data}` with `type ∈ :status | :thread_started | :turn_started | :turn_completed | :item_started | :item_delta | :item_completed | :interaction`; for `:turn_completed` `data.status ∈ "completed" | "interrupted" | "failed"`; for `:item_delta` `data.delta :: String.t()`; for `:interaction` `data == %{method: String.t(), decision: String.t()}`.
  - `SynapsisLocalAgents.Adapter` behaviour (adapter is a process started by Runner, `owner` = Runner pid; adapter sends `{:local_agent_event, %Event{}}` to owner):
    - `start_link(config :: Synapsis.LocalAgentConfig.t(), owner :: pid) :: GenServer.on_start()`
    - `list_threads(pid) :: {:ok, [%{id, title, updated_at}]} | {:error, term}`
    - `start_thread(pid) :: {:ok, %{id}}`, `read_thread(pid, thread_id) :: {:ok, %{id, turns: [%{id, status, items: [%{id, role :: :user | :agent, text}]}]}}`, `resume_thread(pid, thread_id) :: {:ok, %{id}}`
    - `start_turn(pid, thread_id, text) :: {:ok, %{turn_id}}`, `steer_turn(pid, thread_id, turn_id, text) :: :ok | {:error, term}`, `interrupt_turn(pid, thread_id, turn_id) :: :ok | {:error, term}`
    - `stop(pid) :: :ok`
  - Adapter module lookup: `Application.get_env(:synapsis_local_agents, :adapters, %{"codex" => SynapsisLocalAgents.Codex})`.
  - Facade (`agent_id` = config id): `list() :: [%{config, status}]`, `start(agent_id)`, `stop(agent_id)`, `status(agent_id) :: %{state: :stopped | :starting | :running | :crashed, last_error: String.t() | nil}`, `subscribe(agent_id)` on topic `"local_agent:#{agent_id}"`, `subscribe_all()` on `"local_agents"` (status only), plus pass-through `list_threads/1`, `start_thread/1`, `read_thread/2`, `resume_thread/2`, `start_turn/3`, `steer_turn/4`, `interrupt_turn/3` returning `{:error, :not_running}` when stopped. Calls use `GenServer.call(..., 35_000)`.
  - `Runner`: one per agent id (registered in `SynapsisLocalAgents.Registry`), started lazily by `start/1`; traps exits; starts adapter, monitors it; on adapter exit with non-`:normal` reason → `state: :crashed, last_error: inspect-safe short reason`; `stop/1` → adapter `stop`, `state: :stopped`. Broadcasts every Event on `"local_agent:#{id}"` and status changes also on `"local_agents"`.

- [ ] **Step 1: Failing tests** using `FakeAdapter` (records calls, can be told to emit events or crash via `send(adapter_pid, {:crash, reason})`):
  - `start(id)` → status `:running` and `{:local_agent_event, %Event{type: :status}}` received after `subscribe(id)`.
  - `start_turn(id, "t1", "hi")` → `{:ok, %{turn_id: _}}`; fake-emitted `:item_delta` arrives on the topic.
  - fake crash → status `:crashed` with `last_error` set; `start(id)` again → `:running`.
  - `stop(id)` → `:stopped`; `start_turn` → `{:error, :not_running}`.
- [ ] **Step 2:** Run `devenv shell -- bash -c 'mix test apps/synapsis_local_agents/test'` → FAIL; implement; re-run → PASS.
- [ ] **Step 3:** Commit: `feat(local-agents): add unified local agent runner`.

### Task 9: Codex adapter over `SamgitaCodexDriver.Session`

**Files:**
- Create: `apps/synapsis_local_agents/lib/synapsis_local_agents/codex.ex`
- Create test support: `apps/synapsis_local_agents/test/support/scripted_transport.ex` (own implementation of the `SamgitaCodexDriver.Transport` behaviour — `open/send/handle_info/close/metadata` — reporting sent wires to an observer pid and accepting `{:incoming, wire}` / `:drop_connection`)
- Test: `apps/synapsis_local_agents/test/synapsis_local_agents/codex_test.exs`

**Interfaces:**
- Consumes: Adapter behaviour + Event (Task 8).
- Produces: `SynapsisLocalAgents.Codex` implementing the Adapter behaviour.
  - `start_link/2`: GenServer; in `init` (via `handle_continue`) starts `SamgitaCodexDriver.Session.start_link(transport: transport(config), owner: self())` where `transport(config)` is `{SamgitaCodexDriver.Transport.Stdio, executable:, args:, cwd:, codex_home:, env: %{"HOME" => System.user_home!()}}` (overridable via `config`-independent app env `:synapsis_local_agents, :codex_transport` for tests), then `Session.initialize(session, %{"name" => "synapsis", "version" => <app vsn>}, %{"experimentalApi" => false})`; monitors the session; session exit → stop with `{:codex_exited, reason}`.
  - Requests (timeout 30_000): `thread/list` (`effect: :read`) → map `data[]` to `%{id, title: preview/name, updated_at}`; `thread/start` `%{}`; `thread/read` `%{"threadId", "includeTurns" => true}`; `thread/resume` `%{"threadId"}`; `turn/start` `%{"threadId", "input" => [%{"type" => "text", "text" => text}]}` → `turn_id = result["turn"]["id"]`; `turn/steer` `%{"threadId","expectedTurnId","input"}`; `turn/interrupt` `%{"threadId","turnId"}`.
  - On `{:codex_driver, _, :events_available}` drain until empty; map `:notification` methods: `thread/started` → `:thread_started`; `turn/started` → `:turn_started`; `turn/completed` → `:turn_completed` (`data.status = turn.status`); `item/started` / `item/completed` → `:item_started` / `:item_completed` (`data.item` = sanitized `%{type, text}` only); `item/agentMessage/delta` → `:item_delta`. Other notifications ignored.
  - `:server_request`: approval methods (`item/commandExecution/requestApproval`, `item/fileChange/requestApproval`, `item/permissions/requestApproval`, `applyPatchApproval`, `execCommandApproval`) → `Session.respond(session, handle, {:ok, %{"decision" => "accept"}})` and emit `:interaction`; any other server request → `Session.respond(session, handle, {:error, %{"code" => -32601, "message" => "unsupported by synapsis"}})`.
  - `{:codex_driver, _, {:gap, _}}` → stop `{:codex_disconnected, reason}` (Runner reports crashed).
  - `stop/1` → `Session.close(session)` then stop `:normal`.
  - Logs only method names and ids, never wire payloads.

- [ ] **Step 1: Failing tests** with ScriptedTransport (respond to the driver's `initialize` wire with a valid initialize result, then script responses):
  - `start_turn` sends `turn/start` with the text input and returns the scripted turn id.
  - Injected `item/agentMessage/delta` and `turn/completed` (`status: "interrupted"`) notifications arrive at owner as `:item_delta` / `:turn_completed` Events.
  - Injected `item/commandExecution/requestApproval` server request → transport observes a response with `"decision" => "accept"`; owner gets `:interaction`.
  - `:drop_connection` → adapter exits non-normally (Review Focus 4).
  - `list_threads` sends `thread/list`.
- [ ] **Step 2:** Run `devenv shell -- bash -c 'mix test apps/synapsis_local_agents/test/synapsis_local_agents/codex_test.exs'` → FAIL; implement; re-run → PASS. If the driver rejects scripted wires for schema reasons, use `schema_mode: :compatible` (default) and valid schema-shaped fixtures from `deps/samgita_protocol_codex/priv/upstream/current/stable/v2`.
- [ ] **Step 3:** Commit: `feat(local-agents): add codex adapter`.

### Task 10: Local Agents LiveView page

**Files:**
- Create: `apps/synapsis_web/lib/synapsis_web/live/local_agent_live/index.ex`
- Create test support: `apps/synapsis_web/test/support/local_agent_fake_adapter.ex` (same contract as Task 8's FakeAdapter; web cannot see local_agents' test/support)
- Modify: `apps/synapsis_server/lib/synapsis_server/router.ex` (`live "/local-agents", LocalAgentLive.Index, :index`, `live "/local-agents/:agent_id", LocalAgentLive.Index, :agent`, `live "/local-agents/:agent_id/threads/:thread_id", LocalAgentLive.Index, :thread`; add to `no_warn_undefined`), `apps/synapsis_web/lib/synapsis_web/components/layouts/app.html.heex` (appbar menu "Local Agents", icon `robot-outline`)
- Test: `apps/synapsis_web/test/synapsis_web/live/local_agent_live_test.exs`

**Interfaces:**
- Consumes: `SynapsisLocalAgents` facade + `Event` (Task 8).

- [ ] **Step 1: Failing LiveView tests** (set `Application.put_env(:synapsis_local_agents, :adapters, %{"codex" => SynapsisWeb.LocalAgentFakeAdapter})` in setup, restore `on_exit`; create a codex config via `LocalAgentConfigs.create`):
  - `/local-agents` lists "Codex" with status "stopped" and a Start button; click Start → "running".
  - `/local-agents/:id` shows thread list from adapter; "New session" navigates to `/local-agents/:id/threads/:tid`.
  - Submitting the message form calls `start_turn`; broadcasting `:item_delta` Events for that thread appends text in `[data-role=agent-stream]`; `:turn_completed` with `"interrupted"` shows an "interrupted" badge.
  - While a turn is running, Interrupt button calls `interrupt_turn`.
  - Fake crash → status "crashed" with reason text; Stop → "stopped".
  - Opening an existing thread renders `read_thread` history (user and agent items).
- [ ] **Step 2:** Run → FAIL. Implement: two-column layout (agent list with status badge + Start/Stop; right: thread list or conversation); load in `handle_params`; subscribe `subscribe_all/0` in mount and `subscribe(agent_id)` per selected agent; message input as a `dm_form` textarea (Cmd+Enter submit, consistent with the existing chat input). DuskMoon tokens only.
- [ ] **Step 3:** Run `devenv shell -- bash -c 'mix test apps/synapsis_web/test/synapsis_web/live/local_agent_live_test.exs'` → PASS.
- [ ] **Step 4:** Commit: `feat(web): add local agents page`.

### Task 11: Integrated verification and manual demo

**Files:** none new (fix-forward only within files above).

- [ ] **Step 1:** `devenv shell -- bash -c 'mix format --check-formatted && mix compile --warnings-as-errors && mix test'` → all PASS. Record any unrelated pre-existing failures without fixing.
- [ ] **Step 2:** `cd apps/synapsis_web && devenv shell -- bash -c 'mix assets.build'` → success.
- [ ] **Step 3:** `devenv processes restart synapsis` (if it no-ops, stop + start per memory note); `curl -s localhost:4657/api/health` → status ok.
- [ ] **Step 4 (manual, line B):** On `/local-agents` start Codex, new session, send a message, see streaming, interrupt a long reply, reload page and resume the session, stop Codex. Note results.
- [ ] **Step 5 (manual, line A):** follow `docs/samgita-setup.md` against `http://10.100.10.28:4870/`; Samgita-side env changes are an operator action — ask the user before restarting Samgita. Verify spec §6 A1–A6. Note results.
- [ ] **Step 6:** Commit any fixes: `fix(<scope>): ...`.
