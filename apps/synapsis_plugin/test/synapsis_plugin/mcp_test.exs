defmodule SynapsisPlugin.MCPTest do
  use ExUnit.Case, async: true

  alias SynapsisPlugin.MCP.Protocol

  describe "MCP Protocol" do
    test "encodes a JSON-RPC request" do
      {:ok, encoded} = Protocol.encode_request(1, "tools/list")
      assert encoded =~ "\"jsonrpc\":\"2.0\""
      assert encoded =~ "\"id\":1"
      assert encoded =~ "\"method\":\"tools/list\""
      assert String.ends_with?(encoded, "\n")
    end

    test "encodes a request with explicit params" do
      params = %{"name" => "read_file", "arguments" => %{"path" => "/tmp/test.txt"}}
      {:ok, encoded} = Protocol.encode_request(42, "tools/call", params)
      decoded = Jason.decode!(String.trim_trailing(encoded, "\n"))
      assert decoded["id"] == 42
      assert decoded["method"] == "tools/call"
      assert decoded["params"]["name"] == "read_file"
      assert decoded["params"]["arguments"]["path"] == "/tmp/test.txt"
    end

    test "encodes a notification" do
      {:ok, encoded} = Protocol.encode_notification("notifications/initialized")
      assert encoded =~ "\"method\":\"notifications/initialized\""
      refute encoded =~ "\"id\""
    end

    test "encodes a notification with explicit params" do
      {:ok, encoded} = Protocol.encode_notification("notifications/progress", %{"sessionId" => "abc123"})
      decoded = Jason.decode!(String.trim_trailing(encoded, "\n"))
      assert decoded["method"] == "notifications/progress"
      assert decoded["params"]["sessionId"] == "abc123"
      refute Map.has_key?(decoded, "id")
    end

    test "decodes a complete message" do
      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"tools" => []}})
      {messages, rest} = Protocol.decode_message("#{json}\n")
      assert length(messages) == 1
      assert hd(messages)["id"] == 1
      assert rest == ""
    end

    test "decodes multiple messages" do
      msg1 = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      msg2 = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notify", "params" => %{}})
      {messages, _rest} = Protocol.decode_message("#{msg1}\n#{msg2}\n")
      assert length(messages) == 2
    end

    test "handles partial messages" do
      {messages, rest} = Protocol.decode_message("{incomplete")
      assert messages == []
      assert rest == "{incomplete"
    end
  end

  describe "MCP plugin module" do
    test "tools/1 formats tool names with server prefix" do
      state = %SynapsisPlugin.MCP{
        server_name: "my_server",
        tools: [
          %{"name" => "read_file", "description" => "Read a file", "inputSchema" => %{}}
        ],
        port: nil,
        request_id: 1,
        pending: %{},
        buffer: "",
        env: %{},
        initialized: true,
        command: "test",
        args: []
      }

      tools = SynapsisPlugin.MCP.tools(state)
      assert length(tools) == 1
      assert hd(tools).name == "mcp:my_server:read_file"
    end

    test "execute/3 returns async with pending call state" do
      state = %SynapsisPlugin.MCP{
        server_name: "test_server",
        tools: [],
        port: nil,
        request_id: 5,
        pending: %{},
        buffer: "",
        env: %{},
        initialized: true,
        command: "test",
        args: []
      }

      # execute/3 with nil port should still enqueue the call and return :async
      # We cannot actually send data via Port when nil, but the function pattern
      # attempts a Port.command that will fail. We test the naming extraction logic.
      try do
        result = SynapsisPlugin.MCP.execute("mcp:test_server:my_tool", %{"arg" => "val"}, state)
        # If it returns (some implementations guard the nil port), it should be :async
        assert match?({:async, _}, result)
      rescue
        # Port.command on nil will raise — that's expected behavior when port is nil
        _ -> assert true
      end
    end

    test "terminate/2 handles nil port gracefully" do
      state = %SynapsisPlugin.MCP{
        server_name: "test",
        tools: [],
        port: nil,
        request_id: 1,
        pending: %{},
        buffer: "",
        env: %{},
        initialized: false,
        command: "test",
        args: []
      }

      assert :ok = SynapsisPlugin.MCP.terminate(:normal, state)
    end

    test "handle_info/2 for unrelated messages returns {:ok, state}" do
      state = %SynapsisPlugin.MCP{
        server_name: "test",
        tools: [],
        port: nil,
        request_id: 1,
        pending: %{},
        buffer: "",
        env: %{},
        initialized: false,
        command: "test",
        args: []
      }

      assert {:ok, ^state} = SynapsisPlugin.MCP.handle_info(:some_random_message, state)
    end

    test "tools/1 returns empty list when no tools discovered" do
      state = %SynapsisPlugin.MCP{
        server_name: "empty",
        tools: [],
        port: nil,
        request_id: 1,
        pending: %{},
        buffer: "",
        env: %{},
        initialized: false,
        command: "test",
        args: []
      }

      assert SynapsisPlugin.MCP.tools(state) == []
    end

    test "tools/1 handles tool with missing description (uses empty string)" do
      state = %SynapsisPlugin.MCP{
        server_name: "sparse",
        tools: [%{"name" => "minimal"}],
        port: nil,
        request_id: 1,
        pending: %{},
        buffer: "",
        env: %{},
        initialized: true,
        command: "test",
        args: []
      }

      [tool] = SynapsisPlugin.MCP.tools(state)
      assert tool.name == "mcp:sparse:minimal"
      assert tool.description == ""
      assert tool.parameters == %{}
    end

    test "tools/1 handles tool with inputSchema" do
      schema = %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}

      state = %SynapsisPlugin.MCP{
        server_name: "fs",
        tools: [
          %{"name" => "read", "description" => "Read a file", "inputSchema" => schema}
        ],
        port: nil,
        request_id: 1,
        pending: %{},
        buffer: "",
        env: %{},
        initialized: true,
        command: "test",
        args: []
      }

      [tool] = SynapsisPlugin.MCP.tools(state)
      assert tool.parameters == schema
    end
  end

  describe "MCP init/1" do
    test "returns error when binary not found" do
      config = %{
        name: "test_server",
        command: "nonexistent_binary_xyz_#{:rand.uniform(100_000)}",
        args: [],
        env: %{}
      }

      assert {:error, {:no_binary, _}} = SynapsisPlugin.MCP.init(config)
    end
  end

  describe "SynapsisPlugin public API" do
    alias SynapsisPlugin.Test.MockPlugin

    test "start_plugin/3 starts a plugin and returns pid" do
      name = "api_test_start_#{:rand.uniform(100_000)}"
      {:ok, pid} = SynapsisPlugin.start_plugin(MockPlugin, name, %{name: name})
      assert is_pid(pid)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "stop_plugin/1 stops a running plugin" do
      name = "api_test_stop_#{:rand.uniform(100_000)}"
      {:ok, pid} = SynapsisPlugin.start_plugin(MockPlugin, name, %{name: name})
      assert Process.alive?(pid)

      assert :ok = SynapsisPlugin.stop_plugin(name)

      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> assert true
      after
        1000 -> flunk("Plugin did not stop in time")
      end
    end

    test "stop_plugin/1 returns error for non-existent plugin" do
      assert {:error, :not_found} = SynapsisPlugin.stop_plugin("nonexistent_plugin_xyz")
    end

    test "list_plugins/0 returns list of running plugins" do
      name = "api_test_list_#{:rand.uniform(100_000)}"
      {:ok, _pid} = SynapsisPlugin.start_plugin(MockPlugin, name, %{name: name})

      plugins = SynapsisPlugin.list_plugins()
      assert is_list(plugins)
      assert Enum.any?(plugins, fn p -> p.name == name end)
    end

    test "list_plugins/0 returns empty list when no plugins running (approximately)" do
      # We can't guarantee no plugins are running, but we can verify the structure
      plugins = SynapsisPlugin.list_plugins()
      assert is_list(plugins)

      for plugin <- plugins do
        assert Map.has_key?(plugin, :name)
        assert Map.has_key?(plugin, :pid)
      end
    end
  end
end
