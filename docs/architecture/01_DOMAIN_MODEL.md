# 01 — Domain Model

## Core Entities

### Session

A conversation workspace tied to a project directory.

```elixir
%Session{
  id: UUID,
  title: String,
  project_path: String,           # absolute path to project root
  agent: :build | :plan | :custom,
  provider: :anthropic | :openai | :google | :local,
  model: String,                  # e.g. "claude-sonnet-4-20250514"
  status: :idle | :streaming | :tool_executing | :error,
  config: map(),                  # merged project + user config
  inserted_at: DateTime,
  updated_at: DateTime
}
```

### Message

A single turn in a conversation. Contains structured parts.

```elixir
%Message{
  id: UUID,
  session_id: UUID,
  role: :user | :assistant | :system,
  parts: [Part],                  # JSON-encoded list of part structs
  token_count: integer(),         # cached token count for context management
  inserted_at: DateTime
}
```

### Part (embedded, polymorphic)

```elixir
# Discriminated by `type` field
%TextPart{type: :text, content: String}
%ToolUsePart{type: :tool_use, tool: atom(), input: map(), result: map() | nil, status: :pending | :approved | :denied | :completed | :error}
%ToolResultPart{type: :tool_result, tool_use_id: String, content: String}
%ReasoningPart{type: :reasoning, content: String}
%FilePart{type: :file, path: String, content: String}
%SnapshotPart{type: :snapshot, files: [%{path: String, hash: String}]}
%AgentPart{type: :agent, agent: atom(), message: String}
```

### Agent

Configuration for how the AI behaves. Not a DB entity — loaded from config.

```elixir
%Agent{
  name: :build | :plan | :custom,
  system_prompt: String,
  tools: [atom()],                 # which tools this agent can use
  model: String,                   # default model for this agent
  reasoning_effort: :low | :medium | :high,
  read_only: boolean()             # plan mode = true
}
```

### Provider

LLM provider connection configuration.

```elixir
%Provider{
  name: :anthropic | :openai | :google | :copilot | :local,
  api_key: String | nil,
  base_url: String,
  models: [%Model{id: String, name: String, context_window: integer()}]
}
```

### Tool

A capability the AI can invoke. 27 built-in tools across 10 categories. Each tool implements the `Synapsis.Tool` behaviour.

```elixir
%Tool{
  name: String.t(),                # "file_edit", "bash_exec", "grep", "task", etc.
  description: String,
  parameters: map(),               # JSON Schema for input validation
  permission_level: :none | :read | :write | :execute | :destructive,
  category: :filesystem | :search | :execution | :web | :planning
          | :orchestration | :interaction | :session | :notebook
          | :computer | :swarm,
  side_effects: [atom()],          # e.g. [:file_changed]
  version: String.t(),             # semver, e.g. "1.0.0"
  enabled?: boolean()              # false for notebook, computer use
}
```

### ToolCall

A persisted record of a tool invocation for audit and replay.

```elixir
%ToolCall{
  id: UUID,
  session_id: UUID,
  message_id: UUID | nil,
  tool_name: String,
  input: map(),                    # JSONB — tool input parameters
  output: map() | nil,             # JSONB — tool result
  status: :pending | :approved | :denied | :completed | :error,
  duration_ms: integer(),
  error_message: String | nil,
  inserted_at: DateTime,
  updated_at: DateTime
}
```

### SessionPermission

Per-session permission configuration for the tool system.

```elixir
%SessionPermission{
  id: UUID,
  session_id: UUID,                # unique per session
  mode: :interactive | :autonomous,
  allow_write: boolean(),          # default: true
  allow_execute: boolean(),        # default: true
  allow_destructive: :allow | :deny | :ask,
  tool_overrides: map(),           # JSONB — per-tool glob pattern overrides
  inserted_at: DateTime,
  updated_at: DateTime
}
```

### SessionTodo

Session-scoped todo list managed by the `todo_write`/`todo_read` tools.

```elixir
%SessionTodo{
  id: UUID,
  session_id: UUID,
  todos: [map()],                  # JSONB — list of {id, content, status} items
  inserted_at: DateTime,
  updated_at: DateTime
}
```

### MemoryEntry

Persistent key-value memory scoped to global, project, or session.

```elixir
%MemoryEntry{
  id: UUID,
  scope: :global | :project | :session,
  scope_id: String | nil,        # project_id or session_id for scoped entries
  key: String,
  content: String,
  metadata: map(),
  inserted_at: DateTime,
  updated_at: DateTime
}
```

### Skill

Configurable agent behavior extension with custom system prompt fragments.

```elixir
%Skill{
  id: UUID,
  scope: :global | :project,
  project_id: UUID | nil,         # set for project-scoped skills
  name: String,
  description: String,
  system_prompt_fragment: String,
  tool_allowlist: [String],        # JSONB list of allowed tool names
  config_overrides: map(),         # JSONB overrides for agent config
  is_builtin: boolean(),
  inserted_at: DateTime,
  updated_at: DateTime
}
```

### MCPConfig

Configuration for a Model Context Protocol server connection.

```elixir
%MCPConfig{
  id: UUID,
  name: String,
  transport: :stdio | :sse,
  command: String | nil,           # for stdio transport
  args: [String],                  # JSONB list
  url: String | nil,               # for SSE transport
  env: map(),                      # JSONB environment variables
  auto_connect: boolean(),
  inserted_at: DateTime,
  updated_at: DateTime
}
```

### LSPConfig

Configuration for a Language Server Protocol integration.

```elixir
%LSPConfig{
  id: UUID,
  language: String,
  command: String,
  args: [String],                  # JSONB list
  root_path: String | nil,
  auto_start: boolean(),
  settings: map(),                 # JSONB LSP-specific settings
  inserted_at: DateTime,
  updated_at: DateTime
}
```

## Entity Relationships

```
Session 1──*  Message
Message 1──*  Part (embedded)
Session *──1  Agent (config ref)
Session *──1  Provider (config ref)
Agent   1──*  Tool (config ref)
Project 1──*  Skill (optional, project-scoped)
Project 1──*  MemoryEntry (via scope_id, when scope = project)
Session 1──*  MemoryEntry (via scope_id, when scope = session)
Session 1──*  ToolCall (tool invocation audit trail)
Session 1──1  SessionPermission (per-session permission config)
Session 1──*  SessionTodo (session-scoped todo list)
```

## State Machines

### Session Status

```
         send_message
  :idle ──────────────→ :streaming
    ↑                      │
    │                      │ tool_use part received
    │                      ▼
    │               :tool_executing
    │                      │
    │    tool result        │ tool complete
    │    fed back to        │
    │    provider           │
    │                      ▼
    │               :streaming (continues)
    │                      │
    │    stream complete    │
    └──────────────────────┘
    
    any state ──error──→ :error ──retry──→ :idle
```

### Tool Permission

```
  tool_use received
       │
       ▼
  check_permission()
       │
  ┌────┴────┐
  │ auto?   │──yes──→ :approved → execute
  │         │
  └────┬────┘
       │ no
       ▼
  broadcast permission_request to client
       │
  ┌────┴────┐
  │ client  │──approve──→ :approved → execute
  │ responds│
  │         │──deny──────→ :denied → skip, feed denial to provider
  └─────────┘
```

## Context Management

Each session tracks cumulative token count. When approaching the model's context window limit:

1. `Session.Context` calculates total tokens
2. If over threshold (e.g. 80% of window), triggers compaction
3. Compaction: summarize older messages via a separate LLM call, replace with a single `CompactionPart`
4. Preserve: system prompt, last N messages, all tool results from current turn
