defmodule SynapsisPlugin.PluginBehaviourTest do
  use ExUnit.Case, async: true

  describe "Synapsis.Plugin behaviour with __using__ macro" do
    test "module using Synapsis.Plugin gets default handle_effect/3" do
      defmodule MinimalPlugin do
        use Synapsis.Plugin

        @impl Synapsis.Plugin
        def init(_config), do: {:ok, %{}}

        @impl Synapsis.Plugin
        def tools(_state), do: []

        @impl Synapsis.Plugin
        def execute(_tool, _input, state), do: {:ok, "", state}
      end

      assert {:ok, state} = MinimalPlugin.init(%{})
      # Default handle_effect just returns {:ok, state}
      assert {:ok, ^state} = MinimalPlugin.handle_effect(:file_changed, %{}, state)
    end

    test "module using Synapsis.Plugin gets default handle_info/2" do
      defmodule MinimalPlugin2 do
        use Synapsis.Plugin

        @impl Synapsis.Plugin
        def init(_config), do: {:ok, %{counter: 0}}

        @impl Synapsis.Plugin
        def tools(_state), do: []

        @impl Synapsis.Plugin
        def execute(_tool, _input, state), do: {:ok, "", state}
      end

      {:ok, state} = MinimalPlugin2.init(%{})
      # Default handle_info just returns {:ok, state}
      assert {:ok, ^state} = MinimalPlugin2.handle_info(:some_message, state)
    end

    test "module using Synapsis.Plugin gets default terminate/2" do
      defmodule MinimalPlugin3 do
        use Synapsis.Plugin

        @impl Synapsis.Plugin
        def init(_config), do: {:ok, %{}}

        @impl Synapsis.Plugin
        def tools(_state), do: []

        @impl Synapsis.Plugin
        def execute(_tool, _input, state), do: {:ok, "", state}
      end

      {:ok, state} = MinimalPlugin3.init(%{})
      assert :ok = MinimalPlugin3.terminate(:normal, state)
      assert :ok = MinimalPlugin3.terminate(:shutdown, state)
      assert :ok = MinimalPlugin3.terminate({:error, :crash}, state)
    end

    test "optional callbacks can be overridden" do
      defmodule OverridingPlugin do
        use Synapsis.Plugin

        @impl Synapsis.Plugin
        def init(_config), do: {:ok, %{effects: [], messages: []}}

        @impl Synapsis.Plugin
        def tools(_state), do: []

        @impl Synapsis.Plugin
        def execute(_tool, _input, state), do: {:ok, "", state}

        @impl Synapsis.Plugin
        def handle_effect(effect, payload, state) do
          {:ok, %{state | effects: [{effect, payload} | state.effects]}}
        end

        @impl Synapsis.Plugin
        def handle_info(msg, state) do
          {:ok, %{state | messages: [msg | state.messages]}}
        end

        @impl Synapsis.Plugin
        def terminate(_reason, _state) do
          :ok
        end
      end

      {:ok, state} = OverridingPlugin.init(%{})
      assert state.effects == []
      assert state.messages == []

      {:ok, state} = OverridingPlugin.handle_effect(:file_changed, %{path: "/a.ex"}, state)
      assert [{:file_changed, %{path: "/a.ex"}}] = state.effects

      {:ok, state} = OverridingPlugin.handle_info({:port_data, "data"}, state)
      assert [{:port_data, "data"}] = state.messages

      assert :ok = OverridingPlugin.terminate(:normal, state)
    end
  end

  describe "MockPlugin behaviour compliance" do
    alias SynapsisPlugin.Test.MockPlugin

    test "init/1 returns {:ok, state} with valid config" do
      assert {:ok, state} = MockPlugin.init(%{name: "test"})
      assert state.name == "test"
      assert state.counter == 0
      assert state.effects == []
    end

    test "init/1 uses default name when not provided" do
      assert {:ok, state} = MockPlugin.init(%{})
      assert state.name == "mock"
    end

    test "tools/1 returns list of tool definitions" do
      {:ok, state} = MockPlugin.init(%{name: "test"})
      tools = MockPlugin.tools(state)
      assert is_list(tools)
      assert length(tools) == 2

      for tool <- tools do
        assert Map.has_key?(tool, :name)
        assert Map.has_key?(tool, :description)
        assert Map.has_key?(tool, :parameters)
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_map(tool.parameters)
      end
    end

    test "tools/1 returns tools with JSON Schema parameters" do
      {:ok, state} = MockPlugin.init(%{name: "test"})
      tools = MockPlugin.tools(state)

      echo_tool = Enum.find(tools, &(&1.name == "mock_echo"))
      assert echo_tool.parameters["type"] == "object"
      assert Map.has_key?(echo_tool.parameters, "properties")
      assert echo_tool.parameters["required"] == ["text"]
    end

    test "execute/3 returns {:ok, result, state} for known tool" do
      {:ok, state} = MockPlugin.init(%{name: "test"})
      assert {:ok, "hello", _state} = MockPlugin.execute("mock_echo", %{"text" => "hello"}, state)
    end

    test "execute/3 returns empty string when echo text is nil" do
      {:ok, state} = MockPlugin.init(%{name: "test"})
      assert {:ok, "", _state} = MockPlugin.execute("mock_echo", %{}, state)
    end

    test "execute/3 increments counter for mock_count" do
      {:ok, state} = MockPlugin.init(%{name: "test"})
      assert {:ok, "count: 1", state} = MockPlugin.execute("mock_count", %{}, state)
      assert {:ok, "count: 2", state} = MockPlugin.execute("mock_count", %{}, state)
      assert {:ok, "count: 3", _state} = MockPlugin.execute("mock_count", %{}, state)
    end

    test "execute/3 returns {:error, message, state} for unknown tool" do
      {:ok, state} = MockPlugin.init(%{name: "test"})
      assert {:error, "unknown tool", ^state} = MockPlugin.execute("nonexistent", %{}, state)
    end

    test "handle_effect/3 accumulates effects" do
      {:ok, state} = MockPlugin.init(%{name: "test"})
      assert state.effects == []

      {:ok, state} = MockPlugin.handle_effect(:file_changed, %{path: "/a.ex"}, state)
      assert length(state.effects) == 1

      {:ok, state} = MockPlugin.handle_effect(:file_deleted, %{path: "/b.ex"}, state)
      assert length(state.effects) == 2

      # Most recent effect is first (prepended)
      assert [{:file_deleted, %{path: "/b.ex"}}, {:file_changed, %{path: "/a.ex"}}] = state.effects
    end

    test "handle_info/2 returns {:ok, state} (default from __using__)" do
      {:ok, state} = MockPlugin.init(%{name: "test"})
      # MockPlugin does not override handle_info, so it uses the default
      assert {:ok, ^state} = MockPlugin.handle_info(:random_message, state)
    end

    test "terminate/2 returns :ok (default from __using__)" do
      {:ok, state} = MockPlugin.init(%{name: "test"})
      assert :ok = MockPlugin.terminate(:normal, state)
    end
  end

  describe "MCP plugin tools/1 formatting" do
    test "formats tool names with mcp:<server>:<tool> prefix" do
      state = %SynapsisPlugin.MCP{
        server_name: "filesystem",
        tools: [
          %{"name" => "read_file", "description" => "Read a file", "inputSchema" => %{"type" => "object"}},
          %{"name" => "write_file", "description" => "Write a file", "inputSchema" => %{"type" => "object"}}
        ],
        port: nil, request_id: 1, pending: %{}, buffer: "",
        env: %{}, initialized: true, command: "test", args: []
      }

      tools = SynapsisPlugin.MCP.tools(state)
      assert length(tools) == 2
      names = Enum.map(tools, & &1.name)
      assert "mcp:filesystem:read_file" in names
      assert "mcp:filesystem:write_file" in names
    end

    test "returns empty list when no tools discovered" do
      state = %SynapsisPlugin.MCP{
        server_name: "empty_server",
        tools: [],
        port: nil, request_id: 1, pending: %{}, buffer: "",
        env: %{}, initialized: false, command: "test", args: []
      }

      assert SynapsisPlugin.MCP.tools(state) == []
    end

    test "handles tools with missing description and inputSchema" do
      state = %SynapsisPlugin.MCP{
        server_name: "sparse",
        tools: [
          %{"name" => "minimal_tool"}
        ],
        port: nil, request_id: 1, pending: %{}, buffer: "",
        env: %{}, initialized: true, command: "test", args: []
      }

      [tool] = SynapsisPlugin.MCP.tools(state)
      assert tool.name == "mcp:sparse:minimal_tool"
      assert tool.description == ""
      assert tool.parameters == %{}
    end
  end

  describe "LSP plugin tools/1" do
    test "always returns the same 5 tools regardless of state" do
      state = %SynapsisPlugin.LSP{
        port: nil, language: "elixir", root_path: "/tmp",
        request_id: 1, pending: %{}, buffer: "",
        initialized: false, diagnostics: %{}, pending_requests: %{}
      }

      tools = SynapsisPlugin.LSP.tools(state)
      assert length(tools) == 5
      names = Enum.map(tools, & &1.name)
      assert "lsp_diagnostics" in names
      assert "lsp_definition" in names
      assert "lsp_references" in names
      assert "lsp_hover" in names
      assert "lsp_symbols" in names
    end

    test "each tool has required fields" do
      state = %SynapsisPlugin.LSP{
        port: nil, language: "go", root_path: "/project",
        request_id: 1, pending: %{}, buffer: "",
        initialized: true, diagnostics: %{}, pending_requests: %{}
      }

      for tool <- SynapsisPlugin.LSP.tools(state) do
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_map(tool.parameters)
        assert tool.parameters["type"] == "object"
        assert Map.has_key?(tool.parameters, "properties")
        assert Map.has_key?(tool.parameters, "required")
      end
    end
  end

  describe "LSP execute/3 diagnostics edge cases" do
    setup do
      state = %SynapsisPlugin.LSP{
        port: nil, language: "elixir", root_path: "/project",
        request_id: 1, pending: %{}, buffer: "",
        initialized: true, diagnostics: %{}, pending_requests: %{}
      }

      {:ok, state: state}
    end

    test "returns no diagnostics for empty state", %{state: state} do
      assert {:ok, "No diagnostics found.", _} =
               SynapsisPlugin.LSP.execute("lsp_diagnostics", %{}, state)
    end

    test "formats multiple diagnostics from multiple files", %{state: state} do
      state = %{state | diagnostics: %{
        "file:///project/a.ex" => [
          %{"range" => %{"start" => %{"line" => 0}}, "severity" => 1, "message" => "error A"},
          %{"range" => %{"start" => %{"line" => 5}}, "severity" => 2, "message" => "warning A"}
        ],
        "file:///project/b.ex" => [
          %{"range" => %{"start" => %{"line" => 10}}, "severity" => 3, "message" => "info B"}
        ]
      }}

      {:ok, result, _} = SynapsisPlugin.LSP.execute("lsp_diagnostics", %{}, state)
      assert result =~ "error A"
      assert result =~ "warning A"
      assert result =~ "info B"
    end

    test "severity labels are correct in diagnostics output", %{state: state} do
      state = %{state | diagnostics: %{
        "file:///project/test.ex" => [
          %{"range" => %{"start" => %{"line" => 0}}, "severity" => 1, "message" => "err"},
          %{"range" => %{"start" => %{"line" => 1}}, "severity" => 2, "message" => "warn"},
          %{"range" => %{"start" => %{"line" => 2}}, "severity" => 3, "message" => "inf"},
          %{"range" => %{"start" => %{"line" => 3}}, "severity" => 4, "message" => "hnt"},
          %{"range" => %{"start" => %{"line" => 4}}, "severity" => 99, "message" => "unk"}
        ]
      }}

      {:ok, result, _} = SynapsisPlugin.LSP.execute("lsp_diagnostics", %{}, state)
      lines = String.split(result, "\n")
      assert Enum.any?(lines, &String.contains?(&1, "error: err"))
      assert Enum.any?(lines, &String.contains?(&1, "warning: warn"))
      assert Enum.any?(lines, &String.contains?(&1, "info: inf"))
      assert Enum.any?(lines, &String.contains?(&1, "hint: hnt"))
      assert Enum.any?(lines, &String.contains?(&1, "unknown: unk"))
    end

    test "diagnostics line numbers are 1-indexed in output", %{state: state} do
      state = %{state | diagnostics: %{
        "file:///project/zero.ex" => [
          %{"range" => %{"start" => %{"line" => 0}}, "severity" => 1, "message" => "line zero error"}
        ]
      }}

      {:ok, result, _} = SynapsisPlugin.LSP.execute("lsp_diagnostics", %{}, state)
      # Line 0 in LSP should become line 1 in output
      assert result =~ ":1:"
    end

    test "diagnostics handles missing range start line gracefully", %{state: state} do
      state = %{state | diagnostics: %{
        "file:///project/norange.ex" => [
          %{"range" => %{"start" => %{}}, "severity" => 1, "message" => "no line"}
        ]
      }}

      {:ok, result, _} = SynapsisPlugin.LSP.execute("lsp_diagnostics", %{}, state)
      # Falls back to line 0, output shows :1:
      assert result =~ ":1:"
      assert result =~ "no line"
    end

    test "execute returns error for unknown tool name", %{state: state} do
      assert {:error, msg, _} = SynapsisPlugin.LSP.execute("lsp_unknown", %{}, state)
      assert msg =~ "Unknown LSP tool: lsp_unknown"
    end

    test "filtering by path returns only matching file diagnostics", %{state: state} do
      state = %{state | diagnostics: %{
        "file:///project/match.ex" => [
          %{"range" => %{"start" => %{"line" => 0}}, "severity" => 1, "message" => "matched"}
        ],
        "file:///project/other.ex" => [
          %{"range" => %{"start" => %{"line" => 0}}, "severity" => 1, "message" => "other"}
        ]
      }}

      {:ok, result, _} =
        SynapsisPlugin.LSP.execute("lsp_diagnostics", %{"path" => "/project/match.ex"}, state)

      assert result =~ "matched"
      refute result =~ "other"
    end

    test "filtering by nonexistent path returns no diagnostics", %{state: state} do
      state = %{state | diagnostics: %{
        "file:///project/exists.ex" => [
          %{"range" => %{"start" => %{"line" => 0}}, "severity" => 1, "message" => "exists"}
        ]
      }}

      {:ok, "No diagnostics found.", _} =
        SynapsisPlugin.LSP.execute("lsp_diagnostics", %{"path" => "/project/missing.ex"}, state)
    end
  end
end
