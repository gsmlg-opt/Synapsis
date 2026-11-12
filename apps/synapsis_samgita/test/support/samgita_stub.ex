defmodule SynapsisSamgita.Test.SamgitaStub do
  @moduledoc false

  def json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  def body(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(raw), conn}
  end

  @doc "Configure SamgitaConfig to point at a Gaoxy.Test server and return it."
  def configure! do
    server = Gaoxy.Test.open()
    :ok = Synapsis.SamgitaConfig.put_base_url(Gaoxy.Test.url(server))
    {:ok, _} = Synapsis.SamgitaConfig.rotate_secret(:agent_credential)
    server
  end

  def stub_connect(server) do
    Gaoxy.Test.stub(server, "POST", "/api/agent/connect", fn conn ->
      json(conn, 201, %{
        "data" => %{
          "id" => "conn-1",
          "agent_id" => "agent-1",
          "generation" => 1,
          "expires_at" => "2026-11-13T00:00:00Z"
        }
      })
    end)
  end
end
