defmodule Synapsis.Samgita.DevicesTest do
  use Synapsis.DataCase
  alias Synapsis.Samgita.Devices
  alias Synapsis.Config.Store

  setup do
    clear_config_store(:samgita)
    :ok
  end

  test "selection persists independent encrypted tokens and reselect never rotates one" do
    {:ok, first} = Devices.select("agent", "a", "First", "synapsis", "https://samgita.example")

    {:ok, second} =
      Devices.select("local_agent", "b", "Second", "codex", "https://samgita.example")

    {:ok, token} = Devices.resolve_token(first["id"])
    {:ok, other} = Devices.resolve_token(second["id"])
    refute token == other
    assert byte_size(token) == 43
    refute inspect(first) =~ token
    refute File.read!(Store.file_path(:samgita)) =~ token
    assert :ok = Store.reload(:samgita)

    assert {:ok, ^first} =
             Devices.select("agent", "a", "First", "synapsis", "https://samgita.example")

    assert {:ok, ^token} = Devices.resolve_token(first["id"])
  end

  test "disable preserves memory; forget cannot silently create a replacement" do
    {:ok, device} = Devices.select("agent", "a", "First", "synapsis", "http://127.0.0.1:1")
    id = device["id"]
    {:ok, token} = Devices.resolve_token(id)
    assert {:ok, %{"enabled" => false}} = Devices.disable(id)
    assert {:ok, %{"enabled" => true}} = Devices.enable(id)
    assert {:ok, ^token} = Devices.resolve_token(id)
    assert {:ok, %{"forgotten" => true, "enabled" => false}} = Devices.forget(id)
    assert {:error, :credential_unavailable} = Devices.resolve_token(id)

    assert {:error, :device_forgotten} =
             Devices.select("agent", "a", "First", "synapsis", "http://127.0.0.1:1")
  end

  test "connection generations retain the confirmed Agent UUID" do
    {:ok, device} = Devices.select("agent", "a", "First", "synapsis", "http://127.0.0.1:1")
    conn = %{"id" => "c1", "agent_id" => "a1", "generation" => 1}
    assert {:ok, %{"agent_id" => "a1"}} = Devices.record_connection(device["id"], conn)

    assert {:ok, %{"generation" => 2}} =
             Devices.record_connection(device["id"], %{conn | "id" => "c2", "generation" => 2})

    assert {:error, :identity_changed} =
             Devices.record_connection(device["id"], %{conn | "agent_id" => "other"})
  end

  test "base URLs reject credentials, query strings and non-root paths" do
    for url <- [
          "http://secret@localhost",
          "https://host/?token=secret",
          "http://host/path",
          "ftp://host"
        ] do
      assert {:error, :invalid_url} = Devices.select("agent", "a", "First", "synapsis", url)
    end
  end
end
