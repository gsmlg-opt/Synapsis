defmodule SynapsisPlugin.SupervisorTest do
  use ExUnit.Case

  alias SynapsisPlugin.Test.MockPlugin

  describe "start_plugin/3" do
    test "starts a plugin and returns pid" do
      name = "sup_test_#{:rand.uniform(100_000)}"
      {:ok, pid} = SynapsisPlugin.Supervisor.start_plugin(MockPlugin, name, %{name: name})
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "stop_plugin/1" do
    test "stops a running plugin" do
      name = "sup_stop_#{:rand.uniform(100_000)}"
      {:ok, pid} = SynapsisPlugin.Supervisor.start_plugin(MockPlugin, name, %{name: name})
      assert Process.alive?(pid)

      assert :ok = SynapsisPlugin.Supervisor.stop_plugin(name)
      # Give the process time to terminate
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1000 -> flunk("Plugin did not terminate in time")
      end
    end

    test "returns error for unknown plugin name" do
      assert {:error, :not_found} = SynapsisPlugin.Supervisor.stop_plugin("nonexistent_plugin_xyz")
    end
  end

  describe "list_plugins/0" do
    test "returns list of running plugins" do
      name = "sup_list_#{:rand.uniform(100_000)}"
      {:ok, _pid} = SynapsisPlugin.Supervisor.start_plugin(MockPlugin, name, %{name: name})

      plugins = SynapsisPlugin.Supervisor.list_plugins()
      assert is_list(plugins)
      assert Enum.any?(plugins, fn p -> p.name == name end)
    end

    test "each plugin entry has name and pid" do
      name = "sup_list2_#{:rand.uniform(100_000)}"
      {:ok, _pid} = SynapsisPlugin.Supervisor.start_plugin(MockPlugin, name, %{name: name})

      plugins = SynapsisPlugin.Supervisor.list_plugins()
      plugin = Enum.find(plugins, fn p -> p.name == name end)

      assert is_map(plugin)
      assert Map.has_key?(plugin, :name)
      assert Map.has_key?(plugin, :pid)
      assert is_pid(plugin.pid)
    end
  end
end
