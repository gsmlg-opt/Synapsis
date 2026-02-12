defmodule SynapsisServerWeb.ProviderControllerTest do
  use SynapsisServerWeb.ConnCase

  describe "GET /api/providers" do
    test "returns provider list", %{conn: conn} do
      conn = get(conn, "/api/providers")
      assert %{"data" => providers} = json_response(conn, 200)
      assert is_list(providers)
    end
  end

  describe "GET /api/providers/:name/models" do
    test "returns models for anthropic", %{conn: conn} do
      conn = get(conn, "/api/providers/anthropic/models")
      assert %{"data" => models} = json_response(conn, 200)
      assert is_list(models)
      assert length(models) > 0
    end

    test "returns 404 for unknown provider", %{conn: conn} do
      conn = get(conn, "/api/providers/unknown_xyz/models")
      assert json_response(conn, 404)
    end
  end
end
