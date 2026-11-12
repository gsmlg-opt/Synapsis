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
        "data" => %{"id" => "a-1", "task_id" => "t-1", "state" => "leased", "version" => 1,
                    "lease_expires_at" => "2026-11-12T00:02:00Z"}
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
end
