defmodule SynapsisServer.ConfigControllerTest do
  use SynapsisServer.ConnCase

  describe "GET /api/config" do
    test "returns resolved config", %{conn: conn} do
      conn = get(conn, "/api/config")
      assert %{"data" => config} = json_response(conn, 200)
      assert is_map(config["agents"])
    end

    test "does not leak apiKey in provider config", %{conn: conn} do
      conn = get(conn, "/api/config")
      %{"data" => config} = json_response(conn, 200)

      providers = config["providers"] || %{}

      Enum.each(providers, fn {_name, provider} ->
        refute Map.has_key?(provider, "apiKey")
      end)
    end

    test "accepts project_path param", %{conn: conn} do
      conn = get(conn, "/api/config", %{project_path: "/tmp"})
      assert %{"data" => _} = json_response(conn, 200)
    end

    test "returns 200 status", %{conn: conn} do
      conn = get(conn, "/api/config")
      assert conn.status == 200
    end
  end
end
