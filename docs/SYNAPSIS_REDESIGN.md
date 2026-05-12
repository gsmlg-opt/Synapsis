# Synapsis v2 — Agent Management & Runtime Platform

**Status:** Design locked. Ready for scaffolding.
**Date:** 2026-05-12

---

## 1. Overview

Synapsis is repurposed from a single-purpose coding agent into a **single-node agent management & runtime platform**. It creates agents, gives them tools / MCPs / skills / hooks, runs them in sessions against external working directories, and schedules them via cron.

**External dependencies:**

- **Backplane** (`https://github.com/gsmlg-opt/backplane`) — LLM provider proxy + MCP proxy + skills storage + secrets + cache. Synapsis holds no provider credentials.
- **Samgita** (`https://github.com/gsmlg-opt/Samgita`) — *future* multi-node / cross-project coordination. This refactor only defines the outbound event contract; no client.

```
┌─────────────────────────────────────────┐
│ Synapsis  ── agent runtime, sessions,   │
│              cron, workspace fs         │
└──────────────┬──────────────────────────┘
               │ HTTP / SSE
┌──────────────▼──────────────────────────┐
│ Backplane ── LLM API, MCP proxy,        │
│              skills, secrets, cache     │
└─────────────────────────────────────────┘

       ↕ (later, opt-in, via event channel)

┌─────────────────────────────────────────┐
│ Samgita   ── multi-node coordination,   │
│              project memory/graph       │
└─────────────────────────────────────────┘
```

---

## 2. Goals & Non-Goals

### Goals
- Define agents with full config: prompt, model, tools, MCPs, skills, hooks, memory, capabilities.
- Each agent has its own workspace dir (memory, notes, files, skills, hooks, sessions).
- Spawn sessions with a working directory (often an external git repo).
- Always-on agents share an ETS hot memory across sessions.
- Cron-driven sessions.
- Claude Code-parity tool catalog and hook system.

