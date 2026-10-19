defmodule Synapsis.Backplane.ConnectionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Synapsis.Backplane.Connection
  alias Synapsis.Config.Store

  setup do
    clear_store()
    on_exit(&clear_store/0)
    :ok
  end

  test "provider-linked sources share current credentials without persisting a copy" do
    {:ok, provider} =
      Synapsis.Providers.create(%{
        name: "linked-#{System.unique_integer([:positive])}",
        type: "openai",
        base_url: "https://backplane.example.test/prefix/v1",
        api_key_encrypted: "first"
      })

    on_exit(fn -> Synapsis.Providers.delete(provider.id) end)
    assert {:ok, source} = Connection.create(%{name: "linked", provider_id: provider.id})
    assert source.provider_id == provider.id
    assert {:ok, runtime} = Connection.runtime(source)
    assert runtime.endpoint == "https://backplane.example.test/prefix"
    assert runtime.credential == "first"
    {:ok, _} = Synapsis.Providers.update(provider.id, %{api_key_encrypted: "rotated"})
    assert {:ok, rotated} = Connection.runtime(source)
    assert rotated.credential == "rotated"
    assert rotated.id == source.id
    assert {:ok, stored} = Store.get(:backplane, source.id)
    refute Map.has_key?(stored, "credential_encrypted")
    {:ok, _} = Synapsis.Providers.update(provider.id, %{api_key_encrypted: nil})
    assert {:ok, cleared} = Connection.runtime(source)
    assert cleared.credential == nil
    {:ok, _} = Synapsis.Providers.update(provider.id, %{enabled: false})
    assert {:error, :provider_unavailable} = Connection.runtime(source)
  end

  test "rejected linked source edits leave the shared provider unchanged" do
    {:ok, provider} =
      Synapsis.Providers.create(%{
        name: "atomic-#{System.unique_integer([:positive])}",
        type: "openai",
        base_url: "https://original.example.test/v1",
        api_key_encrypted: "original"
      })

    on_exit(fn -> Synapsis.Providers.delete(provider.id) end)
    {:ok, source} = Connection.create(%{name: "atomic", provider_id: provider.id})
    {:ok, _} = Connection.create(%{name: "taken", endpoint: source.endpoint})
    {:ok, original_provider} = Synapsis.Providers.get(provider.id)

    for {invalid, reason} <- [
          {%{name: "invalid name"}, :invalid_name},
          {%{id: "invalid"}, :invalid_id},
          {%{connection_options: []}, :invalid_connection_options},
          {%{name: "taken"}, :name_taken},
          {%{endpoint: "file:///tmp"}, :invalid_endpoint},
          {%{credential: 123}, :invalid_credential}
        ] do
      attrs =
        Map.merge(%{endpoint: "https://changed.example.test", credential: "changed"}, invalid)

      assert {:error, ^reason} = Connection.update(source, attrs)
      assert {:ok, ^original_provider} = Synapsis.Providers.get(provider.id)
      assert {:ok, ^source} = Connection.get(source.id)
    end
  end

  test "failed linked source persistence restores the provider endpoint and credential" do
    {:ok, provider} =
      Synapsis.Providers.create(%{
        name: "rollback-#{System.unique_integer([:positive])}",
        type: "openai",
        base_url: "https://original.example.test/v1",
        api_key_encrypted: "original"
      })

    on_exit(fn -> Synapsis.Providers.delete(provider.id) end)
    {:ok, source} = Connection.create(%{name: "rollback", provider_id: provider.id})
    path = Store.file_path(:backplane)
    File.chmod!(path, 0o400)
    on_exit(fn -> File.chmod(path, 0o600) end)

    assert {:error, {:persist_failed, _}} =
             Connection.update(source, %{
               endpoint: "https://changed.example.test",
               credential: "changed"
             })

    assert {:ok, restored} = Synapsis.Providers.get(provider.id)
    assert restored.base_url == provider.base_url
    assert restored.api_key_encrypted == provider.api_key_encrypted
    assert {:ok, ^source} = Connection.get(source.id)
  end

  test "persists the complete connection model and redacts the credential" do
    connection_options = %{
      "headers.with.dots" => %{
        "x-api-key" => "value",
        "nested values" => [true, nil, %{"quoted\"key" => 1}]
      }
    }

    metadata = %{
      "owner.name" => "ops",
      "release annotations" => %{"#channel" => "stable"}
    }

    counts = %{"models.total" => 2, "by source" => %{"provider.primary" => 1}}

    assert {:ok, connection} =
             Connection.create(%{
               name: "primary",
               endpoint: "https://backplane.example.test/",
               credential: "top-secret",
               connection_options: connection_options,
               sync_on_start: false,
               enabled: false,
               last_success_at: "2026-09-04T01:02:03Z",
               last_attempt_at: "2026-09-04T01:03:03Z",
               last_error: "offline",
               metadata: metadata,
               source_revision: String.duplicate("a", 64),
               stale: true,
               status: "degraded",
               counts: counts,
               artifacts: %{"provider_id" => "provider-1"},
               unavailable: ["skills"]
             })

    assert connection.endpoint == "https://backplane.example.test"
    assert connection.base_url == connection.endpoint
    assert connection.connection_options == connection_options
    assert connection.sync_on_start == false
    assert connection.last_success_at == "2026-09-04T01:02:03Z"
    assert connection.last_attempt_at == "2026-09-04T01:03:03Z"
    assert connection.metadata == metadata
    assert connection.counts == counts
    assert connection.stale == true
    assert connection.credential_configured == true

    assert :ok = Store.reload(:backplane)
    assert {:ok, loaded} = Connection.get(connection.id)
    assert loaded == connection

    assert {:ok, stored} = Store.get(:backplane, connection.id)
    assert stored["endpoint"] == connection.endpoint
    assert stored["base_url"] == connection.endpoint
    assert Jason.decode!(stored["connection_options_json"]) == connection_options
    assert Jason.decode!(stored["metadata_json"]) == metadata
    assert Jason.decode!(stored["counts_json"]) == counts
    assert Jason.decode!(stored["artifacts_json"]) == %{"provider_id" => "provider-1"}
    refute Map.has_key?(stored, "connection_options")
    refute Map.has_key?(stored, "metadata")
    refute Map.has_key?(stored, "counts")
    refute Map.has_key?(stored, "artifacts")
    refute Map.has_key?(stored, "credential")
    refute inspect(Connection.redacted(connection)) =~ "top-secret"
    refute File.read!(Store.file_path(:backplane)) =~ "top-secret"
  end

  test "loads legacy base_url-only records with current defaults" do
    id = Ecto.UUID.generate()

    assert {:ok, _stored} =
             Store.put(:backplane, %{
               "id" => id,
               "name" => "legacy",
               "base_url" => "https://legacy.example.test/",
               "enabled" => true,
               "connection_options" => %{"tenant" => "legacy"},
               "metadata" => %{"owner" => "ops"},
               "counts" => %{"models" => 2}
             })

    assert :ok = Store.reload(:backplane)
    assert {:ok, connection} = Connection.get(id)
    assert connection.endpoint == "https://legacy.example.test"
    assert connection.base_url == connection.endpoint
    assert connection.connection_options == %{"tenant" => "legacy"}
    assert connection.sync_on_start == true
    assert connection.metadata == %{"owner" => "ops"}
    assert connection.counts == %{"models" => 2}
    assert connection.stale == true
  end

  test "list skips malformed persisted connections without exposing credentials" do
    assert {:ok, valid} =
             Connection.create(%{
               name: "valid",
               endpoint: "https://valid.example.test",
               credential: "valid-secret"
             })

    malformed_id = Ecto.UUID.generate()
    malformed_secret = "malformed-secret-must-not-be-logged"

    assert {:ok, _stored} =
             Store.put(:backplane, %{
               "id" => malformed_id,
               "name" => "malformed",
               "endpoint" => "https://malformed.example.test",
               "artifacts_json" => "{",
               "credential" => malformed_secret
             })

    assert :ok = Store.reload(:backplane)

    assert {:error, :invalid_artifacts} = Connection.get(malformed_id)

    parent = self()

    log =
      capture_log(fn ->
        send(parent, {:connections, Connection.list()})
      end)

    assert_receive {:connections, [^valid]}
    assert log =~ "backplane_connection_invalid"
    assert log =~ "invalid_artifacts"
    refute log =~ malformed_secret
    refute log =~ "valid-secret"
  end

  test "a legacy base_url update changes the canonical endpoint" do
    assert {:ok, connection} =
             Connection.create(%{name: "rename-endpoint", endpoint: "https://old.example.test"})

    assert {:ok, updated} =
             Connection.update(connection, %{base_url: "https://new.example.test/"})

    assert updated.endpoint == "https://new.example.test"
    assert updated.base_url == updated.endpoint
    assert {:ok, ^updated} = Connection.get(connection.id)
  end

  test "validates ids, endpoints, maps, booleans, and persisted status fields" do
    base = %{name: "invalid", endpoint: "https://backplane.example.test"}

    assert {:error, :invalid_id} = Connection.new(Map.put(base, :id, "not-a-uuid"))
    assert {:error, :invalid_endpoint} = Connection.new(Map.put(base, :endpoint, "file:///tmp"))

    assert {:error, :invalid_endpoint} =
             Connection.new(Map.put(base, :endpoint, "https://token@backplane.example.test"))

    assert {:error, :invalid_endpoint} =
             Connection.new(
               Map.put(base, :endpoint, "https://backplane.example.test?token=secret")
             )

    assert {:error, :invalid_connection_options} =
             Connection.new(Map.put(base, :connection_options, []))

    assert {:error, :invalid_metadata} = Connection.new(Map.put(base, :metadata, []))
    assert {:error, :invalid_counts} = Connection.new(Map.put(base, :counts, []))
    assert {:error, :invalid_artifacts} = Connection.new(Map.put(base, :artifacts, []))

    assert {:error, :invalid_metadata} =
             Connection.new(Map.put(base, :metadata, %{{:not, :json} => "value"}))

    assert {:error, :invalid_enabled} = Connection.new(Map.put(base, :enabled, "yes"))

    assert {:error, :invalid_sync_on_start} =
             Connection.new(Map.put(base, :sync_on_start, "yes"))

    assert {:error, :invalid_stale} = Connection.new(Map.put(base, :stale, "yes"))

    assert {:error, :invalid_unavailable} =
             Connection.new(Map.put(base, :unavailable, ["models", :skills]))
  end

  defp clear_store do
    :backplane |> Store.file_path() |> File.rm()

    if :ets.info(:synapsis_config_backplane) != :undefined do
      :ets.delete_all_objects(:synapsis_config_backplane)
    end

    :ok
  end
end
