defmodule SynapsisServer.HealthControllerTest do
  use SynapsisServer.ConnCase

  describe "GET /api/health" do
    test "returns subsystem health as JSON", %{conn: conn} do
      conn = get(conn, "/api/health")

      assert conn.status == 200

      assert %{
               "ok" => ok,
               "store" => "ok",
               "pubsub" => "ok",
               "scheduler" => _,
               "tool_registry" => _,
               "provider_registry" => _,
               "session_supervisor" => _,
               "agent_supervisor" => _,
               "agent_daemon" => _,
               "endpoint" => "ok",
               "version" => version
             } = json_response(conn, 200)

      assert is_boolean(ok)
      assert is_binary(version)
    end
  end
end