### Non-Goals (this refactor)
- Multi-node distribution (Samgita's concern).
- Direct LLM provider integrations (backplane).
- Secrets management (backplane).
- MCP wire protocol (backplane).
- LSP as a first-class subsystem (treated as a tool/MCP).
- Samgita client.

---

## 3. Domain Model

```
Agent      ── template: prompt, llm cfg, tools, mcps, skills, hooks, memory cfg, caps, cwd policy
Session    ── running instance of Agent against a cwd; has its own context + transcript
Note       ── full-detail markdown record, topic-keyed
Memory     ── summary entry indexing notes, day-keyed
CronJob    ── scheduled (Agent, prompt_template, cwd_strategy) → Session
Hook       ── event-driven action (command | webhook | module)
Skill      ── composable capability pack (manifest + sys fragment + tools)
Tool       ── typed function (schema + caps + impl)
```

**Agent is data** (TOML on disk). **Session is process** (OTP).

---

## 4. OTP Topology (Single Node)

```
Synapsis.Application
├── Synapsis.PubSub
├── Synapsis.Registry            (Sessions, Agents — local)
├── Synapsis.Backplane.Pool      (Finch HTTP pool)
├── Synapsis.AgentSup            (DynamicSupervisor)
│   └── Agent.Server             (one per active agent — workspace owner, ETS owner)
│       └── SessionSup           (DynamicSupervisor)
│           └── Session.Server   (:gen_statem)
│               ├── ToolSup      (Task.Supervisor per session)
│               └── StreamRelay  (backplane SSE → PubSub)
├── Synapsis.Scheduler           (Oban + Oban.Cron)
└── Synapsis.Telemetry
```

**Agent.Server is single writer** to workspace memory & ETS — guarantees ordering, no inter-session locks needed.

**Lifecycle:**
- `mode = "always_on"` → started at AppSup boot, runs forever.
- `mode = "lazy"` → started on first session, terminated after `idle_timeout_ms`.

---

## 5. Umbrella Apps

```
apps/
├── synapsis_core         # Ecto schemas, contexts, behaviours — LEAF
├── synapsis_workspace    # Agent workspace fs (memory, notes, skills, hooks)
├── synapsis_tools        # Built-in tool implementations
├── synapsis_runtime      # Agent.Server, Session.Server, hook engine, dispatch
├── synapsis_scheduler    # Oban cron → Session factory
├── synapsis_server       # Phoenix: REST + Channels + SSE
├── synapsis_cli          # escript
└── synapsis_web          # React UI
```

**Dependency direction** (enforced via `mix.exs`):
```
web/cli → server → {runtime, scheduler}
                       └→ {workspace, tools} → core
```

---

## 6. Workspace Layout

```
~/.synapsis/
├── hooks.json                       # global hooks
└── agents/
    └── <slug>/
        ├── agent.toml               # versioned definition snapshot
        ├── hooks.json               # per-agent hooks
        ├── memory/
        │   ├── 2026-05-12.md        # today, append-only
        │   ├── 2026-05-11.md
        │   ├── ...
        │   ├── index/
        │   │   └── embeddings.sqlite   # optional vector sidecar
        │   └── compressed/
        │       ├── raw/             # archived originals (if retained)
        │       ├── 2026-W18.md
        │       └── 2026-04.md
        ├── notes/
        │   └── <topic>/<slug>.md
        ├── skills/
        │   └── <skill>/SKILL.md
        ├── files/
        └── sessions/
            └── <id>/
                ├── messages.jsonl
                ├── events.jsonl
                └── cwd.info
```

---

## 7. Memory Model

### 7.1 Note vs Memory — Hard Split

|  | Memory | Note |
|---|---|---|
| Content | summary, terse | full detail |
| Layout | day-keyed (`memory/YYYY-MM-DD.md`) | topic-keyed (`notes/<topic>/<slug>.md`) |
| Write tool | `memory.append(summary, [note_refs])` | `note.write(body, tags) → ref` |
| In ETS? | yes (hot cache) | no |
| Lifetime | compressed over time | retained until explicit archive |

Memory entries reference note refs. **Memory is the index; notes are the leaves.**

### 7.2 Daily Memory File Format

```markdown
# 2026-05-12

## 14:23  [decision, project-x]
Chose Phoenix Channel over SSE for session streaming.  → notes/project-x/streaming-decision.md

## 16:45  [bugfix]
Fixed race in Agent.Server reconfigure path.  → notes/runtime/agent-reconfigure-race.md
```

Each `##` block: timestamp, tags, summary, note ref(s). Greppable, diffable, embeddable as chunks.

### 7.3 Note File Format

```markdown
---
created: 2026-05-12T16:45:00Z
tags: [bugfix, runtime]
session: <id>
linked_from: [memory/2026-05-12.md]
---
<full detail>
```

### 7.4 Hot Cache (Always-On Agents)

`Agent.Server` owns one ETS table per agent:

```
:ets.new(:"mem_<slug>", [
  :ordered_set, :public,
  read_concurrency: true,
  write_concurrency: false
])
```

Row: `{ts_unix_ms, %{kind, tags, body, note_refs, session_id}}`.

**Lifecycle:**

```
boot          → load last D days from memory/*.md → ETS  (D = hot_window_days, default 7)
write         → Agent.Server: ETS insert + append to memory/<today>.md   (write-through)
read recent   → ETS range scan (fast)
read older    → fallback to disk grep + embedding sidecar
shutdown/idle → flush + :ets.delete
```

- **Write-through, not write-behind.** Markdown append is microseconds; WAL complexity not worth it. ETS is purely a read accelerator + cross-session shared state.
- **Lazy agents skip ETS** — hit disk directly. Cache is opt-in via `mode = "always_on"`.
- **Cross-session sharing:** all live sessions of one agent read the same ETS table. Writes serialize through `Agent.Server` for deterministic ordering.

### 7.5 Time-Based Compaction

```
age(file)          action
─────────────      ─────────────────────────────────
< 7 days           daily file, untouched
7–30 days          eligible for weekly rollup
30–365 days        eligible for monthly rollup
> 365 days         eligible for quarterly/yearly rollup
```

Oban-scheduled per `memory.compression.schedule` cron. Each compaction = LLM summarize via backplane. Output: `compressed/<period>.md` with `source_hashes:` frontmatter for dedup. Originals archived (if `keep_raw_after_compaction = true`) or deleted by retention policy.

**Compaction is lossy by design** — notes remain untouched, so detail is recoverable via surviving note refs.

### 7.6 Consolidation Triggers

Two paths, same target:

1. **Tool-driven** — LLM calls `memory.promote(note_ref, topic)`.
2. **Idle-time background** — Oban watches for `active_sessions == 0` for `idle_threshold_ms`, or `short_threshold` exceeded. Skips if last run < `min_interval_ms` ago.

Dedup via `source_hashes` frontmatter; tool path takes precedence.

---

## 8. Tools Catalog (Claude-Code Parity)

| Tool | Caps | Notes |
|---|---|---|
| `fs.read` | `fs_read` | line ranges, binary detect |
| `fs.write` | `fs_write` | create/overwrite |
| `fs.edit` | `fs_write` | string-replace, multi-edit |
| `fs.glob` | `fs_read` | path globbing |
| `fs.grep` | `fs_read` | ripgrep |
| `shell.run` | `exec` | Port, cwd, timeout |
| `shell.bg` | `exec` | streams stdout via PubSub |
| `shell.kill` | `exec` | terminate bg |
| `web.fetch` | `net` | via backplane cache |
| `web.search` | `net` | via backplane |
| `notebook.edit` | `fs_write` | `.ipynb` cells |
| `todo.write` | — | session-local |
| `task.spawn` | — | sub-session (whitelisted children) |
| `plan.exit` | — | leave planning mode |
| `memory.append` | `workspace` | summary to today's daily file + ETS |
| `memory.recent` | `workspace` | last-N from ETS or disk |
| `memory.search` | `workspace` | grep + embedding |
| `memory.promote` | `workspace` | note → memory consolidation |
| `note.write` | `workspace` | full detail markdown |
| `note.read` | `workspace` | fetch by ref |
| `skill.invoke` | — | mid-session skill load |

All implement `Synapsis.Tool`:

```elixir
@callback name() :: String.t()
@callback schema() :: map()              # JSON Schema
@callback capabilities() :: [atom()]
@callback run(args :: map(), ctx :: Synapsis.Session.Context.t()) ::
            {:ok, term()} | {:error, term()}
```

**Effective caps** = `agent.caps ∩ session.caps ∩ tool.declared_caps`. Enforced at dispatch.

---

## 9. Hooks System

Claude Code / Codex semantics. Config: `hooks.json`. Resolution: global → agent → session.

### 9.1 Config Locations

```
~/.synapsis/hooks.json                          # global
~/.synapsis/agents/<slug>/hooks.json            # per-agent
session.params.hooks                            # transient
```

### 9.2 Config Shape

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "fs\\.write|fs\\.edit",
        "hooks": [
          { "type": "command", "command": "guard.sh", "timeout": 5000 },
          { "type": "webhook", "url": "http://localhost:9000/audit" }
        ] }
    ],
    "PostToolUse":      [ ... ],
    "UserPromptSubmit": [ ... ],
    "SessionStart":     [ ... ],
    "SessionEnd":       [ ... ],
    "Stop":             [ ... ],
    "SubagentStop":     [ ... ],
    "PreCompact":       [ ... ],
    "Notification":     [ ... ]
  }
}
```

### 9.3 Events

| Event | Block? | Mutate? | Matcher |
|---|---|---|---|
| `SessionStart` | yes | inject sys msg | — |
| `UserPromptSubmit` | yes | rewrite prompt | — |
| `PreToolUse` | yes | rewrite args | tool name regex |
| `PostToolUse` | no | inject ctx | tool name regex |
| `Stop` | no | trigger continuation | — |
| `SubagentStop` | no | aggregate result | child agent slug |
| `PreCompact` | yes | exclude entries | — |
| `SessionEnd` | no | — | — |
| `Notification` | no | route to UI | kind |

### 9.4 Hook Kinds

```
:command   ── Port exec; stdin = event JSON; stdout = decision JSON
:webhook   ── HTTP POST
:module    ── Elixir module impl Synapsis.Hook
```

### 9.5 Decision Schema

```json
{ "decision": "allow" | "block" | "ask",
  "reason": "...",
  "inject_context": "string to inject as system message",
  "mutated_args": { ... } }
