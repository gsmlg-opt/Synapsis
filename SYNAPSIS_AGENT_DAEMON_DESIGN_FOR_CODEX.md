# Synapsis Phoenix Agent Daemon Design — Codex Implementation Spec

**Repository:** `https://github.com/gsmlg-opt/Synapsis`  
**Primary product shape:** Phoenix web app, LiveView UI, Phoenix Channels, JSON APIs, Oban jobs, supervised long-running agent daemon.  
**Explicit non-goal:** do not build CLI flows, OpenClaw parity, external chat channels, device pairing, or a gateway protocol clone.

---

## 0. Codex Mission

Implement a stable **long-running local agent daemon** inside the existing Synapsis Phoenix umbrella app.

The daemon must:

1. stay alive under OTP supervision;
2. expose status through Phoenix web/API;
3. execute tool-capable agent runs using existing session/runtime/tool infrastructure;
4. support a cheap liveness heartbeat;
5. support scheduled heartbeat routines;
6. support dream/reflection runs;
7. support generic scheduled routines after heartbeat and dream are stable;
8. persist all daemon work as `agent_runs`;
9. render daemon/routine/run state in the existing web UI;
10. preserve the existing browser session chat path.

The first implementation should be conservative: use the existing `Synapsis.Sessions`, `Synapsis.Session.Worker`, graph runtime, `QueryLoop`, provider streaming, and tool registry. Do **not** rewrite the agent runtime before the daemon is proven.

---

## 1. Scope and Non-Goals

### In scope

- Phoenix server ownership cleanup.
- Health/status endpoints.
- `Synapsis.Agent.Daemon` permanent GenServer.
- `agent_runs` persistence and context.
- Daemon event broadcasts.
- Heartbeat execution through the daemon.
- Dream/reflection execution through the daemon.
- Existing Assistant Settings page upgrade from `Cron Jobs` to `Routines`.
- Run history UI.
- Basic web safety hardening for a local tool-using daemon.
- Tests for web/API/LiveView/Oban/daemon/data.

### Out of scope

- CLI implementation or CLI acceptance tests.
- OpenClaw feature parity.
- Slack/Telegram/Discord/WhatsApp channels.
- Remote gateway pairing.
- Multi-device protocol.
- Full sandboxing implementation beyond tool-policy guards.
- Replacing the existing session/runtime/tool system.
- Major provider refactor.

---

## 2. Current Repo Facts to Preserve

Use these facts as implementation constraints.

### 2.1 Release shape

The root release currently includes these applications:

```elixir
synapsis_data: :permanent,
synapsis_agent: :permanent,
synapsis_provider: :permanent,
synapsis_core: :permanent,
synapsis_server: :permanent,
synapsis_plugin: :permanent,
synapsis_workspace: :permanent,
synapsis_web: :permanent
```

Do not introduce CLI as a release dependency.

### 2.2 Web shape

`SynapsisServer.Router` already exposes:

- JSON session/provider/config APIs under `/api`;
- SSE session events at `/api/sessions/:id/events`;
- LiveView routes for dashboard, assistants, sessions, settings, providers, memory, skills, MCP, LSP, model tiers, and workspace;
- Assistant setting route: `/assistant/:name/setting`.

`SynapsisServer.Endpoint` already exposes:

- LiveView socket at `/live`;
- Phoenix session socket at `/socket`;
- static assets from `synapsis_web`.

Preserve these routes. Add new routes only where needed.

### 2.3 Agent runtime shape

`SynapsisAgent.Application` starts:

- `Synapsis.Session.Registry`;
- `Synapsis.Session.SupervisorRegistry`;
- `Synapsis.Agent.Registry`;
- `Synapsis.Session.DynamicSupervisor`;
- `Synapsis.Agent.Supervisor`;
- then registers built-in tools and workspace tools.

`Synapsis.Agent.Supervisor` currently starts:

- `Synapsis.Agent.ProjectRegistry`;
- `Synapsis.Agent.Runtime.RunRegistry`;
- `Synapsis.Agent.ProjectSupervisor`;
- `Synapsis.Agent.AgentRegistry`;
- `Synapsis.Agent.GlobalAssistant`.

Add `Synapsis.Agent.Daemon` here as a permanent child.

### 2.4 Existing session/runtime path

`Synapsis.Sessions.send_message/2` ensures a `Synapsis.Session.Worker` exists and sends user content to the worker.

`Synapsis.Session.Worker` wraps graph/runtime execution and can also run `QueryLoop`. It persists user messages, sets session status, handles cancel/retry/tool approvals, receives provider/tool events, and broadcasts session events.

`Synapsis.Agent.QueryLoop` already implements tail-recursive agentic execution:

```text
user message -> LLM stream -> tool dispatch -> tool result -> LLM again -> completion
```

Events from `QueryLoop` are sent to `context.subscriber` as:

```elixir
{:query_event, event}
```

Use this existing runtime path. The daemon should create/reuse sessions and submit prompts rather than implement a second independent tool executor.

### 2.5 Existing heartbeat path

There is already:

- `Synapsis.HeartbeatConfig` schema/table;
- `Synapsis.Heartbeats` context;
- `Synapsis.Agent.Heartbeat.Templates` default templates;
- `Synapsis.Agent.Heartbeat.Scheduler` using Oban scheduled jobs;
- `Synapsis.Agent.Heartbeat.Worker` executing scheduled heartbeats;
- an Assistant Settings tab labeled `Cron Jobs` that lists and edits heartbeats.

Do not delete this. First make it reliable, then route execution through the daemon.

### 2.6 Known heartbeat completion mismatch

`Synapsis.Agent.Heartbeat.Worker.await_session_completion/2` currently waits for:

```elixir
{:session_completed, session_id, result}
{:session_error, session_id, reason}
```

But the graph completion node currently broadcasts UI-style tuples:

```elixir
{"done", %{}}
{"session_status", %{status: "idle"}}
```

