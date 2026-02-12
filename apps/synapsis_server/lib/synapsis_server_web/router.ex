defmodule SynapsisServerWeb.Router do
  use SynapsisServerWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", SynapsisServerWeb do
    pipe_through :api

    resources "/sessions", SessionController, only: [:index, :show, :create, :delete]
    post "/sessions/:id/messages", SessionController, :send_message
    post "/sessions/:id/fork", SessionController, :fork
    get "/sessions/:id/export", SessionController, :export_session
    post "/sessions/:id/compact", SessionController, :compact
    get "/sessions/:id/events", SSEController, :events

    get "/providers", ProviderController, :index
    get "/providers/:name/models", ProviderController, :models

    get "/config", ConfigController, :show
  end
end