```

### 9.6 Execution Model

- All hooks for an event run **in parallel** as `Task.async_stream` under `Session.ToolSup`.
- Decision fold:
  - any `block` → block (first reason wins; deterministic by config order)
  - any `ask` → escalate to UI
  - `mutated_args` merged left-to-right by config order
  - `inject_context` strings concatenated
- Total wall time bounded by `max(hook.timeout)`, not `sum`.
- Hook crash / timeout → `:no_decision` + telemetry; session unaffected.

### 9.7 Resolution Merge

```
effective_hooks = global ⊕ agent ⊕ session
```

Pure `Map.merge/3` over event keys; list concat within matcher groups. Testable without OTP.

---

## 10. Sessions

### 10.1 State Machine (`:gen_statem`)

```
:idle → :planning → :calling_tool → :awaiting_tool_result → :awaiting_user
                                                          → :completed
                                                          → :failed
                                                          → :cancelled
```

Transitions are pure functions over `{state, event}` — property-testable.

### 10.2 Session Context

```elixir
defmodule Synapsis.Session.Context do
  @enforce_keys [:session_id, :agent_slug, :workspace, :cwd, :caps, :memory_handle]
  defstruct [
    :session_id,           # String.t()
    :agent_slug,           # String.t()
    :workspace,            # Path.t()  — agent workspace root
    :cwd,                  # Path.t()  — task working dir
    :caps,                 # MapSet.t() — effective capabilities
    :memory_handle,        # Synapsis.Memory.Handle.t()
    :pubsub_topic,         # "session:<id>"
    :parent_session_id     # String.t() | nil  — set for sub-agents
  ]
