defmodule SynapsisServer.Router do
  use SynapsisServer, :router

  # LiveView modules live in synapsis_web which compiles after synapsis_server.
  # These are available at runtime but not at compile time.
  @compile {:no_warn_undefined,
            [
              SynapsisWeb.DashboardLive,
              SynapsisWeb.ProjectLive.Index,
              SynapsisWeb.ProjectLive.Show,
              SynapsisWeb.SessionLive.Index,
              SynapsisWeb.SessionLive.Show,
              SynapsisWeb.SettingsLive,
              SynapsisWeb.ProviderLive.Index,
              SynapsisWeb.ProviderLive.Show,
              SynapsisWeb.MemoryLive.Index,
              SynapsisWeb.SkillLive.Index,
              SynapsisWeb.SkillLive.Show,
              SynapsisWeb.MCPLive.Index,
              SynapsisWeb.MCPLive.Show,
              SynapsisWeb.LSPLive.Index,
              SynapsisWeb.LSPLive.Show
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

    get "/config", ConfigController, :show
  end

  scope "/", SynapsisWeb do
    pipe_through :browser

    live "/", DashboardLive, :index

    live "/projects", ProjectLive.Index, :index
    live "/projects/new", ProjectLive.Index, :new
    live "/projects/:id", ProjectLive.Show, :show
    live "/projects/:id/edit", ProjectLive.Show, :edit

    live "/projects/:project_id/sessions", SessionLive.Index, :index
    live "/projects/:project_id/sessions/new", SessionLive.Index, :new
    live "/projects/:project_id/sessions/:id", SessionLive.Show, :show

    live "/settings", SettingsLive, :index

    live "/settings/providers", ProviderLive.Index, :index
    live "/settings/providers/new", ProviderLive.Index, :new
    live "/settings/providers/:id", ProviderLive.Show, :show

    live "/settings/memory", MemoryLive.Index, :index

    live "/settings/skills", SkillLive.Index, :index
    live "/settings/skills/:id", SkillLive.Show, :show

    live "/settings/mcp", MCPLive.Index, :index
    live "/settings/mcp/:id", MCPLive.Show, :show

    live "/settings/lsp", LSPLive.Index, :index
    live "/settings/lsp/:id", LSPLive.Show, :show
  end
end
