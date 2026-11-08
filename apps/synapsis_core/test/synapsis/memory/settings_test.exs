defmodule Synapsis.Memory.SettingsTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Config.Store
  alias Synapsis.Memory.Settings

  setup do
    clear_config_store(:memory)
    Store.reload(:memory)

    on_exit(fn ->
      clear_config_store(:memory)
      Store.reload(:memory)
    end)

    :ok
  end

  test "missing configuration defaults to workspace without creating a file" do
    refute File.exists?(Store.file_path(:memory))
    assert {:ok, %{"backend" => "workspace", "host_agent" => host}} = Settings.get()

    assert host == %{
             "enabled" => false,
             "endpoint" => "http://127.0.0.1:4222",
             "agent_id" => "synapsis"
           }

    assert {:error, :disabled} = Settings.host_source()
    refute Settings.host_enabled?()
    refute File.exists?(Store.file_path(:memory))
  end

  test "explicit enable survives TOML reload and disabling retains connection settings" do
    config = config(true)
    assert {:ok, ^config} = Settings.save(config)
    assert :ok = Store.reload(:memory)
    assert {:ok, ^config} = Settings.get()

    assert {:ok,
            %{id: "backplane-host", endpoint: "http://127.0.0.1:4223", agent_id: "test-agent"}} =
             Settings.host_source()

    disabled = put_in(config, ["host_agent", "enabled"], false)
    assert {:ok, ^disabled} = Settings.save(disabled)
    assert {:error, :disabled} = Settings.host_source()
    assert {:ok, ^disabled} = Settings.get()
  end

  test "rejects nonboolean switches, arbitrary selectors, backend and remote endpoints" do
    for invalid <- [
          put_in(config(false), ["host_agent", "enabled"], "true"),
          put_in(config(false), ["host_agent", "endpoint"], "https://example.com"),
          put_in(config(false), ["host_agent", "agent_id"], "../other"),
          put_in(config(false), ["backend"], "host_agent"),
          put_in(config(false), ["host_agent", "project_id"], "other"),
          Map.put(config(false), "shared", true)
        ] do
      assert {:error, :invalid_config} = Settings.save(invalid)
    end

    refute File.exists?(Store.file_path(:memory))
  end

  test "malformed reloaded configuration fails closed instead of preserving enablement" do
    assert {:ok, _} = Settings.save(config(true))
    File.write!(Store.file_path(:memory), "invalid = [")
    assert {:error, _} = Store.reload(:memory)
    assert {:error, :invalid_config} = Settings.get()
    assert {:error, :invalid_config} = Settings.host_source()
    refute Settings.host_enabled?()
  end

  test "unreadable configuration fails closed" do
    path = Store.file_path(:memory)
    File.mkdir_p!(path)
    assert {:error, _} = Store.reload(:memory)
    assert {:error, :unavailable} = Settings.host_source()
    File.rmdir!(path)
  end

  test "exact get facade requires enablement and rechecks the entire persisted source" do
    id = Ecto.UUID.generate()
    assert {:error, :disabled} = Synapsis.Memory.get_host(id)
    assert {:ok, _} = Settings.save(config(true))
    assert {:ok, source} = Settings.host_source()

    for {field, value} <- [id: "other", endpoint: "http://127.0.0.1:4222", agent_id: "other"] do
      assert {:error, :source_changed} =
               Synapsis.Memory.get_host(id,
                 source: Map.put(source, field, value)
               )
    end

    for opts <- [%{}, nil, [source: source, source: source], [source: source, project: "other"]] do
      assert {:error, :invalid_input} = Synapsis.Memory.get_host(id, opts)
    end

    assert {:ok, _} = Settings.save(config(false))
    assert {:error, :disabled} = Synapsis.Memory.get_host(id, source: source)
  end

  defp config(enabled) do
    %{
      "backend" => "workspace",
      "host_agent" => %{
        "enabled" => enabled,
        "endpoint" => "http://127.0.0.1:4223",
        "agent_id" => "test-agent"
      }
    }
  end
end
