# Guardrails

Storage follows [ADR-006](../decisions/ADR-006-in-process-sessions-and-concord-storage.md): no PostgreSQL, no `Synapsis.Repo`. The live session process is the read authority for in-flight state (`Synapsis.Session.Read.live_snapshot/1`), Concord holds per-turn snapshots, configs are TOML files, memory is files. Product scope and permissions policy are in [the design](../design.md).

## Never

1. **Never rewrite the whole transcript.** Append each completed turn as one atomic Concord snapshot.
2. **Never make synchronous LLM calls.** Stream asynchronously; never block the caller.
3. **Never use `System.cmd` for tool execution.** Use `Port` (or the Backplane local command runtime) for streaming, timeouts and cancellation.
4. **Never hardcode provider message formats in core logic.** Provider adapters own wire formats; core works with domain structs.
5. **Never log API keys or secrets.**
6. **Never block `Session.Worker`.** Delegate tool execution, streaming and slow writes to supervised processes.
7. **Never couple `synapsis_core` to Phoenix.** Communicate through PubSub.
8. **Never run two execution owners for one turn.** The Backplane `Conversation` owns the turn; do not replay effects or revive old child handles after owner loss.

## Always

1. **Broadcast live, snapshot after.** PubSub deltas come from process state; durable snapshots follow at the turn boundary. On crash recovery, rehydrate from the last turn and wait for input — never auto-rerun.
2. **Use UUIDs for IDs.**
3. **Resolve tool paths against the project root** and reject traversal.
4. **Implement `terminate/2` in processes that hold resources.**
5. **Use structured logging:** `Logger.info("session_started", session_id: id)`.
6. **Test provider HTTP with `Gaoxy.Test`.** Never hit real APIs in tests.
7. **Handle `:DOWN` from monitored processes.**
8. **Give Port, Task, HTTP, provider and MCP operations explicit timeouts.**
9. **Keep `.opencode.json` compatibility for agents and providers.** MCP servers use `mcp.toml`.
