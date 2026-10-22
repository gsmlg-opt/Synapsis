defmodule Synapsis.ProviderCredentialsTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.{Config.Store, Credentials, Models, Providers}
  alias Synapsis.Provider.{Adapter, Registry}

  setup do
    for type <- [:provider, :credential, :model], do: clear_config_store(type)
    :ok
  end

  test "legacy raw-key input persists a reference, blank edits preserve it, and clear detaches" do
    {:ok, provider} =
      Providers.create(%{
        name: "manual",
        type: "openai",
        api_key_encrypted: "original-secret-1234"
      })

    assert is_binary(provider.credential_id)
    assert {:ok, raw} = Store.get(:provider, provider.id)
    assert raw["credential_id"] == provider.credential_id
    refute raw["api_key_encrypted"]
    assert {:ok, edited} = Providers.update(provider.id, %{api_key_encrypted: ""})
    assert edited.credential_id == provider.credential_id
    assert edited.api_key_encrypted == "original-secret-1234"
    assert {:ok, cleared} = Providers.clear_api_key(provider.id)
    assert is_nil(cleared.credential_id)
    assert is_nil(cleared.api_key_encrypted)
    assert {:ok, _} = Credentials.get(provider.credential_id)
  end

  test "shared credentials rotate together, reject legacy mutation, and survive provider deletion" do
    {:ok, credential} = Credentials.create(%{name: "Shared", key: "original-shared-1234"})

    {:ok, first} =
      Providers.create(%{name: "first", type: "openai", credential_id: credential.id})

    {:ok, second} =
      Providers.create(%{name: "second", type: "openai", credential_id: credential.id})

    assert {:error, changeset} = Providers.authenticate(first.id, "unexpected-shared-edit")
    assert errors_on(changeset).api_key_encrypted != []
    assert {:ok, _} = Credentials.update(credential.id, %{key: "rotated-shared-5678"})

    for provider <- [first, second] do
      assert {:ok, current} = Providers.get(provider.id)
      assert current.api_key_encrypted == "rotated-shared-5678"
      assert {:ok, %{api_key: "rotated-shared-5678"}} = Registry.get(provider.name)
    end

    assert {:ok, _} = Providers.delete(first.id)
    assert {:ok, _} = Credentials.get(credential.id)
    assert {:error, {:in_use, [_]}} = Credentials.delete(credential.id)
  end

  test "missing explicit references cannot fall back to inline secrets or environment" do
    id = Ecto.UUID.generate()

    :ets.insert(
      :synapsis_config_provider,
      {id,
       %{
         "id" => id,
         "name" => "unavailable",
         "type" => "openai",
         "enabled" => true,
         "credential_id" => Ecto.UUID.generate(),
         "api_key_encrypted" => "stale-secret"
       }}
    )

    assert {:ok, provider} = Providers.get(id)
    refute Providers.runtime_available?(provider)
    assert {:error, :provider_unavailable} = Providers.runtime_config(provider.name)

    assert {:error, %Ecto.Changeset{}} =
             Providers.create(%{
               name: "bad-reference",
               type: "openai",
               credential_id: Ecto.UUID.generate()
             })
  end

  test "migration preserves identities, backs up encrypted records and separates identical legacy keys" do
    first = legacy_provider!("legacy-first")
    second = legacy_provider!("legacy-second")
    {:ok, model} = Models.create(%{provider_id: first, model: "configured"})
    assert {:ok, 2} = Providers.migrate_credentials()
    assert {:ok, migrated} = Providers.get(first)
    assert {:ok, other} = Providers.get(second)
    assert migrated.credential_id != other.credential_id
    assert {:ok, ^model} = Models.get(model.id)
    assert {:ok, raw} = Store.get(:provider, first)
    refute raw["api_key_encrypted"]
    assert {:ok, 0} = Providers.migrate_credentials()
    assert {:ok, credentials} = Credentials.list()
    assert length(credentials) == 2

    backups =
      Path.wildcard(
        Path.join([
          Path.dirname(Store.file_path(:provider)),
          "backups",
          "credentials-migration-*",
          "providers.toml"
        ])
      )

    assert backups != []
    assert Enum.any?(backups, &(File.read!(&1) =~ first))

    for path <- backups do
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      refute File.read!(path) =~ "same-legacy-secret-1234"
    end
  end

  test "migration retry reuses a previously saved and rotated credential" do
    id = legacy_provider!("interrupted")

    {:ok, credential} =
      Credentials.ensure_legacy_provider_key(id, "interrupted", "same-legacy-secret-1234")

    {:ok, _} = Credentials.update(credential.id, %{key: "rotated-during-retry-5678"})
    assert {:ok, 1} = Providers.migrate_credentials()
    assert {:ok, provider} = Providers.get(id)
    assert provider.credential_id == credential.id
    assert provider.api_key_encrypted == "rotated-during-retry-5678"
    assert {:ok, [_]} = Credentials.list()
  end

  test "ordinary edits of a legacy provider retain its key through protected migration" do
    id = legacy_provider!("legacy-edit")
    assert {:ok, provider} = Providers.update(id, %{base_url: "http://localhost:4220/v1"})
    assert provider.api_key_encrypted == "same-legacy-secret-1234"
    assert is_binary(provider.credential_id)
    assert {:ok, raw} = Store.get(:provider, id)
    refute raw["api_key_encrypted"]
  end

  test "migration failure retains the inline key and resumes without another credential" do
    id = legacy_provider!("failed-replacement")
    {:ok, original} = Store.get(:provider, id)
    path = Store.file_path(:provider)
    File.chmod!(path, 0o400)
    on_exit(fn -> File.chmod(path, 0o600) end)
    assert {:error, {:credential_migration_failed, ^id, _}} = Providers.migrate_credentials()
    assert {:ok, ^original} = Store.get(:provider, id)
    assert {:ok, [credential]} = Credentials.list()
    File.chmod!(path, 0o600)
    assert {:ok, 1} = Providers.migrate_credentials()
    assert {:ok, migrated} = Providers.get(id)
    assert migrated.credential_id == credential.id
    assert {:ok, [_]} = Credentials.list()
  end

  test "a failed protected backup prevents all migration writes" do
    id = legacy_provider!("failed-backup")
    {:ok, original} = Store.get(:provider, id)
    path = Store.file_path(:provider)
    File.chmod!(path, 0o000)
    on_exit(fn -> File.chmod(path, 0o600) end)
    assert {:error, _} = Providers.migrate_credentials()
    assert {:ok, ^original} = Store.get(:provider, id)
    assert {:ok, []} = Credentials.list()
    File.chmod!(path, 0o600)
  end

  test "startup reports the failing migration provider without logging its key" do
    id = legacy_provider!("startup-failure")
    path = Store.file_path(:provider)
    File.chmod!(path, 0o400)
    on_exit(fn -> File.chmod(path, 0o600) end)

    log =
      ExUnit.CaptureLog.capture_log([metadata: [:provider_id, :provider_ids, :reason]], fn ->
        assert :ok = Providers.load_all_into_registry()
      end)

    assert log =~ "provider_credential_migration_failed"
    assert log =~ id
    refute log =~ "same-legacy-secret-1234"
  end

  test "late model discovery cannot publish results from before credential rotation" do
    bypass = Bypass.open()
    observer = self()

    Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
      send(observer, {:discovery_started, self()})
      receive do: (:release -> :ok)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{data: [%{id: "obsolete-model"}]}))
    end)

    {:ok, provider} =
      Providers.create(%{
        name: "discovery-rotation",
        type: "openai",
        base_url: "http://localhost:#{bypass.port}/v1",
        api_key_encrypted: "old-discovery-key"
      })

    task = Task.async(fn -> Providers.refresh_models(provider.id) end)
    assert_receive {:discovery_started, request}, 2_000
    {:ok, _} = Credentials.update(provider.credential_id, %{key: "new-discovery-key"})
    send(request, :release)
    assert {:error, :provider_changed} = Task.await(task, 3_000)
    assert {:ok, current} = Providers.get(provider.id)
    assert Providers.cached_models(current) == []
  end

  test "OAuth and explicit no-credential providers stay outside manual-key migration" do
    id =
      legacy_provider!("oauth", %{
        "auth_mode" => "oauth_device",
        "oauth_tokens" => %{"access_token" => "oauth-access"}
      })

    {:ok, keyless} = Providers.create(%{name: "keyless", type: "openai"})
    assert {:ok, 0} = Providers.migrate_credentials()
    assert {:ok, oauth} = Providers.get(id)
    assert is_nil(oauth.credential_id)
    assert Providers.oauth_provider?(oauth)
    assert Providers.runtime_available?(keyless)
    assert {:ok, []} = Credentials.list()
  end

  test "an already-open runtime config resolves rotated authentication before completion and stream" do
    bypass = Bypass.open()

    {:ok, provider} =
      Providers.create(%{
        name: "open-session",
        type: "openai",
        base_url: "http://localhost:#{bypass.port}",
        api_key_encrypted: "old-session-secret"
      })

    {:ok, _} = Models.create(%{provider_id: provider.id, model: "fixture-model"})
    {:ok, config} = Providers.runtime_config(provider.name)
    assert config.api_key == "old-session-secret"
    {:ok, _} = Credentials.update(provider.credential_id, %{key: "new-session-secret"})

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer new-session-secret"]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{choices: [%{message: %{content: "fresh"}, finish_reason: "stop"}]})
      )
    end)

    assert {:ok, "fresh"} =
             Adapter.complete(%{"model" => "fixture-model", "messages" => []}, config)

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer new-session-secret"]

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        "data: {\"choices\":[{\"delta\":{\"content\":\"fresh\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
      )
    end)

    assert {:ok, handle} = Adapter.stream(%{"model" => "fixture-model", "messages" => []}, config)
    assert_receive :provider_done, 3_000
    Process.demonitor(handle.ref, [:flush])
    :ets.delete(:synapsis_config_credential, provider.credential_id)

    assert {:error, :provider_unavailable} =
             Adapter.complete(%{"model" => "fixture-model"}, config)

    assert {:error, :provider_unavailable} = Adapter.stream(%{"model" => "fixture-model"}, config)
  end

  defp legacy_provider!(name, config \\ %{}) do
    {:ok, encrypted} = Synapsis.Encrypted.Binary.dump("same-legacy-secret-1234")
    id = Ecto.UUID.generate()

    {:ok, _} =
      Store.put(:provider, %{
        "id" => id,
        "name" => name,
        "type" => "openai",
        "enabled" => true,
        "config" => config,
        "api_key_encrypted" => "enc:v1:" <> Base.encode64(encrypted)
      })

    id
  end
end
