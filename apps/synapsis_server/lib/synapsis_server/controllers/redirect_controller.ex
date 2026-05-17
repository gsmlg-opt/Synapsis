defmodule SynapsisServer.RedirectController do
  use SynapsisServer, :controller

  def agent(conn, _params) do
    redirect(conn, to: "/agent/agents")
  end
end
