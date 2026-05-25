defmodule SynapsisServer.Router do
  use SynapsisServer, :router

  # LiveView modules live in synapsis_web which compiles after synapsis_server.
  # These are available at runtime but not at compile time.
  @compile {:no_warn_undefined,
            [
              SynapsisWeb.DashboardLive,
              SynapsisWeb.AgentLive.Agents,
              SynapsisWeb.AgentLive.Sessions,
              SynapsisWeb.AgentLive.Toolsets,
              SynapsisWeb.AgentLive.Skills,
              SynapsisWeb.SettingsLive,
              SynapsisWeb.ProviderLive.Index,
              SynapsisWeb.ProviderLive.Show,
              SynapsisWeb.MemoryLive.Index,
              SynapsisWeb.MemoryLive.Show,
              SynapsisWeb.SkillLive.Index,
              SynapsisWeb.SkillLive.Show,
              SynapsisWeb.MCPLive.Index,
              SynapsisWeb.MCPLive.Show,
              SynapsisWeb.LSPLive.Index,
              SynapsisWeb.LSPLive.Show,
              SynapsisWeb.ModelTierLive.Index,
              SynapsisWeb.WorkspaceLive.Explorer
            ]}

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SynapsisWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", SynapsisServer do
    pipe_through :api

    get "/health", HealthController, :show

    resources "/sessions", SessionController, only: [:index, :show, :create, :delete]
    post "/sessions/:id/messages", SessionController, :send_message
    post "/sessions/:id/fork", SessionController, :fork
    get "/sessions/:id/export", SessionController, :export_session
    post "/sessions/:id/compact", SessionController, :compact
    get "/sessions/:id/events", SSEController, :events

    resources "/providers", ProviderController, only: [:index, :show, :create, :update, :delete]
    get "/providers/:id/models", ProviderController, :models
    post "/providers/:id/test", ProviderController, :test_connection
    get "/providers/by-name/:name/models", ProviderController, :models_by_name

    post "/auth/:provider", ProviderController, :authenticate

    post "/providers/:id/oauth/device/start", ProviderController, :oauth_device_start
    post "/providers/:id/oauth/device/poll", ProviderController, :oauth_device_poll
    post "/providers/:id/oauth/refresh", ProviderController, :oauth_refresh

    get "/config", ConfigController, :show
  end

  scope "/", SynapsisServer do
    pipe_through :browser

    get "/agent", RedirectController, :agent
  end

  scope "/", SynapsisWeb do
    pipe_through :browser

    live "/", DashboardLive, :index

    live "/agent/agents", AgentLive.Agents, :index
    live "/agent/agents/new", AgentLive.Agents, :new
    live "/agent/agents/:id/config", AgentLive.Agents, :config
    live "/agent/tools", AgentLive.Toolsets, :index
    live "/agent/tools/new", AgentLive.Toolsets, :new
    live "/agent/tools/:id/edit", AgentLive.Toolsets, :edit
    live "/agent/skills", AgentLive.Skills, :index
    live "/agent/skills/new", AgentLive.Skills, :new
    live "/agent/skills/:id/edit", AgentLive.Skills, :edit
    live "/agent/agents/:agent_id/sessions", AgentLive.Sessions, :sessions
    live "/agent/agents/:agent_id/sessions/:session_id", AgentLive.Sessions, :session

    # TODO: add authentication guard (on_mount hook or pipeline plug) before production
    live "/workspace", WorkspaceLive.Explorer, :index

    live "/settings", SettingsLive, :index

    live "/settings/providers", ProviderLive.Index, :index
    live "/settings/providers/new", ProviderLive.Index, :new
    live "/settings/providers/:id", ProviderLive.Show, :show

    live "/settings/models", ModelTierLive.Index, :index

    live "/settings/memory", MemoryLive.Index, :index
    live "/settings/memory/new", MemoryLive.Index, :new
    live "/settings/memory/:id", MemoryLive.Show, :show

    live "/settings/skills", SkillLive.Index, :index
    live "/settings/skills/:id", SkillLive.Show, :show

    live "/settings/mcp", MCPLive.Index, :index
    live "/settings/mcp/new", MCPLive.Index, :new
    live "/settings/mcp/:id", MCPLive.Show, :show

    live "/settings/lsp", LSPLive.Index, :index
    live "/settings/lsp/new", LSPLive.Index, :new
    live "/settings/lsp/:id", LSPLive.Show, :show
  end
end