Fix this mismatch. Prefer adding system-level completion/error broadcasts to the session runtime so background workers do not parse UI-specific events.

### 2.7 Existing event and memory logs

`Synapsis.AgentEvent` is an append-only event log for agent orchestration.

`Synapsis.MemoryEvent` is an append-only event log for episodic memory and already supports types such as:

```text
run_created
task_received
message_added
tool_called
tool_succeeded
tool_failed
checkpoint_written
task_completed
task_failed
summary_created
memory_promoted
```

Use these where appropriate. Do not create a duplicate event-log system unless a real schema need appears.

---

## 3. Target Architecture

```text
Phoenix Web App
  ├─ SynapsisServer.Endpoint
  │   ├─ /live                  LiveView socket
  │   ├─ /socket                session Phoenix Channel
  │   ├─ /api/health            health endpoint
  │   └─ /api/agent/*           daemon/runs/routines endpoints
  │
  ├─ SynapsisWeb LiveViews
  │   ├─ DashboardLive          health + daemon status
  │   ├─ AssistantLive.Show     existing sessions/chat
  │   └─ AssistantLive.Setting  routines + dream + run history
  │
  ├─ Synapsis.Agent.Daemon
  │   ├─ permanent GenServer
  │   ├─ liveness heartbeat timer
  │   ├─ run queue / current run tracking
  │   ├─ creates AgentRun records
  │   ├─ triggers existing Sessions runtime
  │   ├─ watches session completion/error
  │   ├─ emits PubSub events
  │   └─ recovers stale runs on restart
  │
  ├─ Oban
  │   ├─ heartbeat queue
  │   └─ later: routines queue
  │
  └─ Existing Runtime
      ├─ Synapsis.Sessions
      ├─ Synapsis.Session.Worker
      ├─ Runtime.Runner / QueryLoop
      ├─ provider streaming
      └─ tool registry/executor
```

### Central rule

All autonomous work types must enter the same daemon execution path:

```text
manual web-triggered run
heartbeat routine
scheduled dream
manual dream
scheduled routine
  -> Synapsis.Agent.Daemon
  -> AgentRun
  -> Session runtime
  -> tool/model execution
  -> AgentRun completion/error
  -> PubSub + web UI
```

Do not implement separate execution loops for heartbeat, dream, and schedule.

---

## 4. App Ownership Cleanup

The current implementation has awkward web supervision: `synapsis_server` has a supervisor but no OTP application callback, and `SynapsisCore.Application` conditionally starts `SynapsisServer.Supervisor`.

For a Phoenix web app, `synapsis_server` should own its own application callback.

### 4.1 Add `SynapsisServer.Application`

Create:

```text
apps/synapsis_server/lib/synapsis_server/application.ex
```

Skeleton:

```elixir
defmodule SynapsisServer.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SynapsisServer.Supervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SynapsisServer.ApplicationSupervisor)
  end
end
```

### 4.2 Update `apps/synapsis_server/mix.exs`

Change:

```elixir
def application do
  [extra_applications: [:logger, :runtime_tools]]
end
```

to:

```elixir
def application do
  [
    extra_applications: [:logger, :runtime_tools],
    mod: {SynapsisServer.Application, []}
  ]
end
```

### 4.3 Remove server startup from core

In:

```text
apps/synapsis_core/lib/synapsis_core/application.ex
```

remove `SynapsisServer.Supervisor` from `optional_children`.

Keep `SynapsisPlugin.Supervisor` only if the plugin app does not have its own OTP application. If `synapsis_plugin` already has an application callback, remove it too.

### 4.4 Expected result

Startup order should become:

```text
synapsis_data
synapsis_agent
synapsis_provider
synapsis_core
synapsis_server
synapsis_plugin
synapsis_workspace
synapsis_web
```

and `synapsis_server` starts its own endpoint. Core no longer owns Phoenix.

---

## 5. Health and Status

### 5.1 Add health controller

Create:

```text
apps/synapsis_server/lib/synapsis_server/controllers/health_controller.ex
```

Endpoint:

```http
GET /api/health
```

Response shape:

```json
{
  "ok": true,
  "repo": "ok",
  "pubsub": "ok",
  "oban": "ok",
  "tool_registry": "ok",
  "provider_registry": "ok",
  "session_supervisor": "ok",
  "agent_supervisor": "ok",
  "agent_daemon": "ok",
  "endpoint": "ok",
  "version": "0.1.0"
}
```

If a subsystem is unhealthy, use:

```json
{
  "ok": false,
  "agent_daemon": "error: not_started"
}
```

but still return JSON. Prefer HTTP 200 for diagnostics unless Repo is unreachable so badly that controller cannot execute; then return 503.

### 5.2 Add route

In `SynapsisServer.Router`:

```elixir
scope "/api", SynapsisServer do
  pipe_through :api

  get "/health", HealthController, :show
  ...
end
```

### 5.3 Dashboard

Update `SynapsisWeb.DashboardLive` to show health cards:

```text
Repo
PubSub
Oban
Tool Registry
Provider Registry
Session Supervisor
Agent Supervisor
Agent Daemon
Endpoint
```

Dashboard must subscribe to:

```text
agent:daemon
```

and update when daemon heartbeat/status changes.

---

## 6. Data Model

## 6.1 Add `agent_runs`

Create migration in:

```text
apps/synapsis_data/priv/repo/migrations/*_create_agent_runs.exs
```

Migration:

```elixir
defmodule Synapsis.Repo.Migrations.CreateAgentRuns do
  use Ecto.Migration

  def change do
    create table(:agent_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :status, :string, null: false, default: "queued"
      add :source, :string, null: false, default: "system"
      add :assistant_name, :string
      add :session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all)
      add :project_id, :string
      add :heartbeat_id, references(:heartbeat_configs, type: :binary_id, on_delete: :nilify_all)
      add :routine_id, :binary_id
      add :prompt, :text, null: false
      add :tool_profile, :string, null: false, default: "read_only"
      add :model, :string
      add :provider, :string
      add :summary, :text
      add :error, :text
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agent_runs, [:kind])
    create index(:agent_runs, [:status])
    create index(:agent_runs, [:source])
    create index(:agent_runs, [:session_id])
    create index(:agent_runs, [:project_id])
    create index(:agent_runs, [:heartbeat_id])
    create index(:agent_runs, [:routine_id])
    create index(:agent_runs, [:inserted_at])
  end
end
```

