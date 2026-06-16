# Replace `synapsis_plugin` with `anubis_mcp` (+ remove LSP, rehome sandbox)

- **Date:** 2026-06-15
- **Status:** Approved design, pending implementation plan
- **Scope:** Single large spec covering the full removal of the `synapsis_plugin`
  umbrella app and the adoption of the `anubis_mcp` library for the MCP client.

## 1. Goal

Replace our hand-rolled MCP client with the `anubis_mcp` library (`Anubis.Client`,
v1.6.x), and in the process dissolve the `synapsis_plugin` umbrella app entirely.
MCP and the sandbox bridge move to new dedicated apps; LSP and the custom plugin
framework are deleted.

## 2. Motivation

- The hand-rolled MCP client (`SynapsisPlugin.MCP`, `MCP.Protocol`) reimplements
  JSON-RPC framing, the initialize handshake, stdio Port management, and HTTP/SSE
  transport. `anubis_mcp` is a maintained Elixir MCP SDK that does all of this,
  including the modern Streamable HTTP transport.
- A real bug exists today: restarting an MCP server does not reset its tools.
  `SynapsisPlugin.Server` does not trap exits, so `terminate/2` (the only path
  that unregisters tools) never runs on `DynamicSupervisor.terminate_child/2`, and
  `Synapsis.Tool.Registry` has no pid monitor as a safety net. The new design fixes
  the root cause (see §7).
- `synapsis_plugin` has accreted unrelated responsibilities (MCP, LSP, a sandbox
  bridge, a generic plugin behaviour + loader). Splitting these clarifies
  boundaries.

## 3. Decisions (locked)

| Decision | Choice |
|----------|--------|
| MCP client | `anubis_mcp` (`Anubis.Client`), v1.6.x |
| MCP home | New app `synapsis_mcp` |
| Sandbox bridge home | New app `synapsis_sandbox` |
| LSP | **Removed entirely** (not rehomed) |
| Plugin framework (behaviour/loader/server/supervisor) | Removed |
| `synapsis_plugin` app | Deleted from umbrella |
| Transports | `stdio`, `streamable_http`, `sse` |
| Config schema | Redesigned (drops `.opencode.json` compatibility) |
| Old hand-rolled MCP code | Deleted |

## 4. Target architecture

### 4.1 Umbrella layout & dependency direction

```
synapsis_data
  <- synapsis_provider
  <- synapsis_core
  <- synapsis_workspace
  <- synapsis_agent
  <- synapsis_mcp        (new)
  <- synapsis_sandbox    (new)
  <- synapsis_server
  <- synapsis_web
```

- `synapsis_mcp` deps: `synapsis_core` (`Synapsis.Tool.Registry`),
  `synapsis_data` (config), `anubis_mcp ~> 1.6`.
- `synapsis_sandbox` deps: `synapsis_core` (`Synapsis.Tool.Executor`).
- `synapsis_server` mix dep `synapsis_plugin` is replaced by `synapsis_mcp` +
  `synapsis_sandbox`.
- Each new app owns its own `application.ex` + supervision tree. The soft
  `maybe_apply(SynapsisPlugin.Supervisor / Loader, ...)` lines in
  `synapsis_core/application.ex` are removed; core no longer boots plugins.

### 4.2 `synapsis_mcp` internals

- `Synapsis.MCP.Supervisor` — top-level supervisor started by the app, containing:
  - `Registry` (`Synapsis.MCP.Registry`, keys: `:unique`) — one entry per server.
  - `DynamicSupervisor` (`Synapsis.MCP.DynamicSupervisor`, `:one_for_one`).
  - A boot task that auto-starts every enabled config.
- `Synapsis.MCP.Server` — one GenServer per configured MCP server. Responsibilities:
  1. Build an Anubis transport tuple from config (§6).
  2. Start an `Anubis.Client` (as a linked child or supervised process keyed in the
     registry) with `client_info`, `capabilities`, `protocol_version`, and transport.
  3. `Anubis.Client.await_ready/2` (bounded timeout) before discovering tools.
  4. `Anubis.Client.list_tools/1` → register each tool as `mcp:<server>:<tool>`
     (process-dispatch) in `Synapsis.Tool.Registry`, with description + input schema.
  5. Handle `{:execute, tool, input, ctx}` by calling
     `Anubis.Client.call_tool/3` and normalizing `Anubis.MCP.Response` into the
     `{:ok, content} | {:error, reason}` shape `Synapsis.Tool.Executor` expects.
  6. Trap exits; unregister its tools in `terminate/2`.
- `Synapsis.MCP` — public façade:
  - `start(config)` / `stop(name)` / `restart(name)` / `list/0` / `status(name)`.
  - `restart/1` = `stop` (terminate → tools purged) then `start` (fresh discovery).

### 4.3 `synapsis_sandbox` internals

- New app hosting the existing `sandbox_bridge.ex` essentially unchanged
  (module renamed to `Synapsis.Sandbox.Bridge` or kept under a `Synapsis.Sandbox`
  namespace — naming finalized in the plan).
- Routes sandbox-initiated JSON-RPC requests back through
  `Synapsis.Tool.Executor` (in `synapsis_core`) so tool policy still applies.
- Tests move with it.

## 5. Removals (detailed)

- **MCP (old):** `synapsis_plugin/lib/synapsis_plugin/mcp.ex`,
  `mcp/protocol.ex`, `mcp/presets.ex`.
