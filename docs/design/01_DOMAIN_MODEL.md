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

A capability the AI can invoke.

```elixir
%Tool{
  name: atom(),                    # :file_edit, :bash, :file_search, :grep, :diagnostics
  description: String,
  parameters: map(),               # JSON Schema for input validation
  requires_permission: boolean(),
  timeout_ms: integer()
}
```

## Entity Relationships

```
Session 1──*  Message
Message 1──*  Part (embedded)
Session *──1  Agent (config ref)
Session *──1  Provider (config ref)
Agent   1──*  Tool (config ref)
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