end
```

All tools receive `Session.Context.t()` — no global state, no implicit env.

### 10.3 Working Directory (cwd)

`cwd` is absolute, often outside workspace. Agent's `[cwd_policy]` constrains it.

Strategies:

| Strategy | Description |
|---|---|
| `:fixed_path` | given path (UI/CLI default) |
| `:checkout` | `git worktree add` of a ref; gc'd on session end |
| `:scratch` | temp under `workspace/files/` |
| `:inherit` | caller-provided |

`sessions/<id>/cwd.info` records path + git HEAD for replay/audit.

`fs_write` cap resolves writes under `cwd ∪ workspace.files` only — anything else rejected at dispatch.

---

## 11. Sub-Agents

`task.spawn(child_agent_slug, task_description)`:

- Child must be in parent's `[subagents].allow` whitelist.
- Parent emits a handoff message (LLM-produced or templated).
- Child `Session.Context` starts with:
  - `messages: [{role: :user, content: handoff}]`
  - `parent_session_id` set (for `SubagentStop` event)
  - `cwd` inherited if `subagents.inherit_cwd = true`, else child's strategy applies
  - **No** parent memory, **no** parent transcript
- Child's own agent-level memory (ETS / files) remains accessible.
- On child termination: `SubagentStop` event fires on parent with `{result, exit_reason}`, available for parent's next LLM turn.

Contract: a pure `%Handoff{}` record. Child boots from this; nothing implicit.

---

## 12. Cron Scheduling

Oban + Oban.Cron. Each `CronJob` row:

```
{agent_slug, schedule_cron, prompt_template, cwd_strategy, overlap_policy, timeout_ms, max_attempts}
```

Fire → enqueue worker → `Sessions.start/1` (same entry point as UI). One pipeline, no parallel code path.

Overlap policies: `:skip | :queue | :parallel`.

---

## 13. Outbound Channel (Samgita Stub)

`Synapsis.Channel` behaviour:

```elixir
@callback publish(Synapsis.Event.t()) :: :ok | {:error, term()}
@callback subscribe(topic :: String.t()) :: :ok
```

Events emitted onto local `Phoenix.PubSub` regardless of adapter:

- `agent.{created,updated,deleted}`
- `session.{started,ended,failed}`
- `memory.promoted`
- `cron.fired`
- `tool.called` (sampled, opt-in for cost)

**Adapters:**
- `Synapsis.Channel.Null` — default, drops remote dispatch.
- `Synapsis.Channel.Samgita` — *later*; shovels PubSub → remote. Not implemented in this refactor.

---

## 14. `agent.toml` Schema (Full)

```toml
# ~/.synapsis/agents/<slug>/agent.toml
schema_version = "1"

# ── Identity ──────────────────────────────────────────────────────────────
[meta]
name        = "Code Reviewer"
slug        = "code-reviewer"           # must match dir name
version     = "0.3.0"
description = "Reviews PRs, suggests fixes."
created_at  = "2026-05-12T10:00:00Z"

