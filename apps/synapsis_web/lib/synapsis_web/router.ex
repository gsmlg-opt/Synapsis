defmodule SynapsisWeb.Router do
  use SynapsisWeb, :router

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

  scope "/api", SynapsisWeb do
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

  scope "/", SynapsisWeb do
    pipe_through :browser

    live "/", SessionLive
    live "/sessions/:id", SessionLive
  end
end
