defmodule SynapsisWeb do
  @moduledoc """
  The presentation layer for Synapsis.

  Owns LiveView modules, HEEx templates, function components,
  and React hook bridges. All rendering and UI logic lives here.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {SynapsisWeb.Layouts, :app}

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import Plug.CSRFProtection, only: [get_csrf_token: 0]

      use Gettext, backend: SynapsisWeb.Gettext

      import SynapsisWeb.CoreComponents

      alias Phoenix.LiveView.JS

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: SynapsisServer.Endpoint,
        router: SynapsisServer.Router,
        statics: SynapsisWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate live_view/live_component/html.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