- **LSP (all):** `lsp.ex`, `lsp/manager.ex`, `lsp/protocol.ex`,
  `lsp/position.ex`, `lsp/presets.ex`, plus:
  - `synapsis_core/lib/synapsis/tool/diagnostics.ex` (LSP-only tool) **and its
    registration** — the agent loses the `diagnostics` tool. *(Confirmed
    acceptable.)*
  - `synapsis_web` `lsp_live` LiveView + its route.
- **Plugin framework:** `synapsis/plugin.ex` (behaviour),
  `synapsis_plugin/loader.ex`, `server.ex`, `supervisor.ex`,
  `synapsis_plugin.ex`.
- **App:** remove `apps/synapsis_plugin` from the umbrella; drop its dep from
  `synapsis_server/mix.exs`; remove the soft boot lines from
  `synapsis_core/application.ex`.
- **Tests:** delete obsolete plugin / LSP / old-MCP tests; move sandbox tests.

## 6. Config schema redesign

Stored in `synapsis_data` (`Synapsis.PluginConfigs` → renamed to an MCP-specific
store, e.g. `Synapsis.MCPConfigs`; finalized in the plan). MCP-only shape:

```toml
[[mcp]]
name      = "context7"
enabled   = true
transport = "stdio"            # "stdio" | "streamable_http" | "sse"

# stdio transport
command   = "uvx"
args      = ["mcp-server-context7"]
env       = { CONTEXT7_TOKEN = "..." }

# http / sse transport
url       = "https://example.com/mcp"
headers   = { Authorization = "Bearer ..." }
```

Mapping to Anubis transport tuples at start time:

| `transport` | Anubis tuple |
|-------------|--------------|
| `stdio` | `{:stdio, command: cmd, args: args, env: env}` |
| `streamable_http` | `{:streamable_http, url: url, headers: headers}` |
| `sse` | `{:sse, base_url: url, headers: headers}` |

> The exact option keys for `env` (stdio) and `headers` (http/sse) are confirmed
> against `Anubis.Transport.STDIO` / `Anubis.Transport.StreamableHTTP` /
> `Anubis.Transport.SSE` during implementation; the requirement is that stdio
> supports `env` and the HTTP transports support custom `headers`.

**Migration:** existing stored configs use the old plugin schema and will not load
under the new one. The plan will include a one-time migration that maps old MCP
entries (`transport`, `command`, `args`, `env`, `url`, `settings.headers`) into the
new shape, dropping non-MCP plugin entries. `.opencode.json` compatibility is
intentionally dropped (accepted).

## 7. Original bug fix (restart resets tools)

Two independent layers, both included:

1. **`Synapsis.MCP.Server` traps exits** and unregisters its tools in
   `terminate/2`, so the supervisor-driven stop path cleans up.
2. **`Synapsis.Tool.Registry` gains a pid monitor for process-registered tools.**
   On `:DOWN` it auto-purges the dead pid's entries. This is the true root-cause
   fix (the registry currently has no monitor) and protects every process-tool,
   not just MCP. `register_process/3` starts monitoring; the registry owner handles
   `:DOWN`.

A regression test asserts: start server → tools present → `Synapsis.MCP.restart/1`
→ old tools gone and re-discovered fresh.

## 8. Web changes

- `mcp_live`: update fields to the new schema; wire start/stop/**restart** to the
  `Synapsis.MCP` façade; show per-server status (`await_ready`/`ping`).
- `lsp_live`: deleted with its route and any nav entry.

## 9. Testing strategy

- `synapsis_mcp`:
  - `Bypass` for `streamable_http` and `sse` transports (never hit real servers).
  - A tiny echo MCP script for `stdio` (committed under `test/support`).
  - Cover: config→transport mapping, tool registration naming
    (`mcp:<server>:<tool>`), `call_tool` routing + response normalization,
    `restart` resets tools (regression), error paths (`await_ready` timeout,
    transport failure).
- `synapsis_core`: registry pid-monitor auto-purge test.
- `synapsis_sandbox`: existing bridge tests moved and passing.
- Remove obsolete plugin/LSP/old-MCP tests.
- Gates: `mix compile --warnings-as-errors`, `mix format --check-formatted`,
  full `mix test`.

## 10. Risks & consequences (acknowledged)

1. **Loss of the `diagnostics` tool** (removed with LSP). The agent can no longer
   query LSP diagnostics. *(Accepted.)*
2. **Existing MCP server configs break** under the new schema; a migration (or
   documented re-add) is required. *(Accepted.)*
3. **`anubis_mcp` is LGPL-3.0** — a copyleft license. Consider implications for a
   distributed product. *(Flagged for conscious acceptance.)*
4. Behavioral parity: Anubis manages its own transport/handshake; we must verify
   stdio env passing, HTTP headers, and SSE behave equivalently to the old client
   for current servers.

## 11. Out of scope

- Using Anubis to *serve* Synapsis as an MCP server (client only).
- WebSocket transport.
- Any new MCP features beyond current parity (tool discovery + tool calls).

## 12. Open items for the plan

- Final module names (`Synapsis.MCP.*`, sandbox namespace, config store name).
- Exact Anubis transport option keys (`env`, `headers`) — verify against docs.
- Whether each `Anubis.Client` is supervised directly under the dynamic supervisor
  with the `Synapsis.MCP.Server` as a sibling, or owned/linked by the server. To be
  decided in the plan based on `Anubis.Client` child-spec semantics.
- Migration mechanics for stored configs.
