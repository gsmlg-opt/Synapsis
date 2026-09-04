defmodule Synapsis.Backplane.EventsTest do
  use ExUnit.Case, async: false

  alias Synapsis.Backplane.{Connection, Snapshot, Sync}
  alias Synapsis.Config.Store

  defmodule MockMCPRuntime do
    def restart(_config), do: :ok
    def stop(_name), do: :ok
  end

  setup do
    for type <- [:backplane, :provider, :skill, :mcp] do
      path =
        if type == :backplane,
          do: Path.join(Store.config_dir(), "backplanes.toml"),
          else: Store.file_path(type)

      File.rm(path)
      table = :"synapsis_config_#{type}"
      if :ets.info(table) != :undefined, do: :ets.delete_all_objects(table)
    end

    Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:daemon")
    :ok
  end

  test "publishes started, completed, and capabilities events around persisted success" do
    {:ok, connection} =
      Connection.create(%{name: "events", endpoint: "https://backplane.example.test"})

    {:ok, snapshot} =
      Snapshot.normalize(
        connection,
        %{
          models: {:ok, [%{"id" => "coding"}]},
          skills: {:ok, []},
          mcp_tools: {:ok, []}
        },
        fetched_at: "2026-09-04T12:00:00Z"
      )

    client = fn _connection, _opts -> {:ok, snapshot} end

    assert {:ok, persisted} =
             Sync.run(connection.id,
               client: client,
               mcp_runtime: MockMCPRuntime,
               now: fn -> ~U[2026-09-04 12:00:00Z] end
             )

    assert_receive {:agent_daemon_event, %{event: "backplane.sync.started"} = started}
    assert started.connection_id == connection.id
    assert started.status == "syncing"

    assert_receive {:agent_daemon_event, %{event: "backplane.sync.completed"} = completed}
    assert completed.status == "ready"
    assert completed.source_revision == persisted.source_revision

    assert_receive {:agent_daemon_event, %{event: "backplane.capabilities.updated"} = updated}

    assert updated.counts == %{"models" => 1, "skills" => 0, "tools" => 0}
    assert {:ok, stored} = Connection.get(connection.id)
    assert stored.status == completed.status
    assert stored.source_revision == completed.source_revision

    assert {:ok, repeated} =
             Sync.run(connection.id,
               client: client,
               mcp_runtime: MockMCPRuntime,
               now: fn -> ~U[2026-09-04 12:05:00Z] end
             )

    assert repeated.source_revision == persisted.source_revision
    assert_receive {:agent_daemon_event, %{event: "backplane.sync.started"}}
    assert_receive {:agent_daemon_event, %{event: "backplane.sync.completed"}}
    refute_receive {:agent_daemon_event, %{event: "backplane.capabilities.updated"}}
  end

  test "publishes a bounded redacted failed event after persisting failure" do
    secret = "never-print-this"

    {:ok, connection} =
      Connection.create(%{
        name: "event-failure",
        endpoint: "https://backplane.example.test",
        credential: secret
      })

    client = fn _connection, _opts ->
      {:error, {:unauthorized, secret <> String.duplicate("x", 800)}}
    end

    assert {:ok, persisted} = Sync.run(connection.id, client: client)
    assert persisted.status == "degraded"

    assert_receive {:agent_daemon_event, %{event: "backplane.sync.started"}}
    assert_receive {:agent_daemon_event, %{event: "backplane.sync.failed"} = failed}
    refute inspect(failed) =~ secret
    assert failed.status == "degraded"
    assert byte_size(failed.error) <= 500
    assert failed.error =~ "[REDACTED]"
    refute_receive {:agent_daemon_event, %{event: "backplane.capabilities.updated"}}
    assert {:ok, %{status: "degraded"}} = Connection.get(connection.id)
  end

  test "does not publish capabilities updated when every surface preserves last-known-good state" do
    {:ok, connection} =
      Connection.create(%{name: "no-op", endpoint: "https://backplane.example.test"})

    {:ok, snapshot} =
      Snapshot.normalize(
        connection,
        %{
          models: {:error, :models_unavailable},
          skills: {:error, :skills_unavailable},
          mcp_tools: {:error, :tools_unavailable}
        },
        fetched_at: "2026-09-04T12:00:00Z"
      )

    assert {:ok, %{status: "degraded"}} =
             Sync.run(connection.id,
               client: fn _connection, _opts -> {:ok, snapshot} end,
               mcp_runtime: MockMCPRuntime
             )

    assert_receive {:agent_daemon_event, %{event: "backplane.sync.started"}}
    assert_receive {:agent_daemon_event, %{event: "backplane.sync.failed"}}
    refute_receive {:agent_daemon_event, %{event: "backplane.capabilities.updated"}}
  end

  test "truncates long multibyte errors at a valid UTF-8 byte boundary" do
    {:ok, connection} =
      Connection.create(%{name: "unicode", endpoint: "https://backplane.example.test"})

    message = String.duplicate("界", 800)
    client = fn _connection, _opts -> {:error, {:upstream, message}} end

    assert {:ok, %{status: "degraded"} = persisted} = Sync.run(connection.id, client: client)
    assert String.valid?(persisted.last_error)
    assert byte_size(persisted.last_error) <= 500
    assert_receive {:agent_daemon_event, %{event: "backplane.sync.started"}}
    assert_receive {:agent_daemon_event, %{event: "backplane.sync.failed", error: error}}
    assert String.valid?(error)
    assert byte_size(error) <= 500
  end

  test "publishes an availability capability update only after persistence" do
    {:ok, connection} =
      Connection.create(%{name: "availability-event", endpoint: "https://backplane.example.test"})

    {:ok, snapshot} =
      Snapshot.normalize(
        connection,
        %{
          models: {:ok, [%{"id" => "coding"}]},
          skills: {:ok, []},
          mcp_tools: {:ok, []}
        },
        fetched_at: "2026-09-04T12:00:00Z"
      )

    assert {:ok, _ready} =
             Sync.run(connection.id,
               client: fn _connection, _opts -> {:ok, snapshot} end,
               mcp_runtime: MockMCPRuntime
             )

    assert_receive {:agent_daemon_event, %{event: "backplane.sync.started"}}
    assert_receive {:agent_daemon_event, %{event: "backplane.sync.completed"}}
    assert_receive {:agent_daemon_event, %{event: "backplane.capabilities.updated"}}

    assert {:ok, persisted} =
             Sync.set_available(connection.id, false, mcp_runtime: MockMCPRuntime)

    assert_receive {:agent_daemon_event,
                    %{event: "backplane.capabilities.updated", status: "degraded"} = event}

    assert {:ok, stored} = Connection.get(connection.id)
    assert stored.status == event.status
    assert stored.status == persisted.status
  end
end
