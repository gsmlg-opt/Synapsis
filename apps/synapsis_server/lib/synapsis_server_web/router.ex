defmodule SynapsisServerWeb.Router do
  use SynapsisServerWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", SynapsisServerWeb do
    pipe_through :api
  end
end