# ── Process lifecycle ─────────────────────────────────────────────────────
[runtime]
mode                    = "lazy"        # "lazy" | "always_on"
max_concurrent_sessions = 4
idle_timeout_ms         = 600_000       # ignored when always_on
boot_priority           = 50            # always_on ordering, lower = earlier

# ── LLM (forwarded to backplane) ──────────────────────────────────────────
[llm]
model         = "claude-sonnet-4-7"
temperature   = 0.2
max_tokens    = 8192
system_prompt = """
You are a careful code reviewer...
"""
extra_params  = { reasoning_effort = "medium" }   # passthrough to backplane

# ── Capabilities (effective = agent ∩ session ∩ tool.declared) ────────────
[capabilities]
allow = ["fs_read", "fs_write", "exec", "net", "workspace"]
deny  = []                              # explicit deny overrides allow

# ── Session working dir constraint ────────────────────────────────────────
[cwd_policy]
kind     = "allowlist"                  # "any" | "allowlist" | "under" | "fixed"
patterns = ["~/code/**", "/tmp/**"]
# when kind = "under":  path = "/srv/projects"
# when kind = "fixed":  path = "/srv/projects/yellowdog"

# ── Tools (built-in catalog subset) ───────────────────────────────────────
[tools]
enabled = [
  "fs.read", "fs.write", "fs.edit", "fs.glob", "fs.grep",
  "shell.run", "todo.write", "task.spawn",
  "note.write", "note.read",
  "memory.append", "memory.recent", "memory.search", "memory.promote",
  "skill.invoke", "web.fetch", "web.search"
]

[tools."shell.run"]
timeout_ms       = 30_000
allowed_commands = ["git", "rg", "fd", "make"]
deny_patterns    = ["rm -rf /", "curl .* | sh"]

[tools."fs.write"]
max_file_size_kb = 1024

[tools."web.fetch"]
timeout_ms = 15_000

# ── MCPs (logical names, resolved by backplane) ───────────────────────────
[mcp]
attach = ["github", "filesystem-readonly"]
scope  = "agent"                        # "agent" | "session"

# ── Skills (auto-load on session start) ───────────────────────────────────
[skills]
auto_load = ["code-review-standards", "elixir-idioms"]
resolve   = ["session", "agent_workspace", "backplane"]   # lookup order

# ── Hooks (pointer; full config in hooks.json) ────────────────────────────
[hooks]
file = "hooks.json"

# ── Memory ────────────────────────────────────────────────────────────────
[memory]
hot_window_days           = 7
keep_raw_after_compaction = true

[memory.compression]
schedule          = "0 4 * * *"         # cron, agent-local TZ
retention_daily   = "30d"
retention_weekly  = "1y"
retention_monthly = "5y"
summarizer_model  = "claude-haiku-4-5"

[memory.consolidation]
idle_threshold_ms = 300_000
short_threshold   = 100
min_interval_ms   = 600_000
cluster_strategy  = "tag_prefix"        # "tag_prefix" | "embedding" (later)

# ── Sub-agents (task.spawn whitelist) ─────────────────────────────────────
[subagents]
allow                  = ["test-runner", "doc-writer"]
default_handoff_format = "markdown"     # "markdown" | "json"
inherit_cwd            = true

# ── Outbound channel (Samgita stub) ───────────────────────────────────────
[channel]
adapter = "null"                        # "null" | "samgita"
project = "yellowdog"
events  = ["agent.*", "session.*", "memory.promoted"]

# ── Telemetry ─────────────────────────────────────────────────────────────
[telemetry]
sample_tool_calls = 0.1
record_messages   = true
```

**Loader contract** (in `synapsis_workspace`): TOML → `%Synapsis.Agent.Config{}` struct via a `parse/2` pure function with explicit per-field validation errors. Mismatches between `[capabilities].allow` and `[tools].enabled` are caught at parse time, not at first tool call.

---

## 15. `Synapsis.Memory` Behaviour Signatures

Four layered behaviours: **facade** → **store** + **cache** + **compactor**. Each layer swappable.

### 15.1 Supporting Types

```elixir
defmodule Synapsis.Memory.NoteRef do
  @enforce_keys [:topic, :slug]
  defstruct [:topic, :slug, :path]
  @type t :: %__MODULE__{topic: String.t(), slug: String.t(), path: Path.t() | nil}
