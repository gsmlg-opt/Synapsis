# Phase 0 - Harness Audit

> Status: draft
> Date: 2026-05-12
> Scope: translation of the harness design package onto the current Synapsis
> umbrella layout. No runtime code changes are included in this phase.

## Goal

Start the harness refactor without treating the imported design as greenfield.
The current repo already has sessions, message parts, provider event mapping,
tool execution, session supervision, workspace resources, plugin protocols, and
a graph/query-loop runtime. Phase 0 identifies what to keep, what to port into
the proposed harness shape, and what to avoid changing until a narrower phase
requires it.

## Current Boundary Translation

The design package names an older `synapsis_lsp` boundary. The current umbrella
has these relevant apps instead:

- `synapsis_data`: Ecto schemas, migrations, Repo-backed contexts.
- `synapsis_provider`: provider transport, request mapping, event mapping.
- `synapsis_core`: public session API, tools, config, git, memory, PubSub,
  session supervision support.
- `synapsis_agent`: active agent/session runtime, query loop, graph runner,
  worker, agent memory, heartbeats.
- `synapsis_server`: REST, SSE, channels, endpoint.
- `synapsis_web`: LiveView UI and message rendering.
- `synapsis_plugin`: MCP/LSP protocol and managed plugin servers.
- `synapsis_workspace`: virtual workspace resources and workspace tools.
- `synapsis_cli`: CLI client surface.

Harness implementation should preserve the existing dependency direction:
data/provider/core/plugin/workspace support the runtime; server/web/cli are
presentation surfaces. The reducer should be introduced in the runtime path
without moving Phoenix or Repo concerns into the pure core.

## Module Disposition

| Area | Files | Disposition | Notes |
| --- | --- | --- | --- |
| Session public API | `apps/synapsis_core/lib/synapsis/sessions.ex` | Keep, adapt | Continue as the boundary used by REST, channels, LiveView, and CLI. Add harness-facing calls behind this module rather than bypassing it. |
| Session supervision | `apps/synapsis_core/lib/synapsis/session/dynamic_supervisor.ex`, `apps/synapsis_core/lib/synapsis/session/supervisor.ex` | Keep, adapt | Already provides per-session process isolation and registries. Future shell can replace the child worker without changing callers. |
| Session worker | `apps/synapsis_agent/lib/synapsis/session/worker.ex` and `worker/*.ex` | Port | Current worker mixes API calls, status persistence, runner lifecycle, stream/tool I/O, and query-loop task management. This is the primary shell candidate. |
| Graph runner | `apps/synapsis_agent/lib/synapsis/agent/runtime/*.ex`, `agent/graphs/*.ex`, `agent/nodes/*.ex` | Keep, isolate | The graph runtime is useful for higher-level orchestration. Do not delete it in the first harness slice. Avoid coupling the new reducer to graph node callbacks. |
| Query loop | `apps/synapsis_agent/lib/synapsis/agent/query_loop*.ex`, `streaming_executor.ex` | Port first | This is closest to the proposed `Loop.step/2`: provider chunks, tool calls, tool results, turns, and terminal reasons are already explicit. Extract reducer semantics from here before touching graph orchestration. |
| Pure loop seeds | `apps/synapsis_core/lib/synapsis/agent/stream_accumulator.ex`, `session/monitor.ex`, `session/orchestrator.ex`, `apps/synapsis_agent/lib/synapsis/agent/query_loop/state.ex` | Port | These are the best seeds for reducer state, provider-event folding, loop policy, and budget/stagnation rules. Fold behavior into harness modules instead of calling them directly from the reducer. |
| Response mutation | `apps/synapsis_core/lib/synapsis/agent/response_flusher.ex`, `session/compactor.ex`, `session/fork.ex` | Port to Store/events | These currently mutate messages directly. Replace with append-only session events and projections in later phases. |
| Data schemas | `apps/synapsis_data/lib/synapsis/session.ex`, `message.ex`, `part*.ex`, `tool_call.ex` | Keep, evolve | Existing embedded `messages.parts` JSONB array covers many part variants. The design wants row-level parts and append-only events; migrate additively. |
| Agent events | `apps/synapsis_data/lib/synapsis/agent_event.ex`, `agent_events.ex` | Keep, evaluate | Existing event table is work/project scoped, not session aggregate/version scoped. It can inform the store shape but should not be reused blindly as the durable harness log. |
| Provider mapping | `apps/synapsis_provider/lib/synapsis/provider/event_mapper.ex`, `message_mapper.ex`, `adapter.ex` | Keep, adapt | Provider events are already normalized, but the event names are Anthropic-shaped rather than the design's richer step/finish protocol. Add a harness provider-event ADT at the boundary. |
| Provider stream shell | `apps/synapsis_core/lib/synapsis/session/stream.ex` | Keep, adapt | Thin wrapper around provider registry. Future shell can keep this or call the provider adapter directly. |
| Tool registry/executor | `apps/synapsis_core/lib/synapsis/tool/registry.ex`, `executor.ex`, `permission.ex`, `tool/*.ex` | Keep, adapt | Existing registry, permission levels, and task-supervised execution are valuable. The reducer should emit effects; shell/tool executor should keep actual execution. |
| Plugin protocols | `apps/synapsis_plugin/lib/synapsis_plugin/**/*` | Keep | Treat MCP/LSP/plugin servers as adapters/tools, not part of reducer logic. |
| Workspace resources | `apps/synapsis_workspace/lib/synapsis/workspace/**/*` | Keep | Workspace permissions and path resolution remain support-layer behavior for tools. |
| REST/SSE/channel API | `apps/synapsis_server/lib/synapsis_server/router.ex`, `controllers/session_controller.ex`, `controllers/sse_controller.ex`, `channels/session_channel.ex` | Keep, add parity routes later | Existing API is `/api/sessions`; OpenCode parity uses `/session`. Add compatibility intentionally in Phase 6, not during Phase 1/2 reducer work. |
| LiveView UI | `apps/synapsis_web/lib/synapsis_web/live/agent_live/sessions.ex`, `session_live/*`, `message_helpers.ex`, `components/core_components.ex` | Keep | Main chat is LiveView, not React. UI consumes current serialized parts and PubSub events. Preserve current events while adding harness topics behind the same session boundary. |
| CLI | `apps/synapsis_cli/lib/synapsis_cli/main.ex` | Port later | CLI currently creates `/api/sessions`, sends `/api/sessions/:id/messages`, and streams `/api/sessions/:id/events`. Update after Phase 6 compatibility routes exist. |

