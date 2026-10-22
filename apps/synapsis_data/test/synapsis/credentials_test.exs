defmodule Synapsis.CredentialsTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.{Config.Store, Credentials}

  setup do
    clear_config_store(:provider)
    clear_config_store(:credential)
    previous = Application.get_env(:synapsis_data, :credential_change_callback)
    Application.delete_env(:synapsis_data, :credential_change_callback)

    on_exit(fn ->
      clear_config_store(:provider)
      clear_config_store(:credential)

      if previous,
        do: Application.put_env(:synapsis_data, :credential_change_callback, previous),
        else: Application.delete_env(:synapsis_data, :credential_change_callback)
    end)

    :ok
  end

  test "CRUD exposes safe metadata and persists only encrypted keys" do
    key = "credentials-test-secret-1234"
    assert {:ok, record} = Credentials.create(%{name: "Shared", key: key})
    assert record.name == "Shared"
    assert record.masked_key =~ "1234"
    refute inspect(record) =~ key
    refute Map.has_key?(record, :key)
    refute Map.has_key?(record, :key_encrypted)
    assert %DateTime{} = record.inserted_at
    assert %DateTime{} = record.updated_at
    assert {:ok, ^key} = Credentials.resolve(record.id)
    assert {:ok, ^record} = Credentials.get(record.id)
    assert {:ok, [^record]} = Credentials.list()
    persisted = File.read!(Store.file_path(:credential))
    assert persisted =~ "enc:v1:"
    refute persisted =~ key
    assert :ok = Store.reload(:credential)
    assert {:ok, ^record} = Credentials.get(record.id)
    assert {:ok, ^record} = Credentials.delete(record.id)
    assert {:error, :not_found} = Credentials.get(record.id)
    assert {:error, :credential_unavailable} = Credentials.resolve(record.id)
    assert {:error, :not_found} = Credentials.delete(record.id)
  end

  test "creation validates required fields and fully masks short keys" do
    assert {:error, %Ecto.Changeset{} = changeset} = Credentials.create(%{name: "", key: " "})
    assert %{name: ["can't be blank"], key: ["can't be blank"]} = errors_on(changeset)

    for key <- ["a", "short", "12345678"] do
      assert {:ok, record} = Credentials.create(%{name: "Short", key: key})
      refute record.masked_key =~ key
      assert String.length(record.masked_key) >= 4
    end
  end

  test "blank-key edits retain ciphertext while rotation keeps the UUID" do
    assert {:ok, record} = Credentials.create(%{name: "Before", key: "original-key-1234"})
    assert {:ok, original_raw} = Store.get(:credential, record.id)
    assert {:ok, edited} = Credentials.update(record.id, %{name: "After", key: "  "})
    assert edited.id == record.id
    assert edited.name == "After"
    assert {:ok, edited_raw} = Store.get(:credential, record.id)
    assert edited_raw["key_encrypted"] == original_raw["key_encrypted"]
    assert {:ok, rotated} = Credentials.update(record, %{key: "rotated-key-5678"})
    assert rotated.id == record.id
    assert {:ok, "rotated-key-5678"} = Credentials.resolve(record.id)
    assert {:ok, _} = Credentials.delete(record.id)
    assert {:error, :not_found} = Credentials.update(record, %{name: "Stale edit"})
    assert {:error, :not_found} = Store.get(:credential, record.id)
  end

  test "shared provider references protect all Store deletion and reference write paths" do
    {:ok, credential} = Credentials.create(%{name: "Shared", key: "shared-key-1234"})
    providers = for name <- ["first", "second"], do: provider(name, credential.id)
    refs = Enum.map(providers, &%{id: &1["id"], name: &1["name"]}) |> Enum.sort_by(& &1.id)
    assert Credentials.references(credential.id) == refs
    assert {:error, {:in_use, ^refs}} = Credentials.delete(credential.id)
    assert {:error, {:in_use, ^refs}} = Store.delete(:credential, credential.id)
    [first | _] = providers
    assert :ok = Store.delete(:provider, first["id"])
    assert {:ok, _} = Credentials.get(credential.id)
    for entry <- providers, do: Store.delete(:provider, entry["id"])
    assert {:ok, _} = Credentials.delete(credential.id)

    missing = Ecto.UUID.generate()

    assert {:error, {:missing_reference, :credential, ^missing}} =
             Store.put(:provider, %{"id" => Ecto.UUID.generate(), "credential_id" => missing})

    detached = provider("detached", nil)

    assert {:error, {:missing_reference, :credential, ^missing}} =
             Store.merge_existing(:provider, detached["id"], %{"credential_id" => missing})

    assert {:error, {:missing_reference, :credential, ^missing}} =
             Store.replace_existing(:provider, detached["id"], %{"credential_id" => missing})
  end

  test "provider attachment racing credential deletion cannot leave a dangling reference" do
    for iteration <- 1..8 do
      {:ok, record} = Credentials.create(%{name: "Race", key: "race-key-1234"})

      attrs = %{
        "id" => Ecto.UUID.generate(),
        "name" => "race-#{iteration}",
        "credential_id" => record.id
      }

      attach = Task.async(fn -> Store.put(:provider, attrs) end)
      delete = Task.async(fn -> Store.delete(:credential, record.id) end)
      attached = Task.await(attach)
      deleted = Task.await(delete)

      case attached do
        {:ok, _} ->
          assert {:error, {:in_use, _}} = deleted
          assert {:ok, _} = Credentials.resolve(record.id)
          assert :ok = Store.delete(:provider, attrs["id"])
          assert :ok = Store.delete(:credential, record.id)

        {:error, {:missing_reference, :credential, id}} ->
          assert id == record.id
          assert deleted == :ok
          assert {:error, :not_found} = Store.get(:provider, attrs["id"])
      end
    end
  end

  test "legacy imports are idempotent per provider and never overwrite a rotated key" do
    id = Ecto.UUID.generate()
    assert {:ok, first} = Credentials.ensure_legacy_provider_key(id, "Legacy", "same-secret-1234")

    assert {:ok, ^first} =
             Credentials.ensure_legacy_provider_key(id, "Legacy", "same-secret-1234")

    assert {:ok, rotated} = Credentials.update(first.id, %{key: "rotated-secret-5678"})

    assert {:ok, ^rotated} =
             Credentials.ensure_legacy_provider_key(id, "Legacy", "same-secret-1234")

    assert {:ok, "rotated-secret-5678"} = Credentials.resolve(first.id)

    assert {:ok, other} =
             Credentials.ensure_legacy_provider_key(
               Ecto.UUID.generate(),
               "Other",
               "same-secret-1234"
             )

    refute other.id == first.id
    assert {:ok, records} = Credentials.list()
    assert length(records) == 2
  end

  test "missing provider credentials exclude MCP and managed Skills from runtime" do
    {:ok, credential} = Credentials.create(%{name: "Runtime", key: "runtime-key-1234"})
    provider = provider("runtime", credential.id)
    {:ok, _} = Store.merge_existing(:provider, provider["id"], %{"enabled" => true})
    source_id = Ecto.UUID.generate()

    {:ok, _} =
      Store.put(:backplane, %{
        "id" => source_id,
        "provider_id" => provider["id"],
        "enabled" => true
      })

    on_exit(fn -> Store.delete(:backplane, source_id) end)
    mcp = %Synapsis.MCPConfig{provider_id: provider["id"], enabled: true, config: %{}}

    skill = %Synapsis.Skill{
      enabled: true,
      config_overrides: %{
        "managed_by" => "backplane",
        "backplane_source_id" => source_id,
        "backplane_available" => true
      }
    }

    assert Synapsis.MCPConfigs.runtime_available?(mcp)
    assert Synapsis.Skills.runtime_available?(skill)
    :ets.delete(:synapsis_config_credential, credential.id)
    refute Synapsis.MCPConfigs.runtime_available?(mcp)
    refute Synapsis.Skills.runtime_available?(skill)
  end

  test "successful mutations notify after unlocking and callback can read Store" do
    parent = self()

    Application.put_env(:synapsis_data, :credential_change_callback, fn ids ->
      send(
        parent,
        {:changed, ids, Process.get({Store, :write_lock_held}, false), Store.list(:credential)}
      )
    end)

    assert {:ok, record} = Credentials.create(%{name: "Notify", key: "notification-key"})
    id = record.id
    assert_receive {:changed, [^id], false, [_]}
    assert {:ok, _} = Credentials.update(id, %{name: "Rename"})
    assert_receive {:changed, [^id], false, [_]}
    assert {:error, %Ecto.Changeset{}} = Credentials.update(id, %{name: ""})
    refute_receive {:changed, _, _, _}
    assert {:ok, _} = Credentials.delete(id)
    assert_receive {:changed, [^id], false, []}
  end

  test "external reload detects changed encrypted contents with an unchanged timestamp" do
    {:ok, record} = Credentials.create(%{name: "External", key: "external-first-1234"})
    {:ok, raw} = Store.get(:credential, record.id)
    {:ok, version} = Credentials.version(record.id)
    {:ok, cipher} = Synapsis.Encrypted.Binary.dump("external-second-5678")
    changed = "enc:v1:" <> Base.encode64(cipher)
    path = Store.file_path(:credential)
    File.write!(path, String.replace(File.read!(path), raw["key_encrypted"], changed))
    parent = self()

    Application.put_env(
      :synapsis_data,
      :credential_change_callback,
      &send(parent, {:changed, &1})
    )

    assert :ok = Store.reload(:credential)
    assert_receive {:changed, ids}
    assert record.id in ids
    assert {:ok, "external-second-5678"} = Credentials.resolve(record.id)
    assert {:ok, next_version} = Credentials.version(record.id)
    refute next_version == version
    assert {:ok, reloaded} = Credentials.get(record.id)
    assert reloaded.updated_at == record.updated_at

    File.write!(path, "")
    assert :ok = Store.reload(:credential)
    assert_receive {:changed, removed_ids}
    assert record.id in removed_ids
    assert {:error, :credential_unavailable} = Credentials.version(record.id)
  end

  test "unchanged file reload does not invalidate clients and changed reload reports only changed IDs" do
    {:ok, first} = Credentials.create(%{name: "First", key: "reload-first-1234"})
    {:ok, second} = Credentials.create(%{name: "Second", key: "reload-second-5678"})
    parent = self()

    Application.put_env(
      :synapsis_data,
      :credential_change_callback,
      &send(parent, {:changed, &1})
    )

    assert :ok = Store.reload(:credential)
    refute_receive {:changed, _}
    {:ok, raw} = Store.get(:credential, first.id)
    path = Store.file_path(:credential)
    File.write!(path, String.replace(File.read!(path), raw["name"], "Renamed"))
    assert :ok = Store.reload(:credential)
    assert_receive {:changed, ids}
    assert ids == [first.id]
    refute second.id in ids
  end

  test "notification failure does not turn a persisted credential write into an API failure" do
    Application.put_env(:synapsis_data, :credential_change_callback, fn _ ->
      raise "notification unavailable"
    end)

    assert {:ok, credential} = Credentials.create(%{name: "Durable", key: "durable-key-1234"})
    assert {:ok, _} = Credentials.get(credential.id)
  end

  test "invalid encrypted keys fail closed without leaking stored contents" do
    {:ok, record} = Credentials.create(%{name: "Broken", key: "initial-key-1234"})

    assert {:ok, _} =
             Store.merge_existing(:credential, record.id, %{"key_encrypted" => "enc:v1:invalid"})

    assert {:error, :credential_unavailable} = Credentials.resolve(record.id)
    assert {:ok, safe} = Credentials.get(record.id)
    refute inspect(safe) =~ "enc:v1:invalid"
  end

  test "migration backups preserve existing files with private permissions" do
    {:ok, _} = Credentials.create(%{name: "Backup", key: "backup-key-1234"})
    provider("legacy", nil)
    providers = File.read!(Store.file_path(:provider))
    credentials = File.read!(Store.file_path(:credential))

    assert {:ok, backup_dir} = Store.backup([:provider, :credential], "credentials-migration")
    on_exit(fn -> File.rm_rf!(backup_dir) end)
    assert Path.dirname(backup_dir) == Path.join(Store.config_dir(), "backups")
    assert File.read!(Path.join(backup_dir, "providers.toml")) == providers
    assert File.read!(Path.join(backup_dir, "credentials.toml")) == credentials
    assert Bitwise.band(File.stat!(backup_dir).mode, 0o777) == 0o700

    for name <- ["providers.toml", "credentials.toml"] do
      assert Bitwise.band(File.stat!(Path.join(backup_dir, name)).mode, 0o777) == 0o600
    end

    assert {:error, :invalid_backup_request} = Store.backup([:unknown], "backup")
    assert {:error, :invalid_backup_request} = Store.backup([:provider], "../escape")
  end

  test "migration backup skips absent files and reports unreadable existing files" do
    assert {:ok, backup_dir} = Store.backup([:provider, :credential], "empty")
    on_exit(fn -> File.rm_rf!(backup_dir) end)
    assert File.ls!(backup_dir) == []
    provider("unreadable", nil)
    path = Store.file_path(:provider)
    File.chmod!(path, 0o000)
    on_exit(fn -> File.chmod(path, 0o600) end)
    assert {:error, _} = Store.backup([:provider, :credential], "unreadable")
  end

  defp provider(name, credential_id) do
    attrs = %{"id" => Ecto.UUID.generate(), "name" => name, "credential_id" => credential_id}
    assert {:ok, stored} = Store.put(:provider, attrs)
    stored
  end
end
