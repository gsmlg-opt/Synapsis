# Assistant Identity & Context Assembly — Product Requirements Document

## 1. Overview

**Scope:** Cross-cutting enhancement to `synapsis_agent` and `synapsis_workspace`
**Primary modules:** `SynapsisAgent.ContextBuilder`, `SynapsisAgent.Compaction`, `SynapsisAgent.Nodes.*`
**Location:** `apps/synapsis_agent` + `apps/synapsis_workspace` within the Synapsis umbrella
**Target:** Elixir >= 1.18 / OTP 28+

This PRD defines the workspace-driven identity system, context assembly pipeline, session compaction, and proactive execution for Synapsis agents. It replaces hard-coded agent personalities with user-editable workspace files and introduces OpenClaw-inspired patterns adapted to Synapsis's BEAM-native architecture.

**The problem it solves:** Agents today have no configurable personality, no automatic context loading, no session compaction, and no proactive execution. The user cannot shape how the assistant behaves without code changes. Long sessions silently degrade as they exceed context windows. The assistant never initiates — it only responds.

**One-line definition:** The assistant's brain is files, not code.

### What This PRD Covers

- AI-1: Workspace-driven identity files (SOUL, IDENTITY, BOOTSTRAP)
- AI-2: Context assembly pipeline (system prompt construction)
- AI-3: Skill injection at prompt time
- AI-4: Memory as automatic context
- AI-5: Session compaction
- AI-6: Proactive execution (heartbeats)
- AI-7: Persistent tool approval memory

### What This PRD Does NOT Cover

- Multi-channel gateway (Telegram, Discord, etc.) — future work
- Vector/semantic search for memory — future enhancement to AI-4
- Agent-to-agent delegation semantics — covered by agent-system-prd §AS-7
- Workspace data model — covered by workspace-system-prd

### Dependency Position

This work touches two existing apps but adds no new apps:

```
synapsis_workspace (owns identity file paths, provides read API)
    ↑
synapsis_agent (ContextBuilder reads workspace, new nodes added)
```

No new cross-app dependencies are introduced. `ContextBuilder` already depends on `synapsis_workspace` (via `synapsis_core`). This PRD formalizes and extends that relationship.

---

## 2. Motivation

### 2.1 The Personality Problem

OpenClaw's most powerful insight is `SOUL.md`: a single markdown file that transforms a generic LLM into a specific assistant with consistent behavior. The user writes it, the system injects it, and the agent becomes *someone*.

Synapsis agents today have personalities defined in code — module-level constants or hard-coded strings in graph node implementations. To change how the Global Agent talks, you edit Elixir source. This means:

- Users cannot customize agent behavior without developer intervention
- Different projects cannot have different assistant personalities
- A/B testing personality variants requires code changes and deploys
- The agent's identity is invisible — buried in source, not browsable

### 2.2 The Context Assembly Problem

When an LLM receives a request, the system prompt determines everything: personality, capabilities, constraints, domain knowledge. Today, `ContextBuilder` assembles context from project metadata (file trees, git logs, diagnostics). But it misses:

- **Who the agent is** — no personality injection
- **Who the user is** — no persistent user profile in context
- **What skills are available** — skills exist but aren't advertised to the LLM at prompt time
- **What the agent remembers** — memory entries exist but aren't automatically loaded

The result: agents are amnesiac, personality-free, and unaware of their own capabilities.

### 2.3 The Context Window Problem

Sessions grow unbounded. A coding session with extensive tool use can hit 100K+ tokens in a single sitting. When the session exceeds the model's context window, the oldest messages are silently truncated (at best) or the request fails (at worst). There is no graceful degradation.

### 2.4 The Passivity Problem

The assistant only responds — it never initiates. No morning briefings, no stale PR alerts, no "you left a TODO three days ago" nudges. OpenClaw's heartbeat/cron system makes the agent proactive. Synapsis already has Oban for background jobs — the infrastructure exists, but no agent uses it.

---

## 3. Identity Files

### AI-1: Workspace Identity Convention

The assistant's identity is defined by markdown files at conventional workspace paths. These files are workspace documents (stored in `workspace_documents` table via synapsis_workspace).

**AI-1.1** — Identity file schema:

| File | Path | Scope | Purpose |
|---|---|---|---|
| Soul | `/global/soul.md` | Global | Agent personality, voice, behavioral rules |
| Identity | `/global/identity.md` | Global | Who the user is — name, preferences, working style |
| Bootstrap | `/global/bootstrap.md` | Global | Environment context — OS, tools, conventions |
| Project Soul | `/projects/<id>/soul.md` | Project | Project-specific personality override |
| Project Context | `/projects/<id>/context.md` | Project | Project-specific knowledge, architecture notes |

**AI-1.2** — Precedence rules (see RD-1):
- Project soul **extends** global soul — global soul is the base, project soul is appended as addendum
- Project context supplements (does not replace) global identity/bootstrap
- If a file does not exist, its section is omitted from the system prompt — never error
- To fully override global personality, a project soul explicitly opens with override instructions

**AI-1.3** — Default templates. On first run (or workspace initialization), Synapsis seeds default identity files:

```markdown
<!-- /global/soul.md (default) -->
# Soul

You are a coding assistant built into Synapsis.

## Personality
- Be direct and concise
- Skip pleasantries — help immediately
- Have opinions about code quality and architecture
- When uncertain, say so — don't guess

## Boundaries
- Ask before making destructive changes (deleting files, force-pushing)
- Explain trade-offs when suggesting approaches
- Respect the user's architectural decisions even when you'd choose differently

## Coding Style
- Prefer functional patterns
- Write tests for non-trivial changes
- Commit messages should explain *why*, not just *what*
```

