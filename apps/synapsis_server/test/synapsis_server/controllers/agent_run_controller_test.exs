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
             |> post("/api/agent/heartbeat/trigger", %{"name" => "health-check"})
             |> json_response(201)

    assert heartbeat["kind"] == "heartbeat"
    assert heartbeat["heartbeat_id"] == heartbeat_id
    assert heartbeat["prompt"] == "check health"

    assert %{"data" => %{"id" => heartbeat_run_id, "status" => "cancelled"}} =
             conn
             |> post("/api/agent/runs/#{heartbeat["id"]}/cancel")
             |> json_response(200)

    assert heartbeat_run_id == heartbeat["id"]
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

  test "routine resources use stable IDs and trigger only the persisted definition", %{conn: conn} do
    name = "api-routine-#{System.unique_integer([:positive])}"

    assert %{"data" => %{"id" => routine_id, "name" => ^name}} =
             conn
             |> post("/api/agent/routines", %{
               "name" => name,
               "kind" => "schedule",
               "enabled" => true,
               "schedule" => "0 3 * * *",
               "prompt" => "stored prompt",
               "tool_profile" => "assistant_basic"
             })
             |> json_response(201)

    on_exit(fn -> Store.delete(:routine, routine_id) end)
    assert {:ok, _uuid} = Ecto.UUID.cast(routine_id)

    assert %{"data" => listed} =
             conn |> get("/api/agent/routines?kind=schedule") |> json_response(200)

    assert %{"id" => ^routine_id, "name" => ^name} =
             Enum.find(listed, &(&1["id"] == routine_id))

    assert %{"data" => %{"id" => ^routine_id, "name" => "renamed", "prompt" => "stored prompt"}} =
             conn
             |> patch("/api/agent/routines/#{routine_id}", %{"name" => "renamed"})
             |> json_response(200)

    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:daemon")

    assert %{"data" => %{"id" => run_id, "routine_id" => ^routine_id} = run} =
             conn
             |> post("/api/agent/routines/#{routine_id}/trigger", %{"prompt" => "caller override"})
             |> json_response(201)

    assert run["prompt"] == "stored prompt"

    assert_receive {:agent_daemon_event,
                    %{
                      event: "agent.routine.triggered",
                      routine_id: ^routine_id,
                      routine_name: "renamed",
                      kind: "schedule",
                      run_id: ^run_id
                    }}

    assert %{"data" => %{"status" => "cancelled"}} =
             conn |> post("/api/agent/runs/#{run_id}/cancel") |> json_response(200)

    assert conn
           |> post("/api/agent/routines/schedule/trigger", %{
             "routine_id" => Ecto.UUID.generate(),
             "prompt" => "unsafe"
           })
           |> response(404)
  end

  test "heartbeat and dream trigger selectors require one enabled stored routine", %{conn: conn} do
    heartbeat_one = Ecto.UUID.generate()
    heartbeat_two = Ecto.UUID.generate()
    dream_id = Ecto.UUID.generate()

    on_exit(fn ->
      Enum.each([heartbeat_one, heartbeat_two, dream_id], &Store.delete(:routine, &1))
    end)

    for attrs <- [
          routine(heartbeat_one, "heartbeat-one", "heartbeat"),
          routine(heartbeat_two, "heartbeat-two", "heartbeat"),
          routine(dream_id, "only-dream", "dream")
        ] do
      assert {:ok, _routine} = Store.put(:routine, attrs)
    end

    assert %{"error" => "ambiguous"} =
             conn |> post("/api/agent/heartbeat/trigger", %{}) |> json_response(409)

    assert %{"data" => %{"heartbeat_id" => ^heartbeat_one} = heartbeat_run} =
             conn
             |> post("/api/agent/heartbeat/trigger", %{"name" => "heartbeat-one"})
             |> json_response(201)

    assert %{"data" => %{"routine_id" => ^dream_id} = dream_run} =
             conn |> post("/api/agent/dream/trigger", %{}) |> json_response(201)

    for run <- [heartbeat_run, dream_run] do
      assert %{"data" => %{"status" => "cancelled"}} =
               conn |> post("/api/agent/runs/#{run["id"]}/cancel") |> json_response(200)
    end

    assert {:ok, _disabled} =
             Store.put(:routine, %{routine(dream_id, "only-dream", "dream") | "enabled" => false})

    assert %{"error" => "routine not found"} =
             conn |> post("/api/agent/dream/trigger", %{}) |> json_response(404)
  end

  defp routine(id, name, kind) do
    %{
      "id" => id,
      "name" => name,
      "kind" => kind,
      "enabled" => true,
      "schedule" => "0 4 * * *",
      "prompt" => "#{name} prompt",
      "tool_profile" => if(kind == "dream", do: "assistant_dream", else: "assistant_basic")
    }
  end
end
