# ADR-006: In-Process Session State, Embedded Concord Storage, Collapsed Runtime

## Status: Accepted

Supersedes [ADR-002 (PostgreSQL Storage)](ADR-002-postgresql-storage.md).
Amends [ADR-004 (Process-Per-Session)](ADR-004-process-per-session.md) — the
process-per-session subtree is retained, but its internal structure, supervision
strategy, and the "state lives in the DB" principle are replaced.

## Context

The agent runtime and persistence model accumulated three structural problems:

1. **Two co-linked processes per session.** `Session.Worker` (GenServer) and
   `Agent.Runtime.Runner` (GenServer) are one logical unit split across two
   processes. The Runner `{:wait}`s, delegates I/O back to the Worker via
   `{:node_request, …}`, and is woken by `Runner.resume/2`, which must
   **poll-retry up to 50× every 10ms** because resume often arrives before the
   Runner has transitioned to `:waiting` (the `:not_waiting` race). The Runner is
   `start_link`'d inside `Worker.init` (linked, not supervised), so the
   per-session `Session.Supervisor` is a hollow `one_for_all` with a single child
   and does not actually supervise the runner. Checkpoint/resume infrastructure
   exists (`Runner.start_from_checkpoint`) but is never wired into the session
   path.

2. **PostgreSQL is operationally heavy for a local agent.** An external daemon,
   connection pools, migrations, and Oban-on-Postgres for background jobs — for a
   single-user coding agent whose real ground truth (files, git) already lives on
   disk.

3. **DB-as-source-of-truth fights the streaming runtime.** `BuildPrompt` reloads
   the whole conversation from Postgres every iteration; the checkpoint serializes
   the entire in-memory `workflow_state` (structs, `MapSet`s, the conversation) to
   JSONB and rehydrates via `String.to_existing_atom` — fat, lossy, and duplicating
   the normalized `messages`/`parts` tables it can diverge from.

## Decision

### 1. Collapse Worker + Runner into one process; the engine becomes pure functions

The graph engine (`Agent.Runtime.Runner`) stops being a GenServer and becomes a
**pure reducer** — `state → node → {:next, edge, state} | {:wait, state}` plus
graph data. A single `Session.GenServer` per session owns the engine and steps it
inline. There is no cross-process `resume`, no `:not_waiting` race. The engine
remains reusable as a library (data + functions), not coupled to session concerns.

### 2. Per-session supervision: rest_for_one, tasks survive

```
Session.DynamicSupervisor (one_for_one, node-local)
└── Session.Supervisor (rest_for_one)              [one per session]
      ├── Task.Supervisor    (started 1st; survives a GenServer-only restart)
      └── Session.GenServer  (started 2nd; owns the pure engine)
```

LLM streaming and tool execution run as `Task.Supervisor.async_nolink` Tasks under
the per-session `Task.Supervisor`. `rest_for_one` means a GenServer crash restarts
only the GenServer; **in-flight tasks survive** so long-running work (a build, a
large write) is not killed.

### 3. Epoch fencing for orphaned task results

Each `Session.GenServer` incarnation has a **monotonic epoch** (stored in Concord
meta, bumped on every (re)boot). Tasks capture the epoch at spawn and stamp it on
every result/chunk message, addressed to the **registered name** (not a captured
pid). The GenServer **drops any message whose epoch ≠ current**. This makes
`rest_for_one` safe: results from a dead incarnation are silently discarded; live
work is honored. (Fixes the existing `pending_tool_count` underflow on stale
results.)

### 4. Two-tier recovery

- **Soft (caught) error** → resume the node in-memory (fine-grained cursor).
- **Process crash** → supervisor restart → rehydrate the last turn from Concord →
  **bump epoch** → **wait for input**. No automatic re-run, no tool double-apply.

### 5. Storage: no PostgreSQL — three tiers

- **Files**
  - **TOML** — configs: agent, provider, MCP, LSP, plugin, heartbeat, toolset.
  - **Markdown / plain files** — workspace documents (they are files anyway).
- **Memory plugin (port)** — a `Memory` behaviour with two adapters:
  - **file adapter** (default/bootstrap): Markdown + frontmatter
    (`scope`/`kind`/`tags`/`importance`), indexed in ETS at boot;
  - **service adapter** (production): external hybrid-search memory service.
  - All memory calls must be **async + timeout-bounded** (same rule as LLM calls).
  - Replaces `semantic_memory`, `memory_events`, `memory_checkpoints` tables and
    the summarizer job (summarization moves into the memory port).
- **Concord** (embedded, `ra`-based; etcd/Khepri-like KV with MVCC, txns, leases,
  watches) — **node-local namespace** holds sessions.

### 6. Session shape in Concord (node-local)