```markdown
<!-- /global/identity.md (default) -->
# User

(Edit this file to tell the assistant about yourself.)

## Preferences
- Language: (your primary programming language)
- Editor: (your editor/IDE)
- OS: (your operating system)
```

```markdown
<!-- /global/bootstrap.md (default) -->
# Environment

(Edit this file to describe your development environment.)

## Tools
- Version control: git
- Package manager: (your package manager)

## Conventions
- (Add project-wide conventions here)
```

**AI-1.4** — Identity files are readable and writable by agents via existing workspace tools (`workspace_read`, `workspace_write`). The agent can update its own soul or the user's identity file when explicitly asked.

**AI-1.5** — Identity files are editable by users through the workspace web UI (synapsis_web workspace explorer). Changes take effect on the next agent turn — no restart required.

**AI-1.6** — Type spec for identity config:

```elixir
@type identity_config :: %{
  soul: String.t() | nil,
  identity: String.t() | nil,
  bootstrap: String.t() | nil,
  project_soul: String.t() | nil,
  project_context: String.t() | nil
}
```

---

## 4. Context Assembly Pipeline

### AI-2: System Prompt Construction

The system prompt is assembled in layers. Each layer is optional. The pipeline produces a single string injected as the `system` parameter in the LLM request.

**AI-2.1** — Assembly order (top to bottom):

```
┌─────────────────────────────────────────┐
│ 1. Base Prompt (hardcoded)              │  Safety framing, tool-use instructions,
│                                         │  response format constraints
├─────────────────────────────────────────┤
│ 2. Soul (workspace file)               │  Personality, voice, behavioral rules
├─────────────────────────────────────────┤
│ 3. Identity (workspace file)           │  User profile, preferences
├─────────────────────────────────────────┤
│ 4. Skills Manifest (computed)          │  Compact list of available skills
├─────────────────────────────────────────┤
│ 5. Memory Context (auto-retrieved)     │  Top-N relevant memory entries
├─────────────────────────────────────────┤
│ 6. Bootstrap (workspace file)          │  Environment, conventions
├─────────────────────────────────────────┤
│ 7. Project Context (conditional)       │  File tree, git log, diagnostics,
│                                         │  project soul, project context file
└─────────────────────────────────────────┘
```

**AI-2.2** — `ContextBuilder.build_system_prompt/2` signature:

```elixir
@spec build_system_prompt(agent_type :: atom(), opts :: keyword()) :: String.t()

# opts:
#   :project_id   — optional, for project-scoped agents
#   :session_id   — for memory relevance scoring
#   :user_message — latest user message, used for memory search query
```

**AI-2.3** — Each layer is assembled by a dedicated function:

```elixir
@spec load_base_prompt(agent_type :: atom()) :: String.t()
@spec load_soul(project_id :: String.t() | nil) :: String.t() | nil
@spec load_identity() :: String.t() | nil
@spec build_skills_manifest(project_id :: String.t() | nil) :: String.t()
@spec load_memory_context(query :: String.t(), opts :: keyword()) :: String.t() | nil
@spec load_bootstrap() :: String.t() | nil
@spec load_project_context(project_id :: String.t()) :: String.t() | nil
```

**AI-2.4** — Layer concatenation uses section headers for LLM clarity:

```
<soul>
{soul content}
</soul>

<user_identity>
{identity content}
</user_identity>

<available_skills>
{skills manifest}
</available_skills>

<memory>
{relevant memory entries}
</memory>

<environment>
{bootstrap content}
</environment>

<project>
{project context}
</project>
```

XML tags are used (not markdown headers) because they're unambiguous to the LLM and won't collide with user-authored markdown content inside the files.

**AI-2.5** — Token budget. The system prompt has a configurable maximum token budget (default: 30% of model context window). Each layer has a priority for truncation:

| Priority | Layer | Truncation Strategy |
|---|---|---|
| 1 (highest) | Base Prompt | Never truncated |
| 2 | Soul | Never truncated (user controls length) |
| 3 | Identity | Never truncated (user controls length) |
| 4 | Skills Manifest | Truncate lowest-relevance skills |
| 5 | Project Context | Truncate file tree depth, limit git log entries |
| 6 | Memory Context | Reduce number of entries |
| 7 (lowest) | Bootstrap | Truncate from end |

**AI-2.6** — Caching. `ContextBuilder` caches assembled identity content (soul + identity + bootstrap) in ETS with a TTL of 60 seconds. Cache is invalidated on workspace PubSub events for identity file paths. Skills manifest and project context use existing `ContextBuilder` caching.

---

## 5. Skill Injection

### AI-3: Skills Manifest at Prompt Time

Skills are currently registered in `synapsis_tool` but not advertised to the LLM in the system prompt. The agent doesn't know what it can do until it tries.

**AI-3.1** — At prompt assembly time, `ContextBuilder` queries the tool registry for all enabled skills scoped to the current agent context (global + project).

**AI-3.2** — Skills manifest format (one line per skill, compact):

```
Available skills:
- file_read: Read file contents from the project directory
- file_write: Create or overwrite a file
- shell_exec: Execute a shell command (requires approval for unsafe commands)
- git_status: Show current git status
- workspace_read: Read a workspace document by path
- workspace_write: Write content to a workspace document
- memory_save: Store information in long-term memory
- memory_search: Search long-term memory
...
```

**AI-3.3** — Skills from MCP/LSP plugins are included with a provider prefix:

```
- [mcp:chrome-devtools] evaluate_expression: Evaluate JS in browser context
- [lsp:elixir-ls] get_diagnostics: Get compilation errors and warnings
```