### 6.2 Add schema

Create:

```text
apps/synapsis_data/lib/synapsis/agent_run.ex
```

Schema:

```elixir
defmodule Synapsis.AgentRun do
  @moduledoc "Persistent daemon run record for manual, heartbeat, dream, and scheduled work."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(manual heartbeat dream schedule)
  @statuses ~w(queued running waiting_approval sleeping completed failed cancelled)
  @sources ~w(web system oban)
  @tool_profiles ~w(read_only reflect heartbeat coding maintenance dangerous)

  schema "agent_runs" do
    field :kind, :string
    field :status, :string, default: "queued"
    field :source, :string, default: "system"
    field :assistant_name, :string
    field :session_id, :binary_id
    field :project_id, :string
    field :heartbeat_id, :binary_id
    field :routine_id, :binary_id
    field :prompt, :string
    field :tool_profile, :string, default: "read_only"
    field :model, :string
    field :provider, :string
    field :summary, :string
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :kind,
      :status,
      :source,
      :assistant_name,
      :session_id,
      :project_id,
      :heartbeat_id,
      :routine_id,
      :prompt,
      :tool_profile,
      :model,
      :provider,
      :summary,
      :error,
      :started_at,
      :finished_at,
      :metadata
    ])
    |> validate_required([:kind, :status, :source, :prompt, :tool_profile])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:tool_profile, @tool_profiles)
  end
end
```

### 6.3 Add context

Create:

```text
apps/synapsis_agent/lib/synapsis/agent/runs.ex
```

Why in `synapsis_agent`: daemon business logic belongs to the agent app; persistence schema remains in `synapsis_data`.

API:

```elixir
defmodule Synapsis.Agent.Runs do
  alias Synapsis.{AgentRun, Repo}
  import Ecto.Query

  def create(attrs)
  def get(id)
  def list_recent(opts \\ [])
  def list_by_status(status, opts \\ [])
  def mark_running(%AgentRun{} = run, attrs \\ %{})
  def mark_waiting_approval(%AgentRun{} = run, attrs \\ %{})
  def mark_completed(%AgentRun{} = run, summary, attrs \\ %{})
  def mark_failed(%AgentRun{} = run, error, attrs \\ %{})
  def mark_cancelled(%AgentRun{} = run, attrs \\ %{})
  def recover_stale_running_runs(opts \\ [])
end
```

Implementation requirements:

- `mark_running` sets `status: "running"` and `started_at` if absent.
- `mark_completed` sets `status: "completed"`, `summary`, `finished_at`.
- `mark_failed` sets `status: "failed"`, `error`, `finished_at`.
- `recover_stale_running_runs` runs on daemon boot and marks old `running` / `waiting_approval` runs as `failed` with error `"daemon restarted before completion"`, unless they are recent and can be reattached.

### 6.4 Event append helper

Add helper functions that write to existing `AgentEvent` and `MemoryEvent` when available. Do not block run execution on event-log failure; log and continue.

Suggested helper:

```text
apps/synapsis_agent/lib/synapsis/agent/run_events.ex
```

API:

```elixir
append_run_created(run)
append_run_started(run)
append_run_completed(run)
append_run_failed(run)
append_tool_event(run, event)
append_dream_summary(run, summary)
```

---

## 7. Agent Daemon

Create:

```text
apps/synapsis_agent/lib/synapsis/agent/daemon.ex
```

Add as child under `Synapsis.Agent.Supervisor` after `Synapsis.Agent.GlobalAssistant`:

```elixir
children = [
  {Registry, keys: :unique, name: Synapsis.Agent.ProjectRegistry},
  {Registry, keys: :unique, name: Synapsis.Agent.Runtime.RunRegistry},
  {DynamicSupervisor, strategy: :one_for_one, name: Synapsis.Agent.ProjectSupervisor},
  Synapsis.Agent.AgentRegistry,
  Synapsis.Agent.GlobalAssistant,
  Synapsis.Agent.Daemon
]
```

### 7.1 Daemon public API

```elixir
defmodule Synapsis.Agent.Daemon do
  use GenServer

  def start_link(opts \\ [])
  def status()
  def submit_manual(prompt, opts \\ %{})
  def trigger_heartbeat(heartbeat_id, opts \\ %{})
  def trigger_dream(opts \\ %{})
  def trigger_schedule(routine_id, opts \\ %{})
  def cancel(run_id)
end
```

### 7.2 State

```elixir
%{
  status: :idle | :running | :paused,
  started_at: DateTime.t(),
  last_liveness_at: DateTime.t() | nil,
  last_heartbeat_run_at: DateTime.t() | nil,
  last_dream_at: DateTime.t() | nil,
  current_run_id: binary() | nil,
  current_task_ref: reference() | nil,
  queue: :queue.queue(),
  run_index: %{binary() => map()},
  liveness_timer_ref: reference() | nil
}
```

### 7.3 Liveness heartbeat

This is not an LLM run.

Every configured interval, default 60 seconds:

1. update `last_liveness_at`;
2. inspect daemon state;
3. optionally inspect Repo/Oban/tool registry/provider registry cheaply;
4. broadcast:

```elixir
Phoenix.PubSub.broadcast(
  Synapsis.PubSub,
  "agent:daemon",
  {:agent_daemon_event, %{event: "agent.daemon.heartbeat", status: status_map}}
)
```

Do not call the model during liveness heartbeat.

### 7.4 Run queue policy