```
/sessions/<id>/meta      -> {status, cursor, epoch, parent_id, model, turn_count}
/sessions/<id>/turns/<n> -> {parts for that turn}
```

Append per-turn (no rewrite of the whole transcript → no Raft write amplification).
Rehydrate = read `meta` + range-read `turns/*`.

### 7. Snapshot durability: fire-and-forget, atomic per-turn

The live truth is **in process memory** during a turn. At the turn boundary the
whole turn (user message + assistant message + parts) is written as **one
one-shot Concord transaction**, **fire-and-forget** (not awaited). A crash can lose
the *whole* last turn — never a half turn. On rehydrate an absent turn means the
session is idle at the prior turn and **waits for input**; the coding agent's
ground truth (files/git) covers any side effects that did occur.

### 8. Read path inverts (supersedes "persist before broadcast")

The `Session.GenServer` is the **live read authority**: a reader (LiveView mount,
REST/SSE, CLI) fetches a snapshot via `GenServer.call` (in-mem state incl. the
in-flight turn) and subscribes to PubSub for live deltas; if the process is down it
falls back to Concord's last durable turn. The guardrail flips from
**persist-then-broadcast** to **broadcast-live, snapshot-after**.

### 9. Sessions and agents are node-local

Keep the node-local `Registry` + `DynamicSupervisor`; no distributed singleton.
Spawned "Code Agents" are ordinary sessions; the parent→child link is node-local
session meta + a node-local index. **`Agent.AgentRegistry` (the ETS GenServer with
a full-table `match_object` scan on every status update) is deleted.**

### 10. Cluster is future-only

Concord's **cluster (Raft) namespace** is reserved for a future **shared
todo / plan / note** layer between agents. Its async leader election gates only
those shared-data features — **never session boot** (sessions are node-local and
synchronously available).

### 11. Scheduler: node-local cron replaces Oban

Oban (Postgres-backed) is removed. Heartbeats run on a **node-local scheduler**
(Quantum or GenServer timers) reading `heartbeats.toml`; the health endpoint reports
scheduler state. The memory summarizer moves to the memory port.

### 12. Boot tree

```
synapsis_store (was synapsis_data):
  ├── Session.Store        (node-local; synchronously ready; sessions live here)
  └── Concord.Cluster      (ra/Raft group; async; FUTURE shared todo/plan/note only)
synapsis_core:
  ├── Phoenix.PubSub
  ├── Config.Supervisor    (TOML loaders + file watchers)
  ├── Provider Task.Supervisor + Provider.Registry
  ├── Tool Task.Supervisor + Tool.Registry
  ├── Memory.Supervisor    (plugin port: file / service adapters)
  └── Heartbeat.Scheduler  (node-local cron)
synapsis_agent:
  ├── Registry  Session.Registry / Session.SupervisorRegistry
  └── Session.DynamicSupervisor (one_for_one)
       └── Session.Supervisor (rest_for_one): [Task.Supervisor, Session.GenServer]
synapsis_server / web: endpoint, channels
Removed: Synapsis.Repo, Oban, ecto_sql, postgrex
```

## Rationale

- One process per session removes the `:not_waiting` poll-retry race and the
  split-state coordination entirely; the per-session supervisor becomes meaningful
  (it supervises the GenServer + the I/O `Task.Supervisor`).
- `rest_for_one` + epoch fencing preserves long-running work across a GenServer
  restart without letting stale results corrupt the new incarnation.
- Files + Concord + a memory port match the domain: a coding agent on a git repo
  keeps configs and docs as files; only live session transcripts need a store.
- Process-as-truth + per-turn append fits a streaming runtime (no per-iteration DB
  reload, no fat lossy checkpoint) and keeps Concord writes small and infrequent.
- Node-local sessions avoid distributed-singleton complexity; the Raft path is paid
  for only by the future shared layer that actually needs replication.

## Alternatives Considered

- **Keep two processes, supervise the Runner** / **invert to Runner-as-session** —
  retain a process split that buys no fault isolation (the two are co-linked).
  Rejected in favor of collapse.
- **Full `workflow_state` checkpoint** / **no checkpoint, infer from messages** —
  rejected; the slim per-turn append avoids both divergence and fragile inference.
- **`one_for_all` per session** (kill tasks on GenServer crash) — simpler, no
  orphans, but kills long-running work. Rejected in favor of `rest_for_one` +
  fencing.
- **Sync snapshot barrier at turn end** — durable but rejected; fire-and-forget
  was chosen, accepting last-turn loss because files/git are the real ground truth.
- **Single key per session / app-level event log in Concord** — write
  amplification / double-logging over Raft. Rejected for append-per-turn.
- **Clustered session ownership (lease/Horde)** — unnecessary; sessions are
  node-local.
