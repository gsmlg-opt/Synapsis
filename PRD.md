# Synapsis Memory System — Product Requirements Document

## 1. Executive Summary

Synapsis is an AI coding agent with a persistent agent hierarchy: a Global Assistant, per-project Project Agents, and ephemeral Specialized Agents spawned for specific tasks. This PRD specifies the memory system — the mechanism by which agents remember what happened, recover from interruption, retrieve relevant prior work, and accumulate reusable knowledge.

The memory system is not a chat transcript store. It is a structured, multi-layer system that separates execution state from knowledge, supports deterministic resumption, and enables selective retrieval for prompt construction.

This document covers:

- Four-layer memory model (Working, Episodic, Checkpoint, Semantic)
- Memory scope model (Shared, Project, Agent, Session)
- Storage schema and Ecto integration in `synapsis_data`
- Domain logic placement in `synapsis_core`
- Memory tools (`session_summarize`, `memory_save`, `memory_search`, `memory_update`)
- Summarization pipeline
- Retrieval and context construction
- Integration with existing agent loop, tool executor, and UI
- Migration path for existing `memory_entries` table
- OTP supervision structure

---

## 2. Design Principles

### 2.1 Memory is not chat history

Raw message history is not a usable memory system. A real agent memory system needs: events for what happened, state snapshots for resumability, summaries for compression, retrieval for relevance, and promotion rules for long-term knowledge.

### 2.2 Separate execution state from knowledge

Two things must not be mixed:

**Execution state** — current task, current graph node, pending tools, retries, workflow status. For deterministic continuation.

**Knowledge state** — facts learned, project decisions, recurring patterns, prior outcomes. For future reasoning.

### 2.3 Append-first, compress later

At runtime, the system appends raw events, checkpoints state, and continues work. Asynchronous summarization converts raw data into compact memory later. This keeps the runtime simple and reliable.

### 2.4 Retrieval must be selective

The system never dumps all history into prompt context. Instead it ranks memory by relevance, prefers recent + important + successful items, provides compact summaries, and includes provenance.

### 2.5 Memory as observer, not participant

The memory system is a PubSub subscriber to existing domain events. The agent loop does not dual-write — it broadcasts tool effects via PubSub as it already does. `Synapsis.Memory.Writer` subscribes and persists. This keeps the agent loop unchanged.

---

## 3. Agent Hierarchy and Memory Ownership

Synapsis has a pre-existing agent hierarchy:

```
Global Assistant (one)
  └── Project Agent (one per project)
        └── Specialized Agents (spawned per task — review, docs, etc.)
              └── Sub-agents (via `task` tool — ephemeral)
```

Each agent level has a natural relationship with memory:

| Agent | Reads | Writes | Summarizes |
|---|---|---|---|
| Global Assistant | shared + all project summaries (read-only) | shared | cross-project meta-learnings |
| Project Agent | project + shared | project | session outcomes within project |
| Specialized Agent | own agent scope + project + shared | agent (own) | task-level operational heuristics |
| Sub-agent (via `task`) | inherits parent visibility | nothing persistent (ephemeral) | parent decides what to save |

---

## 4. Memory Scope Model

### 4.1 Scopes

```
:shared     — visible to all agents, any agent can contribute
:project    — visible to all agents within a project
:agent      — private to one agent identity
:session    — ephemeral, current run only
```

### 4.2 Scope semantics

**Shared** is a commons pool, not a hierarchy level. No single owner. Any agent — Global Assistant, Project Agent, Specialist — can write shared memories. A `contributed_by` field tracks provenance.

**Project** is bound to one project. The Project Agent is the primary contributor. Specialists can promote agent-scoped memories to project scope when the learning is broadly useful.

**Agent** is private to one agent identity. Contains operational heuristics, specialization notes, performance signals specific to that agent's role.

**Session** is ephemeral working memory and checkpoints for the current run. Not persisted as semantic memory — it is the raw material from which semantic memory is extracted.

### 4.3 Retrieval hierarchy

Retrieval walks **up** the scope chain. Never sideways.

```
Agent retrieval    = agent's own + project + shared
Project retrieval  = project + shared
Shared retrieval   = shared only
```

Agent A does not see Agent B's memories unless they are promoted to project or shared scope.

### 4.4 No "global" scope

There is no global scope. What other systems call "global" is the shared scope. The distinction: "global" implies ownership by one entity; "shared" implies a commons that any agent can read and contribute to.

---

## 5. Memory Model — Four Layers

### 5.1 Layer A: Working Memory

Short-lived memory for current execution. Held in-process, maps to the `context` accumulator in the agent loop.

Contains: active messages, recent tool outputs, temporary notes, current plan, local scratch state.

Properties: scope is session/run, storage is in-memory + optional short persistence, retention is short, retrieval is direct (no semantic search).

```elixir
%Synapsis.Memory.WorkingMemory{
  run_id: "run_123",
  session_id: "session_456",
  agent_id: "project_agent:synapsis",
  current_goal: "Design memory schema",
  recent_messages: [...],
  tool_results: [...],
  temporary_notes: [...],
  current_plan: [...]
}
```

### 5.2 Layer B: Episodic Memory