## Existing Data Shape

Current persistence:

- `sessions`: `project_id`, `title`, `agent`, `provider`, `model`, `status`,
  `config`, `debug`, timestamps.
- `messages`: `session_id`, `role`, embedded JSONB `parts`, `token_count`,
  `inserted_at`.
- `Synapsis.Part`: custom Ecto type over embedded JSONB variants:
  `text`, `tool_use`, `tool_result`, `reasoning`, `image`, `file`, `snapshot`,
  `agent`.
- `tool_calls`: separate audit table with status enum and optional `message_id`.
- `agent_events`: append-only-ish table for orchestration events, scoped by
  `project_id` and `work_id`.

Target persistence from the harness design:

- Keep `sessions` and `messages`, but add explicit session hierarchy,
  tombstones, and ordinal/version fields only when the migration phase starts.
- Introduce row-level `parts` additively instead of replacing embedded message
  parts in place.
- Introduce a session aggregate event log with `aggregate_id`, `version`,
  `event_type`, `schema_version`, and JSONB payload. This should be distinct
  from current `agent_events` unless Phase 1 proves reuse is safe.
- Build projection/read compatibility so existing UI can keep reading message
  parts while the event-sourced path matures.

## Existing Runtime Shape

Current request flow:

1. `SynapsisServer.SessionController` or `SynapsisServer.SessionChannel` calls
   `Synapsis.Sessions`.
2. `Synapsis.Sessions` ensures the session process is running and delegates to
   `Synapsis.Session.Worker`.
3. `Synapsis.Session.Worker` persists a user message and either resumes the
   graph runner or starts `Synapsis.Agent.QueryLoop` in a task.
4. Provider streams are normalized by `Synapsis.Provider.EventMapper` and sent
   back as `{:provider_chunk, event}` messages.
5. Tool execution flows through `Synapsis.Tool.Registry`, permission logic, and
   task-supervised execution.
6. UI clients receive lossy live updates over PubSub topic `session:<id>`.

Target flow:

1. Existing controllers/channels still call `Synapsis.Sessions`.
2. Session shell normalizes external inputs into `Synapsis.Agent.Harness.Loop.Input`.
3. `Loop.step/2` returns new context, durable events, imperative effects, and
   transient broadcasts.
4. Shell persists events first, executes effects second, then broadcasts.
5. Rehydration folds events into context; projections feed existing UI/API.

## API Parity Gap

Current HTTP routes:

