defmodule Synapsis.Backplane.CredentialGenerationTest do
  use ExUnit.Case, async: false

  alias Synapsis.Backplane
  alias Synapsis.Backplane.{Connection, Snapshot, Sync}
  alias Synapsis.Config.Store
  alias Synapsis.MCP.Transport
  alias Synapsis.MCPConfigs

  defmodule MCPRuntimeStub do
    def restart(_config), do: :ok
    def stop(_name), do: :ok
  end

  setup do
    Enum.each(MCPConfigs.list(), &MCPConfigs.delete/1)
    Enum.each(Connection.list(), &Connection.delete/1)

    on_exit(fn ->
      Enum.each(MCPConfigs.list(), &MCPConfigs.delete/1)
      Enum.each(Connection.list(), &Connection.delete/1)
    end)

    :ok
  end

  test "linked endpoint and credential edits retain a coherent current provider generation" do
    assert {:ok, connection} =
             Connection.create(%{
               name: "credential-generation",
               endpoint: "https://old.example.test",
               credential: "old-secret"
             })

    assert {:ok, _ready} =
             Sync.run(connection.id,
               client: snapshot_client(:ok),
               mcp_runtime: MCPRuntimeStub
             )

    [old_mcp] = MCPConfigs.list()
    assert old_mcp.url == "https://old.example.test/mcp"
    refute old_mcp.config["backplane_credential_encrypted"] =~ "old-secret"
    assert authorization(old_mcp) == "Bearer old-secret"

    assert {:ok, _repeated} =
             Sync.run(connection.id,
               client: snapshot_client(:ok),
               mcp_runtime: MCPRuntimeStub
             )

    [repeated_mcp] = MCPConfigs.list()

    assert is_binary(repeated_mcp.provider_id)
    refute Map.has_key?(repeated_mcp.config, "backplane_credential_encrypted")
    assert repeated_mcp.config["provider_url_override"] == false

    assert {:ok, changed} =
             Backplane.update(
               connection.id,
               %{endpoint: "https://new.example.test", credential: "new-secret"},
               sync_opts: [
                 client: snapshot_client({:error, :mcp_offline}),
                 mcp_runtime: MCPRuntimeStub
               ]
             )

    assert changed.endpoint == "https://new.example.test"
    [retained_mcp] = MCPConfigs.list()
    assert retained_mcp.id == old_mcp.id
    assert retained_mcp.url == "https://old.example.test/mcp"
    assert authorization(retained_mcp) == "Bearer new-secret"
    assert {:streamable_http, current_transport} = Transport.build(retained_mcp)
    assert current_transport[:base_url] == "https://new.example.test"
    assert current_transport[:mcp_path] == "/mcp"
    assert retained_mcp.provider_id == changed.provider_id
    assert "tools" in changed.unavailable
    assert changed.metadata["surface_errors"]["tools"] =~ "mcp_offline"

    assert {:ok, _refreshed} =
             Backplane.refresh(connection.id,
               sync_opts: [client: snapshot_client(:ok), mcp_runtime: MCPRuntimeStub]
             )

    [promoted_mcp] = MCPConfigs.list()
    assert promoted_mcp.id == old_mcp.id
    assert promoted_mcp.url == "https://new.example.test/mcp"
    assert authorization(promoted_mcp) == "Bearer new-secret"
  end

  test "failed keyless to credential update retains the TOML-safe keyless generation" do
    assert {:ok, connection} =
             Connection.create(%{
               name: "keyless-credential-generation",
               endpoint: "https://keyless.example.test"
             })

    assert {:ok, _ready} =
             Sync.run(connection.id,
               client: snapshot_client(:ok),
               mcp_runtime: MCPRuntimeStub
             )

    [keyless_mcp] = MCPConfigs.list()
    assert keyless_mcp.url == "https://keyless.example.test/mcp"
    assert keyless_mcp.config["backplane_credential_mode"] == "keyless"
    refute Map.has_key?(keyless_mcp.config, "backplane_credential_encrypted")
    assert authorization(keyless_mcp) == nil

    assert :ok = Store.reload(:mcp)
    reloaded_keyless_mcp = MCPConfigs.get(keyless_mcp.id)
    assert reloaded_keyless_mcp.config["backplane_credential_mode"] == "keyless"
    assert authorization(reloaded_keyless_mcp) == nil

    assert {:ok, changed} =
             Backplane.update(
               connection.id,
               %{endpoint: "https://credentialed.example.test", credential: "new-secret"},
               sync_opts: [
                 client: snapshot_client({:error, :mcp_offline}),
                 mcp_runtime: MCPRuntimeStub
               ]
             )

    assert changed.endpoint == "https://credentialed.example.test"
    [retained_mcp] = MCPConfigs.list()
    assert retained_mcp.id == keyless_mcp.id
    assert retained_mcp.url == "https://keyless.example.test/mcp"
    assert retained_mcp.config["backplane_credential_mode"] == "keyless"
    refute Map.has_key?(retained_mcp.config, "backplane_credential_encrypted")
    assert authorization(retained_mcp) == nil
    refute MCPConfigs.runtime_available?(retained_mcp)

    assert {:ok, _refreshed} =
             Backplane.refresh(connection.id,
               sync_opts: [client: snapshot_client(:ok), mcp_runtime: MCPRuntimeStub]
             )

    [promoted_mcp] = MCPConfigs.list()
    assert promoted_mcp.id == keyless_mcp.id
    assert promoted_mcp.url == "https://credentialed.example.test/mcp"
    assert promoted_mcp.provider_id == changed.provider_id
    refute Map.has_key?(promoted_mcp.config, "backplane_credential_mode")
    refute Map.has_key?(promoted_mcp.config, "backplane_credential_encrypted")
    assert authorization(promoted_mcp) == "Bearer new-secret"
  end

  defp snapshot_client(mcp_result) do
    fn connection, _opts ->
      Snapshot.normalize(connection, %{
        models: {:ok, []},
        skills: {:ok, []},
        mcp_tools:
          case mcp_result do
            :ok -> {:ok, [%{"name" => "read_status"}]}
            {:error, _reason} = error -> error
          end
      })
    end
  end

  defp authorization(config) do
    {:streamable_http, opts} = Transport.build(config)
    opts[:headers]["authorization"]
  end
end