**AI-3.4** — Disabled skills are excluded. Skills that require configuration not yet provided are listed with a `(not configured)` suffix so the agent can tell the user.

**AI-3.5** — Skill descriptions are sourced from the tool's `:description` field in the registry. Max 80 characters per description, truncated with `…` if longer.

---

## 6. Memory as Context

### AI-4: Automatic Memory Loading

Memory entries exist in the database but are only accessible through explicit tool calls. The agent must *decide* to search memory — it doesn't happen automatically.

**AI-4.1** — On every agent turn (before LLM call), `ContextBuilder` performs a memory search using the latest user message as the query.

**AI-4.2** — Search method (Phase 1 — keyword):

```elixir
@spec search_relevant_memories(query :: String.t(), opts :: keyword()) ::
  [SynapsisData.MemoryEntry.t()]

# opts:
#   :model_context_window — used to compute token budget (default: 128_000)
#   :scope     — :global | {:project, project_id}
#   :min_score — minimum relevance score threshold
```

Implementation: PostgreSQL `ts_vector` full-text search over `memory_entries.content` with `ts_rank` scoring. This leverages existing infrastructure — no new dependencies.

Token budget: 5% of model context window, hard cap of 10 entries (see RD-4). Entries are selected by descending relevance, then trimmed to fit the token budget.

**AI-4.3** — Memory entries are formatted as context:

```
<memory>
## Relevant memories

### user-preferences (saved 2026-03-10)
User prefers functional patterns. Primary language: Elixir.
Uses NixOS with devenv for development environments.

### project-architecture (saved 2026-03-12)
Synapsis uses an umbrella structure with strict dependency direction.
Database is source of truth — no GenServers for domain entities.
</memory>
```

