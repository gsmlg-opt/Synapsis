defmodule SynapsisServer.BackplaneConnectionControllerTest do
  use SynapsisServer.ConnCase, async: false

  alias Synapsis.Config.Store

  setup do
    for type <- [:backplane, :provider, :skill, :mcp] do
      type |> Store.list() |> Enum.each(&Store.delete(type, &1["id"]))
    end

    :ok
  end

  test "connection CRUD and status never expose credentials", %{conn: conn} do
    assert %{"data" => []} = conn |> get("/api/backplane/connections") |> json_response(200)

    assert %{"data" => created} =
             conn
             |> post("/api/backplane/connections", %{
               "name" => "team",
               "base_url" => "https://backplane.example.test",
               "credential" => "connection-secret"
             })
             |> json_response(201)

    assert created["credential_configured"] == true
    refute Map.has_key?(created, "credential")
    refute inspect(created) =~ "connection-secret"

    assert %{"data" => updated} =
             conn
             |> put("/api/backplane/connections/#{created["id"]}", %{"enabled" => false})
             |> json_response(200)

    assert updated["enabled"] == false

    assert %{"data" => status} =
             conn
             |> get("/api/backplane/connections/#{created["id"]}/status")
             |> json_response(200)

    assert status["status"] == "never_synced"
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

      result =
        case request["method"] do
          "initialize" -> %{"protocolVersion" => "2025-03-26", "capabilities" => %{}}
          "tools/list" -> %{"tools" => []}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
      )
    end)
  end
end