end

defmodule Synapsis.Memory.Note do
  defstruct [:ref, :body, :tags, :created_at, :session_id, :linked_from]
  @type t :: %__MODULE__{
          ref: NoteRef.t(),
          body: String.t(),
          tags: [String.t()],
          created_at: DateTime.t(),
          session_id: String.t() | nil,
          linked_from: [Path.t()]
        }
end

defmodule Synapsis.Memory.Entry do
  @type source :: :tool | :consolidation | :compaction
  defstruct [:ts, :body, :tags, :note_refs, :session_id, :source, :hash]
  @type t :: %__MODULE__{
          ts: integer(),                    # unix ms
          body: String.t(),
          tags: [String.t()],
          note_refs: [NoteRef.t()],
          session_id: String.t() | nil,
          source: source(),
          hash: binary()                    # sha256 of body
        }
end

defmodule Synapsis.Memory.Query do
  defstruct text: nil, tags: [], embed: nil, limit: 50
  @type t :: %__MODULE__{
          text: String.t() | nil,
          tags: [String.t()],
          embed: binary() | nil,
          limit: pos_integer()
        }
end

defmodule Synapsis.Memory.Range do
  defstruct [:from, :to]
  @type t :: %__MODULE__{from: DateTime.t() | nil, to: DateTime.t() | nil}
end

defmodule Synapsis.Memory.Handle do
  @enforce_keys [:agent_slug, :workspace_root]
  defstruct [:agent_slug, :workspace_root, :cache, :store]
  @type t :: %__MODULE__{
          agent_slug: String.t(),
          workspace_root: Path.t(),
          cache: term() | nil,              # nil for lazy agents
          store: module()
        }
end
```

### 15.2 Facade — `Synapsis.Memory`

Public API consumed by tools and `Session.Server`. All functions take a `Handle.t()` as first arg — no global state.

```elixir
defmodule Synapsis.Memory do
  alias Synapsis.Memory.{Handle, Entry, Note, NoteRef, Query, Range}

  # ── Notes (detail) ───────────────────────────────────────────────
  @callback write_note(Handle.t(), body :: String.t(), opts :: keyword()) ::
              {:ok, NoteRef.t()} | {:error, term()}

  @callback read_note(Handle.t(), NoteRef.t()) ::
              {:ok, Note.t()} | {:error, :not_found | term()}

  @callback archive_note(Handle.t(), NoteRef.t()) :: :ok | {:error, term()}

  # ── Memory (summary index) ───────────────────────────────────────
  @callback append(Handle.t(), summary :: String.t(), opts :: keyword()) ::
              {:ok, Entry.t()} | {:error, term()}

  @callback recent(Handle.t(), window_ms :: pos_integer()) ::
              {:ok, [Entry.t()]}

  @callback search(Handle.t(), Query.t(), Range.t() | nil) ::
              {:ok, [Entry.t()]} | {:error, term()}

  @callback promote(Handle.t(), NoteRef.t(), topic :: String.t()) ::
              {:ok, Entry.t()} | {:error, term()}

  # ── Compaction (admin / Oban) ────────────────────────────────────
  @callback compact(Handle.t(), Range.t(), opts :: keyword()) ::
              {:ok, compacted_path :: Path.t()} | {:error, term()}

  # ── Hot cache lifecycle (always-on agents) ───────────────────────
  @callback load_hot(Handle.t(), days :: pos_integer()) :: {:ok, Handle.t()} | {:error, term()}
  @callback flush_hot(Handle.t()) :: :ok