Event-oriented append-only record of what happened. The foundation for debugging, replay, and summarization.

Contains: task started, plan updated, tool invoked, tool failed, human approved, task completed, summary generated, memory promoted/updated/archived.

Properties: append-only, timestamped, replayable.

```elixir
%Synapsis.Memory.Event{
  id: "evt_001",
  scope: :project,
  scope_id: "synapsis",
  agent_id: "project_agent:synapsis",
  run_id: "run_123",
  type: :task_completed,
  importance: 0.7,
  payload: %{
    task: "Design memory system",
    result: "accepted",
    artifacts: ["memory_design_v1.md"]
  },
  causation_id: "evt_000",
  correlation_id: "corr_abc",
  inserted_at: ~U[2026-03-09 02:00:00Z]
}
```

`causation_id` links to the immediate preceding cause. `correlation_id` groups a whole workflow or request chain. Both are critical for replay and debugging.

### 5.3 Layer C: Checkpoint Memory

Serializable execution state required for recovery after crash, deploy, or restart.

Contains: workflow node position, pending edges, retry counters, task-local state, model/tool execution metadata.

Properties: binary or structured snapshot, versioned, resumable, replaceable by newer checkpoints.

```elixir
%Synapsis.Memory.Checkpoint{
  checkpoint_id: "ckpt_001",
  run_id: "run_123",
  session_id: "session_456",
  workflow: "project_task_graph",
  node: "quality_gate",
  state_version: 1,
  state_format: :json,
  state_json: %{current_step: "finalize_doc", retries: 0},
  inserted_at: ~U[2026-03-09 02:01:00Z]
}
```

Checkpoint writes happen after each completed tool call cycle — the natural boundary in the agent loop's `reduce_while`. On session reconnect or crash recovery, the system loads the latest checkpoint, rebuilds the `context` accumulator, and resumes the loop.

### 5.4 Layer D: Semantic Memory

Stable, summarized, reusable knowledge. The long-term memory that agents retrieve for future reasoning.

Contains: project facts, architectural decisions, successful patterns, failure lessons, user preferences, agent operating rules.

Properties: compressed, tagged, retrievable, scored by importance/confidence/recency.

```elixir
%Synapsis.Memory.SemanticRecord{
  id: "mem_001",
  scope: :project,
  scope_id: "synapsis",
  kind: :decision,
  title: "Memory architecture pattern",
  summary: "Synapsis uses event log + checkpoint + semantic summary, not transcript-only memory.",
  detail: %{},
  tags: ["memory", "architecture", "agent_core"],
  evidence_event_ids: ["evt_001", "evt_002"],
  importance: 0.9,
  confidence: 0.95,
  freshness: 1.0,
  source: :summarizer,
  contributed_by: "project_agent:synapsis",
  access_count: 0,
  last_accessed_at: nil,
  archived_at: nil,
  inserted_at: ~U[2026-03-09 02:10:00Z]
}
```

**Memory kinds:** `:fact`, `:decision`, `:lesson`, `:preference`, `:pattern`, `:warning`, `:summary`, `:policy`

**Source types:** `:human` (user-authored via UI), `:summarizer` (generated by summarization pipeline), `:agent` (saved directly by agent via `memory_save` tool)

**Size constraints.** Each memory record must be compact:

- `title`: max ~10 words. A label, not a description.
- `summary`: max 200 tokens (~1–3 sentences). The summarizer prompt enforces this. If a memory needs a paragraph to explain, it is not compressed enough.
- `detail`: structured metadata only (JSONB) — file paths, related memory IDs, session references. Not prose. Not a second, longer summary.

Memory is a **pointer with a summary**, not a **store with full content**. Large content stays in its source of truth: full conversation history in the `messages` table, raw event payloads in `memory_events`, tool outputs in `tool_calls`, documents in the filesystem. Semantic memory points to these via `evidence_event_ids`. If an agent needs the full context behind a memory, it follows the evidence trail — reads the original events or files via `file_read` or event queries.

The ContextBuilder's token budget math assumes compact entries. Oversized memories break the budget allocation and degrade retrieval quality.

**Promotion rules.** Not every event becomes semantic memory. Promote when: high importance, repeat occurrence, explicit human approval, task completed successfully, introduces project decision, identifies recurring failure pattern, user preference likely to matter again.

---

## 6. Storage Schema

PostgreSQL is the source of truth. ETS/Cachex for hot retrieval cache.

### 6.1 `memory_events`

```sql
CREATE TABLE memory_events (
  id          text PRIMARY KEY,
  scope       text NOT NULL,        -- 'shared' | 'project' | 'agent' | 'session'
  scope_id    text NOT NULL,
  agent_id    text NOT NULL,
  run_id      text,
  type        text NOT NULL,
  importance  double precision NOT NULL DEFAULT 0.5,
  payload     jsonb NOT NULL,
  causation_id  text,
  correlation_id text,
  inserted_at timestamptz NOT NULL
);
```

Indexes: `(scope, scope_id, inserted_at DESC)`, `(run_id, inserted_at ASC)`, `(agent_id, inserted_at DESC)`, `(type, inserted_at DESC)`

### 6.2 `memory_checkpoints`

