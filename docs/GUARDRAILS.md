# Guardrails

## NEVER DO

1. **Never store session/message state in GenServer** — DB is source of truth. Processes hold transient operational state only (current stream, pending chunks).

2. **Never make synchronous LLM calls** — Always stream async. Never block the caller.

3. **Never use `System.cmd` for tool execution** — Use `Port` for streaming output, timeout control, and kill capability.

4. **Never hardcode provider message formats in core logic** — Each provider implements `format_request/3` via the behaviour. Core works with domain structs.

5. **Never trust tool input without validation** — Validate paths are within project root (no `../` escapes), commands don't contain injection.

6. **Never log API keys or secrets** — Scrub credentials from all log output.

7. **Never block Session.Worker** — Tool execution, LLM streaming, and DB writes that could be slow must be delegated to Task/Task.Supervisor.

8. **Never couple synapsis_core to Phoenix** — Core has no Phoenix dependency. Communication is via PubSub (which is a stdlib-level abstraction).

9. **Never skip permission checks** — Even in "auto-approve" mode, the permission check function must be called. The policy decides, not the caller.

10. **Never assume provider response format** — Always pattern match with fallback. Providers change their SSE formats without warning.

## ALWAYS DO

1. **Always persist before broadcasting** — Write message to DB, then broadcast via PubSub. On crash recovery, DB is the source of truth.

2. **Always use UUID for IDs** — Postgres-native, no coordination needed. Never auto-increment.

3. **Always validate file paths against project root** — `Path.expand(path) |> String.starts_with?(project_root)`.

4. **Always implement `terminate/2` in GenServers that hold resources** — Close Ports, cancel HTTP streams, flush pending writes.

5. **Always use structured logging** — `Logger.info("session_started", session_id: id, project: path)`. Never string interpolation in logs.

6. **Always test provider integration with Bypass** — Never hit real APIs in tests.

7. **Always handle `:DOWN` messages from monitored processes** — Stream process, tool tasks, LSP servers can all crash.

8. **Always include `project_path` in tool execution context** — Tools must know the working directory.

9. **Always provide timeout for Port and Task operations** — No unbounded waits.

10. **Always make config backward-compatible with OpenCode's `.opencode.json`** — Users should be able to switch between tools.
