defmodule SynapsisSamgita.InboundTest do
  use ExUnit.Case, async: false
  alias Synapsis.Samgita.{Devices, Inbox}
  alias SynapsisSamgita.{Inbound, Events}

  @event %{
    "schema_version" => "1.0",
    "event_id" => "evt-inbound",
    "delivery_attempt_id" => "delivery-1",
    "created_at" => "2026-11-18T00:00:00Z",
    "correlation_id" => "corr-1",
    "type" => "manual.triggered",
    "project_ref" => "project-1",
    "payload" => %{}
  }

  setup do
    for device <- Devices.list(), do: Inbound.disconnect(device["id"])
    Synapsis.DataCase.clear_config_store(:samgita)
    Synapsis.DataCase.clear_coord("coord/samgita/inbox/")
    Events.subscribe_devices()

    listener =
      start_supervised!(
        {Gaoxy.HTTP,
         id: :inbound_fixture,
         plug: {SynapsisSamgita.Test.IngressHost, [test: self()]},
         ip: {127, 0, 0, 1},
         port: 0}
      )

    %{local: {:ok, {_, port}}} = Gaoxy.info(listener, :inbound_fixture)

    on_exit(fn ->
      for device <- Devices.list(), do: Inbound.disconnect(device["id"])
      Synapsis.DataCase.clear_config_store(:samgita)
      Synapsis.DataCase.clear_coord("coord/samgita/inbox/")
    end)

    %{url: "http://127.0.0.1:#{port}"}
  end

  test "pending confirmation initializes the same socket and acknowledges durable scoped events",
       %{url: url} do
    {:ok, device} = Devices.select("agent", "one", "One", "synapsis", url)
    id = device["id"]
    {:ok, _} = Inbound.connect(id)

    assert_receive {:bootstrap, socket, %{"type" => "agent/connect", "device_token" => token}},
                   3_000

    assert {:ok, ^token} = Devices.resolve_token(id)
    assert_receive {:samgita_device_status, %{device_id: ^id, state: :pending}}, 3_000
    assert {:error, %{code: "not_connected"}} = Inbound.api_conn(id)
    approve(socket, "agent-one", 1)
    assert_receive {:native_ready, ^socket}, 3_000
    assert_receive {:samgita_device_status, %{device_id: ^id, state: :connected}}, 3_000

    assert {:ok, %{agent_id: "agent-one", connection_id: "connection-1", credential: ^token}} =
             Inbound.api_conn(id)

    send(socket, {:request, "project/event.receive", %{"event" => @event}, "operation-1"})

    assert_receive {:host_response, ^socket, "project/event.receive",
                    {:ok, %{"acceptance" => "durable"}}, %{"command_id" => "operation-1"}},
                   3_000

    assert {:ok, %{"device_id" => ^id}} = Inbox.get(@event["event_id"], id)
    assert {:error, :not_found} = Inbox.get(@event["event_id"])

    send(
      socket,
      {:request, "project/event.status", %{"event_id" => @event["event_id"]}, "status-op"}
    )

    assert_receive {:host_response, ^socket, "project/event.status",
                    {:ok, %{"processing_status" => "pending"}}, _},
                   3_000
  end

  test "reconnect reuses persisted token and original Agent while changing generation", %{
    url: url
  } do
    {:ok, device} = Devices.select("agent", "one", "One", "synapsis", url)
    id = device["id"]
    {:ok, _} = Inbound.connect(id)
    assert_receive {:bootstrap, first, %{"device_token" => token}}, 3_000
    approve(first, "agent-one", 1)
    assert_receive {:samgita_device_status, %{device_id: ^id, state: :connected}}, 3_000
    send(first, {:close, 1001})
    assert_receive {:bootstrap, second, %{"device_token" => ^token}}, 4_000
    refute second == first
    approve(second, "agent-one", 2)

    assert_receive {:samgita_device_status, %{device_id: ^id, state: :connected, generation: 2}},
                   3_000

    assert {:ok, %{"agent_id" => "agent-one"}} = Devices.get(id)
    assert {:ok, %{state: :disconnected}} = Inbound.disconnect(id)
    assert :ok = Synapsis.Config.Store.reload(:samgita)
    assert {:ok, _} = Inbound.connect(id)
    assert_receive {:bootstrap, third, %{"device_token" => ^token}}, 3_000
    approve(third, "agent-one", 3)

    assert_receive {:samgita_device_status, %{device_id: ^id, state: :connected, generation: 3}},
                   3_000
  end

  test "identities remain independent and ambiguous policy close stops automatic reconnect", %{
    url: url
  } do
    {:ok, one} = Devices.select("agent", "one", "One", "synapsis", url)
    {:ok, two} = Devices.select("local_agent", "two", "Two", "sigma", url)
    {:ok, _} = Inbound.connect(one["id"])
    assert_receive {:bootstrap, first, %{"device_token" => token_one}}, 3_000
    {:ok, _} = Inbound.connect(two["id"])
    assert_receive {:bootstrap, second, %{"device_token" => token_two}}, 3_000
    refute token_one == token_two
    approve(first, "agent-one", 1)
    approve(second, "agent-two", 1)
    one_id = one["id"]
    two_id = two["id"]
    assert_receive {:samgita_device_status, %{device_id: ^one_id, state: :connected}}, 3_000
    assert_receive {:samgita_device_status, %{device_id: ^two_id, state: :connected}}, 3_000
    send(first, {:close, 1008})

    assert_receive {:samgita_device_status,
                    %{device_id: ^one_id, state: :error, last_error: "policy_closed"}},
                   3_000

    assert %{state: :connected} = Inbound.status(two_id)
    assert {:ok, %{"enabled" => false}} = Devices.get(one_id)
    refute_receive {:bootstrap, _, _}, 1_200
    assert {:ok, %{state: :forgotten}} = Inbound.forget(one_id)
    assert {:error, :device_forgotten} = Inbound.connect(one_id)
  end

  test "native initialization has a bounded deadline", %{url: url} do
    {:ok, device} = Devices.select("agent", "one", "One", "synapsis", url)
    id = device["id"]
    {:ok, _} = Inbound.connect(id)
    assert_receive {:bootstrap, socket, _}, 3_000
    send(socket, :silence_native)
    approve(socket, "agent-one", 1)
    assert_receive {:samgita_device_status, %{device_id: ^id, state: :initializing}}, 3_000

    assert_receive {:samgita_device_status,
                    %{device_id: ^id, state: :offline, last_error: "initialize_timeout"}},
                   6_000

    assert {:error, %{code: "not_connected"}} = Inbound.api_conn(id)
  end

  defmodule BlockingHandler do
    def handle_request(_, _, _, state) do
      test = :persistent_term.get({__MODULE__, :test})
      send(test, {:handler_running, self()})

      receive do
        :continue -> {:error, SamgitaProtocol.Error.new("handler_error"), state}
      end
    end
  end

  test "native initialization rejects a different connection UUID", %{url: url} do
    {:ok, device} = Devices.select("agent", "one", "One", "synapsis", url)
    id = device["id"]
    {:ok, _} = Inbound.connect(id)
    assert_receive {:bootstrap, socket, _}, 3_000
    conn = %{"id" => "connection-1", "agent_id" => "agent-one", "generation" => 1}
    send(socket, {:approve, conn, "different-connection"})

    assert_receive {:samgita_device_status,
                    %{device_id: ^id, state: :offline, last_error: "connection_mismatch"}},
                   3_000

    assert {:error, %{code: "not_connected"}} = Inbound.api_conn(id)
  end

  test "handler tasks stop when their socket owner is killed or shut down", %{url: url} do
    :persistent_term.put({BlockingHandler, :test}, self())
    on_exit(fn -> :persistent_term.erase({BlockingHandler, :test}) end)

    for reason <- [:kill, :shutdown] do
      {:ok, device} = Devices.select("agent", Atom.to_string(reason), "One", "synapsis", url)

      spec =
        Supervisor.child_spec(
          {SynapsisSamgita.Inbound.Client, device_id: device["id"], handler: BlockingHandler},
          restart: :temporary
        )

      owner = start_supervised!(spec)
      assert_receive {:bootstrap, socket, _}, 3_000
      approve(socket, "agent-one", 1)
      assert_receive {:native_ready, ^socket}, 3_000

      send(
        socket,
        {:request, "project/event.status", %{"event_id" => "blocked"}, "blocked-operation"}
      )

      assert_receive {:handler_running, handler}, 3_000
      monitor = Process.monitor(handler)

      if reason == :kill,
        do: Process.exit(owner, :kill),
        else: stop_supervised!(SynapsisSamgita.Inbound.Client)

      assert_receive {:DOWN, ^monitor, :process, ^handler, _}, 2_000
    end
  end

  defp approve(socket, agent_id, generation) do
    send(
      socket,
      {:approve,
       %{
         "id" => "connection-#{generation}",
         "agent_id" => agent_id,
         "generation" => generation,
         "expires_at" => "2099-01-01T00:00:00Z"
       }}
    )
  end
end