end
```

**`opts` conventions:**
- `write_note`: `[tags: [String.t()], session_id: String.t() | nil]`
- `append`: `[tags: [String.t()], note_refs: [NoteRef.t()], session_id: String.t() | nil, source: Entry.source()]`
- `compact`: `[summarizer: module(), retain_raw: boolean()]`

Default impl: `Synapsis.Memory.Default` — composes `Store` + `Cache` + `Compactor`.

### 15.3 Store — `Synapsis.Memory.Store`

Persistence. Default: `Synapsis.Memory.Store.Filesystem` (markdown + YAML frontmatter).

```elixir
defmodule Synapsis.Memory.Store do
  alias Synapsis.Memory.{Entry, Note, NoteRef, Range}

  @callback append_entry(workspace_root :: Path.t(), Entry.t()) ::
              :ok | {:error, term()}

  @callback list_entries(workspace_root :: Path.t(), Range.t()) ::
              {:ok, [Entry.t()]} | {:error, term()}

  @callback put_note(workspace_root :: Path.t(), Note.t()) ::
              {:ok, NoteRef.t()} | {:error, term()}

  @callback get_note(workspace_root :: Path.t(), NoteRef.t()) ::
              {:ok, Note.t()} | {:error, :not_found}

  @callback delete_note(workspace_root :: Path.t(), NoteRef.t()) ::
              :ok | {:error, term()}

  @callback list_files(workspace_root :: Path.t(), Range.t()) ::
              {:ok, [Path.t()]}

  @callback write_compacted(
              workspace_root :: Path.t(),
              relative_path :: Path.t(),
              content :: String.t(),
              metadata :: map()
            ) :: :ok | {:error, term()}

  @callback archive_files(workspace_root :: Path.t(), [Path.t()]) ::
              :ok | {:error, term()}
end
```

### 15.4 Cache — `Synapsis.Memory.Cache`

Hot-path read accelerator. Default: `Synapsis.Memory.Cache.ETS`. Opened by `Agent.Server` for always-on agents; `nil` for lazy.

```elixir
defmodule Synapsis.Memory.Cache do
  alias Synapsis.Memory.Entry

  @type handle :: term()

  @callback open(agent_slug :: String.t(), opts :: keyword()) ::
              {:ok, handle()} | {:error, term()}

  @callback close(handle()) :: :ok

  @callback put(handle(), Entry.t()) :: :ok

  @callback range(handle(), from_ts :: integer(), to_ts :: integer()) ::
              [Entry.t()]

  @callback all(handle()) :: [Entry.t()]

  @callback size(handle()) :: non_neg_integer()
end
```

Single-writer invariant enforced upstream by `Agent.Server`; impls assume serialized `put/2`.

### 15.5 Compactor — `Synapsis.Memory.Compactor`

Summarization step. Pluggable so tests use a deterministic identity compactor. Default: `Synapsis.Memory.Compactor.Backplane`.

```elixir
defmodule Synapsis.Memory.Compactor do
  alias Synapsis.Memory.Entry

  @callback summarize(entries :: [Entry.t()], opts :: keyword()) ::
              {:ok, summary :: String.t(), source_hashes :: [binary()]}
              | {:error, term()}
end
```

`opts`: `[model: String.t(), max_tokens: pos_integer(), instructions: String.t() | nil]`.

### 15.6 Wiring

```
Tool call (memory.append)
   └→ Synapsis.Memory.append(handle, summary, opts)
        ├→ Cache.put(handle.cache, entry)       # if hot
        └→ Store.append_entry(handle.workspace_root, entry)

Oban CompactionJob.perform/1
   └→ Synapsis.Memory.compact(handle, range, opts)
        ├→ Store.list_entries(_, range)
        ├→ Compactor.summarize(entries, opts)   # via backplane
        ├→ Store.write_compacted(_, path, content, %{source_hashes: hashes})
        └→ Store.archive_files(_, sources)      # if retain_raw

Agent.Server.init/1  (always_on)
   └→ Synapsis.Memory.load_hot(handle, days)
        ├→ Cache.open(slug)
        ├→ Store.list_entries(_, last_n_days)
        └→ Enum.each(entries, &Cache.put(...))
