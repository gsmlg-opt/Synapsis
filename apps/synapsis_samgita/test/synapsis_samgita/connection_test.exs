defmodule SynapsisSamgita.ConnectionTest do
  use ExUnit.Case, async: false

  import SynapsisSamgita.Test.SamgitaStub

  setup do
    Synapsis.DataCase.clear_config_store(:samgita)
    SynapsisSamgita.disconnect()

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(SynapsisSamgita.AttemptSupervisor),
          do: DynamicSupervisor.terminate_child(SynapsisSamgita.AttemptSupervisor, pid)

      SynapsisSamgita.disconnect()
    end)

    %{server: configure!()}
  end

  test "connect/0 stores the connection and broadcasts it", %{server: s} do
    stub_connect(s)
    SynapsisSamgita.subscribe()

    assert {:ok, %{state: :connected, agent_id: "agent-1", connection_id: "conn-1"}} =
             SynapsisSamgita.connect()

    assert_receive {:samgita_status, %{state: :connected}}
    assert %{state: :connected} = SynapsisSamgita.status()
  end

  test "a rejected credential leaves an error state", %{server: s} do
    Gaoxy.Test.stub(s, "POST", "/api/agent/connect", fn conn ->
      json(conn, 401, %{"errors" => %{"code" => "unauthorized"}})
    end)

    assert {:error, %{code: "unauthorized"}} = SynapsisSamgita.connect()
    assert %{state: :error, last_error: "unauthorized"} = SynapsisSamgita.status()
  end

  test "listing requires a connection" do
    assert {:error, %{code: "not_connected"}} = SynapsisSamgita.list_tasks("p-1")
  end

  test "claim/2 opens a session, claims, and starts a supervised attempt", %{server: s} do
    stub_connect(s)
    {:ok, _} = SynapsisSamgita.connect()
    test_pid = self()

    Gaoxy.Test.expect_once(s, "POST", "/api/agent/projects/p-1/sessions", fn conn ->
      {body, conn} = body(conn)
      assert String.starts_with?(body["external_id"], "synapsis-t-1-")
      json(conn, 201, %{"data" => %{"id" => "s-1", "state" => "open"}})
    end)

    Gaoxy.Test.expect_once(s, "POST", "/api/agent/projects/p-1/tasks/t-1/claim", fn conn ->
      {body, conn} = body(conn)
      send(test_pid, {:claim_body, body})

      json(conn, 201, %{
        "data" => %{
          "id" => "a-1",
          "task_id" => "t-1",
          "state" => "leased",
          "version" => 1,
          "lease_expires_at" => "2026-11-12T00:02:00Z"
        }
      })
    end)

    Gaoxy.Test.stub(s, "GET", "/api/agent/projects/p-1/attempts/a-1/proof", fn conn ->
      json(conn, 200, %{"data" => %{"attempt_id" => "a-1", "proof" => "v1.k.p0"}})
    end)

    assert {:ok, %{id: "a-1", state: "leased", task_id: "t-1"}} =
             SynapsisSamgita.claim("p-1", %{"id" => "t-1", "version" => 7})

    assert_receive {:claim_body, %{"expected_version" => 7, "session_id" => "s-1"}}
    assert [%{id: "a-1"}] = SynapsisSamgita.list_attempts()
  end

  test "reconnecting is refused while an attempt is active", %{server: s} do
    stub_connect(s)
    {:ok, _} = SynapsisSamgita.connect()

    Gaoxy.Test.stub(s, "POST", "/api/agent/projects/p-1/sessions", fn conn ->
      json(conn, 201, %{"data" => %{"id" => "s-1", "state" => "open"}})
    end)

    Gaoxy.Test.stub(s, "POST", "/api/agent/projects/p-1/tasks/t-1/claim", fn conn ->
      json(conn, 201, %{
        "data" => %{"id" => "a-9", "task_id" => "t-1", "state" => "leased", "version" => 1}
      })
    end)

    Gaoxy.Test.stub(s, "GET", "/api/agent/projects/p-1/attempts/a-9/proof", fn conn ->
      json(conn, 200, %{"data" => %{"attempt_id" => "a-9", "proof" => "v1.k.p0"}})
    end)

    {:ok, _} = SynapsisSamgita.claim("p-1", %{"id" => "t-1", "version" => 1})

    connects = fn ->
      Enum.count(Gaoxy.Test.requests(s).entries, &(&1.path == "/api/agent/connect"))
    end

    before = connects.()

    assert {:error, %{code: "attempts_active"}} = SynapsisSamgita.connect()
    assert connects.() == before
    assert %{state: :connected, connection_id: "conn-1"} = SynapsisSamgita.status()
  end

  describe "mark_processed/2" do
    @event %{
      "schema_version" => "1.0",
      "event_id" => "evt-mp",
      "delivery_attempt_id" => "att-1",
      "created_at" => "2026-11-12T00:00:00Z",
      "correlation_id" => "c-1",
      "type" => "manual.triggered",
      "project_ref" => "p-1",
      "payload" => %{}
    }

    setup do
      Synapsis.DataCase.clear_coord("coord/samgita/inbox/")
      on_exit(fn -> Synapsis.DataCase.clear_coord("coord/samgita/inbox/") end)
      {:ok, :new, _} = Synapsis.Samgita.Inbox.record(@event)
      :ok
    end

    test "completes the event locally and reports it to Samgita", %{server: s} do
      stub_connect(s)
      {:ok, _} = SynapsisSamgita.connect()
      test_pid = self()

      Gaoxy.Test.expect_once(s, "GET", "/api/agent/projects/p-1/deliveries", fn conn ->
        json(conn, 200, %{
          "data" => [
            %{
              "id" => "d-other",
              "event_id" => "evt-x",
              "agent_id" => "agent-1",
              "state" => "accepted"
            },
            %{
              "id" => "d-1",
              "event_id" => "evt-mp",
              "agent_id" => "agent-1",
              "state" => "accepted",
              "version" => 3,
              "operation_id" => "op-1",
              "fence" => 2
            }
          ],
          "limit" => 100,
          "offset" => 0
        })
      end)

      Gaoxy.Test.expect_once(
        s,
        "POST",
        "/api/agent/projects/p-1/deliveries/d-1/report",
        fn conn ->
          {body, conn} = body(conn)
          send(test_pid, {:report, body})
          json(conn, 200, %{"data" => %{"id" => "d-1", "state" => "completed"}})
        end
      )

      assert {:ok, %{entry: %{"processing_status" => "completed"}, reported: true}} =
               SynapsisSamgita.mark_processed("evt-mp", "seen")

      assert_receive {:report, body}

      assert %{
               "expected_version" => 3,
               "operation_id" => "op-1",
               "fence" => 2,
               "processing_status" => "completed",
               "result" => %{"note" => "seen"}
             } = body

      assert {:ok, _} = Ecto.UUID.cast(body["decision_id"])
      assert {:ok, %{"decision_id" => decision_id}} = Synapsis.Samgita.Inbox.get("evt-mp")
      assert decision_id == body["decision_id"]
    end

    test "without a connection the event is still completed locally" do
      assert {:ok,
              %{entry: %{"processing_status" => "completed"}, reported: {:error, "not_connected"}}} =
               SynapsisSamgita.mark_processed("evt-mp", "seen")
    end
  end
end
