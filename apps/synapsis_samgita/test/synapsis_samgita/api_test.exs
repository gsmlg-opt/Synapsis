defmodule SynapsisSamgita.APITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  alias SynapsisSamgita.API

  @credential String.duplicate("c", 43)

  setup do
    server = Gaoxy.Test.open()

    conn = %{
      base_url: Gaoxy.Test.url(server) |> String.trim_trailing("/"),
      credential: @credential,
      connection_id: nil
    }

    %{server: server, conn: conn}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp body(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(raw), conn}
  end

  test "connect/1 authenticates and sends a command_id without a connection header", %{
    server: s,
    conn: c
  } do
    Gaoxy.Test.expect_once(s, "POST", "/api/agent/connect", fn conn ->
      headers = Map.new(conn.req_headers)
      assert headers["authorization"] == "Bearer " <> @credential
      refute Map.has_key?(headers, "x-agent-connection")
      {body, conn} = body(conn)
      assert {:ok, _} = Ecto.UUID.cast(body["command_id"])

      json(conn, 201, %{"data" => %{"id" => "conn-1", "agent_id" => "agent-1", "generation" => 2}})
    end)

    assert {:ok, %{"id" => "conn-1", "agent_id" => "agent-1"}} = API.connect(c)
  end

  test "list_tasks/3 sends the connection header and assignee filter", %{server: s, conn: c} do
    Gaoxy.Test.expect_once(s, "GET", "/api/agent/projects/p-1/tasks", fn conn ->
      assert Map.new(conn.req_headers)["x-agent-connection"] == "conn-1"
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["assignee_agent_id"] == "agent-1"
      json(conn, 200, %{"data" => [%{"id" => "t-1"}], "limit" => 100, "offset" => 0})
    end)

    assert {:ok, [%{"id" => "t-1"}]} =
             API.list_tasks(%{c | connection_id: "conn-1"}, "p-1", "agent-1")
  end

  test "project_context/2 and get_task/3 read project context and task detail", %{
    server: s,
    conn: c
  } do
    Gaoxy.Test.expect_once(s, "GET", "/api/agent/projects/p-1/context", fn conn ->
      json(conn, 200, %{"data" => %{"project" => %{"id" => "p-1"}}})
    end)

    Gaoxy.Test.expect_once(s, "GET", "/api/agent/projects/p-1/tasks/t-1", fn conn ->
      json(conn, 200, %{"data" => %{"id" => "t-1", "version" => 3}})
    end)

    c = %{c | connection_id: "conn-1"}
    assert {:ok, %{"project" => %{"id" => "p-1"}}} = API.project_context(c, "p-1")
    assert {:ok, %{"id" => "t-1", "version" => 3}} = API.get_task(c, "p-1", "t-1")
  end

  test "claim/5 and the attempt commands send version, proof and command ids", %{
    server: s,
    conn: c
  } do
    c = %{c | connection_id: "conn-1"}

    Gaoxy.Test.expect_once(s, "POST", "/api/agent/projects/p-1/tasks/t-1/claim", fn conn ->
      {body, conn} = body(conn)
      assert %{"expected_version" => 3, "session_id" => "s-1", "command_id" => _} = body
      json(conn, 201, %{"data" => %{"id" => "a-1", "version" => 1}})
    end)

    Gaoxy.Test.expect_once(s, "POST", "/api/agent/projects/p-1/attempts/a-1/report", fn conn ->
      {body, conn} = body(conn)

      assert %{
               "expected_version" => 4,
               "proof" => "v1.k.p",
               "outcome" => "succeeded",
               "effects_resolved" => true,
               "result" => %{"note" => "done"},
               "command_id" => _
             } = body

      json(conn, 200, %{"data" => %{"id" => "a-1", "state" => "succeeded", "version" => 5}})
    end)

    assert {:ok, %{"id" => "a-1"}} = API.claim(c, "p-1", "t-1", 3, "s-1")

    assert {:ok, %{"state" => "succeeded"}} =
             API.report(c, "p-1", "a-1", 4, "v1.k.p", "succeeded", true, %{"note" => "done"})
  end

  test "proof/3 returns the proof string", %{server: s, conn: c} do
    Gaoxy.Test.expect_once(s, "GET", "/api/agent/projects/p-1/attempts/a-1/proof", fn conn ->
      json(conn, 200, %{"data" => %{"attempt_id" => "a-1", "proof" => "v1.k.p"}})
    end)

    assert {:ok, "v1.k.p"} = API.proof(%{c | connection_id: "conn-1"}, "p-1", "a-1")
  end

  test "a caller-supplied command_id is reused verbatim", %{server: s, conn: c} do
    id = Ecto.UUID.generate()

    Gaoxy.Test.expect_once(s, "POST", "/api/agent/projects/p-1/attempts/a-1/progress", fn conn ->
      {body, conn} = body(conn)
      assert body["command_id"] == id
      assert body["payload"] == %{"summary" => "half way"}
      json(conn, 200, %{"data" => %{"id" => "a-1"}})
    end)

    assert {:ok, _} =
             API.progress(%{c | connection_id: "conn-1"}, "p-1", "a-1", 2, "v1.k.p", "half way",
               command_id: id
             )
  end

  test "error bodies map to status and code", %{server: s, conn: c} do
    Gaoxy.Test.expect_once(s, "POST", "/api/agent/projects/p-1/attempts/a-1/start", fn conn ->
      json(conn, 409, %{"errors" => %{"code" => "stale_version", "detail" => "x"}})
    end)

    Gaoxy.Test.expect_once(s, "POST", "/api/agent/connect", fn conn ->
      json(conn, 401, %{"errors" => %{"code" => "unauthorized"}})
    end)

    assert {:error, %{status: 409, code: "stale_version"}} =
             API.start(%{c | connection_id: "conn-1"}, "p-1", "a-1", 1, "v1.k.p")

    log =
      capture_log(fn ->
        assert {:error, %{status: 401, code: "unauthorized"}} = API.connect(c)
      end)

    refute log =~ @credential
  end

  test "transport failures are reported without a status", %{server: s, conn: c} do
    Gaoxy.Test.close(s)
    assert {:error, %{status: nil, code: "transport_error"}} = API.connect(c)
  end
end