MVP can be single-run-at-a-time.

Policy:

- if idle: start immediately;
- if running and `no_overlap` is true: reject or skip depending on trigger;
- if running and queue allowed: enqueue;
- default for heartbeat/dream/schedule: `no_overlap: true` and skip if another autonomous run is active;
- manual web-triggered runs may enqueue.

Return values:

```elixir
{:ok, run}
{:queued, run}
{:skip, :busy}
{:error, reason}
```

### 7.5 Daemon events

Broadcast to:

```text
agent:daemon
agent:runs
agent:run:<run_id>
```

Event wrapper:

```elixir
{:agent_daemon_event, %{
  event: "agent.run.started",
  run_id: run.id,
  kind: run.kind,
  status: run.status,
  payload: %{},
  at: DateTime.utc_now()
}}
```

Required events:

```text
agent.daemon.started
agent.daemon.heartbeat
agent.run.created
agent.run.queued
agent.run.started
agent.run.waiting_approval
agent.run.completed
agent.run.failed
agent.run.cancelled
agent.heartbeat.started
agent.heartbeat.completed
agent.dream.started
agent.dream.completed
agent.schedule.triggered
```

### 7.6 Execution strategy

The daemon should call an executor helper. Create:

```text
apps/synapsis_agent/lib/synapsis/agent/daemon/session_executor.ex
```

API:

```elixir
defmodule Synapsis.Agent.Daemon.SessionExecutor do
  def run(%Synapsis.AgentRun{} = run, opts \\ %{})
end
```

Execution flow:

```text
1. resolve project path
2. create session with daemon metadata
3. update AgentRun with session_id
4. subscribe to session topic
5. call Synapsis.Sessions.send_message(session.id, prompt)
6. wait for system completion/error event
7. fetch final assistant message
8. optionally delete ephemeral session depending on keep_history policy
9. return {:ok, summary} or {:error, reason}
```

Session metadata:

```elixir
%{
  type: :agent_run,
  agent_run_id: run.id,
  run_kind: run.kind,
  heartbeat_id: run.heartbeat_id,
  routine_id: run.routine_id,
  source: run.source,
  tool_profile: run.tool_profile
}
```

### 7.7 Completion events

Add system-level session broadcasts.

In graph completion node:

```text
apps/synapsis_agent/lib/synapsis/agent/nodes/complete.ex
```

Keep existing UI broadcasts:

```elixir
{"done", %{}}
{"session_status", %{status: "idle"}}
```

Add:

```elixir
{:session_completed, session_id, %{status: :completed}}
```

In error paths, add:

```elixir
{:session_error, session_id, reason}
```

Likely locations:

- provider error handler;
- runner exit handler;
- QueryLoop task down handler;
- send_message failure path if available;
- any terminal model error handler.

The daemon and heartbeat worker should watch system events, not UI events.

### 7.8 Final assistant summary extraction

Use existing message persistence:

```elixir
Synapsis.Sessions.get_messages(session_id)
```

Find latest assistant message and extract text parts. Implement in executor helper:

```elixir
defp fetch_last_assistant_text(session_id) do
  session_id
  |> Synapsis.Sessions.get_messages()
  |> Enum.filter(&(&1.role == :assistant))
  |> List.last()
  |> extract_text()
end
```

Return `"(no assistant response)"` if none.

---

## 8. Heartbeat Design

There are two heartbeat meanings. Keep them separate.

## 8.1 Daemon liveness heartbeat

- cheap;
- internal;
- no LLM;
- every 60 seconds by default;
- updates daemon status and dashboard;
- emits `agent.daemon.heartbeat`.

## 8.2 Heartbeat routine

- scheduled proactive agent run;
- can call model;
- can use restricted tools;
- configured by existing `heartbeat_configs`;
- executed through `Synapsis.Agent.Daemon.trigger_heartbeat/2`.

### 8.3 Update heartbeat worker

Current `Synapsis.Agent.Heartbeat.Worker` manually creates a session and writes workspace results. Replace execution body with daemon trigger.

New flow:

```elixir
def perform(%Oban.Job{args: %{"heartbeat_id" => heartbeat_id}}) do
  with %HeartbeatConfig{} = config <- Heartbeats.get(heartbeat_id),
       true <- config.enabled,
       {:ok, run} <- Synapsis.Agent.Daemon.trigger_heartbeat(config.id, %{source: :oban}) do
    Synapsis.Agent.Heartbeat.Scheduler.schedule_heartbeat(config)
    :ok
  else
    nil -> {:error, :config_not_found}
    false -> :ok
    {:skip, :busy} -> :ok
    {:error, reason} -> {:error, reason}
  end
end
```

The daemon/session executor should handle:

- run creation;
- session execution;
- workspace result writing;
- notification;
- run completion.

### 8.4 Heartbeat workspace output

Preserve current workspace output behavior:

```text
/global/heartbeats/<name>/latest.md
/global/heartbeats/<name>/history/<timestamp>.md
```

But move this responsibility into a helper:

```text
apps/synapsis_agent/lib/synapsis/agent/heartbeat/result_writer.ex
```

API:

```elixir
write_result(config, run, summary)
write_error(config, run, error)
```

### 8.5 Heartbeat run prompt

For scheduled heartbeat routines, use the existing config prompt but wrap it in system constraints:

```text
You are running a scheduled Synapsis heartbeat routine.
This is an autonomous read-mostly check.
Do not modify project files.
Do not run shell commands unless the routine explicitly allows execution.
Summarize what changed, what needs attention, and suggested next actions.
```

Add this wrapper in the daemon before sending the prompt.

### 8.6 Heartbeat tool profile

Default:

```text
heartbeat
```

Allowed by default:

```text
file_read
list_dir
grep
glob
repo_status
memory_search
todo_read
web_fetch
web_search, if configured
```

Blocked unless explicitly allowed:

```text
bash
file_write
file_edit
file_delete
repo_sync
worktree_remove
destructive tools
```

