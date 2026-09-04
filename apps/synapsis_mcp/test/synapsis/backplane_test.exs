defmodule Synapsis.BackplaneTest do
  use ExUnit.Case, async: false

  alias Synapsis.Backplane
  alias Synapsis.Backplane.{Connection, Snapshot}
  alias Synapsis.Config.Store

  defmodule SyncStub do
    alias Synapsis.Backplane.Connection

    def run(id, opts) do
      send(opts[:test_pid], {:sync_run, id, opts})
      opts[:run_result] || Connection.get(id)
    end

    def status(_id), do: {:error, :stub_status}

    def set_available(id, available?, opts) do
      send(opts[:test_pid], {:set_available, id, available?, opts})
      opts[:availability_result] || Connection.get(id)
    end
  end

  defmodule ClientStub do
    alias Synapsis.Backplane.Snapshot

    def fetch_snapshot(connection, opts) do
      send(opts[:test_pid], {:discovered, connection.id, opts})

      Snapshot.normalize(connection, %{
        models: {:ok, [%{"id" => "coding"}]},
        skills: {:ok, [%{"id" => "review", "name" => "Review"}]},
        mcp_tools: {:ok, [%{"name" => "memory::search"}]}
      })
    end
  end

  setup do
    clear_store()
    on_exit(&clear_store/0)
    :ok
  end

  test "create immediately refreshes enabled connections and keeps them when refresh fails" do
    opts = [sync: SyncStub, sync_opts: [test_pid: self()]]

    assert {:ok, created} =
             Backplane.create(
               %{name: "created", endpoint: "https://backplane.example.test"},
               opts
             )

    assert_receive {:sync_run, created_id, _opts}
    assert created_id == created.id

    assert {:ok, degraded} =
             Backplane.create(
               %{name: "degraded", endpoint: "https://offline.example.test"},
               sync: SyncStub,
               sync_opts: [test_pid: self(), run_result: {:error, :offline}]
             )

    assert_receive {:sync_run, degraded_id, _opts}
    assert degraded_id == degraded.id
    assert {:ok, %{id: ^degraded_id}} = Connection.get(degraded_id)
  end

  test "disabled create skips refresh" do
    assert {:ok, connection} =
             Backplane.create(
               %{name: "disabled", endpoint: "https://backplane.example.test", enabled: false},
               sync: SyncStub,
               sync_opts: [test_pid: self()]
             )

    assert connection.enabled == false
    refute_receive {:sync_run, _, _}
  end

  test "update refreshes enabled source changes, disables before returning, and refreshes re-enable" do
    opts = [sync: SyncStub, sync_opts: [test_pid: self()]]

    assert {:ok, connection} =
             Backplane.create(
               %{name: "updated", endpoint: "https://old.example.test"},
               opts
             )

    assert_receive {:sync_run, connection_id, _opts}
    assert connection_id == connection.id

    assert {:ok, metadata_only} =
             Backplane.update(connection.id, %{metadata: %{"owner" => "ops"}}, opts)

    assert metadata_only.metadata == %{"owner" => "ops"}
    refute_receive {:sync_run, _, _}

    assert {:ok, renamed} = Backplane.update(connection.id, %{name: "renamed"}, opts)
    assert renamed.name == "renamed"
    assert_receive {:sync_run, ^connection_id, _opts}

    assert {:ok, changed} =
             Backplane.update(
               connection.id,
               %{
                 endpoint: "https://new.example.test",
                 credential: "replacement",
                 connection_options: %{"tenant" => "engineering"}
               },
               opts
             )

    assert changed.endpoint == "https://new.example.test"
    assert_receive {:sync_run, ^connection_id, _opts}

    assert {:ok, disabled} = Backplane.update(connection.id, %{enabled: false}, opts)
    assert disabled.enabled == false
    assert_receive {:set_available, ^connection_id, false, _opts}
    refute_receive {:sync_run, _, _}

    assert {:ok, enabled} = Backplane.update(connection.id, %{enabled: true}, opts)
    assert enabled.enabled == true
    assert_receive {:sync_run, ^connection_id, _opts}
  end

  test "retrying a disable reconciles capabilities after the first shutdown fails" do
    assert {:ok, connection} =
             Backplane.create(
               %{name: "disable-retry", endpoint: "https://backplane.example.test"},
               sync: SyncStub,
               sync_opts: [test_pid: self()]
             )

    assert_receive {:sync_run, connection_id, _opts}

    assert {:error, :mcp_stop_failed} =
             Backplane.update(connection.id, %{enabled: false},
               sync: SyncStub,
               sync_opts: [test_pid: self(), availability_result: {:error, :mcp_stop_failed}]
             )

    assert_receive {:set_available, ^connection_id, false, _opts}
    assert {:ok, %{enabled: false}} = Connection.get(connection.id)

    assert {:ok, %{enabled: false}} =
             Backplane.update(connection.id, %{enabled: false},
               sync: SyncStub,
               sync_opts: [test_pid: self()]
             )

    assert_receive {:set_available, ^connection_id, false, _opts}
  end

  test "create and update ignore forged sync-owned lifecycle fields" do
    forged_time = DateTime.utc_now()

    assert {:ok, created} =
             Backplane.create(%{
               "name" => "forgery-safe",
               "endpoint" => "https://backplane.example.test",
               "enabled" => false,
               "status" => "ready",
               "stale" => false,
               "counts" => %{"models" => 999},
               "artifacts" => %{"provider_id" => "forged"},
               "last_error" => "forged-error",
               "last_attempt_at" => forged_time
             })

    assert created.status == "never_synced"
    assert created.stale == true
    assert created.counts == %{}
    assert created.artifacts == %{}
    assert created.last_error == nil
    assert created.last_attempt_at == nil

    assert {:ok, updated} =
             Backplane.update(created.id, %{
               metadata: %{"owner" => "platform"},
               status: "ready",
               stale: false,
               counts: %{"models" => 999},
               artifacts: %{"provider_id" => "forged"},
               last_error: "forged-error",
               last_attempt_at: forged_time
             })

    assert updated.metadata == %{"owner" => "platform"}
    assert updated.status == "never_synced"
    assert updated.stale == true
    assert updated.counts == %{}
    assert updated.artifacts == %{}
    assert updated.last_error == nil
    assert updated.last_attempt_at == nil
    assert Connection.get(created.id) == {:ok, updated}
  end

  test "delete disables imported capabilities first and never cascades artifact records" do
    provider_id = Ecto.UUID.generate()

    assert {:ok, _provider} =
             Store.put(:provider, %{
               "id" => provider_id,
               "name" => "retained-provider",
               "type" => "openai",
               "base_url" => "https://provider.example.test"
             })

    assert {:ok, connection} =
             Backplane.create(
               %{
                 name: "deleted",
                 endpoint: "https://backplane.example.test",
                 enabled: false,
                 artifacts: %{"provider_id" => provider_id}
               },
               sync: SyncStub,
               sync_opts: [test_pid: self()]
             )

    assert :ok =
             Backplane.delete(connection.id,
               sync: SyncStub,
               sync_opts: [test_pid: self()]
             )

    assert_receive {:set_available, connection_id, false, _opts}
    assert connection_id == connection.id
    assert {:error, :not_found} = Connection.get(connection.id)
    assert {:ok, %{"id" => ^provider_id}} = Store.get(:provider, provider_id)
  end

  test "delete keeps the connection when capability shutdown fails" do
    assert {:ok, connection} =
             Backplane.create(
               %{name: "kept", endpoint: "https://backplane.example.test", enabled: false},
               sync: SyncStub,
               sync_opts: [test_pid: self()]
             )

    assert {:error, :mcp_stop_failed} =
             Backplane.delete(connection.id,
               sync: SyncStub,
               sync_opts: [test_pid: self(), availability_result: {:error, :mcp_stop_failed}]
             )

    assert_receive {:set_available, connection_id, false, _opts}
    assert connection_id == connection.id
    assert {:ok, %{id: ^connection_id}} = Connection.get(connection.id)
  end

  test "refresh rejects disabled connections without invoking sync" do
    assert {:ok, connection} =
             Backplane.create(%{
               name: "refresh-disabled",
               endpoint: "https://backplane.example.test",
               enabled: false
             })

    assert {:error, :connection_disabled} =
             Backplane.refresh(connection.id,
               sync: SyncStub,
               sync_opts: [test_pid: self()]
             )

    refute_receive {:sync_run, _, _}
  end

  test "test performs bounded snapshot discovery without importing and refresh delegates to Sync" do
    assert {:ok, connection} =
             Backplane.create(%{
               name: "tested",
               endpoint: "https://backplane.example.test",
               enabled: false
             })

    assert {:ok, result} =
             Backplane.test(connection.id,
               client: ClientStub,
               client_opts: [test_pid: self(), timeout: 321]
             )

    assert result == %{
             status: "ok",
             counts: %{"models" => 1, "skills" => 1, "tools" => 1},
             errors: %{}
           }

    assert_receive {:discovered, connection_id, client_opts}
    assert connection_id == connection.id
    assert client_opts[:timeout] == 321
    refute_receive {:sync_run, _, _}

    assert {:ok, enabled_connection} = Connection.update(connection, %{enabled: true})

    assert {:ok, refreshed} =
             Backplane.refresh(enabled_connection.id,
               sync: SyncStub,
               sync_opts: [test_pid: self()]
             )

    assert refreshed.id == connection.id
    assert_receive {:sync_run, ^connection_id, _opts}
    assert Backplane.list() == [refreshed]
    assert Backplane.get(connection.id) == {:ok, refreshed}
    assert Backplane.status(connection.id, sync: SyncStub) == {:error, :stub_status}
  end

  defp clear_store do
    for {type, table} <- [
          backplane: :synapsis_config_backplane,
          provider: :synapsis_config_provider
        ] do
      type |> Store.file_path() |> File.rm()

      if :ets.info(table) != :undefined, do: :ets.delete_all_objects(table)
    end

    :ok
  end
end