**AI-4.4** — Memory search is cached per session turn. If the same message triggers multiple context builds (shouldn't happen, but defensive), the search runs once.

**AI-4.5** — Future enhancement (not in this PRD): replace keyword search with `pgvector` cosine similarity over embeddings. The API (`search_relevant_memories/2`) is designed to be backend-agnostic — swap implementation without changing callers.

---

## 7. Session Compaction

### AI-5: Context Window Management

Sessions grow without bound. Compaction summarizes old messages to stay within the model's context window.

**AI-5.1** — New graph node: `SynapsisAgent.Nodes.CompactContext`

```elixir
defmodule SynapsisAgent.Nodes.CompactContext do
  @behaviour SynapsisAgent.Node

  @doc """
  Checks session token count. If over threshold, summarizes older messages
  and replaces them with a compact summary. Returns updated messages list.
  """
  @callback run(state :: map(), ctx :: map()) ::
    {:ok, %{messages: [map()]}}
end
```

**AI-5.2** — Compaction triggers when estimated token count of `state.messages` exceeds the compaction threshold:

```elixir
@type compaction_config :: %{
  threshold_ratio: float(),     # fraction of model context window (default: 0.75)
  summary_model: String.t(),    # model to use for summarization (can be cheaper)
  preserve_recent: pos_integer(), # minimum recent messages to keep (default: 10)
  max_summary_tokens: pos_integer() # max tokens for the summary (default: 2000)
}
```

**AI-5.3** — Compaction algorithm:

1. Estimate token count of `state.messages` (heuristic: `byte_size(json) / 4`)
2. If under threshold → return `{:ok, %{}}` (no-op patch)
3. Split messages at midpoint, preserving at least `preserve_recent` recent messages
4. Send older messages to summarization LLM with prompt:
   ```
   Summarize this conversation concisely. Preserve:
   - Key facts about the user (name, preferences, decisions)
   - Important technical decisions made
   - Open tasks, TODOs, or unresolved questions
   - File paths and code references that were discussed
   ```
5. Replace older messages with a single summary message:
   ```elixir
   %{role: "user", content: "[Conversation summary]\n#{summary}"}
   ```
6. Persist compacted messages to session
7. Return `{:ok, %{messages: compacted_messages}}`

**AI-5.4** — Compaction is a node in the conversational loop graph, positioned after `receive_message` and before `build_prompt`:

```
receive_message → compact_context → build_prompt → llm_call → ...
```

**AI-5.5** — Compaction uses a separate LLM call via `synapsis_provider`. The summarization model is configurable — can be a cheaper/faster model than the main agent model.

**AI-5.6** — Compaction events (see RD-2 — silent with notification):
- PubSub broadcast: `{:session_compacted, session_id, %{removed: n, summary_tokens: m}}`
- PubSub broadcast: `{:system_message, %{type: :compaction, text: "...", metadata: %{...}}}` — rendered as inline system message in chat UI
- Telemetry: `[:synapsis_agent, :compaction, :complete]` with measurements

**AI-5.7** — Compaction is idempotent. If messages are already under threshold, it's a no-op. If compaction was recently performed (within last N turns), skip to avoid cascading summarizations.

---

## 8. Proactive Execution

### AI-6: Heartbeat System

Heartbeats are scheduled agent invocations — the assistant wakes up, runs a task, and (optionally) notifies the user.

**AI-6.1** — Heartbeats are Oban jobs in a dedicated `:heartbeat` queue:

```elixir
defmodule SynapsisAgent.Heartbeat.Worker do
  use Oban.Worker,
    queue: :heartbeat,
    max_attempts: 3,
    priority: 3  # lower priority than interactive work

  @impl true
  def perform(%Oban.Job{args: %{"heartbeat_id" => id}}) do
    # Load heartbeat config
    # Create isolated session
    # Run agent turn with heartbeat prompt
    # Optionally notify user via PubSub
  end
end
```

**AI-6.2** — Heartbeat configuration stored in `heartbeat_configs` table:

```elixir
# In synapsis_data
schema "heartbeat_configs" do
  field :name, :string                    # "morning-briefing"
  field :schedule, :string                # Oban cron expression: "30 7 * * 1-5"
  field :agent_type, Ecto.Enum, values: [:global, :project]
  field :project_id, :binary_id           # nil for global heartbeats
  field :prompt, :string                  # "Good morning! Summarize overnight activity."
  field :enabled, :boolean, default: true
  field :notify_user, :boolean, default: true
  field :session_isolation, Ecto.Enum,
    values: [:isolated, :main],           # :isolated = own session, :main = inject into main
    default: :isolated
  field :keep_history, :boolean, default: false  # write timestamped entries at :draft lifecycle

  timestamps()
end
```

**AI-6.3** — Heartbeat scheduling via Oban Cron plugin:

```elixir
# In SynapsisAgent.Application
config :synapsis_agent, Oban,
  queues: [heartbeat: 2],
  plugins: [
    {Oban.Plugins.Cron, crontab: []}  # Dynamic — loaded from DB
  ]
```

Heartbeat cron entries are synced from `heartbeat_configs` to Oban's cron plugin on startup and on config change (via PubSub).

**AI-6.4** — Each heartbeat runs in an isolated session with key pattern `heartbeat:<heartbeat_id>:<timestamp>`. This prevents heartbeat history from polluting the user's main conversation.

**AI-6.5** — Heartbeat results are optionally written to workspace:

```
/global/heartbeats/<name>/latest.md     ← most recent result
/global/heartbeats/<name>/history/      ← archived results (configurable retention)
```

**AI-6.6** — User notification: if `notify_user: true`, heartbeat completion broadcasts a PubSub event that the web UI can render as a notification or toast.

**AI-6.7** — Built-in heartbeat templates (seeded on first run):

| Name | Schedule | Prompt |
|---|---|---|
| `morning-briefing` | `30 7 * * 1-5` | Summarize overnight git activity, open PRs, and unresolved TODOs |
| `stale-pr-check` | `0 10 * * 1-5` | Check for PRs older than 3 days without review |
| `daily-summary` | `0 18 * * 1-5` | Summarize today's completed work and remaining tasks |

Templates are disabled by default — user enables via settings UI.

---

## 9. Persistent Tool Approvals

### AI-7: Approval Memory

Tool approvals are currently per-session and ephemeral. The user approves `git push` once, and next session they're asked again.

**AI-7.1** — Tool approvals stored in `tool_approvals` table:

```elixir
schema "tool_approvals" do
  field :pattern, :string           # "shell_exec:git *" or "file_write:/projects/*/src/**"
  field :scope, Ecto.Enum,
    values: [:global, :project]
  field :project_id, :binary_id     # nil for global approvals
  field :policy, Ecto.Enum,
    values: [:ask, :record, :allow]  # ask=prompt, record=log+allow, allow=silent
  field :created_by, Ecto.Enum,
    values: [:user, :system]         # user=explicitly approved, system=default

  timestamps()
end
```

**AI-7.2** — Pattern matching syntax:

```
tool_name                    → exact tool match, any input
tool_name:arg_pattern        → tool match with argument glob
shell_exec:git *             → any git command
shell_exec:rm *              → any rm command (user probably denies this)
file_write:/projects/*/src/** → file writes under any project src/
file_read:*                  → all file reads (blanket allow)
```

**AI-7.3** — Approval resolution order:
1. Check project-scoped approvals (if agent is project-scoped)
2. Check global approvals
3. Most specific pattern wins (longer pattern = more specific)
4. If no match → default to `:ask`

**AI-7.4** — The `approval_gate` node (existing in agent-system-prd) is updated to consult `tool_approvals`:

```elixir
@spec check_approval(tool_name :: String.t(), input :: map(), opts :: keyword()) ::
  :allow | :record | :ask | :deny
```

**AI-7.5** — When user approves via the approval gate UI:
- If "always allow" → insert approval with `:allow` policy
- If "allow this once" → proceed but don't persist
- If "deny" → proceed with denial, optionally persist as deny pattern

**AI-7.6** — Approvals are viewable and manageable through the workspace:

```
/global/approvals.md    ← projected view of all approval rules
```

And through a dedicated settings page in synapsis_web.

---

## 10. Graph Integration

### AI-8: Updated Conversational Loop

The conversational loop graph (used by Global and Project agents) is updated to include compaction and the new context assembly:

```
                    ┌──────────────────────────────┐
                    │                              │
                    ▼                              │
             ┌──────────────┐                      │
             │receive_message│  (pause node)        │
             └──────┬───────┘                      │
                    │                              │
                    ▼                              │
          ┌─────────────────┐                      │
          │compact_context  │  (AI-5: compaction)   │
          └────────┬────────┘                      │
                   │                               │
                   ▼                               │
          ┌────────────────┐                       │
          │  build_prompt  │  (AI-2: full assembly) │
          └────────┬───────┘                       │
                   │                               │
                   ▼                               │
            ┌──────────┐                           │
            │ llm_call │                           │
            └─────┬────┘                           │
                  │                                │
                  ▼                                │
         ┌────────────────┐                        │
         │ tool_dispatch  │──── no tools ──►┐      │
         └───────┬────────┘                 │      │
                 │ has tools                │      │
                 ▼                          │      │
        ┌────────────────┐                  │      │
        │ approval_gate  │  (AI-7: checks   │      │
        │                │   persistent     │      │
        │                │   approvals)     │      │
        └───────┬────────┘                  │      │
                │                           │      │
                ▼                           │      │
        ┌──────────────┐                    │      │
        │ tool_execute │                    │      │
        └──────┬───────┘                    │      │
               │                            │      │
               ▼                            │      │
        ┌──────────────┐                    │      │
        │inject_result │                    │      │
        └──────┬───────┘                    │      │
               │                            │      │
               ▼                            ▼      │
          ┌─────────┐               ┌──────────┐   │
          │llm_call │◄──── or ─────│ respond  │───┘
          └─────────┘               └──────────┘
```

**AI-8.1** — `build_prompt` node is updated to call `ContextBuilder.build_system_prompt/2` with the full assembly pipeline (AI-2).

**AI-8.2** — `compact_context` node is inserted between `receive_message` and `build_prompt`.

**AI-8.3** — `approval_gate` node is updated to call `check_approval/3` which consults persistent approvals (AI-7).

---

## 11. File Structure

New and modified files:

```
apps/synapsis_agent/
├── lib/synapsis_agent/
│   ├── context_builder.ex                    # MODIFIED — full assembly pipeline
│   ├── compaction.ex                         # NEW — compaction logic
│   ├── compaction_config.ex                  # NEW — compaction configuration
│   ├── nodes/
│   │   ├── compact_context.ex                # NEW — compaction graph node
│   │   ├── build_prompt.ex                   # MODIFIED — uses new ContextBuilder
│   │   └── approval_gate.ex                  # MODIFIED — persistent approvals
│   ├── heartbeat/
│   │   ├── worker.ex                         # NEW — Oban worker
│   │   ├── scheduler.ex                      # NEW — syncs DB config to Oban cron
│   │   └── templates.ex                      # NEW — built-in heartbeat templates
│   └── graphs/
│       └── conversational_loop.ex            # MODIFIED — insert compact_context node

apps/synapsis_data/
├── lib/synapsis_data/
│   ├── heartbeat_config.ex                   # NEW — schema
│   └── tool_approval.ex                      # NEW — schema
├── priv/repo/migrations/
│   ├── *_create_heartbeat_configs.exs        # NEW
│   └── *_create_tool_approvals.exs           # NEW

apps/synapsis_workspace/
├── lib/synapsis_workspace/
│   └── identity.ex                           # NEW — convenience API for identity files
```

---

## 12. Implementation Phases

### Phase 1: Identity Files & Context Assembly (AI-1, AI-2)

**Goal:** Agent personality is driven by workspace files. System prompt is assembled from layers.

**Modules:** `ContextBuilder` (modified), `SynapsisWorkspace.Identity` (new)

**Tests:**

```
test/synapsis_workspace/identity_test.exs
├── describe "load_soul/1"
│   ├── returns global soul when no project
│   ├── returns project soul when project has one
│   ├── falls back to global soul when project has none
│   ├── returns nil when no soul exists
│   └── does not error on missing file
├── describe "load_identity/0"
│   ├── returns identity content
│   └── returns nil when not set
├── describe "load_bootstrap/0"
│   ├── returns bootstrap content
│   └── returns nil when not set
├── describe "seed_defaults/0"
│   ├── creates default soul.md
│   ├── creates default identity.md
│   ├── creates default bootstrap.md
│   ├── does not overwrite existing files
│   └── is idempotent

test/synapsis_agent/context_builder_test.exs
├── describe "build_system_prompt/2"
│   ├── includes base prompt for agent type
│   ├── includes soul from workspace
│   ├── includes identity from workspace
│   ├── includes bootstrap from workspace
│   ├── includes project context when project-scoped
│   ├── wraps each section in XML tags
│   ├── omits sections for missing files
│   ├── respects token budget
│   └── truncates lower-priority layers first
├── describe "soul assembly"
│   ├── global only → uses global soul
│   ├── project only → uses project soul
│   ├── both → concatenates global + separator + project
│   ├── neither → omits soul section entirely
│   └── project overrides are appended after global
├── describe "layer functions"
│   ├── load_base_prompt/1 returns per-agent-type prompt
│   ├── load_soul/1 delegates to Workspace.Identity
│   ├── load_identity/0 delegates to Workspace.Identity
│   └── load_bootstrap/0 delegates to Workspace.Identity
├── describe "caching"
│   ├── caches identity content in ETS
│   ├── invalidates on workspace PubSub event
│   ├── TTL expires after 60 seconds
│   └── concurrent reads return consistent data
```

### Phase 2: Skill Injection (AI-3)

**Goal:** LLM knows what tools are available via the system prompt.

**Modules:** `ContextBuilder` (extended)

**Tests:**

```
test/synapsis_agent/context_builder_test.exs (additions)
├── describe "build_skills_manifest/1"
│   ├── lists all enabled built-in tools
│   ├── includes MCP plugin tools with prefix
│   ├── includes LSP plugin tools with prefix
│   ├── excludes disabled tools
│   ├── marks unconfigured tools as "(not configured)"
│   ├── truncates descriptions at 80 chars
│   ├── scopes to project when project_id given
│   └── returns empty string when no tools available
```

### Phase 3: Memory as Context (AI-4)

**Goal:** Relevant memories are automatically included in the system prompt.

**Modules:** `ContextBuilder` (extended), `SynapsisCore.Memory` (query addition)

**Tests:**

```
test/synapsis_agent/context_builder_test.exs (additions)
├── describe "load_memory_context/2"
│   ├── searches memory entries using user message as query
│   ├── returns entries within token budget
│   ├── formats entries with key, date, and content
│   ├── budget is 5% of model context window
│   ├── hard cap at 10 entries regardless of budget
│   ├── selects highest relevance first
│   ├── drops low-relevance entries when over token budget
│   ├── scopes to project when project_id given
│   ├── includes global memories for project-scoped queries
│   ├── returns nil when no relevant memories found
│   └── caches search result for current turn
├── describe "memory_budget/1"
│   ├── returns 3 max entries for 32K context
│   ├── returns 10 max entries for 128K context (cap)
│   ├── returns 10 max entries for 200K context (cap)
│   └── token budget is 5% of context window
├── describe "select_memory_entries/2"
│   ├── selects highest relevance first
│   ├── respects token budget
│   ├── drops low-relevance entries when over budget
│   └── always includes at least 1 entry if any match

test/synapsis_core/memory_search_test.exs
├── describe "search/2"
│   ├── finds entries matching keywords
│   ├── ranks by ts_rank score
│   ├── handles multi-word queries
│   ├── returns empty list for no matches
│   └── respects scope filter
```

### Phase 4: Session Compaction (AI-5)

**Goal:** Long sessions are gracefully compacted to stay within context limits.

**Modules:** `SynapsisAgent.Compaction`, `SynapsisAgent.Nodes.CompactContext`

**Tests:**

```
test/synapsis_agent/compaction_test.exs
├── describe "should_compact?/2"
│   ├── returns false when under threshold
│   ├── returns true when over threshold
│   ├── uses model-specific context window size
│   └── respects custom threshold_ratio
├── describe "compact/2"
│   ├── splits messages at midpoint
│   ├── preserves at least preserve_recent messages
│   ├── calls summarization LLM
│   ├── replaces old messages with summary
│   ├── summary includes key facts
│   ├── summary includes open tasks
│   └── returns compacted message list
├── describe "estimate_tokens/1"
│   ├── approximates from JSON byte size
│   ├── handles empty messages
│   └── handles tool_use content blocks

test/synapsis_agent/nodes/compact_context_test.exs
├── describe "run/2"
│   ├── no-op when under threshold
│   ├── compacts when over threshold
│   ├── returns messages patch
│   ├── broadcasts compaction event
│   ├── broadcasts system_message for inline chat notification
│   ├── emits telemetry
│   ├── skips if recently compacted
│   └── handles summarization failure gracefully
```

### Phase 5: Proactive Execution (AI-6)

**Goal:** Agents run scheduled tasks via Oban heartbeats.

**Modules:** `SynapsisAgent.Heartbeat.Worker`, `SynapsisAgent.Heartbeat.Scheduler`, `SynapsisData.HeartbeatConfig`

**Tests:**

```
test/synapsis_data/heartbeat_config_test.exs
├── describe "changeset/2"
│   ├── valid with required fields
│   ├── validates cron expression format
│   ├── requires name uniqueness
│   ├── requires prompt
│   ├── defaults keep_history to false
│   └── defaults enabled to true

test/synapsis_agent/heartbeat/worker_test.exs
├── describe "perform/1"
│   ├── loads heartbeat config
│   ├── creates isolated session
│   ├── runs agent turn with heartbeat prompt
│   ├── writes result to workspace latest.md (scratch lifecycle)
│   ├── writes timestamped entry when keep_history is true (draft lifecycle)
│   ├── skips history entry when keep_history is false
│   ├── broadcasts notification when notify_user is true
│   ├── handles agent failure gracefully
│   └── respects max_attempts

test/synapsis_agent/heartbeat/scheduler_test.exs
├── describe "sync_crontab/0"
│   ├── loads enabled configs from DB
│   ├── builds Oban cron entries
│   ├── updates Oban cron plugin
│   ├── handles empty config list
│   └── re-syncs on PubSub config change

test/synapsis_agent/heartbeat/templates_test.exs
├── describe "seed_defaults/0"
│   ├── creates morning-briefing template
│   ├── creates stale-pr-check template
│   ├── creates daily-summary template
│   ├── all templates disabled by default
│   └── idempotent
```

### Phase 6: Persistent Approvals (AI-7)

**Goal:** Tool approvals persist across sessions.

**Modules:** `SynapsisData.ToolApproval`, approval_gate node (modified)

**Tests:**

```
test/synapsis_data/tool_approval_test.exs
├── describe "changeset/2"
│   ├── valid with required fields
│   ├── validates pattern format
│   └── validates policy enum

test/synapsis_agent/approval_test.exs
├── describe "check_approval/3"
│   ├── returns :allow for matching allow pattern
│   ├── returns :record for matching record pattern
│   ├── returns :ask for matching ask pattern
│   ├── returns :ask when no pattern matches (default)
│   ├── project-scoped patterns checked first
│   ├── most specific pattern wins
│   ├── glob matching works for shell commands
│   ├── glob matching works for file paths
│   └── handles empty approvals table
├── describe "persist_approval/3"
│   ├── inserts new approval
│   ├── updates existing approval for same pattern
│   └── broadcasts change event

test/synapsis_agent/nodes/approval_gate_test.exs (additions)
├── describe "persistent approval integration"
│   ├── auto-allows when persistent approval exists
│   ├── prompts user when no persistent approval
│   ├── persists user choice when "always allow" selected
│   ├── does not persist for "allow once"
│   └── logs when policy is :record
```

---

## 13. Acceptance Criteria

- [ ] **AC-1:** User edits `/global/soul.md` in workspace UI → next agent response reflects new personality
- [ ] **AC-2:** System prompt includes all 7 layers in correct order with XML tags
- [ ] **AC-3:** Agent lists available tools in response when asked "what can you do?"
- [ ] **AC-4:** Agent references memory from a previous session without explicit memory_search tool call
- [ ] **AC-5:** Session with 200+ messages compacts without losing key facts (verified by asking agent about earlier context)
- [ ] **AC-6:** Configured heartbeat fires on schedule and produces workspace artifact
- [ ] **AC-7:** Tool approval persists — approve `git push` once, not asked again in new session
- [ ] **AC-8:** Default identity files are created on first workspace initialization
- [ ] **AC-9:** Project soul overrides global soul for project-scoped agents
- [ ] **AC-10:** Compaction uses separate (cheaper) model when configured

---

## 14. Integration Points

### With synapsis_workspace

- Identity files are workspace documents at conventional paths
- `SynapsisWorkspace.Identity` provides typed read API over workspace
- Heartbeat results written to workspace
- Approval rules projected as workspace document

### With synapsis_provider

- Compaction makes LLM calls via `synapsis_provider` (summarization)
- Token estimation uses model metadata from provider config

### With synapsis_data

- New schemas: `heartbeat_configs`, `tool_approvals`
- Memory search uses existing `memory_entries` with `tsvector`

### With synapsis_core

- Skills manifest reads from tool registry
- Memory search query goes through `SynapsisCore.Memory`

### With synapsis_web

- Workspace explorer renders identity files with special UI (syntax highlighting, preview)
- Settings page for heartbeat management (enable/disable, schedule, prompt)
- Settings page for approval management (view/revoke patterns)
- Notification rendering for heartbeat results

### With PubSub

- `{:workspace_document_updated, path}` → invalidates identity cache
- `{:session_compacted, session_id, metadata}` → UI notification
- `{:system_message, %{type: :compaction, ...}}` → inline chat system message
- `{:heartbeat_completed, heartbeat_id, result}` → user notification
- `{:tool_approval_changed, pattern}` → invalidates approval cache

---

## 15. Resolved Design Decisions

### RD-1: Soul Inheritance — Concatenate with Override Sections

**Decision:** Global soul is the base. Project soul is an **addendum** appended after global soul. Project soul can override specific sections by re-declaring them.

**Rationale:** Replacement forces users to duplicate shared behavioral rules (tone, boundaries, coding style) in every project soul. That's fragile — a global rule update requires N project edits. Concatenation means the user writes project-specific refinements only.

**Mechanics:**

```
System prompt soul section =
  global soul.md content
  + "\n\n<!-- Project-specific overrides -->\n\n"
  + project soul.md content (if exists)
```

The LLM naturally resolves conflicts by giving weight to the later instruction. If global soul says "be concise" and project soul says "be thorough when explaining architecture decisions," the project-specific instruction wins in that context. This is how system prompt layering already works in practice — later instructions take precedence.

**Edge case:** If a user genuinely wants a completely different personality per project, they write a project soul that opens with `"Ignore the global personality above. You are..."`. This is explicit, visible, and the user's choice.

**Update to AI-1.2:**

```elixir
# In ContextBuilder
defp assemble_soul(project_id) do
  global = SynapsisWorkspace.Identity.load_soul(nil)
  project = SynapsisWorkspace.Identity.load_soul(project_id)

  case {global, project} do
    {nil, nil}     -> nil
    {g, nil}       -> g
    {nil, p}       -> p
    {g, p}         -> g <> "\n\n<!-- Project-specific -->\n\n" <> p
  end
end
```

**Tests to add:**

```
test/synapsis_agent/context_builder_test.exs (additions)
├── describe "soul assembly"
│   ├── global only → uses global soul
│   ├── project only → uses project soul
│   ├── both → concatenates global + project
│   ├── neither → omits soul section
│   └── project overrides are appended, not prepended
```

---

### RD-2: Compaction Consent — Silent with Notification

**Decision:** Compact silently. Notify the user via PubSub after compaction completes. Never ask for permission.

**Rationale:** Compaction is infrastructure, not a user decision. Asking "may I summarize your history?" interrupts the flow and creates a decision the user has no basis to make well (they don't know token counts or context window limits). OpenClaw compacts silently and nobody complains.

The notification matters because transparency builds trust. The user should be able to see that compaction happened and what was preserved, especially during debugging ("why doesn't the agent remember X?").

**Mechanics:**

1. `compact_context` node runs, determines compaction is needed
2. Summarization LLM call executes
3. Messages replaced with summary
4. PubSub broadcast: `{:session_compacted, session_id, %{messages_removed: n, messages_kept: m, summary_tokens: t}}`
5. Web UI renders a subtle inline system message in the chat:

   ```
   ── Context compacted: 147 messages summarized, 12 recent messages preserved ──
   ```

6. The summary itself is visible if the user scrolls up — it's the first message in the compacted history, prefixed with `[Conversation summary]`

**No opt-out needed.** If the user wants to avoid compaction, they start a new session. Sessions are cheap. Compaction is a property of long-running sessions, not a preference.

**Update to AI-5.6:** Add a `system_message` event type alongside the existing PubSub event:

```elixir
# After compaction
PubSub.broadcast("session:#{session_id}", {:system_message, %{
  type: :compaction,
  text: "Context compacted: #{removed} messages summarized, #{kept} recent messages preserved",
  metadata: %{messages_removed: removed, messages_kept: kept, summary_tokens: summary_tokens}
}})
```

---

### RD-3: Heartbeat Session Cleanup — Align with Workspace GC

**Decision:** Heartbeat sessions are workspace documents at `scratch` lifecycle. They follow existing workspace GC rules: `session_scratch_retention_days` (default: 7 days).

**Rationale:** The workspace already has a GC system (WS-9) with configurable retention for session scratch documents. Heartbeat sessions are conceptually the same — transient agent work products. Inventing a parallel retention mechanism would violate the single-application-rule and create two GC configs to reason about.

**Mechanics:**

1. Heartbeat worker writes results to workspace at `scratch` lifecycle:
   ```
   /global/heartbeats/<name>/latest.md     ← overwritten each run (scratch)
   ```

2. If the user wants to keep a heartbeat result, they promote it via the workspace UI ("Promote to Shared"), which changes lifecycle to `:shared` and exempts it from scratch GC. This leverages existing WS-8.4 promotion.

3. The heartbeat's *session transcript* (the JSONL conversation) is stored as a regular session. Session cleanup is a separate concern — sessions have their own retention policy in `synapsis_data`. Heartbeat sessions are marked with `metadata: %{type: :heartbeat, heartbeat_id: id}` so they can be identified and cleaned independently if needed.

4. Configuration is unified — the user sets `session_scratch_retention_days` once and it applies to both workspace scratch and heartbeat results.

**Additionally:** Keep the **latest** result per heartbeat always accessible (overwrite `/global/heartbeats/<name>/latest.md` each run). This is scratch lifecycle — no version history, just the most recent output. If users want historical results, they configure the heartbeat to write timestamped entries at `:draft` lifecycle:

```
/global/heartbeats/<name>/history/2026-03-17T07:30:00Z.md   ← draft, keeps last 5 versions
```

This is opt-in per heartbeat via a `keep_history: boolean` config field (default: `false`).

**Update to AI-6.2 schema:**

```elixir
field :keep_history, :boolean, default: false  # add to heartbeat_configs
```

---

### RD-4: Memory Injection Limit — Token-Budget-Proportional with Hard Cap

**Decision:** Memory entries get a **token budget**, not a fixed count. Budget = 5% of model context window, hard cap of 10 entries regardless of budget.

**Rationale:** A fixed count of 5 works fine for a 128K context model, but wastes space on a 200K model and is too generous for a 32K model. Tying it to the context window means the system auto-adapts. The hard cap of 10 prevents pathological cases where a huge context window would pull 50 memory entries (diminishing returns — the LLM can't usefully attend to that many).

**Mechanics:**

```elixir
@spec memory_budget(model_context_window :: pos_integer()) :: %{
  max_tokens: pos_integer(),
  max_entries: pos_integer()
}
def memory_budget(model_context_window) do
  max_tokens = trunc(model_context_window * 0.05)
  %{
    max_tokens: max_tokens,
    max_entries: min(10, max(3, div(max_tokens, 500)))  # ~500 tokens per entry estimate
  }
end
```

For common models:
| Model Context | 5% Budget | Estimated Max Entries |
|---|---|---|
| 32K | 1,600 tokens | 3 entries |
| 128K | 6,400 tokens | 10 entries (cap) |
| 200K | 10,000 tokens | 10 entries (cap) |

**Selection strategy:** Query returns top-N by relevance score, then trim by token budget. If the top 10 entries exceed the token budget, drop lowest-relevance entries until under budget. This means high-relevance entries are always included even if they're long.

```elixir
defp select_memory_entries(entries, budget) do
  entries
  |> Enum.sort_by(& &1.relevance_score, :desc)
  |> Enum.take(budget.max_entries)
  |> Enum.reduce_while({[], 0}, fn entry, {acc, tokens} ->
    entry_tokens = estimate_tokens(entry.content)
    if tokens + entry_tokens <= budget.max_tokens do
      {:cont, {[entry | acc], tokens + entry_tokens}}
    else
      {:halt, {acc, tokens}}
    end
  end)
  |> elem(0)
  |> Enum.reverse()
end
```

**Update to AI-4.2 opts:**

```elixir
# Replace :limit with :budget
@spec search_relevant_memories(query :: String.t(), opts :: keyword()) ::
  [SynapsisData.MemoryEntry.t()]

# opts:
#   :model_context_window — used to compute token budget (default: 128_000)
#   :scope     — :global | {:project, project_id}
#   :min_score — minimum relevance score threshold
```

**Tests to add:**

```
test/synapsis_agent/context_builder_test.exs (additions)
├── describe "memory_budget/1"
│   ├── returns 3 entries for 32K context
│   ├── returns 10 entries for 128K context (cap)
│   ├── returns 10 entries for 200K context (cap)
│   └── token budget is 5% of context window
├── describe "select_memory_entries/2"
│   ├── selects highest relevance first
│   ├── respects token budget
│   ├── drops low-relevance entries when over budget
│   └── always includes at least 1 entry if any match
```

---

### RD-5: Identity File Format — Plain Markdown, Metadata in Database

**Decision:** Identity files are **plain markdown**. No YAML frontmatter. Metadata (author, timestamps, version) lives in the `workspace_documents` table where it already exists.

**Rationale:**

1. **Simplicity for users.** The identity file is something users edit by hand. Frontmatter adds syntax they need to understand and maintain. OpenClaw uses plain markdown for `SOUL.md` and it works.

2. **Metadata already exists.** The `workspace_documents` schema (WS-5) already tracks `created_by`, `updated_by`, `version`, `metadata` (jsonb), and timestamps. Adding frontmatter would duplicate this — violating the "workspace as projection, not duplication" principle.

3. **No parsing step.** Plain markdown is injected directly into the system prompt as a string. Frontmatter requires a parsing step to separate metadata from content, adding complexity for zero LLM benefit (the LLM doesn't need to see `last_modified_by`).

4. **Future flexibility.** If we later want structured metadata visible to the LLM (e.g., "this soul was last edited 3 days ago"), we can inject it from the database record as a comment or header — no format migration needed.

**The one exception:** If the user *chooses* to put YAML or structured data in their markdown, that's fine — it's their file. The system treats the entire file content as opaque markdown and injects it as-is. The system never parses identity file content for structure.

**No changes to PRD needed** — this was already the implicit design. This decision documents and locks it.