Implementation can start by passing `tool_profile` in session metadata and filtering tools in daemon/session config if the existing runtime supports it. If not, add a tool-filter helper that resolves agent tools and drops unsafe names for autonomous runs.

---

## 9. Dream / Reflection Design

Dream is the idle/reflection loop. It converts recent activity into durable memory, proposed tasks, and risk notes.

### 9.1 Dream triggers

- manual web button: `Run Dream Now`;
- scheduled nightly job later;
- idle trigger later after daemon has been idle for a configurable interval.

MVP: manual web button only.

### 9.2 Dream behavior

Dream should read:

```text
recent agent_runs
recent agent_events
recent memory_events
recent sessions
recent tool failures
heartbeat outputs
open todos
project summaries
```

Dream should produce:

```text
summary
memory candidates
risks
suggested scheduled work
ignored/noisy items
```

Dream must not edit project files or run shell commands by default.

### 9.3 Add modules

Create:

```text
apps/synapsis_agent/lib/synapsis/agent/dream.ex
apps/synapsis_agent/lib/synapsis/agent/dream_prompt.ex
```

`Synapsis.Agent.Dream` API:

```elixir
def build_prompt(opts \\ %{})
def collect_context(opts \\ %{})
def persist_result(run, summary, opts \\ %{})
```

### 9.4 Dream prompt

Base prompt:

```text
You are Synapsis during an idle reflection cycle.

Review recent runs, messages, tool results, todos, failed attempts, heartbeats, and memories.
Do not modify project files.
Do not run shell commands.
Extract durable facts, unresolved tasks, risks, and suggested next actions.

Return exactly these sections:

1. Recent activity
2. Durable memories to keep
3. User attention needed
4. Suggested scheduled work
5. Noise to ignore
6. Risk notes
```

Append compact context after the prompt.

### 9.5 Dream tool profile

Default:

```text
reflect
```

Allowed:

```text
memory_search
memory_save
todo_read
todo_write
session_summarize
repo_status
list_dir
file_read
grep
glob
```

Blocked:

```text
bash
file_write
file_edit
file_delete
repo_sync
worktree_remove
destructive tools
```

### 9.6 Dream persistence

After dream completes:

1. update `agent_runs.summary`;
2. append `AgentEvent` with event type `dream_completed` or `summary_created` if existing allowed values constrain event type;
3. append `MemoryEvent` with type `summary_created`;
4. optionally create memory candidates if there is an existing memory API for that.

Do not invent a new memory schema unless required.

---

## 10. Generic Scheduled Routines

Do this after heartbeat and dream work.

### 10.1 Add `agent_routines`

Migration:

```elixir
create table(:agent_routines, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :name, :string, null: false
  add :kind, :string, null: false
  add :scope, :string, null: false, default: "global"
  add :assistant_name, :string
  add :project_id, :string
  add :schedule, :string, null: false
  add :prompt, :text, null: false
  add :enabled, :boolean, null: false, default: false
  add :tool_profile, :string, null: false, default: "read_only"
  add :allow_actions, :boolean, null: false, default: false
  add :no_overlap, :boolean, null: false, default: true
  add :max_runtime_ms, :integer, null: false, default: 120_000
  add :notify_user, :boolean, null: false, default: true
  add :keep_history, :boolean, null: false, default: true
  add :last_run_id, :binary_id
  add :last_run_at, :utc_datetime_usec
  add :next_run_at, :utc_datetime_usec
  add :metadata, :map, null: false, default: %{}

  timestamps(type: :utc_datetime_usec)
end

create unique_index(:agent_routines, [:name])
create index(:agent_routines, [:kind])
create index(:agent_routines, [:enabled])
create index(:agent_routines, [:next_run_at])
```

Valid kinds:

```text
heartbeat
dream
schedule
```

Use existing `heartbeat_configs` during MVP. Add `agent_routines` only after heartbeat and dream are stable.

### 10.2 Routine worker

Create:

```text
apps/synapsis_agent/lib/synapsis/agent/routine_worker.ex
```

Oban queue:

```text
routines
```

Flow:

```text
Oban job fires
  -> load AgentRoutine
  -> skip if disabled
  -> skip if no_overlap and daemon busy
  -> Synapsis.Agent.Daemon.trigger_schedule(routine.id, source: :oban)
  -> reschedule next occurrence
```

---

## 11. Web API

Add controllers under:

```text
apps/synapsis_server/lib/synapsis_server/controllers/
```

### 11.1 `AgentController`

Routes:

```elixir
scope "/api/agent", SynapsisServer do
  pipe_through :api

  get "/status", AgentController, :status
  post "/dream", AgentController, :dream
end
```

Actions:

```elixir
status(conn, _params)
```

Returns daemon status.

```elixir
dream(conn, params)
```

Calls:

```elixir
Synapsis.Agent.Daemon.trigger_dream(%{source: :web, assistant_name: params["assistant_name"]})
```

### 11.2 `AgentRunController`

Routes:

```elixir
get "/runs", AgentRunController, :index
get "/runs/:id", AgentRunController, :show
post "/runs", AgentRunController, :create
post "/runs/:id/cancel", AgentRunController, :cancel
```

`POST /api/agent/runs` body:

```json
{
  "kind": "manual",
  "prompt": "Check project health and summarize risks.",
  "assistant_name": "default",
  "project_id": null,
  "tool_profile": "read_only"
}
```

For now this is optional because existing session chat already supports manual messages. Implement if useful for web daemon testing.

### 11.3 `HeartbeatController`

Routes:

```elixir
post "/heartbeats/:id/run", HeartbeatController, :run_now
```

Calls:

```elixir
Synapsis.Agent.Daemon.trigger_heartbeat(id, %{source: :web})
```

### 11.4 JSON serialization

Use simple maps. Do not introduce a large serializer framework.

Run JSON:

