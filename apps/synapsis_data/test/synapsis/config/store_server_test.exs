defmodule Synapsis.Config.Store.ServerTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Config.Store

  setup do
    clear_config_store(:provider)
    on_exit(fn -> clear_config_store(:provider) end)
    :ok
  end

  test "failed persistence leaves the published entry unchanged" do
    original = %{"id" => "provider-1", "name" => "Original"}
    updated = %{"id" => "provider-1", "name" => "Updated"}

    assert {:ok, ^original} = Store.put(:provider, original)

    path = Store.file_path(:provider)
    File.chmod!(path, 0o400)

    assert {:error, _reason} = Store.put(:provider, updated)
    assert {:ok, ^original} = Store.get(:provider, "provider-1")
  end

  test "failed delete persistence keeps the entry in ETS and on disk" do
    provider = %{"id" => "provider-1", "name" => "Original"}

    assert {:ok, ^provider} = Store.put(:provider, provider)

    path = Store.file_path(:provider)
    persisted = File.read!(path)
    File.chmod!(path, 0o400)

    assert {:error, {:persist_failed, _reason}} = Store.delete(:provider, "provider-1")
    assert {:ok, ^provider} = Store.get(:provider, "provider-1")
    assert File.read!(path) == persisted
  end

  test "successful delete removes the entry from ETS and disk" do
    provider = %{"id" => "provider-1", "name" => "Original"}

    assert {:ok, ^provider} = Store.put(:provider, provider)
    assert :ok = Store.delete(:provider, "provider-1")
    assert {:error, :not_found} = Store.get(:provider, "provider-1")

    assert :ok = Store.reload(:provider)
    assert {:error, :not_found} = Store.get(:provider, "provider-1")
  end
end