```sql
CREATE TABLE memory_checkpoints (
  checkpoint_id text PRIMARY KEY,
  run_id        text NOT NULL,
  session_id    text NOT NULL,
  workflow      text NOT NULL,
  node          text NOT NULL,
  state_version integer NOT NULL,
  state_format  text NOT NULL,       -- 'json' | 'binary'
  state_bytea   bytea,
  state_json    jsonb,
  inserted_at   timestamptz NOT NULL
);
```

Indexes: `(run_id, inserted_at DESC)`, `(session_id, inserted_at DESC)`, `(workflow, inserted_at DESC)`

### 6.3 `semantic_memories`

```sql
CREATE TABLE semantic_memories (
  id              text PRIMARY KEY,
  scope           text NOT NULL,     -- 'shared' | 'project' | 'agent'
  scope_id        text NOT NULL,
  kind            text NOT NULL,
  title           text NOT NULL,
  summary         text NOT NULL,
  detail          jsonb NOT NULL DEFAULT '{}',
  tags            text[] NOT NULL DEFAULT '{}',
  evidence_event_ids text[] NOT NULL DEFAULT '{}',
  importance      double precision NOT NULL DEFAULT 0.5,
  confidence      double precision NOT NULL DEFAULT 0.5,
  freshness       double precision NOT NULL DEFAULT 1.0,
  source          text NOT NULL DEFAULT 'agent',  -- 'human' | 'summarizer' | 'agent'
  contributed_by  text,
  access_count    integer NOT NULL DEFAULT 0,
  last_accessed_at timestamptz,
  archived_at     timestamptz,
  inserted_at     timestamptz NOT NULL
);
```

Indexes: `(scope, scope_id, archived_at, inserted_at DESC)`, GIN on `tags`, full-text index on `title + summary`

### 6.4 Optional: `semantic_memory_embeddings`

```sql
CREATE TABLE semantic_memory_embeddings (
  memory_id text PRIMARY KEY REFERENCES semantic_memories(id),
  embedding vector(...)
);
```

Only if vector retrieval is enabled. Deferred to Phase 3.

### 6.5 Migration: `memory_entries` → `semantic_memories`

The existing `memory_entries` table (key/value, scoped global/project/session) is migrated into `semantic_memories`:

- `scope: :global` entries → `scope: :shared`
- `scope: :project` entries → `scope: :project`
- `scope: :session` entries → discarded or archived (session-scoped entries are ephemeral)
- `key` → `title`
- `content` → `summary`
- `metadata` → `detail`
- All migrated entries get `source: :human`, `confidence: 1.0`, `importance: 1.0`

The `memory_entries` table is dropped after migration. One table, one retrieval path, one UI.

---

## 7. Module Architecture

### 7.1 Umbrella placement

```
synapsis_data    — Ecto schemas, repos, queries
  SynapsisData.Schema.MemoryEvent
  SynapsisData.Schema.MemoryCheckpoint
  SynapsisData.Schema.SemanticMemory
  SynapsisData.Memory  (query functions)

synapsis_core    — Domain logic, behaviours, OTP processes
  Synapsis.Memory                    (public API facade)
  Synapsis.Memory.Event              (struct)
  Synapsis.Memory.Checkpoint         (struct)
  Synapsis.Memory.SemanticRecord     (struct)
  Synapsis.Memory.WorkingMemory      (struct)
  Synapsis.Memory.Writer             (PubSub subscriber, persists events)
  Synapsis.Memory.Retriever          (query + rank + filter)
  Synapsis.Memory.Summarizer         (LLM-based event → semantic extraction)
  Synapsis.Memory.ContextBuilder     (prompt packing)
  Synapsis.Memory.Cache              (ETS hot cache for retrieval)
```

### 7.2 Behaviour contract

```elixir
defmodule Synapsis.Memory do
  @callback append_event(map()) :: {:ok, map()} | {:error, term()}
  @callback write_checkpoint(map()) :: {:ok, map()} | {:error, term()}
  @callback latest_checkpoint(String.t()) :: {:ok, map() | nil} | {:error, term()}
  @callback store_semantic(map()) :: {:ok, map()} | {:error, term()}
  @callback update_semantic(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback retrieve(map()) :: {:ok, [map()]} | {:error, term()}
end
```

### 7.3 OTP supervision

```
SynapsisCore.Supervisor
├── Synapsis.Memory.Supervisor
│   ├── Synapsis.Memory.Writer           (PubSub subscriber GenServer)
│   ├── Synapsis.Memory.Cache            (ETS-backed GenServer)
│   └── Synapsis.Memory.SummarizerDispatcher  (Oban job enqueuer)
├── Synapsis.Agent.Supervisor
└── ...
```

Oban handles summarization jobs. `Synapsis.Memory.Writer` is a GenServer that subscribes to PubSub topics and persists events to Postgres. `Synapsis.Memory.Cache` holds hot retrieval metadata in ETS.

---

## 8. Memory Writer — Event Capture as Observer

The agent loop already broadcasts tool effects via PubSub (`tool_effects:{session_id}`). The Memory Writer subscribes and persists, with no changes to the agent loop.