```json
{
  "id": "...",
  "kind": "heartbeat",
  "status": "completed",
  "source": "web",
  "assistant_name": "default",
  "session_id": "...",
  "project_id": null,
  "heartbeat_id": "...",
  "prompt": "...",
  "tool_profile": "heartbeat",
  "summary": "...",
  "error": null,
  "started_at": "...",
  "finished_at": "...",
  "metadata": {}
}
```

---

## 12. LiveView UI

### 12.1 Dashboard

Update:

```text
apps/synapsis_web/lib/synapsis_web/live/dashboard_live.ex
```

Show:

```text
System Health
Daemon Status
Current Run
Recent Runs
Last Liveness Heartbeat
Last Routine Heartbeat
Last Dream
```

Subscribe to:

```elixir
Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:daemon")
Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:runs")
```

### 12.2 Assistant Settings: rename Cron Jobs to Routines

Update:

```text
apps/synapsis_web/lib/synapsis_web/live/assistant_live/setting.ex
```

Current tab label:

```text
Cron Jobs
```

Change to:

```text
Routines
```

Current active tab key can remain `cron_jobs` for compatibility, or change to `routines` and support old key as alias.

New sections:

```text
Routines
  ├─ Heartbeats
  │   ├─ list existing heartbeat configs
  │   ├─ create/edit/delete/toggle
  │   ├─ Run now
  │   ├─ last run status
  │   └─ last result preview
  │
  ├─ Dream
  │   ├─ Run Dream Now
  │   ├─ last dream status
  │   └─ last dream summary
  │
  └─ Run History
      ├─ recent agent_runs
      ├─ filter by kind/status
      └─ click to view details
```

### 12.3 Heartbeat run-now event

Add LiveView event:

```elixir
def handle_event("run_heartbeat_now", %{"id" => id}, socket) do
  case Synapsis.Agent.Daemon.trigger_heartbeat(id, %{source: :web, assistant_name: socket.assigns.assistant_name}) do
    {:ok, run} -> ...
    {:queued, run} -> ...
    {:skip, :busy} -> ...
    {:error, reason} -> ...
  end
end
```

### 12.4 Dream run-now event

```elixir
def handle_event("run_dream_now", _params, socket) do
  case Synapsis.Agent.Daemon.trigger_dream(%{source: :web, assistant_name: socket.assigns.assistant_name}) do
    {:ok, run} -> ...
    {:queued, run} -> ...
    {:skip, :busy} -> ...
    {:error, reason} -> ...
  end
end
```

### 12.5 Run details

Either add inline modal or a route:

```elixir
live "/agent/runs/:id", SynapsisWeb.AgentLive.RunShow, :show
```

MVP can show run details inline in Assistant Settings.

Show:

```text
id
kind
status
source
session_id
project_id
heartbeat_id
prompt
summary
error
started_at
finished_at
metadata
link to session if session_id present
```

---

## 13. Tool Policy for Autonomous Runs

The daemon must distinguish manual chat from autonomous routines.

### 13.1 Tool profiles

```text
read_only
  file_read, list_dir, grep, glob, repo_status, memory_search, todo_read

heartbeat
  read_only + web_fetch + web_search if configured

reflect
  read_only + memory_save + todo_write + session_summarize

coding
  read_only + file_write + file_edit + bash, but approval required

maintenance
  coding + repo/worktree tools, approval required

dangerous
  destructive tools; never automatic
```

### 13.2 Default profiles by run kind

```text
manual      read_only unless UI requests otherwise
heartbeat   heartbeat
dream       reflect
schedule    read_only
```

### 13.3 Enforcement

Preferred implementation:

- add a tool profile resolver in `synapsis_agent`:

```text
apps/synapsis_agent/lib/synapsis/agent/tool_profiles.ex
```

API:

```elixir
allowed_tool_names(profile)
filter_tools(tools, profile)
autonomous?(run_kind)
```

- pass filtered tools to session/runtime where possible;
- if current runtime always resolves all agent tools, modify the resolver path so session metadata `tool_profile` restricts tools for daemon-created sessions.

Do not weaken existing approval gates. Autonomous heartbeat/dream/schedule should not auto-approve writes or shell execution by default.

---

## 14. Safety and Local Web Hardening

MVP safety requirements:

1. bind development endpoint to `127.0.0.1` unless explicitly configured otherwise;
2. enable origin checks for known local origins;
3. add at least a local token/session guard before production exposure;
4. avoid unauthenticated `/workspace` in production;
5. do not auto-approve `:write` or `:execute` for autonomous runs;
6. keep autonomous routine policy separate from manual interactive chat policy.

### 14.1 Dev config

Current dev config binds all IPv6 interfaces and disables origin checks. Change only if this does not break local development:

```elixir
config :synapsis_server, SynapsisServer.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4657],
  check_origin: ["http://localhost:4657", "http://127.0.0.1:4657"]
```

If all-interface binding is needed, require an env var:

```text
SYNAPSIS_BIND_ALL=true
```

### 14.2 Socket auth

Current `UserSocket.connect/3` accepts all clients. Add token/session validation in a later hardening PR if not feasible in MVP.

At minimum document this warning and do not expose beyond local host.

---

## 15. Detailed Implementation Phases

## Phase 1 — Phoenix ownership and health

Files:

```text
apps/synapsis_server/mix.exs
apps/synapsis_server/lib/synapsis_server/application.ex
apps/synapsis_core/lib/synapsis_core/application.ex
apps/synapsis_server/lib/synapsis_server/controllers/health_controller.ex
apps/synapsis_server/lib/synapsis_server/router.ex
apps/synapsis_web/lib/synapsis_web/live/dashboard_live.ex
```

Tasks:

1. Add `SynapsisServer.Application`.
2. Update `synapsis_server/mix.exs` with `mod: {SynapsisServer.Application, []}`.
3. Remove `SynapsisServer.Supervisor` from core optional children.
4. Add `GET /api/health`.
5. Add dashboard health cards.
6. Add tests.

Acceptance:

