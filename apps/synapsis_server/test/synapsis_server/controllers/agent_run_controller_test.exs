defmodule SynapsisServer.AgentRunControllerTest do
  use SynapsisServer.ConnCase, async: false

  alias Synapsis.Agent.Runs
  alias Synapsis.Config.Store

  test "daemon status and run list/show/cancel routes expose durable coordination state", %{
    conn: conn
  } do
    assert %{"data" => %{"ready" => ready, "queued_ids" => queued_ids}} =
             conn |> get("/api/agent/daemon/status") |> json_response(200)

    assert is_boolean(ready)
    assert is_list(queued_ids)

    assert {:ok, run} =
             Runs.create(%{
               kind: "manual",
               status: "queued",
               source: "web",
               prompt: "inspect the release",
               tool_profile: "assistant_basic"
             })

    run_id = run.id
    assert %{"data" => listed} = conn |> get("/api/agent/runs") |> json_response(200)
    assert %{"id" => ^run_id, "status" => "queued"} = Enum.find(listed, &(&1["id"] == run_id))

    assert %{"data" => %{"id" => ^run_id, "prompt" => "inspect the release"}} =
             conn |> get("/api/agent/runs/#{run_id}") |> json_response(200)

    assert %{"error" => "not_owned"} =
             conn |> post("/api/agent/runs/#{run_id}/cancel") |> json_response(409)
  end

  test "manual run and routine trigger/list routes use the daemon submission path", %{conn: conn} do
    heartbeat_id = Ecto.UUID.generate()
    routine_id = Ecto.UUID.generate()

    on_exit(fn ->
      Store.delete(:heartbeat, heartbeat_id)
      Store.delete(:routine, routine_id)
    end)

    assert {:ok, _} =
             Store.put(:heartbeat, %{
               "id" => heartbeat_id,
               "name" => "health-check",
               "schedule" => "0 * * * *",
               "prompt" => "check health",
               "enabled" => true
             })

    assert {:ok, _} =
             Store.put(:routine, %{
               "id" => routine_id,
               "name" => "nightly-reflection",
               "kind" => "dream",
               "schedule" => "0 2 * * *",
               "prompt" => "reflect",
               "enabled" => true
             })

    assert %{"data" => heartbeats} =
             conn |> get("/api/agent/routines/heartbeat") |> json_response(200)

    assert %{"id" => ^heartbeat_id, "name" => "health-check"} =
             Enum.find(heartbeats, &(&1["id"] == heartbeat_id))

    assert %{"data" => dreams} =
             conn |> get("/api/agent/routines/dream") |> json_response(200)

    assert %{"id" => ^routine_id, "kind" => "dream"} =
             Enum.find(dreams, &(&1["id"] == routine_id))

    assert %{"data" => schedules} =
             conn |> get("/api/agent/routines/schedule") |> json_response(200)

    assert Enum.all?(schedules, &(&1["kind"] == "schedule"))

    assert %{"data" => manual} =
             conn
             |> post("/api/agent/runs", %{"prompt" => "manual API run"})
             |> json_response(201)

    assert manual["kind"] == "manual"

    assert %{"data" => %{"id" => manual_id, "status" => "cancelled"}} =
             conn
             |> post("/api/agent/runs/#{manual["id"]}/cancel")
             |> json_response(200)

    assert manual_id == manual["id"]

    assert %{"data" => heartbeat} =
             conn
             |> post("/api/agent/routines/heartbeat/trigger", %{
               "heartbeat_id" => Ecto.UUID.generate(),
               "prompt" => "heartbeat API run"
             })
             |> json_response(201)

    assert heartbeat["kind"] == "heartbeat"

    assert %{"data" => %{"id" => heartbeat_id, "status" => "cancelled"}} =
             conn
             |> post("/api/agent/runs/#{heartbeat["id"]}/cancel")
             |> json_response(200)

    assert heartbeat_id == heartbeat["id"]
  end

  test "invalid and missing run requests return stable HTTP errors", %{conn: conn} do
    assert %{"error" => "prompt is required"} =
             conn |> post("/api/agent/runs", %{}) |> json_response(422)

    missing = Ecto.UUID.generate()

    assert %{"error" => "run not found"} =
             conn |> get("/api/agent/runs/#{missing}") |> json_response(404)

    assert %{"error" => "unsupported routine kind"} =
             conn |> get("/api/agent/routines/unknown") |> json_response(404)
  end
end
