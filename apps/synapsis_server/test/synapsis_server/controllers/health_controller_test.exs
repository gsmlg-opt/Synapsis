defmodule SynapsisServer.HealthControllerTest do
  use SynapsisServer.ConnCase

  alias SynapsisServer.HealthController

  describe "GET /api/health" do
    test "returns subsystem health as JSON", %{conn: conn} do
      conn = get(conn, "/api/health")

      assert conn.status == 200

      assert %{
               "ok" => true,
               "store" => "ok",
               "pubsub" => "ok",
               "scheduler" => _,
               "tool_registry" => _,
               "provider_registry" => _,
               "session_supervisor" => _,
               "agent_supervisor" => _,
               "agent_runtime" => "ok",
               "endpoint" => "ok",
               "version" => version
             } = payload = json_response(conn, 200)

      refute Map.has_key?(payload, "agent_daemon")
      assert is_binary(version)
    end

    test "maps required check failures to an unhealthy service response" do
      checks = %{
        store: "ok",
        pubsub: "ok",
        scheduler: "not_configured",
        tool_registry: "ok",
        provider_registry: "ok",
        session_supervisor: "ok",
        agent_supervisor: "ok",
        agent_runtime: "ok",
        endpoint: "ok"
      }

      assert HealthController.healthy?(checks)
      assert HealthController.response_status(checks) == :ok

      for required <- Map.keys(checks) -- [:scheduler] do
        failed = Map.put(checks, required, "error: not_started")
        refute HealthController.healthy?(failed)
        assert HealthController.response_status(failed) == :service_unavailable
      end

      assert HealthController.healthy?(Map.put(checks, :scheduler, "ok"))
      assert HealthController.healthy?(Map.put(checks, :scheduler, "not_configured"))
      refute HealthController.healthy?(Map.put(checks, :scheduler, "error: not_started"))
    end

    test "returns JSON 503 when the heartbeat scheduler is down", %{conn: conn} do
      child = Synapsis.Agent.Heartbeat.LocalScheduler
      assert :ok = Supervisor.terminate_child(SynapsisCore.Supervisor, child)

      conn =
        try do
          get(conn, "/api/health")
        after
          assert {:ok, _pid} = Supervisor.restart_child(SynapsisCore.Supervisor, child)
        end

      assert %{
               "ok" => false,
               "scheduler" => "error: not_started",
               "scheduler_entries" => []
             } = json_response(conn, 503)
    end
  end
end