```text
mix compile
GET /api/health returns JSON
Dashboard loads and shows health state
```

## Phase 2 — AgentRun persistence

Files:

```text
apps/synapsis_data/priv/repo/migrations/*_create_agent_runs.exs
apps/synapsis_data/lib/synapsis/agent_run.ex
apps/synapsis_agent/lib/synapsis/agent/runs.ex
apps/synapsis_agent/lib/synapsis/agent/run_events.ex
```

Tasks:

1. Add migration/schema.
2. Add context with lifecycle functions.
3. Add stale run recovery.
4. Add event helper.
5. Add data tests.

Acceptance:

```text
create run
mark running
mark completed
mark failed
list recent
recover stale running runs
```

## Phase 3 — Daemon MVP

Files:

```text
apps/synapsis_agent/lib/synapsis/agent/supervisor.ex
apps/synapsis_agent/lib/synapsis/agent/daemon.ex
apps/synapsis_agent/lib/synapsis/agent/daemon/session_executor.ex
apps/synapsis_agent/lib/synapsis/agent/tool_profiles.ex
```

Tasks:

1. Add daemon child to supervisor.
2. Implement `status/0`.
3. Implement liveness timer.
4. Implement `submit_manual/2` with existing session runtime.
5. Implement single-run-at-a-time policy.
6. Broadcast daemon/run events.
7. Add daemon tests.

Acceptance:

```text
daemon starts under supervisor
daemon status returns idle
daemon emits liveness heartbeat
daemon creates AgentRun for manual prompt
daemon marks run completed or failed
```

## Phase 4 — Session completion system events

Files:

```text
apps/synapsis_agent/lib/synapsis/agent/nodes/complete.ex
apps/synapsis_agent/lib/synapsis/session/worker.ex
apps/synapsis_agent/lib/synapsis/session/worker/io_handler.ex
apps/synapsis_agent/lib/synapsis/session/worker/persistence.ex
```

Tasks:

1. Add `{:session_completed, session_id, result}` broadcast on normal completion.
2. Add `{:session_error, session_id, reason}` broadcasts on errors.
3. Keep existing UI events unchanged.
4. Update tests around session completion.

Acceptance:

```text
normal session emits done + session_status + session_completed
error session emits session_error
heartbeat/daemon executor can wait for system event
```

## Phase 5 — Heartbeat through daemon

Files:

```text
apps/synapsis_agent/lib/synapsis/agent/heartbeat/worker.ex
apps/synapsis_agent/lib/synapsis/agent/heartbeat/result_writer.ex
apps/synapsis_agent/lib/synapsis/agent/daemon.ex
apps/synapsis_web/lib/synapsis_web/live/assistant_live/setting.ex
```

Tasks:

1. Implement `Daemon.trigger_heartbeat/2`.
2. Replace heartbeat worker execution with daemon trigger.
3. Preserve workspace latest/history result writing.
4. Add `Run now` button to heartbeat UI.
5. Show last run status/result.
6. Add Oban tests.

Acceptance:

```text
manual heartbeat run creates AgentRun(kind: heartbeat)
Oban heartbeat job creates AgentRun(kind: heartbeat)
heartbeat result visible in web UI
heartbeat latest.md written
heartbeat history written when keep_history=true
```

## Phase 6 — Dream

Files:

```text
apps/synapsis_agent/lib/synapsis/agent/dream.ex
apps/synapsis_agent/lib/synapsis/agent/dream_prompt.ex
apps/synapsis_agent/lib/synapsis/agent/daemon.ex
apps/synapsis_web/lib/synapsis_web/live/assistant_live/setting.ex
apps/synapsis_server/lib/synapsis_server/controllers/agent_controller.ex
apps/synapsis_server/lib/synapsis_server/router.ex
```

Tasks:

1. Implement dream context collection.
2. Implement dream prompt builder.
3. Implement `Daemon.trigger_dream/1`.
4. Add `POST /api/agent/dream`.
5. Add `Run Dream Now` UI.
6. Persist dream summary into AgentRun and MemoryEvent.
7. Add tests.

Acceptance:

```text
Run Dream Now creates AgentRun(kind: dream)
dream run uses reflect tool profile
dream summary appears in UI
dream summary stored as MemoryEvent(summary_created)
```

## Phase 7 — Run APIs and UI

Files:

```text
apps/synapsis_server/lib/synapsis_server/controllers/agent_controller.ex
apps/synapsis_server/lib/synapsis_server/controllers/agent_run_controller.ex
apps/synapsis_server/lib/synapsis_server/controllers/heartbeat_controller.ex
apps/synapsis_server/lib/synapsis_server/router.ex
apps/synapsis_web/lib/synapsis_web/live/assistant_live/setting.ex
```

Tasks:

1. Add daemon status API.
2. Add run list/show APIs.
3. Add heartbeat run-now API.
4. Add run history UI.
5. Subscribe LiveViews to run PubSub events.
6. Add tests.

Acceptance:

```text
GET /api/agent/status
GET /api/agent/runs
GET /api/agent/runs/:id
POST /api/agent/heartbeats/:id/run
run history updates live when run completes
```

## Phase 8 — Generic routines

Only start after Phase 6/7 pass.

Files:

```text
apps/synapsis_data/priv/repo/migrations/*_create_agent_routines.exs
apps/synapsis_data/lib/synapsis/agent_routine.ex
apps/synapsis_agent/lib/synapsis/agent/routines.ex
apps/synapsis_agent/lib/synapsis/agent/routine_worker.ex
apps/synapsis_agent/lib/synapsis/agent/routine_scheduler.ex
apps/synapsis_web/lib/synapsis_web/live/assistant_live/setting.ex
```

Tasks:

1. Add `agent_routines` table/schema/context.
2. Add routine scheduler with Oban.
3. Add routine worker.
4. Add UI for generic schedules.
5. Add `Daemon.trigger_schedule/2`.
6. Add tests.

