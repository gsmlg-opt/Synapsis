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

# Project management
Synapsis.Projects.list()                              # => [project]
Synapsis.Projects.get(id)                             # => {:ok, project} | {:error, :not_found}
Synapsis.Projects.find_or_create(path)                # => {:ok, project}

# Session extras
Synapsis.Sessions.list_by_project(project_id, opts)   # => [session]
Synapsis.Sessions.recent(opts)                        # => [session]
Synapsis.Sessions.fork(session_id, opts)              # => {:ok, session}
Synapsis.Sessions.export(session_id)                  # => {:ok, export_data}
Synapsis.Sessions.compact(session_id)                 # => :ok | {:error, reason}
```

### synapsis_server → Endpoint, Router, Channels

`synapsis_server` owns all Phoenix infrastructure: the Endpoint, Router, Plug pipelines, Channels, and REST controllers. It defines no OTP application — `SynapsisServer.Supervisor` is started by `SynapsisCore.Application` at runtime.

```
Endpoint:  SynapsisServer.Endpoint
Router:    SynapsisServer.Router
Socket:    SynapsisServer.UserSocket (at /socket)
LiveView:  /live socket (for LiveView connections)
```

### synapsis_web → LiveView Pages

`synapsis_web` owns all LiveView modules, HEEx templates, function components, and React hook bridges. It depends on `synapsis_server` and defines no OTP application.

**15 LiveView pages** (all under `SynapsisWeb.*` namespace, routed from `SynapsisServer.Router`):

```
GET  /                                  DashboardLive       — projects + recent sessions
GET  /projects                          ProjectLive.Index   — project CRUD
GET  /projects/:id                      ProjectLive.Show    — project detail + sessions
GET  /projects/:project_id/sessions     SessionLive.Index   — session list
GET  /projects/:project_id/sessions/:id SessionLive.Show    — chat view (React ChatApp hook)
GET  /settings                          SettingsLive        — settings hub
GET  /settings/providers                ProviderLive.Index  — provider CRUD
GET  /settings/providers/:id            ProviderLive.Show   — provider edit
GET  /settings/memory                   MemoryLive.Index    — memory entries
GET  /settings/skills                   SkillLive.Index     — skill CRUD
GET  /settings/skills/:id              SkillLive.Show      — skill edit
GET  /settings/mcp                      MCPLive.Index       — MCP server CRUD
GET  /settings/mcp/:id                  MCPLive.Show        — MCP config edit
GET  /settings/lsp                      LSPLive.Index       — LSP server CRUD
GET  /settings/lsp/:id                  LSPLive.Show        — LSP config edit
```

`SessionLive.Show` is the core chat view. LiveView owns the page chrome (sidebar, header, agent mode toggle). React `ChatApp` is mounted via `phx-hook="ChatApp"` with `phx-update="ignore"` — React owns the DOM for the chat widget and manages its own Phoenix Channel connection for streaming.

**Workspace packages** (Bun workspaces in `packages/`):
- `@synapsis/hooks` — LiveView hooks: `ChatApp`, `MarkdownRenderer`, `DiffViewer`, `TerminalOutput`
- `@synapsis/ui` — React components + Redux store (chatSlice, uiSlice, sessionSlice)
- `@synapsis/channel` — Phoenix Socket singleton, session channel factory, Redux middleware

### synapsis_server → Channel Protocol

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

### synapsis_server → REST API

The `:api` pipeline serves JSON endpoints (no session, no CSRF):

```
GET    /api/sessions                 # list sessions for project
POST   /api/sessions                 # create session
GET    /api/sessions/:id             # get session with messages
DELETE /api/sessions/:id             # delete session
POST   /api/sessions/:id/messages    # send message (also via channel)
POST   /api/sessions/:id/fork        # fork session
GET    /api/sessions/:id/export      # export session
POST   /api/sessions/:id/compact     # compact session context
GET    /api/sessions/:id/events      # SSE stream (alternative to channels)
GET    /api/providers                # list providers + models
GET    /api/providers/:id/models     # list models for provider
POST   /api/providers/:id/test       # test provider connection
GET    /api/providers/by-name/:name/models  # models by provider name
PUT    /api/providers/:id            # update provider
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
