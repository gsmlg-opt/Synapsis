defmodule SynapsisWeb.ConnCase do
  @moduledoc "Test case for LiveView tests."
  use ExUnit.CaseTemplate
  import ExUnit.Assertions

  using do
    quote do
      @endpoint SynapsisServer.Endpoint

      use SynapsisWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import SynapsisWeb.ConnCase
    end
  end

  setup tags do
    Synapsis.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  def assert_unique_form_ids(html) when is_binary(html) do
    form_ids =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("form[id]")
      |> LazyHTML.attribute("id")

    assert form_ids == Enum.uniq(form_ids),
           "expected rendered form ids to be unique, got: #{inspect(form_ids)}"
  end
end