Acceptance:

```text
create disabled schedule routine
validate cron
run routine now
Oban fires enabled routine
no_overlap respected
run history updated
```

## Phase 9 — Web safety hardening

Files:

```text
config/dev.exs
config/runtime.exs
apps/synapsis_server/lib/synapsis_server/channels/user_socket.ex
apps/synapsis_server/lib/synapsis_server/router.ex
apps/synapsis_web/lib/synapsis_web/live/*
```

Tasks:

1. Bind local by default.
2. Add origin checks.
3. Add local auth/token guard if production exposure is possible.
4. Add guard before `/workspace`.
5. Ensure autonomous runs do not auto-approve write/execute.
6. Add security tests where practical.

---

## 16. Test Plan

### 16.1 Data tests

```text
AgentRun changeset validates kind/status/source/tool_profile
Runs.create/1 persists
Runs.mark_running/2 sets started_at
Runs.mark_completed/3 sets finished_at and summary
Runs.mark_failed/3 sets error
Runs.recover_stale_running_runs/1 marks stale active runs failed
```

### 16.2 Daemon tests

```text
daemon starts under Synapsis.Agent.Supervisor
daemon status returns idle initially
liveness heartbeat updates last_liveness_at
daemon submit creates AgentRun
daemon busy policy skips autonomous run when running
daemon queues or rejects manual run depending on configured policy
daemon broadcasts agent.run.started and agent.run.completed
```

### 16.3 Session completion tests

```text
completion node broadcasts {"done", %{}}
completion node broadcasts {"session_status", %{status: "idle"}}
completion node broadcasts {:session_completed, session_id, %{status: :completed}}
error path broadcasts {:session_error, session_id, reason}
```

### 16.4 Heartbeat tests

```text
Heartbeats.create validates cron
Heartbeat.Scheduler.next_run_time returns DateTime
Heartbeat.Worker calls Daemon.trigger_heartbeat
trigger_heartbeat creates AgentRun(kind: heartbeat)
heartbeat result writer writes latest.md
history written only when keep_history=true
heartbeat UI lists configs
heartbeat UI Run Now creates run
```

### 16.5 Dream tests

```text
Dream.collect_context returns bounded context
Dream.build_prompt includes required sections
trigger_dream creates AgentRun(kind: dream)
dream uses reflect tool profile
dream summary writes MemoryEvent(summary_created)
Dream UI Run Now creates run
```

### 16.6 Controller tests

```text
GET /api/health
GET /api/agent/status
GET /api/agent/runs
GET /api/agent/runs/:id
POST /api/agent/heartbeats/:id/run
POST /api/agent/dream
```

### 16.7 LiveView tests

```text
Dashboard renders health and daemon status
Assistant Settings renders Routines tab
Heartbeat list renders existing configs
Run Now button invokes daemon
Dream button invokes daemon
Run history updates after PubSub event
```

### 16.8 Oban tests

Use Oban test mode.

```text
heartbeat job enqueued at next run time
heartbeat job performs and schedules next occurrence
disabled heartbeat returns :ok without run
busy daemon causes scheduled autonomous run skip
```

---

## 17. Acceptance Criteria

The project is considered working for this milestone when this browser-first flow passes:

1. `mix compile` succeeds.
2. `mix test` succeeds for the new data/daemon/web tests.
3. `mix phx.server` starts the Phoenix app.
4. Browser opens `/` successfully.
5. Dashboard shows health for Repo, PubSub, Oban, tool registry, provider registry, session supervisor, agent supervisor, agent daemon, endpoint.
6. `/api/health` returns JSON.
7. `/api/agent/status` returns daemon status.
8. Existing assistant session chat still works.
9. `/assistant/:name/setting` has a `Routines` tab.
10. Routines tab lists heartbeat configs.
11. User can create/edit/toggle/delete a heartbeat.
12. User can click `Run now` for a heartbeat.
13. Heartbeat creates `AgentRun(kind: heartbeat)`.
14. Heartbeat result appears in run history.
15. Heartbeat result writes workspace latest/history files according to config.
16. User can click `Run Dream Now`.
17. Dream creates `AgentRun(kind: dream)`.
18. Dream summary appears in run history.
19. Dream writes a memory summary event.
20. Restarting Phoenix does not lose agent run history.

---

## 18. Coding Rules for Codex

1. Do not add CLI features.
2. Do not remove existing LiveView routes.
3. Do not remove existing session chat behavior.
4. Do not rewrite provider adapters.
5. Do not rewrite the tool executor unless needed to enforce autonomous tool profiles.
6. Prefer small modules with clear APIs over one large daemon file.
7. Keep UI labels user-facing: `Routines`, `Run History`, `Dream`, `Heartbeat`.
8. Keep implementation compatible with existing heartbeat configs.
9. Add tests with each phase.
10. Use existing `Synapsis.PubSub` for live updates.
11. Use existing `Synapsis.Repo` and Ecto schemas.
12. Use existing `Oban` queues; add a `routines` queue only when generic routines are implemented.
13. Autonomous runs must be conservative by default.
14. Preserve UI events for browser clients when adding system completion events.
15. Mark implementation TODOs explicitly if a phase needs a later follow-up.

---

## 19. Suggested First Codex Task

Start with Phase 1 and Phase 2 only.

Prompt to Codex:

```text
Implement Phase 1 and Phase 2 from SYNAPSIS_AGENT_DAEMON_DESIGN_FOR_CODEX.md.

Do not implement daemon execution yet.

Required changes:
1. Add SynapsisServer.Application and make synapsis_server own SynapsisServer.Supervisor.
2. Remove SynapsisServer.Supervisor startup from SynapsisCore.Application.
3. Add GET /api/health.
4. Add agent_runs migration/schema/context.
5. Add tests for health and AgentRun lifecycle.

Keep existing routes and session chat behavior unchanged.
Run mix compile and mix test for affected apps.
```

After that passes, continue to Phase 3.
