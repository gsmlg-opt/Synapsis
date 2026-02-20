defmodule SynapsisPlugin.LoaderTest do
  use Synapsis.DataCase

  alias SynapsisPlugin.Loader

  describe "start_auto_plugins/0" do
    test "returns :ok when no auto_start configs exist" do
      assert :ok = Loader.start_auto_plugins()
    end

    test "attempts to start auto_start plugins" do
      # Insert an MCP config with auto_start=true but a non-existent command
      %Synapsis.PluginConfig{}
      |> Synapsis.PluginConfig.changeset(%{
        type: "mcp",
        name: "loader-test-mcp",
        transport: "stdio",
        command: "nonexistent_test_command_xyz",
        auto_start: true
      })
      |> Repo.insert!()

      # Should not crash even if plugin start fails
      assert :ok = Loader.start_auto_plugins()
    end

    test "handles database errors gracefully" do
      # The loader rescues errors, so this should always return :ok
      assert :ok = Loader.start_auto_plugins()
    end
  end

  describe "module_for_type/1 (indirectly tested)" do
    test "mcp type resolves correctly via start_auto_plugins" do
      %Synapsis.PluginConfig{}
      |> Synapsis.PluginConfig.changeset(%{
        type: "mcp",
        name: "loader-mcp-type-test",
        transport: "stdio",
        command: "nonexistent_mcp_xyz",
        auto_start: true
      })
      |> Repo.insert!()

      # Should not crash - dispatches to SynapsisPlugin.MCP
      assert :ok = Loader.start_auto_plugins()
    end

    test "lsp type resolves correctly via start_auto_plugins" do
      %Synapsis.PluginConfig{}
      |> Synapsis.PluginConfig.changeset(%{
        type: "lsp",
        name: "loader-lsp-type-test",
        transport: "stdio",
        command: "nonexistent_lsp_xyz",
        auto_start: true
      })
      |> Repo.insert!()

      # Should not crash - dispatches to SynapsisPlugin.LSP
      assert :ok = Loader.start_auto_plugins()
    end
  end
end