```

### 15.7 Default Impl Map

| Module | Behaviour | Notes |
|---|---|---|
| `Synapsis.Memory.Default` | `Synapsis.Memory` | composes the three below |
| `Synapsis.Memory.Store.Filesystem` | `Synapsis.Memory.Store` | markdown + YAML frontmatter, day-keyed |
| `Synapsis.Memory.Cache.ETS` | `Synapsis.Memory.Cache` | `:ordered_set`, sharded by hour if size grows |
| `Synapsis.Memory.Compactor.Backplane` | `Synapsis.Memory.Compactor` | Req call to backplane completions |
| `Synapsis.Memory.Compactor.Identity` | `Synapsis.Memory.Compactor` | test-only, concatenates inputs |

All swappable via `Application.get_env(:synapsis, :memory_impls, ...)`.

---

## 16. Migration Plan from Current Synapsis

Current state: Phoenix umbrella with `synapsis_core`, `synapsis_server`, `synapsis_cli`, `synapsis_lsp`, `synapsis_web`. Coding-agent specific.

### 16.1 Removed
- `synapsis_lsp` app → LSP becomes a tool (or backplane MCP).
- Direct provider adapters in `synapsis_core` → replaced by Req SSE call to backplane.
- MCP wire protocol code → backplane proxies.
- Any secrets handling → backplane.

### 16.2 Added
- `synapsis_workspace` app.
- `synapsis_tools` app.
- `synapsis_scheduler` app (Oban + cron).
- `Agent.Server` + ETS hot cache.
- `Synapsis.Memory` + `Synapsis.Memory.{Store, Cache, Compactor}` behaviours.
- `Synapsis.Hook` engine.
- `Synapsis.Channel` stub (Null adapter).

### 16.3 Generalized
- `Sessions` context: drop coding-agent assumptions; agent_slug required.
- `Tools`: extract impls into `synapsis_tools`; schema in core.
- `Agents`: now versioned, TOML-on-disk, snapshot-at-session-start.

### 16.4 Suggested Implementation Order

1. **Scaffold** — create new umbrella apps; mod deps in `mix.exs`; enforce dep direction.
2. **Core schemas** — Ecto migrations for `agents`, `sessions`, `runs`, `cron_jobs`, `hooks_defs`.
3. **Workspace fs** — layout + `agent.toml` parser + `Synapsis.Memory.Store.Filesystem`.
4. **Memory** — facade + ETS cache + filesystem store + Backplane compactor.
5. **Agent.Server** — lifecycle (lazy + always_on), workspace ownership, ETS owner.
6. **Backplane client** — Req SSE for LLM completions; HTTP for tool/MCP proxy.
7. **Tool catalog** — implement built-ins one at a time; capability guard.
8. **Session.Server** — `:gen_statem`; transcript persistence; cwd policy enforcement.
9. **Hook engine** — `hooks.json` loader; parallel exec; decision fold.
10. **Scheduler** — Oban + cron table; `Sessions.start/1` from cron worker.
11. **Sub-agents** — `task.spawn` + handoff record + `SubagentStop` event.
12. **Phoenix Channels** — `session:<id>` topic; live streaming relay.
13. **REST API** — CRUD over agents / sessions / cron / hooks.
14. **CLI escript** — connect via WebSocket; run-once + interactive modes.
15. **React UI** — agent list, session viewer, cron editor, hooks editor.
16. **Channel stub** — Null adapter wired; Samgita adapter behind a flag.

---

## 17. Open Items (Implementation-Time)

- ETS sharding strategy (hour-buckets) if hot agents hit contention.
- Compaction scheduling fairness across many always-on agents.
- Cron overlap dedup at the Oban worker level.
- Vector index format (sqlite-vss vs lance vs duckdb-vss) — defer; markdown is source of truth.
- Phoenix Channel auth model (single-user assumption now; multi-user later).

---

## 18. Resolved Decisions Summary

| Question | Decision |
|---|---|
| Multi-node? | No — Samgita's concern. Single node only. |
| Secrets storage? | None in Synapsis — backplane owns auth. |
| Provider adapters? | None — backplane proxies. |
| MCP protocol code? | None — backplane proxies. |
| Skills storage? | Filesystem (`~/.synapsis/agents/<slug>/skills/`) + backplane registry. |
| Space concept? | Dropped — folded into per-agent workspace. |
| Agent startup mode? | Lazy by default; per-agent `mode = "always_on"`. |
| Memory format? | Markdown, day-keyed daily files. Vector sidecar later. |
| Sub-agent memory? | Empty + parent-produced handoff summary. |
| Hook execution? | Claude Code semantics; parallel; `hooks.json` config. |
| Memory consolidation? | Tool-driven (`memory.promote`) + idle-time Oban background. |
| Session cwd? | External path, governed by per-agent `cwd_policy`. |
| Note vs memory? | Notes = detail; memory = day-keyed summaries indexing notes. |
| Always-on hot cache? | Per-agent ETS table owned by `Agent.Server`; write-through. |

---