- `GET /api/sessions`
- `POST /api/sessions`
- `GET /api/sessions/:id`
- `DELETE /api/sessions/:id`
- `POST /api/sessions/:id/messages`
- `POST /api/sessions/:id/fork`
- `GET /api/sessions/:id/export`
- `POST /api/sessions/:id/compact`
- `GET /api/sessions/:id/events`

Current WebSocket surface:

- Topic pattern `session:<id>`.
- Incoming events include `session:message`, `session:cancel`, `session:retry`,
  `session:tool_approve`, `session:tool_deny`, `session:ask_user_response`,
  `session:switch_agent`, and debug toggles.
- Outgoing events are ad hoc PubSub messages forwarded to the socket.

OpenCode-style target routes from the design:

- `POST /session`, `GET /session`, `GET /session/{id}`
- `PATCH /session/{id}`, `DELETE /session/{id}`
- `GET /session/{id}/children`
- `POST /session/{id}/fork`
- `POST /session/{id}/abort`
- `GET /session/{id}/message`
- `POST /session/{id}/prompt`
- `PATCH /session/{id}/message/{mid}/part/{pid}`
- `DELETE /session/{id}/message/{mid}/part/{pid}`

Do not add these routes in Phase 1. Add them in the Phase 6 parity slice after
the reducer/store shape is stable.

Also do not drop legacy `/api/sessions` or channel behavior during early
phases. They are the current UI and CLI contract and should be preserved until
the compatibility layer has tests.

## Phase 1 Entry Point

Start with additive data and pure functions:

1. Define pure harness ADTs in `synapsis_core` under
   `apps/synapsis_core/lib/synapsis/harness/*`. This matches current
   dependencies: `synapsis_agent` depends on `synapsis_core`, while
   `synapsis_core` cannot depend on the active agent runtime.
2. Add pure context/fold tests before adding migrations.
3. Add migrations for a session event log and row-level parts only after the
   fold API is explicit.
4. Keep existing `messages.parts` working until a projection layer can write
   both shapes or read from the event log.

## Risks

- Replacing `Session.Worker` too early would break channels, SSE, LiveView, and
  CLI behavior at once.
- Reusing `agent_events` for the session event log may create a weak aggregate
  model because it lacks session versions and payload schema versioning.
- The imported design assumes row-level parts; the repo currently stores parts
  embedded in messages. Migration must be additive and reversible.
- Current provider events do not expose explicit `step_start` and
  `step_finish`. Phase 2 must either derive steps or extend provider mapping.
- Current tool permissions are session-config driven and return
  `:allowed | :denied | :requires_approval`; the design's effect classes must
  map onto existing `:none | :read | :write | :execute | :destructive`.
- `workspace_search` accepts caller-supplied scope/project filters instead of
  deriving scope from tool context. Fix before exposing workspace tools through
  the harness as session-scoped tools.
- The graph runner and query loop are two active loop concepts. The reducer
  should replace query-loop transition semantics first; graph orchestration can
  remain adjacent until a later consolidation.
- `Compactor` deletes messages today, which conflicts with append-only replay.
  Convert compaction into events/snapshots before using it in the harness path.
- Some adjacent modules still use `System.cmd`; do not copy that pattern into
  shell/tool execution, which must use `Port`-based paths per repo guardrails.

## Stop Conditions

Stop and revisit the design if any Phase 1 task requires:

- Changing public controller/channel payloads.
- Removing the graph runner or query loop before replacement tests exist.
- Hard-deleting or rewriting existing messages.
- Making provider API calls from tests.
- Moving Repo access out of `synapsis_data` contexts or schemas.

## Next Step

Write the Phase 1 implementation plan as a narrow data-model/fold slice:

- harness event structs and context fold tests,
- additive event-log migration,
- additive row-level parts spike or migration plan,
- compatibility projection for existing message reads.

## Phase 1 Exit Notes

Phase 1 adds pure harness events, a pure context fold, an additive
`harness_events` log, and an additive row-level `parts` projection. Existing
session runtime, API payloads, and embedded message parts remain unchanged.

## Phase 2 Exit Notes

Phase 2 adds the pure reducer slice under `Synapsis.Harness.Loop`, translating
the design's `Synapsis.Core.Loop` boundary to this umbrella's existing
`synapsis_core` harness namespace. It includes loop input/effect/broadcast/next
action ADTs, a normalized harness provider-event ADT, context in-flight state,
and focused reducer coverage for user prompts, provider text turns, tool calls,
permission gating, aborts, provider errors, and token-budget halts.

This phase intentionally does not change provider adapters, the session worker,
persistence integration, controller/channel/CLI contracts, or LiveView rendering.
