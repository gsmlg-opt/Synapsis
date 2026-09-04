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
end
