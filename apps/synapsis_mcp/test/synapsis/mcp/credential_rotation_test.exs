defmodule Synapsis.MCP.CredentialRotationTest do
  use ExUnit.Case, async: false

  alias Synapsis.Backplane.{Connection, ProviderSource, Snapshot, Sync}
  alias Synapsis.{Config.Store, Credentials, MCP, MCPConfigs, Providers}
  alias Synapsis.MCP.Server
  alias Synapsis.Tool.Registry

  defmodule Runtime do
    def restart(_), do: :ok
    def restart_for_reconciliation(_), do: :ok
    def stop(_), do: :ok
  end

  defmodule RotatingRuntime do
    def restart_for_reconciliation(_config) do
      if Process.get({Store, :write_lock_held}, false),
        do: raise("runtime reconnect held the config write lock")

      {:ok, _} =
        Credentials.update(Process.get({__MODULE__, :credential_id}), %{
          key: "rotated-during-reconnect"
        })

      :ok
    end

    def stop(_), do: :ok
  end

  setup do
    previous = Application.get_env(:synapsis_provider, :credential_invalidation)
    Application.delete_env(:synapsis_provider, :credential_invalidation)
    Enum.each([:mcp, :backplane, :provider, :credential], &Synapsis.DataCase.clear_config_store/1)

    on_exit(fn ->
      for config <- MCPConfigs.list(), do: MCP.stop(config.name)

      Enum.each(
        [:mcp, :backplane, :provider, :credential],
        &Synapsis.DataCase.clear_config_store/1
      )

      if previous,
        do: Application.put_env(:synapsis_provider, :credential_invalidation, previous),
        else: Application.delete_env(:synapsis_provider, :credential_invalidation)
    end)

    %{bypass: Bypass.open()}
  end

  test "missing explicit credentials are unavailable even with allow_disabled", %{bypass: bypass} do
    {credential, provider, _config} = linked_config(bypass, "missing")
    {:ok, connection} = Connection.create(%{name: "credential-skills", provider_id: provider.id})
    File.write!(Store.file_path(:credential), "")
    assert :ok = Store.reload(:credential)
    assert {:error, :provider_unavailable} = ProviderSource.get(provider.id)
    assert {:error, :provider_unavailable} = ProviderSource.get(provider.id, allow_disabled: true)
    assert {:error, :provider_unavailable} = Connection.credential(connection)
    assert {:error, :credential_unavailable} = Credentials.resolve(credential.id)
  end

  test "encrypted content changes fence an existing client even when secret and timestamp match",
       %{bypass: bypass} do
    {credential, _provider, config} = linked_config(bypass, "fingerprint")
    rpc_stub(bypass, config.name)
    assert {:ok, server} = MCP.start(config)
    assert :ok = Server.await_ready(server)
    tool = "mcp:#{config.name}:echo"
    assert Registry.runtime_available?(tool)
    reencrypt_same_key(credential.id)
    refute Registry.runtime_available?(tool)
    assert {:error, :mcp_unavailable} = Server.execute_runtime(server, tool, %{}, %{}, 1_000)
  end

  test "late discovery cannot register tools from an obsolete credential generation", %{
    bypass: bypass
  } do
    {credential, _provider, config} = linked_config(bypass, "late")
    observer = self()

    rpc_stub(bypass, config.name, fn conn, request ->
      if request["method"] == "tools/list" do
        send(observer, {:discovery_waiting, self()})

        receive do
          :release -> :ok
        after
          5_000 -> flunk("discovery test was not released")
        end
      end

      conn
    end)

    assert {:ok, server} = MCP.start(config)
    assert_receive {:discovery_waiting, request}, 3_000
    reencrypt_same_key(credential.id)
    send(request, :release)
    assert {:error, {:discover_failed, :connection_changed}} = Server.await_ready(server)
    assert {:error, :not_found} = Registry.lookup("mcp:#{config.name}:echo")
  end

  test "shared rotation removes old clients and reconnects both sources with current authentication",
       %{bypass: bypass} do
    {credential, provider, config} = linked_config(bypass, "shared-one")

    {:ok, second_provider} =
      Providers.create(%{
        name: "shared-two",
        type: "openai",
        base_url: provider.base_url,
        credential_id: credential.id
      })

    {:ok, second_config} =
      MCPConfigs.create(%{
        name: "shared-two",
        provider_id: second_provider.id,
        transport: "streamable_http",
        url: config.url
      })

    observer = self()

    rpc_stub(bypass, "shared", fn conn, request ->
      if request["method"] == "initialize",
        do: send(observer, {:initialized, Plug.Conn.get_req_header(conn, "authorization")})

      conn
    end)

    {:ok, first} = MCP.start(config)
    {:ok, second} = MCP.start(second_config)
    assert :ok = Server.await_ready(first)
    assert :ok = Server.await_ready(second)
    assert_receive {:initialized, ["Bearer shared-credential-1234"]}
    assert_receive {:initialized, ["Bearer shared-credential-1234"]}
    Application.put_env(:synapsis_provider, :credential_invalidation, &MCP.credentials_changed/1)
    assert {:ok, _} = Credentials.update(credential.id, %{key: "rotated-credential-5678"})
    refute Process.alive?(first)
    refute Process.alive?(second)
    assert_receive {:initialized, ["Bearer rotated-credential-5678"]}, 3_000
    assert_receive {:initialized, ["Bearer rotated-credential-5678"]}, 3_000

    assert wait_until(fn ->
             Registry.runtime_available?("mcp:#{config.name}:echo") and
               Registry.runtime_available?("mcp:#{second_config.name}:echo")
           end)
  end

  test "a snapshot fetched before rotation cannot reconcile obsolete capabilities", %{
    bypass: bypass
  } do
    {credential, provider, _config} = linked_config(bypass, "snapshot-generation")

    {:ok, connection} =
      Connection.create(%{name: "snapshot-generation-source", provider_id: provider.id})

    client = fn current, _opts ->
      {:ok, _} = Credentials.update(credential.id, %{key: "new-snapshot-credential"})

      Snapshot.normalize(current, %{
        models: {:ok, [%{"id" => "stale-model"}]},
        skills: {:ok, []},
        mcp_tools: {:ok, []}
      })
    end

    assert {:error, :connection_changed} =
             Sync.run(connection.id, client: client, mcp_runtime: Runtime)

    assert {:ok, "new-snapshot-credential"} = Credentials.resolve(credential.id)
    assert {:ok, []} = Synapsis.Models.list(provider_id: provider.id)
  end

  test "rotation during unlocked reconnect prevents an obsolete successful snapshot commit", %{
    bypass: bypass
  } do
    {credential, provider, _config} = linked_config(bypass, "commit-generation")

    {:ok, connection} =
      Connection.create(%{name: "commit-generation-source", provider_id: provider.id})

    Process.put({RotatingRuntime, :credential_id}, credential.id)

    client = fn current, _opts ->
      Snapshot.normalize(current, %{
        models: {:ok, []},
        skills: {:ok, []},
        mcp_tools: {:ok, [%{"name" => "old-tool"}]}
      })
    end

    assert {:error, :connection_changed} =
             Sync.run(connection.id, client: client, mcp_runtime: RotatingRuntime)

    assert {:ok, "rotated-during-reconnect"} = Credentials.resolve(credential.id)
    assert {:ok, current} = Connection.get(connection.id)
    refute current.status == "ready"
    assert current.last_success_at == nil
  end

  test "credential changes leave a configured dormant source inactive", %{bypass: bypass} do
    {credential, _provider, config} = linked_config(bypass, "dormant")
    observer = self()

    rpc_stub(bypass, config.name, fn conn, request ->
      if request["method"] == "initialize", do: send(observer, :dormant_source_started)
      conn
    end)

    assert [] = Elixir.Registry.lookup(Synapsis.MCP.Registry, {:config_id, config.id})
    assert :ok = MCP.credentials_changed([credential.id])
    refute_receive :dormant_source_started, 500
    assert [] = Elixir.Registry.lookup(Synapsis.MCP.Registry, {:config_id, config.id})
  end

  defp linked_config(bypass, name) do
    {:ok, credential} = Credentials.create(%{name: "Shared", key: "shared-credential-1234"})

    {:ok, provider} =
      Providers.create(%{
        name: name,
        type: "openai",
        base_url: "http://localhost:#{bypass.port}/v1",
        credential_id: credential.id
      })

    {:ok, config} =
      MCPConfigs.create(%{
        name: name,
        provider_id: provider.id,
        transport: "streamable_http",
        url: "http://localhost:#{bypass.port}/mcp"
      })

    {credential, provider, config}
  end

  defp reencrypt_same_key(id) do
    {:ok, encrypted} = Synapsis.Encrypted.Binary.dump("shared-credential-1234")

    {:ok, _} =
      Store.merge_existing(:credential, id, %{
        "key_encrypted" => "enc:v1:" <> Base.encode64(encrypted)
      })
  end

  defp rpc_stub(bypass, name, before_response \\ fn conn, _ -> conn end) do
    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      conn = before_response.(conn, request)

      result =
        case request["method"] do
          "initialize" ->
            %{
              "protocolVersion" => request["params"]["protocolVersion"],
              "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => name, "version" => "1"}
            }

          "tools/list" ->
            %{"tools" => [%{"name" => "echo", "inputSchema" => %{"type" => "object"}}]}

          "tools/call" ->
            flunk("obsolete client dispatched a tool")

          _ ->
            %{}
        end

      if request["id"] do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
        )
      else
        Plug.Conn.resp(conn, 202, "")
      end
    end)

    for method <- ["GET", "DELETE"],
        do: Bypass.stub(bypass, method, "/mcp", &Plug.Conn.resp(&1, 200, ""))
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() ->
        true

      tries <= 0 ->
        false

      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end
end
