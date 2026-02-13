defmodule SynapsisPlugin.ServerTest do
  use ExUnit.Case

  alias SynapsisPlugin.Test.MockPlugin

  describe "plugin lifecycle" do
    test "starts a mock plugin and registers tools" do
      {:ok, pid} =
        SynapsisPlugin.start_plugin(MockPlugin, "test_mock_#{:rand.uniform(100_000)}", %{
          name: "test"
        })

      assert Process.alive?(pid)

      # Check that tools were registered
      assert {:ok, _} = Synapsis.Tool.Registry.lookup("mock_echo")
      assert {:ok, _} = Synapsis.Tool.Registry.lookup("mock_count")

      # Execute a tool via the process dispatch
      assert {:ok, "hello"} =
               GenServer.call(pid, {:execute, "mock_echo", %{"text" => "hello"}, %{}})

      # Execute count tool
      assert {:ok, "count: 1"} =
               GenServer.call(pid, {:execute, "mock_count", %{}, %{}})

      assert {:ok, "count: 2"} =
               GenServer.call(pid, {:execute, "mock_count", %{}, %{}})

      # Stop and verify process is dead
      GenServer.stop(pid)
      refute Process.alive?(pid)
    end

    test "handles effect forwarding" do
      {:ok, pid} =
        SynapsisPlugin.start_plugin(MockPlugin, "test_effects_#{:rand.uniform(100_000)}", %{
          name: "effects_test"
        })

      send(pid, {:tool_effect, :file_changed, %{path: "/tmp/test.txt"}})
      Process.sleep(50)

      state = GenServer.call(pid, :get_state)
      assert [{:file_changed, %{path: "/tmp/test.txt"}}] = state.effects

      GenServer.stop(pid)
    end
  end
end
