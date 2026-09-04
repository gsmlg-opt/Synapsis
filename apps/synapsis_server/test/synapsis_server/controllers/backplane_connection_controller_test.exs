defmodule SynapsisServer.BackplaneConnectionControllerTest do
  use SynapsisServer.ConnCase, async: false

  alias Synapsis.Config.Store

  setup do
    for type <- [:backplane, :provider, :skill, :mcp] do
      type |> Store.list() |> Enum.each(&Store.delete(type, &1["id"]))
    end

    :ok
  end

  test "connection CRUD, PATCH, and status expose the lifecycle fields but never credentials", %{
    conn: conn
  } do
    assert %{"data" => []} = conn |> get("/api/backplane/connections") |> json_response(200)

    assert %{"data" => created} =
             conn
             |> post("/api/backplane/connections", %{
               "name" => "team",
               "base_url" => "https://backplane.example.test",
               "credential" => "connection-secret",
               "enabled" => false,
               "sync_on_start" => true,
               "connection_options" => %{"tenant" => "engineering"},
               "metadata" => %{"owner" => "ops"}
             })
             |> json_response(201)

    assert created["credential_configured"] == true
    assert created["endpoint"] == "https://backplane.example.test"
    assert created["sync_on_start"] == true
    assert created["stale"] == true
    assert created["connection_options"] == %{"tenant" => "engineering"}
    assert created["metadata"] == %{"owner" => "ops"}
    refute Map.has_key?(created, "credential")
    refute inspect(created) =~ "connection-secret"

    assert %{"data" => updated} =
             conn
             |> patch("/api/backplane/connections/#{created["id"]}", %{"sync_on_start" => false})
             |> json_response(200)

    assert updated["enabled"] == false
    assert updated["sync_on_start"] == false

    assert %{"data" => put_updated} =
             conn
             |> put("/api/backplane/connections/#{created["id"]}", %{
               "metadata" => %{"owner" => "platform"}
             })
             |> json_response(200)

    assert put_updated["metadata"] == %{"owner" => "platform"}

    assert %{"data" => status} =
             conn
             |> get("/api/backplane/connections/#{created["id"]}/status")
             |> json_response(200)

    assert status["status"] == "never_synced"
    assert status["last_attempt_at"] == nil
    assert status["last_success_at"] == nil
    assert status["source_revision"] == nil
    assert status["counts"] == %{}
    assert status["last_error"] == nil
    refute Map.has_key?(status, "credential")

    assert response(delete(conn, "/api/backplane/connections/#{created["id"]}"), 204)
    assert %{"data" => []} = conn |> get("/api/backplane/connections") |> json_response(200)
  end

  test "test and refresh use the audited Backplane endpoints", %{conn: conn} do
    bypass = Bypass.open()
    stub_backplane(bypass)

    assert %{"data" => connection} =
             conn
             |> post("/api/backplane/connections", %{
               "name" => "local",
               "base_url" => "http://127.0.0.1:#{bypass.port}"
             })
             |> json_response(201)

    assert %{"data" => %{"status" => "ok", "counts" => counts}} =
             conn
             |> post("/api/backplane/connections/#{connection["id"]}/test")
             |> json_response(200)

    assert counts == %{"models" => 1, "skills" => 0, "tools" => 0}

    assert %{"data" => refreshed} =
             conn
             |> post("/api/backplane/connections/#{connection["id"]}/refresh")
             |> json_response(200)

    assert refreshed["status"] == "ready"
    assert refreshed["counts"] == counts
  end

  test "invalid and missing connections return stable HTTP errors", %{conn: conn} do
    assert %{"error" => "invalid base URL"} =
             conn
             |> post("/api/backplane/connections", %{"name" => "bad", "base_url" => "file:///tmp"})
             |> json_response(422)

    missing = Ecto.UUID.generate()

    assert %{"error" => "connection not found"} =
             conn
             |> get("/api/backplane/connections/#{missing}/status")
             |> json_response(404)
  end

  test "refresh returns conflict for a disabled connection", %{conn: conn} do
    assert %{"data" => connection} =
             conn
             |> post("/api/backplane/connections", %{
               "name" => "disabled-refresh",
               "base_url" => "https://backplane.example.test",
               "enabled" => false
             })
             |> json_response(201)

    assert %{"error" => "connection disabled"} =
             conn
             |> post("/api/backplane/connections/#{connection["id"]}/refresh")
             |> json_response(409)
  end

  defp stub_backplane(bypass) do
    Bypass.stub(bypass, "GET", "/v1/models", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"data" => [%{"id" => "coding"}]}))
    end)

    Bypass.stub(bypass, "GET", "/skills", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"data" => []}))
    end)

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      case request["method"] do
        "initialize" ->
          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "controller-session")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => request["id"],
              "result" => %{
                "protocolVersion" => "2025-03-26",
                "capabilities" => %{"tools" => %{}},
                "serverInfo" => %{"name" => "controller-test", "version" => "1"}
              }
            })
          )

        "notifications/initialized" ->
          Plug.Conn.resp(conn, 202, "")

        "tools/list" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => request["id"],
              "result" => %{"tools" => []}
            })
          )
      end
    end)
  end
end