- **Minimal job queue on Concord** / **Oban on embedded SQLite** — rejected for a
  node-local cron; heartbeats are node-local and config is a file.
- **Keep PostgreSQL / embedded SQLite (CubDB, etc.)** — rejected; the goal is a
  self-contained BEAM release with files + an embedded store and a future cluster
  path.

## Consequences

- **No migration — direct cutover.** Existing PostgreSQL data is disposable; there
  is no phased dual-running and no data-migration step. The data layer is replaced
  wholesale: remove `Synapsis.Repo`, the 29 schemas, and the 47 migrations, and
  rewrite the Repo callers in 8 of 9 apps against the files / Concord / memory-port
  APIs in one cutover.
- `docs/architecture/02_DATA_LAYER.md` and `docs/guardrails/GUARDRAILS.md` must be
  updated: "database is the source of truth / persist before broadcast" no longer
  holds — the process is the live truth and snapshots follow.
- Full-text/tag memory search (Postgres `tsvector`) moves behind the memory port;
  the file adapter offers weaker ranking than the production service.
- Fire-and-forget snapshots accept losing the most recent completed turn on a hard
  crash; tolerable for a coding agent, surprising for a pure-chat one.
- Readers can no longer query a store for current state; they must call the live
  process (or accept Concord staleness during an in-flight turn).

## B0 Validation Findings (Concord spike — gate for Track B)

`Synapsis.Session.Store` was implemented against the **released Hex `concord 1.1.0`**
and validated by `apps/synapsis_data/test/synapsis/session/store_test.exs`
(8 tests, all green). Result: **Concord can back node-local sessions, with deltas.**

**Assumptions that hold (validated against real Concord):**

- **Whole-turn atomic commit** — achieved with `Concord.put_many/2`, which the Ra
  state machine applies as a **single log entry** (all-or-nothing by construction).
  `Session.Store.commit_turn/4` writes `turns/<n>` + `meta` in one such call.
- **Range read of `turns/*`** — `Concord.prefix_scan/2` does a server-side ordered
  scan, **but returns keys in descending order**, so `list_turns/1` sorts ascending.
  Turn keys are zero-padded so lexicographic = numeric order.
- **Single-key `get`/`put`** for `meta` round-trip.
- **Node-local** single-member Ra is the leader immediately; reads use `:leader`
  consistency with no real election gating once booted.
- **Idempotency** of the snapshot model is structural: turns are keyed by number,
  so re-committing a turn overwrites in place (no separate token needed).

**Deltas from the design — captured back here (and filed upstream):**

1. **The advertised v2 API is unreleased.** `main` shows `Concord.Txn` (etcd-style
   compare/CAS multi-key txn), `Concord.KV.list`, and a `clustering` switch, but
   Hex 1.1.0 ships none of them. ADR §7 ("one-shot Concord transaction") is realised
   with `put_many` instead; `Txn` would only be needed for *conditional* turn commits
   later. Tracked: **gsmlg-dev/concord#18**.
2. **Concord does not start the `:ra` default system** when used as an embedded
   dependency — `init_cluster` fails with `:system_not_started`. The host must start
   it; `Session.Store.ensure_started/1` does so (and bounces `:concord` once so its
   fire-and-forget `init_cluster` re-runs). Tracked: **gsmlg-dev/concord#17**.
3. **Concord defaults `prometheus_enabled: true`** (binds `:9568`, hard-fails host
   boot on conflict) and **ignores `clustering: false`** (libcluster spam). The
   umbrella config now sets `prometheus_enabled: false`, `http: [enabled: false]`,
   and `clustering: false`. Tracked: **gsmlg-dev/concord#17**.

**Implication for Track B:** B1/B2 can build on `Session.Store` now. The boot tree
(ADR §12) must own the embedded-store bring-up (start ra system → ensure Concord
ready) before the first session, rather than relying on Concord's app-start task.

## Open Items (not yet decided)

1. **Poison / unbootable session** — if `init` rehydrate crashes on corrupt Concord
   data the supervisor restart-loops; needs `max_restarts` + a quarantine path.
   (Addressed by B1 #12.)
2. **Crashed-tool error result** — a crashed tool Task must still emit an error
   `tool_result` for its `tool_use_id` (providers require every `tool_use` be
   answered), even with `async_nolink` + fencing. (Resolved in A2 #11.)
3. **Tool idempotency** on the in-process node soft-retry path. (Resolved in A2 #11.)
4. **Embedded-store bring-up location** — whether `ensure_started/1` becomes a
   supervised boot step (a `Concord.Cluster`/`Session.Store` child in the
   `synapsis_data` tree) or stays a lazy gate, pending upstream
   gsmlg-dev/concord#17. Until then the `ensure_started/1` workaround stands.
