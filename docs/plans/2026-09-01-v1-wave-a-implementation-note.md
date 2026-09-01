# Synapsis v1 Wave A Implementation Note

Status: complete

Synapsis baseline: `main@0d6cc714ec16b34c8c191f158fe82c8a6ef08cf8`

Backplane reference: `main@938863b247fc0a42e2c2e181136696e7954c880f`

Current source and tests override historical examples in
`docs/architecture/05_TOOLS.md`, `docs/architecture/07_AGENT_SYSTEM.md`, and
`SYNAPSIS_AGENT_DAEMON_DESIGN_FOR_CODEX.md`.

## M0 baseline

GitHub Actions run `33462708089` exposed a probabilistic encrypted-binary test.
Repeated local runs also exposed file-backed Provider LiveView fixtures surviving
between Mix test runs. Local commit `fd816fb` fixes both test boundaries without
production changes, retries, timeout increases, or skips. It passed format,
warnings-as-errors compile, 2,038 ExUnit tests, 7 hook tests, TypeScript, and
production assets. Remote M0 is
not green until this fix reaches `main` and its CI run succeeds.

## Twelve current-path answers

| # | Current path and selected seam |
|---|---|
| 1 | LiveView, REST, and Channel prompts converge on `Synapsis.Sessions.send_message/2,3` -> `Session.Worker.send_message/3`. The daemon will use this facade. |
| 2 | CodingLoop success emits `"done"` then idle; failures emit `"error"` plus error status. QueryLoop emits no done event and loses some failure status, so autonomous v1 runs use CodingLoop. |
| 3 | `ToolDispatch` classifies through `ToolDispatcher` and `Tool.Permission`. Allowed calls route directly to `ToolExecute`; only `:requires_approval` calls route through `ApprovalGate` first. |
| 4 | Both branches reach `ToolExecute` -> `Tool.Executor.execute_approved/3`. A daemon run exposes an explicit toolset and pre-approves only calls present in it; interactive approval remains unchanged. |
| 5 | `AgentRun` has queued, running, waiting_approval, sleeping, completed, failed, and cancelled, but no interrupted status or validated transitions. Wave B adds interrupted/restart reason handling and surfaces store errors. |
| 6 | `HeartbeatConfig` persists to `heartbeats.toml`; `LocalScheduler` starts `Heartbeat.Worker` directly. The worker creates no AgentRun and waits for events nobody emits, so it will trigger the daemon. |
| 7 | `skills.toml` -> `Synapsis.Skills`; agent `skill_ids` resolve through `Agent.Resolver`, then `ContextBuilder` injects prompt fragments. Backplane imports enter this path. |
| 8 | `mcp.toml` -> `MCPConfigs` -> `MCP.Server` -> `tools/list` -> `Tool.Registry` names `mcp:<server>:<tool>`. Imported MCP artifacts reuse this runtime and explicit reconcile/restart. |
| 9 | `providers.toml` -> `Synapsis.Providers` -> `Provider.Registry`. Dynamic models live in provider `available_models` / `enabled_models`, so imported providers/models reuse this path. |
| 10 | Backplane exposes `/v1/models`, all archives at `/skills/export`, metadata/search at `/skills`, detail at `/skills/:slug`, and `/mcp` JSON-RPC tools/prompts/resources. There is no unified catalog endpoint and none will be invented. |
| 11 | URLs and OAuth `client_id` are public; access tokens and `client_secret` are secret. Current provider persistence bypasses `Synapsis.Encrypted.Binary.dump/1`; Wave D must correct/reuse that secret seam before storing a Backplane token. |
| 12 | `fix/restore-green-main@fd816fb`, based on current `origin/main`, is locally green. `main` and its last CI run remain at failed `0d6cc71` until explicitly integrated and verified. |

## Minimum implementation decisions

- Add one permanently supervised `Synapsis.Agent.Daemon`; its small interface owns
  bounded FIFO coordination and AgentRun/session correlation only.
- Use one ephemeral CodingLoop session per run. Subscribe before submission,
  persist `session_id`, and translate correlated done/error/cancel/down signals.
- Keep provider, graph, streaming, tool, Concord, and config implementations in
  their existing modules. Daemon callbacks perform no long I/O.
- Route heartbeat, schedule, and dream through the same daemon path.
- Keep each Backplane connection as a distinct capability-source record with its
  own sync/last-known-good lifecycle. Per connection, sync creates source-managed
  provider/model, skill, and MCP artifacts in the existing subsystems; the
  connection itself is not a Provider or MCP config.
- Aggregate Backplane from `/v1/models`, `/skills/export`, and MCP `tools/list`.
  Preserve surfaces independently on failure and hash normalized content for the
  composite source revision.

Immediate gaps are confined to their owning waves: `Runs` transition/store error
handling, `SessionBridge` subscription ordering, nonexistent Heartbeat completion
tuples, Provider/MCP runtime reconciliation after config reload, and secure token
persistence. No new auth, permission engine, scheduler, provider runtime, skill
runtime, MCP runtime, SQL store, or distributed ownership is introduced.
