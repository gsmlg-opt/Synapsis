defmodule SynapsisPlugin.ServerTest do
  use ExUnit.Case

  alias SynapsisPlugin.Test.MockPlugin

  # A minimal plugin that does NOT export handle_info/2
  defmodule NoHandleInfoPlugin do
    use Synapsis.Plugin

    defstruct [:name]

    @impl Synapsis.Plugin
    def init(_config), do: {:ok, %__MODULE__{name: "no_handle_info"}}

    @impl Synapsis.Plugin
    def tools(_state),
      do: [%{name: "nhi_tool", description: "test", parameters: %{"type" => "object"}}]

    @impl Synapsis.Plugin
    def execute("nhi_tool", _input, state), do: {:ok, "ok", state}
    def execute(_, _, state), do: {:error, "unknown", state}
  end

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

    test "execute returns error tuple for unknown tool" do
      {:ok, pid} =
        SynapsisPlugin.start_plugin(MockPlugin, "test_err_#{:rand.uniform(100_000)}", %{
          name: "err_test"
        })

      assert {:error, "unknown tool"} =
               GenServer.call(pid, {:execute, "nonexistent_tool", %{}, %{}})

      GenServer.stop(pid)
    end

    test "unknown messages are silently ignored without crash" do
      {:ok, pid} =
        SynapsisPlugin.start_plugin(MockPlugin, "test_noop_#{:rand.uniform(100_000)}", %{
          name: "noop"
        })

      send(pid, :completely_random_unknown_message)
      Process.sleep(30)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "plugin without handle_info/2 ignores unknown messages silently" do
      name = "test_nhi_#{:rand.uniform(100_000)}"
      {:ok, pid} = SynapsisPlugin.start_plugin(NoHandleInfoPlugin, name, %{name: name})

      assert Process.alive?(pid)

      send(pid, :some_unknown_message)
      Process.sleep(30)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "plugin without handle_info/2 ignores tool_effect messages" do
      name = "test_nhi_effect_#{:rand.uniform(100_000)}"
      {:ok, pid} = SynapsisPlugin.start_plugin(NoHandleInfoPlugin, name, %{name: name})

      # Tool effect: plugin doesn't export handle_effect/3 either, so this
      # should go to the no-op branch in Server.handle_info/2
      send(pid, {:tool_effect, :file_changed, %{path: "/tmp/test.ex"}})
      Process.sleep(30)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "plugin init failure returns stop tuple" do
      # Use a module that returns {:error, ...} from init
      defmodule FailInitPlugin do
        use Synapsis.Plugin

        @impl Synapsis.Plugin
        def init(_config), do: {:error, :init_failed}

        @impl Synapsis.Plugin
        def tools(_state), do: []

        @impl Synapsis.Plugin
        def execute(_, _, state), do: {:error, "n/a", state}
      end

      name = "test_fail_init_#{:rand.uniform(100_000)}"
      result = SynapsisPlugin.start_plugin(FailInitPlugin, name, %{})
      # DynamicSupervisor wraps the :stop as an error
      assert {:error, _} = result
    end

    test "get_state returns current plugin state" do
      name = "test_get_state_#{:rand.uniform(100_000)}"
      {:ok, pid} = SynapsisPlugin.start_plugin(MockPlugin, name, %{name: name})

      state = GenServer.call(pid, :get_state)
      assert %MockPlugin{} = state
      assert state.counter == 0

      GenServer.stop(pid)
    end
  end
end
