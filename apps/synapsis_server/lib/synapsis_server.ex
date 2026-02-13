defmodule SynapsisServer do
  @moduledoc """
  The HTTP/WebSocket gateway for Synapsis.

  Owns the transport layer: Phoenix Endpoint, Router, Plug pipeline,
  Channels for LLM streaming, and REST API for programmatic access.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: SynapsisServer.Endpoint,
        router: SynapsisServer.Router,
        statics: SynapsisServer.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/channel/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
