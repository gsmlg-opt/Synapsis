defmodule SynapsisWeb.ConfigControllerTest do
  use SynapsisWeb.ConnCase

  describe "GET /api/config" do
    test "returns resolved config", %{conn: conn} do
      conn = get(conn, "/api/config")
      assert %{"data" => config} = json_response(conn, 200)
      assert is_map(config["agents"])
    end
  end
end
