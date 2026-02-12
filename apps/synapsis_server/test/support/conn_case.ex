defmodule SynapsisServerWeb.ConnCase do
  @moduledoc "Test case for controller tests."
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint SynapsisServerWeb.Endpoint

      use SynapsisServerWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import SynapsisServerWeb.ConnCase
    end
  end

  setup tags do
    Synapsis.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