```
Agent Loop
  → tool executes
  → PubSub.broadcast("tool_effects:{session_id}", {:tool_effect, ...})

Synapsis.Memory.Writer (subscriber)
  → receives {:tool_effect, type, payload}
  → maps to MemoryEvent struct
  → inserts into memory_events table
```

Additional PubSub topics the Writer subscribes to:

```
"session:{session_id}"     — message_complete, status changes
"tool_effects:{session_id}" — tool call/result events
"memory:{scope}:{scope_id}" — memory_promoted, memory_updated, memory_archived
```

This observer pattern means adding memory does not change the existing ToolExecutor, SessionChannel, or Agent Loop code.

---

## 9. Checkpoint Integration

Checkpoint writes happen at the natural boundary in the agent loop — after each completed tool call cycle.

```elixir
# In Synapsis.Agent.Loop, after processing tool results:
defp maybe_checkpoint(context, tool_results) do
  Synapsis.Memory.write_checkpoint(%{
    run_id: context.run_id,
    session_id: context.session_id,
    workflow: "agent_loop",
    node: "post_tool_cycle",
    state_version: 1,
    state_format: :json,
    state_json: serialize_context(context)
  })
end
```

On crash recovery:

1. Load latest checkpoint for the session
2. Rebuild `context` / `WorkingMemory` from checkpoint state
3. Resume the agent loop from the checkpoint node

---

## 10. Retrieval System

### 10.1 Retrieval inputs

The Retriever accepts:

- `query` — current user request or task goal
- `scope` — starting scope (defaults to calling agent's scope, walks up)
- `agent_id` — calling agent identity
- `project_id` — current project
- `kinds` — filter by memory kind
- `tags` — filter by tags
- `limit` — max results (default 5)

### 10.2 Retrieval stages

**Stage 1: Hard filtering.** Filter by scope visibility (agent sees own + project + shared), archive status (`archived_at IS NULL`), kind, project.

**Stage 2: Candidate generation.** Keyword search on title + summary, tag matching. Optional embedding search (Phase 3).

**Stage 3: Reranking.** Weighted score:

```
score = keyword_match   * 0.30
      + importance       * 0.25
      + recency          * 0.15
      + confidence       * 0.15
      + freshness        * 0.10
      + success_bias     * 0.05
```

When embedding search is enabled (Phase 3), add `semantic_similarity * 0.40` and rebalance.

**Stage 4: Packing.** Select top memories within token budget. Update `access_count` and `last_accessed_at` on returned records.

### 10.3 Cache

ETS cache keyed by `{scope, scope_id, query_hash}`. Invalidated via PubSub on `memory_promoted`, `memory_updated`, `memory_archived` events.

---

## 11. Context Builder

### 11.1 Injection mechanism

Memory is **not** part of the static system prompt. The system prompt is set once at session start (agent identity, role instructions, tool definitions, skill fragments) and does not change between turns.

Memory is injected as a **dynamic system message** rebuilt before each LLM request. Different turns in the same session retrieve different memories based on the current query.

The agent loop builds the LLM request in this order:

```
1. System prompt        — static: agent role + skills + tool defs
2. Memory context       — dynamic: ContextBuilder output, rebuilt per turn
3. Conversation history — messages so far in this session
4. Current user message — the latest input
```

```elixir
defp build_messages(context) do
  system_prompt = build_system_prompt(context)
  memory_context = Synapsis.Memory.ContextBuilder.build(context)
  history = context.messages

  messages = [%{role: :system, content: system_prompt}]

  messages = if memory_context != "" do
    messages ++ [%{role: :system, content: memory_context}]
  else
    messages
  end

  messages ++ history
end
```

If the Retriever returns no relevant results, the memory context message is omitted entirely. No empty block — the agent operates without memory context, same as a fresh session.

### 11.2 Per-turn flow

On every turn:

1. Extract query signal from the latest user message (keywords, intent)
2. Call `Synapsis.Memory.Retriever.retrieve/1` with query + agent scope
3. Format retrieved memories into structured sections
4. Enforce token budget — trim if total exceeds allocation
5. Return formatted string

Retrieval is cheap — keyword search + ETS cache hit in the common case. Cost is a few milliseconds per turn, not an LLM call.

### 11.3 Injected format

```xml
<memory>
<shared>
- Retry flaky network tools up to 2 times
- Prefer delegation over direct specialist execution
</shared>

<project context="synapsis">
- Architecture: event log + checkpoint + semantic summary
- User prefers concise markdown, skip basics
- Use Ecto.Multi for transactional writes
</project>

<agent context="review_agent">
- Prioritize correctness over style
- Check test coverage before approving
</agent>
</memory>
```

XML tags give the LLM clear section boundaries. Each entry is one line (~1–2 sentences). No verbose descriptions. No raw event data.

### 11.4 Token budget allocation

| Section | Budget | Notes |
|---|---|---|
| Shared | ~5% | Short policies, few entries |
| Project | ~50% | Richest knowledge, most relevant |
| Agent | ~20% | Operational heuristics |
| Session (working memory) | ~25% | Current context, fills remaining |

### 11.5 Relationship to `memory_search` tool

Two access patterns, both needed:

**Push (ContextBuilder)** — automatic, every turn. The agent does not ask for it. Handles the common case where relevant memories exist and should inform the response. The agent sees relevant context appear in its system messages — it is invisible to the agent as a tool call.

**Pull (`memory_search` tool)** — explicit, agent decides to search. Handles the case where the agent knows it needs specific prior knowledge that was not auto-retrieved. Returns results inline in the conversation as a tool result, not as a system message.

The ContextBuilder handles breadth (general relevance). The `memory_search` tool handles depth (specific lookup). Both return the same compact memory records — `memory_search` exists because there are **many** memories across scopes (potentially hundreds per project), not because any single memory is large.

---

## 12. Summarization Pipeline

### 12.1 Triggers

Summarization runs on:

- `message_complete` broadcast — if session has enough new events since last summary (threshold: configurable, default 10 events or 15 minutes)
- Task/session completion
- Explicit agent invocation via `session_summarize` tool
- Scheduled compaction window (Oban cron)

### 12.2 Pipeline

```
Trigger
  → Oban job enqueued (Synapsis.Memory.SummarizerDispatcher)
  → Worker loads event range for session/run
  → Compress: strip redundant tool outputs, collapse streaming chunks
  → LLM call via Synapsis.LLM.complete/2 (single-shot, no agent loop)
     - Uses cheaper/faster model (configurable per project)
     - System prompt instructs extraction of decisions, lessons, patterns, preferences
     - Agent role included so output is scoped correctly
  → Parse structured output into SemanticRecord candidates
  → Apply promotion rules (importance threshold, kind filter)
  → Insert into semantic_memories with appropriate scope
  → Broadcast :memory_promoted via PubSub
```

### 12.3 Nested LLM call pattern

`Synapsis.LLM.complete/2` is a simple request/response call through `synapsis_provider`, distinct from the `task` tool's full sub-agent loop. No tool use, no agent loop — just a single completion. This abstraction is reusable for future tools that need LLM reasoning without spawning a full agent (code review, commit message generation, etc.).

### 12.4 Scope inference for summaries

| Calling Agent | Default Candidate Scope | Promotion Path |
|---|---|---|
| Global Assistant | `:shared` | — |
| Project Agent | `:project` | → `:shared` if cross-project |
| Specialized Agent | `:agent` | → `:project` if broadly useful |
| Sub-agent | not persisted | parent decides via `memory_save` |

### 12.5 Summarizer extraction targets

The summarizer should extract:

- What goal was pursued
- What was decided
- What succeeded
- What failed
- What should be remembered
- What scope the memory belongs to
- How confident the system is

---

## 13. Forgetting, Archiving, and Compaction

### 13.1 Raw event retention

Hot storage: 30–90 days (configurable per project). Cold archive: compressed long-term storage. Delete only if retention policy allows.

### 13.2 Semantic memory decay

Freshness decays over time but importance persists. Architectural decisions: freshness falls slowly. Temporary issue summaries: freshness falls quickly. Decay function applied during retrieval scoring, not by modifying stored records.

### 13.3 Archive conditions

Archive semantic memory when: superseded by newer memory, repeatedly low relevance, low confidence and old, explicitly invalidated by user or agent. Never hard-delete critical decisions without policy support. Archived memories are soft-deleted via `archived_at` timestamp.

---

## 14. Memory Tools

Four tools added to the Synapsis tools system under a new `:memory` category.

### 14.1 `session_summarize`

| Field | Value |
|---|---|
| Module | `Synapsis.Tools.SessionSummarize` |
| Permission | `:read` |
| Side Effects | none |
| Category | `:memory` |
| Description | Compress current session context into candidate semantic memory records. Returns candidates for review — does not persist. |

Parameters:
- `scope` (optional, enum: `"full" | "recent" | "range"`, default: `"full"`) — what portion to summarize
- `message_range` (optional, `[start, end]`) — for `"range"` scope
- `focus` (optional, string) — hint to summarizer (e.g. "focus on architectural decisions")
- `kinds` (optional, array of strings) — which memory kinds to extract

Execution:
1. Load session messages + tool call history from `synapsis_data`
2. Compress representation (strip redundant outputs, collapse chunks)
3. Call `Synapsis.LLM.complete/2` with summarization prompt + compressed context + focus hint
4. Parse structured output into candidate SemanticRecord structs
5. Return candidates — agent or user reviews before saving

### 14.2 `memory_save`

| Field | Value |
|---|---|
| Module | `Synapsis.Tools.MemorySave` |
| Permission | `:write` |
| Side Effects | `[:memory_promoted]` |
| Category | `:memory` |
| Description | Persist one or more semantic memory records. Scope defaults to the calling agent's natural scope. |

Parameters:
- `memories` (required, array of objects) — each with:
  - `scope` (optional, enum: `"shared" | "project" | "agent"`, default: inferred from calling agent)
  - `kind` (required, enum: `"fact" | "decision" | "lesson" | "preference" | "pattern" | "warning"`)
  - `title` (required, string)
  - `summary` (required, string)
  - `tags` (optional, array of strings)
  - `importance` (optional, float, default: 0.7)

Scope inference: Global Assistant → `:shared`, Project Agent → `:project`, Specialist → `:agent`. Explicit `scope` parameter overrides for promotion (e.g. specialist saving to `:project`).

`contributed_by` is auto-populated from `context.agent_id`. `evidence_event_ids` are auto-populated from the session's event log. `source` is set to `:agent`.

### 14.3 `memory_search`

| Field | Value |
|---|---|
| Module | `Synapsis.Tools.MemorySearch` |
| Permission | `:read` |
| Side Effects | none |
| Category | `:memory` |
| Description | Search semantic memory. Retrieval walks up the scope hierarchy from the calling agent's scope. |

Parameters:
- `query` (required, string) — search query
- `scope` (optional, enum: `"shared" | "project" | "agent"`) — starting scope, defaults to agent's scope (walks up)
- `kinds` (optional, array of strings)
- `tags` (optional, array of strings)
- `limit` (optional, integer, default: 5)

Returns ranked results with id, kind, title, summary, score, scope, contributed_by.

This gives pull-based memory access in addition to the push-based context injection from ContextBuilder. ContextBuilder handles the common case; `memory_search` handles "I know I've seen this before, let me look it up."

### 14.4 `memory_update`

| Field | Value |
|---|---|
| Module | `Synapsis.Tools.MemoryUpdate` |
| Permission | `:write` |
| Side Effects | `[:memory_updated]` |
| Category | `:memory` |
| Description | Update, archive, or restore a semantic memory record. Used for correcting mistakes or managing memory lifecycle. |

Parameters:
- `action` (required, enum: `"update" | "archive" | "restore"`)
- `memory_id` (required, string)
- `changes` (optional, map) — for `"update"` action:
  - `title` (optional, string)
  - `summary` (optional, string)
  - `kind` (optional, string)
  - `tags` (optional, array of strings)
  - `importance` (optional, float)
  - `confidence` (optional, float)

Every update appends a `memory_updated` event to `memory_events` with the previous values, creating a full audit trail.

### 14.5 Tool inventory addition

| # | Tool | Name | Category | Permission | Side Effects | Enabled |
|---|---|---|---|---|---|---|
| 28 | SessionSummarize | `session_summarize` | memory | `:read` | — | yes |
| 29 | MemorySave | `memory_save` | memory | `:write` | `[:memory_promoted]` | yes |
| 30 | MemorySearch | `memory_search` | memory | `:read` | — | yes |
| 31 | MemoryUpdate | `memory_update` | memory | `:write` | `[:memory_updated]` | yes |

These are Phase 2 tools in the tools system PRD (alongside `todo_write`, `ask_user`, plan mode). They depend on the memory tables from Phase 1.

### 14.6 Tool context extension

The tool `context` struct gains memory-related fields:

```elixir
@type context :: %{
  # ... existing fields ...
  agent_id: String.t(),
  agent_scope: :shared | :project | :agent
}
```

The agent loop populates these from the session's bound agent. Memory tools use them for default scope inference.

---

## 15. Interaction Patterns

### 15.1 Agent-initiated save

Agent decides the session has valuable knowledge (heuristics: long session, successful complex task, user said "remember this"). Agent calls `session_summarize`, reviews candidates, calls `memory_save`.

### 15.2 User-initiated save

User says "save this session to memory." Agent calls `session_summarize`, optionally uses `ask_user` to let user pick candidates, calls `memory_save`.

### 15.3 User explicit memory

User says "remember: always use tabs in this project." Agent skips `session_summarize` entirely. Calls `memory_save` directly with a single preference record. No LLM summarization needed.

### 15.4 User correction

User says "that's wrong, we decided to use GenStage not Broadway."

1. Agent calls `memory_search` to find the record
2. Agent shows current memory to user (inline in chat)
3. Agent calls `memory_update` with corrections
4. Side effect `[:memory_updated]` broadcasts via PubSub → MemoryLive updates if open

### 15.5 Direct UI edit

User sees wrong memory in MemoryLive, clicks edit, fixes summary, saves. Standard LiveView `phx-submit` → `Synapsis.Memory.update_semantic/2`. No agent involved.

---

## 16. Side Effect System

Two new side effects:

- `[:memory_promoted]` — new semantic memory created
- `[:memory_updated]` — existing semantic memory modified or archived

PubSub topic: `memory:{scope}:{scope_id}`

Subscribers:

| Subscriber | On `memory_promoted` | On `memory_updated` |
|---|---|---|
| MemoryLive | Real-time list refresh | Real-time list refresh |
| Memory.Cache | Cache invalidation | Cache invalidation |
| ContextBuilder | (no action, fetches fresh) | Bust cached context for affected scope |

---

## 17. Event Types

Complete event type inventory:

```
run_created
task_received
plan_created
plan_updated
message_added
tool_called
tool_succeeded
tool_failed
handoff_requested
handoff_completed
human_feedback_received
checkpoint_written
task_completed
task_failed
run_paused
run_resumed
summary_created
memory_promoted
memory_updated
memory_archived
```

---

## 18. UI Integration

### 18.1 MemoryLive evolution

The existing `MemoryLive.Index` (flat key/value CRUD for `memory_entries`) evolves to three tabs:

**Tab: Knowledge** (`semantic_memories`) — primary view. Filterable by scope, kind, tags, agent. Each card shows: title, summary, kind badge, importance/confidence scores, source badge (`:human | :summarizer | :agent`), `contributed_by` label, timestamps. Inline edit. Archive button. Create button for human-authored memories. Agent filter dropdown alongside scope/kind filters.

**Tab: Events** (`memory_events`) — read-only audit log. Filterable by run/session, type, agent. Paginated, newest first. Expandable payload. Inspection only.

**Tab: Checkpoints** (`memory_checkpoints`) — read-only. Grouped by run/session. Shows workflow, node, state_version, timestamp. Expandable state view (JSON via CodeEditor hook, read-only).

### 18.2 MemoryLive.Show (new)

Detail view for a single semantic memory:

- Editable fields: title, summary, kind, tags, importance, confidence
- **History section** — query `memory_events` where `type: :memory_updated` and `payload.memory_id` matches. Shows change log with diffs of previous values.
- **Evidence section** — links to source events via `evidence_event_ids`
- **Source badge** — `:human`, `:summarizer`, `:agent`
- **Contributed by** — agent identity that created/last updated

### 18.3 Scope visibility in UI

When viewing from an agent context, the knowledge tab shows:

- Agent's own memories (primary, full edit)
- Inherited project memories (dimmed, read-only in agent context)
- Inherited shared memories (dimmed, read-only)

When viewing shared memories, `contributed_by` badge shows which agent added it. Any user can edit shared memories from the UI.

### 18.4 Routes

```elixir
live "/settings/memory", MemoryLive.Index, :index          # replaces existing
live "/settings/memory/:id", MemoryLive.Show, :show         # new detail view
live "/settings/memory/new", MemoryLive.Index, :new          # create human-authored
```

### 18.5 Channel events

Memory activity flows through existing PubSub → SessionChannel path:

```
← broadcast("memory_update", %{type, memory_id, ...})
```

The React chat UI does not render memory events directly — they are not chat messages. Memory updates are surfaced in MemoryLive only.

---

## 19. Consistency Model

### 19.1 Event writes

Event append is strongly reliable relative to task progress. If a task step commits, the event must exist. If a checkpoint advances, related events must exist. The Writer is a synchronous subscriber for critical events.

### 19.2 Summaries

Summaries are eventually consistent. A task completes; the summary appears seconds later via Oban. Acceptable.

### 19.3 Retrieval staleness

Retriever tolerates brief lag. Critical execution state uses checkpoints, not summaries. ETS cache TTL is short (30 seconds default).

---

## 20. Memory Access Policy

### 20.1 Visibility rules

Default to minimum necessary memory visibility:

- Global Assistant: reads shared + project summaries (not raw project events)
- Project Agent: reads project + shared
- Specialized Agent: reads own agent scope + project + shared
- Sub-agents: inherit parent's read visibility, no write
- Raw event access: restricted to orchestration/debug agents

### 20.2 Agent memory policy

The agent's configuration includes a `memory_policy` map:

```json
{
  "read_scopes": ["agent", "project", "shared"],
  "write_scopes": ["agent"],
  "promote_to_project": true,
  "promote_to_shared": false,
  "max_memories": 500,
  "auto_summarize": true
}
```

Most agents read up the full hierarchy but write only to their own scope. `promote_to_project: true` allows `memory_save` with `scope: "project"`. Restrictive agents might only read project scope, never shared.

---

## 21. Failure Modes and Recovery

### 21.1 Crash before checkpoint

If event exists but checkpoint does not, replay from last checkpoint and re-derive step from events.

### 21.2 Checkpoint exists without semantic summary

Fine. Summary is asynchronous. No data loss.

### 21.3 Summary conflicts with newer decision

Mark older semantic memory as superseded via `memory_update(action: "archive")`. The audit trail in `memory_events` preserves history.

### 21.4 Retrieval returns stale memory

Freshness + evidence + recency scoring handles this. Prefer memories tied to approved outcomes.

### 21.5 Duplicate summarization

Oban's unique job constraint prevents duplicate runs. If two summaries produce conflicting records, the more recent one wins (higher freshness score).

---

## 22. Observability

### 22.1 Metrics

- Events written per run
- Checkpoint size and write latency
- Summarization queue lag (Oban job wait time)
- Semantic memory count per scope
- Retrieval latency and hit rate
- Stale memory usage rate (memories accessed that were later archived)

### 22.2 Logging context

All memory operations log with: `run_id`, `agent_id`, `correlation_id`, `scope`, `scope_id`.

---

## 23. Security and Privacy

Even in a single-user system, memory should support:

- Scope isolation (agents cannot read across scope boundaries without policy)
- Explicit retention policy per project
- Redaction of sensitive tool outputs (API keys, secrets) before summarization
- Metadata-only summaries where needed
- Human invalidation of incorrect memories via UI or `memory_update` tool

Never blindly promote secrets from tool outputs into semantic memory. The summarizer prompt explicitly instructs redaction of credentials, tokens, and secrets.

---

## 24. Implementation Phases

### Phase 1: Operational Memory

Build:
- `memory_events` table + Ecto schema
- `memory_checkpoints` table + Ecto schema
- `Synapsis.Memory.Writer` as PubSub subscriber
- Checkpoint write in agent loop after tool cycles
- Migrate `memory_entries` into `semantic_memories` with `source` field
- Keyword retrieval + `Synapsis.Memory.ContextBuilder`
- Update `MemoryLive` UI to tabbed layout (knowledge + events + checkpoints)

Deliverable: agents can be resumed after crash, events are captured, existing memories are preserved.

### Phase 2: Semantic Memory + Tools

Build:
- `session_summarize` tool (nested LLM call via `Synapsis.LLM.complete/2`)
- `memory_save` tool
- `memory_search` tool
- `memory_update` tool
- Summarization pipeline via Oban
- `MemoryLive.Show` detail view with edit history
- Scope inference from agent identity

Deliverable: agents can save, search, and correct memories. Users can review and edit via UI or conversation.

### Phase 3: Smart Retrieval

Build:
- Hybrid ranking with tuned weights
- Optional embedding generation and vector search
- Usage feedback loop (track which retrieved memories were useful)
- Freshness decay function
- Memory archival automation

Deliverable: retrieval quality improves over time, stale memories fade.

### Phase 4: Multi-Agent Memory Policy

Build:
- Per-agent memory visibility policies
- Delegation memory (cross-agent task handoff records)
- Cross-project pattern extraction (shared scope mining)
- Agent-scoped memory UI in AgentLive.Show

Deliverable: full multi-agent memory isolation and sharing.

---

## 25. Resolved Decisions

1. **Four layers, not transcript.** Event log + checkpoint + semantic memory + retrieval. Not infinite transcript + vector search.

2. **Shared scope, not global.** Shared is a commons any agent can contribute to. No single owner. `contributed_by` tracks provenance.

3. **Memory as observer.** Writer subscribes to PubSub. No changes to agent loop for event capture. Checkpoints are the one integration point.

4. **Merge `memory_entries` into `semantic_memories`.** One table, one retrieval path, one UI. Human-authored entries get `source: :human`, `confidence: 1.0`.

5. **Scope inference from agent identity.** Memory tools default to the calling agent's natural scope. Explicit scope parameter only for promotion.

6. **Nested LLM call for summarization.** `Synapsis.LLM.complete/2` — single-shot completion, not a full agent loop. Reusable abstraction.

7. **Four memory tools.** `session_summarize` (read, returns candidates), `memory_save` (write, persists), `memory_search` (read, retrieves), `memory_update` (write, corrects). Separation of summarize vs save preserves human-in-the-loop.

8. **Provenance on all mutations.** Every update to semantic memory appends a `memory_updated` event with previous values. Full audit trail.

9. **Keyword-first retrieval.** Start with keyword + tags + recency + importance. Add embeddings in Phase 3 only if needed.

10. **Oban for summarization.** Background jobs with unique constraints prevent duplicates. Configurable trigger thresholds.

11. **ETS cache with PubSub invalidation.** Hot retrieval cache, busted on `memory_promoted` / `memory_updated` / `memory_archived` events.

12. **ContextBuilder token budgets.** Shared ~5%, Project ~50%, Agent ~20%, Session ~25%. Project knowledge gets the most space.

13. **User correction via tool and UI.** Both paths: conversational (`memory_update` tool) and direct (MemoryLive edit form). Both produce audit trail events.

14. **Memory injected as dynamic system message, not system prompt.** System prompt is static (agent role, skills, tools). Memory context is rebuilt per turn by the ContextBuilder and injected as a separate system message between the system prompt and conversation history. Omitted entirely when no relevant memories are found.

15. **Compact memory records only.** `title` max ~10 words, `summary` max 200 tokens. `detail` is structured metadata (JSONB), not prose. Memory is a pointer with a summary — large content stays in source-of-truth tables (messages, events, tool_calls, filesystem). Agents follow `evidence_event_ids` to get full context.

16. **Two retrieval paths: push and pull.** ContextBuilder auto-injects ~5–10 memories per turn (push, invisible to agent). `memory_search` tool lets the agent explicitly query when auto-retrieval misses something (pull, visible as tool result). Both return the same compact records.

---

## 26. Data Model Summary

```
memory_events          — append-only event log (Layer B)
memory_checkpoints     — resumable execution state (Layer C)
semantic_memories      — stable reusable knowledge (Layer D)
  ↑ migrated from memory_entries (dropped after migration)
```

Working memory (Layer A) is in-process only — the `context` accumulator in the agent loop, formalized as `%Synapsis.Memory.WorkingMemory{}`.

---

## 27. Tool Inventory Update

Updated tools system total: **31 tools** (25 enabled by default, 3 disabled/future, 3 swarm).

| # | Tool | Name | Category | Permission | Side Effects | Enabled |
|---|---|---|---|---|---|---|
| 1–27 | (existing) | ... | ... | ... | ... | ... |
| 28 | SessionSummarize | `session_summarize` | memory | `:read` | — | yes |
| 29 | MemorySave | `memory_save` | memory | `:write` | `[:memory_promoted]` | yes |
| 30 | MemorySearch | `memory_search` | memory | `:read` | — | yes |
| 31 | MemoryUpdate | `memory_update` | memory | `:write` | `[:memory_updated]` | yes |
