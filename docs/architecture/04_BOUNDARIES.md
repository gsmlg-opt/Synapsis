# 04 — Boundaries

## App-Level Boundaries

### synapsis_core → Public API

The core exposes these context modules as the sole interface:

```elixir
# Session lifecycle
Synapsis.Sessions.create(project_path, opts)        # => {:ok, session}
Synapsis.Sessions.get(session_id)                     # => {:ok, session} | {:error, :not_found}
Synapsis.Sessions.list(project_path, opts)            # => [session]
Synapsis.Sessions.delete(session_id)                  # => :ok

# Messaging (starts the agent loop)
Synapsis.Sessions.send_message(session_id, content)   # => :ok (async, results via PubSub)
Synapsis.Sessions.cancel(session_id)                  # => :ok
Synapsis.Sessions.retry(session_id)                   # => :ok

# Tool permission responses
Synapsis.Sessions.approve_tool(session_id, tool_use_id)  # => :ok
Synapsis.Sessions.deny_tool(session_id, tool_use_id)     # => :ok

# Provider management
Synapsis.Providers.list()                             # => [provider]
Synapsis.Providers.models(provider_name)              # => [model]
Synapsis.Providers.authenticate(provider_name, key)   # => :ok | {:error, reason}

# Config
Synapsis.Config.resolve(project_path)                 # => config_map
Synapsis.Config.update_user(key, value)               # => :ok
```

### synapsis_web → LiveView

The web frontend uses LiveView for page structure with React mounted via `phx-hook` for the chat widget:

```
GET  /                LiveView (SessionLive) — sidebar + welcome
GET  /sessions/:id    LiveView (SessionLive) — sidebar + ChatView hook
```

`SessionLive` handles:
- `mount/3` — loads session list from `Synapsis.Sessions.list/1`
- `handle_params/3` — sets active session from URL
- `handle_event("create_session", ...)` — creates session, `push_patch` to new URL
- `handle_event("delete_session", ...)` — deletes session, updates sidebar

The ChatView React component is mounted into a `<div phx-hook="ChatView" phx-update="ignore">` element. React manages its own Channel connection for streaming chat — LiveView does not participate in the message flow.

### synapsis_web → Channel Protocol

```elixir
# Client → Server (push)
"session:create"        %{project_path: str}
"session:message"       %{session_id: str, content: str, files: []}
"session:cancel"        %{session_id: str}
"session:tool_approve"  %{session_id: str, tool_use_id: str}
"session:tool_deny"     %{session_id: str, tool_use_id: str}
"session:switch_agent"  %{session_id: str, agent: str}

# Server → Client (broadcast)
"text_delta"            %{session_id: str, content: str}
"tool_use"              %{session_id: str, tool: str, input: map}
"tool_result"           %{session_id: str, tool_use_id: str, result: map}
"permission_request"    %{session_id: str, tool_use_id: str, tool: str, input: map}
"reasoning"             %{session_id: str, content: str}
"session_status"        %{session_id: str, status: str}
"error"                 %{session_id: str, message: str}
"done"                  %{session_id: str}
```

### synapsis_web → REST API

The `:api` pipeline serves JSON endpoints (no session, no CSRF):

```
GET    /api/sessions                 # list sessions for project
POST   /api/sessions                 # create session
GET    /api/sessions/:id             # get session with messages
DELETE /api/sessions/:id             # delete session
POST   /api/sessions/:id/messages    # send message (also via channel)
GET    /api/sessions/:id/events      # SSE stream (alternative to channels)
GET    /api/providers                # list providers + models
POST   /api/auth/:provider           # authenticate provider
GET    /api/config                   # resolved config
```

### synapsis_lsp → Internal API

```elixir
Synapsis.LSP.diagnostics(project_path)                # => [%Diagnostic{}]
Synapsis.LSP.diagnostics_for_file(project_path, file) # => [%Diagnostic{}]
Synapsis.LSP.ensure_server(project_path, language)     # => :ok
Synapsis.LSP.stop_server(project_path, language)       # => :ok
```

## PubSub Topics

```
"session:#{session_id}"          # all events for a session
"sessions:#{project_path_hash}"  # session lifecycle events (create/delete)
"config:#{project_path_hash}"    # config change notifications
```

## Behaviour Contracts

### Provider Behaviour

```elixir
defmodule Synapsis.Provider.Behaviour do
  @callback stream(request :: map(), config :: map()) :: {:ok, stream_ref} | {:error, term()}
  @callback cancel(stream_ref :: term()) :: :ok
  @callback models(config :: map()) :: {:ok, [Model.t()]} | {:error, term()}
  @callback format_request(messages :: [Message.t()], tools :: [Tool.t()], opts :: map()) :: map()
end
```

### Tool Behaviour

```elixir
defmodule Synapsis.Tool.Behaviour do
  @callback name() :: atom()
  @callback description() :: String.t()
  @callback parameters() :: map()  # JSON Schema
  @callback call(input :: map(), context :: map()) :: {:ok, term()} | {:error, term()}
end
```
