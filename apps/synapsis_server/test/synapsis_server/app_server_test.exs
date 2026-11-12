defmodule SynapsisServer.AppServerTest do
  use ExUnit.Case, async: false

  alias SamgitaProtocolWebSocket.Client

  @event %{
    "schema_version" => "1.0",
    "event_id" => "evt-ws1",
    "delivery_attempt_id" => "att-1",
    "created_at" => "2026-11-12T00:00:00Z",
    "correlation_id" => "c-1",
    "type" => "task.updated",
    "project_ref" => "p-1",
    "payload" => %{}
  }

  setup do
    Synapsis.DataCase.clear_config_store(:samgita)
    Synapsis.DataCase.clear_coord("coord/samgita/inbox/")
    on_exit(fn -> Synapsis.DataCase.clear_coord("coord/samgita/inbox/") end)

    options =
      SynapsisServer.Endpoint.config(:http)
      |> Keyword.merge(
        id: __MODULE__,
        plug: {SynapsisServer.Endpoint, []},
        ip: {127, 0, 0, 1},
        port: 0
      )

    listener = start_supervised!({Gaoxy.HTTP, options})
    %{local: {:ok, {_address, port}}} = Gaoxy.info(listener, __MODULE__)
    {:ok, token} = Synapsis.SamgitaConfig.rotate_secret(:app_server_token)
    %{url: "ws://127.0.0.1:#{port}/app-server", port: port, token: token}
  end

  test "an authenticated Samgita client initializes and delivers an event", %{
    url: url,
    token: token
  } do
    {:ok, client} =
      Client.connect(url, token: token, capabilities: ["project_events.v1"], allow_insecure: true)

    assert {:ok, %{"capabilities" => ["project_events.v1"]}} =
             Client.request(client, "connection/initialize", %{
               "versions" => ["1.0"],
               "capabilities" => ["project_events.v1"],
               "required_capabilities" => ["project_events.v1"]
             })

    assert {:ok, %{"acceptance" => "durable", "processing_status" => "pending"}} =
             Client.request(client, "project/event.receive", %{"event" => @event},
               command_id: "cmd-1"
             )

    assert {:ok, %{"processing_status" => "pending"}} =
             Client.request(client, "project/event.status", %{"event_id" => "evt-ws1"})
  end

  test "a wrong token is rejected", %{url: url} do
    assert {:error, %{details: %{"http_status" => 401}}} =
             Client.connect(url,
               token: String.duplicate("x", 43),
               capabilities: ["project_events.v1"],
               allow_insecure: true
             )
  end

  test "no configured token rejects every client", %{url: url, token: token} do
    Synapsis.DataCase.clear_config_store(:samgita)

    assert {:error, %{details: %{"http_status" => 401}}} =
             Client.connect(url,
               token: token,
               capabilities: ["project_events.v1"],
               allow_insecure: true
             )
  end

  test "other routes still reach the router", %{port: port} do
    {:ok, response} = Req.get("http://127.0.0.1:#{port}/api/health", retry: false)
    assert response.status in [200, 503]
    assert is_map(response.body)
  end
end
