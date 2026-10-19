defmodule Synapsis.Backplane.ProviderSourceTest do
  use ExUnit.Case, async: false
  alias Synapsis.Backplane.{Connection, Snapshot, Sync}
  alias Synapsis.{Config.Store, MCPConfigs, Providers}

  defmodule Runtime do
    def restart(_), do: :ok
    def restart_for_reconciliation(_), do: :ok
    def stop(_), do: :ok
  end

  setup do
    Enum.each([:backplane, :mcp, :provider, :model], &Synapsis.DataCase.clear_config_store/1)

    on_exit(fn ->
      Enum.each([:backplane, :mcp, :provider, :model], &Synapsis.DataCase.clear_config_store/1)
    end)

    :ok
  end

  test "default MCP endpoint follows provider changes while explicit overrides survive snapshot and sync" do
    {:ok, provider} =
      Providers.create(%{
        name: "source",
        type: "openai",
        base_url: "https://old.example.test/prefix/v1",
        config: %{"preset" => "backplane"}
      })

    {:ok, config} = Synapsis.Backplane.select_mcp_provider(provider.id)
    assert {:streamable_http, before} = Synapsis.MCP.Transport.build(config)
    assert before[:base_url] == "https://old.example.test"
    assert before[:mcp_path] == "/prefix/mcp"
    {:ok, _} = Providers.update(provider.id, %{base_url: "https://new.example.test/gateway/v1"})

    assert {:streamable_http, after_change} =
             Synapsis.MCP.Transport.build(MCPConfigs.get(config.id))

    assert after_change[:base_url] == "https://new.example.test"
    assert after_change[:mcp_path] == "/gateway/mcp"
    override = "https://override.example.test/custom/mcp"
    {:ok, overridden} = Synapsis.Backplane.select_mcp_provider(provider.id, override)
    assert overridden.id == config.id
    [source] = Connection.list()
    assert {:ok, runtime} = Connection.runtime(source)
    assert Connection.mcp_url(runtime) == override

    {:ok, snapshot} =
      Snapshot.normalize(runtime, %{
        models: {:ok, []},
        skills: {:ok, []},
        mcp_tools: {:ok, [%{"name" => "fresh"}]}
      })

    assert hd(snapshot.mcp_servers).metadata["endpoint"] == override

    assert {:ok, refreshed} =
             Sync.run(source.id, client: fn _, _ -> {:ok, snapshot} end, mcp_runtime: Runtime)

    assert refreshed.id == source.id
    assert MCPConfigs.get(config.id).url == override
    assert MCPConfigs.get(config.id).provider_id == provider.id

    assert [%{"external_id" => "fresh"}] =
             MCPConfigs.get(config.id).config["backplane_tools"]
  end

  test "skill-only source discovery contacts only the Skill Protocol catalog" do
    bypass = Bypass.open()

    {:ok, provider} =
      Providers.create(%{
        name: "skill-only",
        type: "openai",
        base_url: "http://localhost:#{bypass.port}/v1",
        api_key_encrypted: "shared",
        config: %{"preset" => "backplane"}
      })

    {:ok, source} = Synapsis.Backplane.select_provider(provider.id, "skills")

    Bypass.expect_once(bypass, "GET", "/skill-protocol/v1/catalog", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer shared"]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"protocol_version" => "1", "data" => [], "next_cursor" => nil})
      )
    end)

    assert {:ok, refreshed} = Sync.run(source.id, mcp_runtime: Runtime)
    assert refreshed.status == "ready"
    assert MCPConfigs.list() == []
  end

  test "migration uses ownership markers and refuses differing credentials" do
    {:ok, source} =
      Connection.create(%{
        name: "legacy",
        endpoint: "https://source.example.test",
        credential: "source-secret",
        source_revision: "revision"
      })

    {:ok, unrelated} =
      Providers.create(%{
        name: "legacy",
        type: "openai",
        base_url: "https://source.example.test/v1",
        api_key_encrypted: "source-secret"
      })

    assert {:ok, unchanged} = Connection.migrate_provider(source)
    assert unchanged.provider_id == nil

    {:ok, owned} =
      Providers.create(%{
        name: "owned",
        type: "openai",
        base_url: "https://source.example.test/v1",
        api_key_encrypted: "different",
        config: %{
          "managed_by" => "backplane",
          "source" => "backplane",
          "kind" => "provider",
          "backplane_source_id" => source.id
        }
      })

    assert {:error, :provider_credential_conflict} = Connection.migrate_provider(source)
    assert {:ok, conflict} = Connection.get(source.id)
    assert conflict.last_error == "provider_credential_conflict"
    observer = self()

    {:ok, snapshot} =
      Snapshot.normalize(source, %{
        models: {:ok, [%{"id" => "model"}]},
        skills: {:ok, []},
        mcp_tools: {:ok, []}
      })

    client = fn _, _ ->
      send(observer, :conflicted_source_fetched)
      {:ok, snapshot}
    end

    assert {:error, :provider_credential_conflict} =
             Synapsis.Backplane.refresh(source.id,
               sync_opts: [client: client, mcp_runtime: Runtime]
             )

    assert {:error, :provider_credential_conflict} = Connection.runtime(source)
    refute_receive :conflicted_source_fetched, 20
    assert {:ok, still_conflicted} = Connection.get(source.id)
    assert still_conflicted.metadata["runtime_blocked_surfaces"] == ~w(models skills tools)
    {:ok, _} = Connection.update(still_conflicted, %{last_error: "later startup failure"})

    assert {:error, :provider_credential_conflict} =
             Sync.run(source.id, client: client, mcp_runtime: Runtime)

    refute_receive :conflicted_source_fetched, 20
    assert {:ok, untouched} = Providers.get(owned.id)
    assert untouched.api_key_encrypted == "different"
    {:ok, _} = Providers.update(owned.id, %{api_key_encrypted: "source-secret"})
    assert {:ok, linked} = Connection.migrate_provider(source)
    assert linked.provider_id == owned.id
    refute linked.provider_id == unrelated.id
    assert linked.id == source.id
    assert linked.source_revision == "revision"
    assert {:ok, runtime} = Connection.runtime(linked)
    assert runtime.credential == "source-secret"
    assert {:ok, _} = Sync.run(source.id, client: client, mcp_runtime: Runtime)
    assert_receive :conflicted_source_fetched
    {:ok, _} = Providers.update(owned.id, %{api_key_encrypted: "current"})
    assert {:ok, current_runtime} = Connection.runtime(source)
    assert current_runtime.credential == "current"
    assert {:ok, stored} = Store.get(:backplane, source.id)
    refute Map.has_key?(stored, "credential_encrypted")
  end

  test "refresh rejects fresh legacy ownership conflicts before discovery or migration" do
    for {credentials, reason} <- [
          {["different"], :provider_credential_conflict},
          {["source-secret", "source-secret"], :provider_ownership_conflict}
        ] do
      {:ok, source} =
        Connection.create(%{
          name: "fresh-#{System.unique_integer([:positive])}",
          endpoint: "https://source.example.test",
          credential: "source-secret",
          sync_on_start: false
        })

      providers =
        for credential <- credentials do
          {:ok, provider} =
            Providers.create(%{
              name: "owned-#{System.unique_integer([:positive])}",
              type: "openai",
              base_url: "https://provider.example.test/v1",
              api_key_encrypted: credential,
              config: %{
                "managed_by" => "backplane",
                "source" => "backplane",
                "kind" => "provider",
                "external_id" => "openai-compatible",
                "backplane_source_id" => source.id
              }
            })

          provider
        end

      observer = self()

      {:ok, snapshot} =
        Snapshot.normalize(source, %{
          models: {:ok, [%{"id" => "model"}]},
          skills: {:ok, []},
          mcp_tools: {:ok, []}
        })

      client = fn _, _ ->
        send(observer, :fresh_conflict_fetched)
        {:ok, snapshot}
      end

      refute Map.has_key?(source.metadata, "provider_migration_error")

      assert {:error, ^reason} =
               Synapsis.Backplane.refresh(source.id,
                 sync_opts: [client: client, mcp_runtime: Runtime]
               )

      refute_receive :fresh_conflict_fetched, 20

      for provider <- providers do
        assert {:ok, current} = Providers.get(provider.id)
        assert current.api_key_encrypted == provider.api_key_encrypted
        assert current.base_url == provider.base_url
      end

      assert {:ok, blocked} = Connection.get(source.id)
      assert blocked.metadata["provider_migration_error"] == to_string(reason)
      assert blocked.provider_id == nil

      assert {:error, ^reason} =
               Connection.update(blocked, %{endpoint: "https://edited.example.test"})
    end
  end

  test "matching ownership resolves the current provider endpoint before first migration" do
    {:ok, source} =
      Connection.create(%{
        name: "matching-owner",
        endpoint: "https://old.example.test",
        credential: "shared",
        sync_on_start: false
      })

    {:ok, snapshot} =
      Snapshot.normalize(source, %{
        models: {:ok, [%{"id" => "model"}]},
        skills: {:ok, []},
        mcp_tools: {:ok, []}
      })

    {:ok, synced} =
      Sync.run(source.id, client: fn _, _ -> {:ok, snapshot} end, mcp_runtime: Runtime)

    provider_id = synced.artifacts["provider_id"]

    {:ok, _} =
      Providers.update(provider_id, %{base_url: "https://current.example.test/prefix/v1"})

    assert {:ok, runtime} = Connection.runtime(source)
    assert runtime.provider_id == provider_id
    assert runtime.endpoint == "https://current.example.test/prefix"
    observer = self()

    client = fn current, _ ->
      send(observer, {:provider_endpoint_fetched, current.endpoint})
      {:ok, snapshot}
    end

    assert {:ok, _} =
             Synapsis.Backplane.refresh(source.id,
               sync_opts: [client: client, mcp_runtime: Runtime]
             )

    assert_receive {:provider_endpoint_fetched, "https://current.example.test/prefix"}
    assert {:ok, provider} = Providers.get(provider_id)
    assert provider.base_url == "https://current.example.test/prefix/v1"
  end

  test "stale legacy callers resolve current endpoint and credential before provider migration" do
    {:ok, source} =
      Connection.create(%{
        name: "legacy-current",
        endpoint: "https://old.example.test",
        credential: "old-secret"
      })

    {:ok, updated} =
      Connection.update(source, %{
        endpoint: "https://current.example.test",
        credential: "current-secret"
      })

    assert updated.provider_id == nil
    assert {:ok, current} = Connection.runtime(source)
    assert current.endpoint == updated.endpoint
    assert current.credential == updated.credential
    assert {:ok, "current-secret"} = Connection.credential(source)
  end

  test "explicit legacy credential edits link the owned provider before rotating shared connection values" do
    {:ok, source} =
      Connection.create(%{
        name: "explicit-rotation",
        endpoint: "https://source.example.test",
        credential: "original"
      })

    {:ok, snapshot} =
      Snapshot.normalize(source, %{
        models: {:ok, [%{"id" => "model"}]},
        skills: {:ok, []},
        mcp_tools: {:ok, []}
      })

    {:ok, synced} =
      Sync.run(source.id, client: fn _, _ -> {:ok, snapshot} end, mcp_runtime: Runtime)

    assert {:ok, updated} =
             Connection.update(synced, %{
               credential: "rotated",
               endpoint: "https://updated.example.test"
             })

    assert updated.provider_id == synced.artifacts["provider_id"]
    assert {:ok, provider} = Providers.get(updated.provider_id)
    assert provider.api_key_encrypted == "rotated"
    assert provider.base_url == "https://updated.example.test/v1"

    assert {:ok, _} =
             Sync.run(source.id, client: fn _, _ -> {:ok, snapshot} end, mcp_runtime: Runtime)
  end

  test "linked managed model availability follows refreshed snapshots without replacing provider or model edits" do
    {:ok, source} =
      Connection.create(%{
        name: "model-owner",
        endpoint: "https://source.example.test",
        credential: "original"
      })

    snapshot = fn models ->
      Snapshot.normalize(source, %{models: {:ok, models}, skills: {:ok, []}, mcp_tools: {:ok, []}})
    end

    {:ok, initial} = snapshot.([%{"id" => "tracked"}])

    {:ok, synced} =
      Sync.run(source.id, client: fn _, _ -> {:ok, initial} end, mcp_runtime: Runtime)

    {:ok, linked} = Connection.migrate_provider(synced)
    {:ok, provider} = Providers.get(linked.provider_id)

    {:ok, model} =
      Synapsis.Models.create(%{
        provider_id: provider.id,
        model: "tracked",
        name: "Custom",
        context_window: 12345
      })

    {:ok, provider} =
      Providers.update(provider.id, %{
        base_url: "https://edited.example.test/custom/v1",
        api_key_encrypted: "rotated",
        config: Map.put(provider.config, "custom", "preserved")
      })

    assert Providers.model_runtime_available?(provider, "tracked")

    {:ok, skill_only} =
      Connection.update(linked, %{connection_options: %{"enabled_surfaces" => ["skills"]}})

    {:ok, disabled} = snapshot.([%{"id" => "tracked", "enabled" => false}])

    assert {:ok, _} =
             Sync.run(source.id, client: fn _, _ -> {:ok, disabled} end, mcp_runtime: Runtime)

    assert {:ok, after_skills} = Providers.get(provider.id)
    assert after_skills.config == provider.config
    assert Providers.model_runtime_available?(after_skills, "tracked")
    {:ok, _} = Connection.update(skill_only, %{connection_options: %{}})

    for models <- [[%{"id" => "tracked", "enabled" => false}], []] do
      {:ok, next} = snapshot.(models)

      assert {:ok, _} =
               Sync.run(source.id, client: fn _, _ -> {:ok, next} end, mcp_runtime: Runtime)

      assert {:ok, current} = Providers.get(provider.id)
      refute Providers.model_runtime_available?(current, "tracked")
      assert current.base_url == provider.base_url
      assert current.api_key_encrypted == provider.api_key_encrypted
      assert current.config["custom"] == "preserved"
      assert {:ok, ^model} = Synapsis.Models.get(model.id)
    end
  end
end
