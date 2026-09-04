defmodule Synapsis.Backplane.SyncTest do
  use ExUnit.Case, async: false

  alias Synapsis.Backplane.{Client, Connection, Sync}
  alias Synapsis.MCP.Transport
  alias Synapsis.{Config.Store, MCPConfigs, Providers, Skills}

  defmodule MockClient do
    @behaviour Synapsis.Backplane.Client

    def fetch_models(_connection, opts), do: Keyword.fetch!(opts, :models)
    def list_skills(_connection, opts), do: Keyword.fetch!(opts, :skills)

    def fetch_skill(_connection, slug, opts) do
      opts |> Keyword.fetch!(:skill_details) |> Map.fetch!(slug)
    end

    def list_tools(_connection, opts), do: Keyword.fetch!(opts, :tools)
  end

  defmodule MockMCPRuntime do
    def restart(config) do
      send(self(), {:mcp_restarted, config})
      :ok
    end

    def stop(name) do
      send(self(), {:mcp_stopped, name})
      :ok
    end
  end

  setup do
    for type <- [:backplane, :provider, :skill, :mcp] do
      path =
        if type == :backplane,
          do: Path.join(Store.config_dir(), "backplanes.toml"),
          else: Store.file_path(type)

      File.rm(path)

      table = :"synapsis_config_#{type}"
      if :ets.info(table) != :undefined, do: :ets.delete_all_objects(table)
    end

    :ok
  end

  test "connection persists in Config.Store and sync imports source-owned capabilities idempotently" do
    assert {:ok, connection} =
             Connection.create(%{
               name: "team",
               base_url: "https://backplane.example.test",
               credential: "source-secret"
             })

    assert connection.status == "never_synced"

    assert {:ok, %{"id" => id, "base_url" => "https://backplane.example.test"}} =
             Store.get(:backplane, connection.id)

    assert id == connection.id

    client_opts = [
      models: {:ok, [%{"id" => "coding", "owned_by" => "team"}]},
      skills: {:ok, [%{"slug" => "repo-review", "name" => "Repo Review"}]},
      skill_details: %{
        "repo-review" =>
          {:ok,
           %{
             "slug" => "repo-review",
             "name" => "Repo Review",
             "description" => "Review repositories",
             "content" => "Inspect the diff before reporting."
           }}
      },
      tools:
        {:ok,
         [
           %{
             "name" => "memory::search",
             "description" => "Search memory",
             "inputSchema" => %{"type" => "object"}
           }
         ]}
    ]

    assert {:ok, synced} =
             Sync.run(connection.id,
               client: MockClient,
               client_opts: client_opts,
               mcp_runtime: MockMCPRuntime
             )

    assert_receive {:mcp_restarted, %{name: "backplane-team"}}
    assert synced.status == "ready"
    assert synced.unavailable == []
    assert synced.counts == %{"models" => 1, "skills" => 1, "tools" => 1}
    assert is_binary(synced.last_synced_at)

    assert {:ok, provider} = Providers.get_by_name("backplane-team")
    assert provider.base_url == "https://backplane.example.test/v1"
    assert provider.api_key_encrypted == "source-secret"
    assert provider.config["backplane_source_id"] == connection.id
    assert provider.config["available_models"] == [%{"id" => "coding", "owned_by" => "team"}]

    assert [skill] = Skills.list()
    assert skill.name == "Repo Review"
    assert skill.system_prompt_fragment == "Inspect the diff before reporting."
    assert skill.config_overrides["backplane_source_id"] == connection.id

    assert mcp = MCPConfigs.get_by_name("backplane-team")
    assert mcp.url == "https://backplane.example.test/mcp"
    assert mcp.config["backplane_source_id"] == connection.id

    assert {:streamable_http, transport_opts} = Transport.build(mcp)
    assert transport_opts[:headers] == %{"authorization" => "Bearer source-secret"}

    assert {:ok, status} = Sync.status(connection.id)
    assert status.status == "ready"
    assert status.counts == %{"models" => 1, "skills" => 1, "tools" => 1}
    assert status.credential_configured
    refute Map.get(status, :credential)
    refute inspect(status) =~ "source-secret"
    refute File.read!(Store.file_path(:backplane)) =~ "source-secret"
    refute File.read!(Store.file_path(:provider)) =~ "source-secret"
    refute File.read!(Store.file_path(:mcp)) =~ "source-secret"

    first_artifacts = synced.artifacts

    assert {:ok, _provider} = Providers.update(provider.id, %{enabled: false})
    assert {:ok, _skill} = Skills.update(skill, %{enabled: false})
    assert {:ok, _mcp} = MCPConfigs.update(mcp, %{enabled: false})

    changed_opts =
      client_opts
      |> Keyword.put(:models, {:ok, [%{"id" => "coding-v2"}]})
      |> Keyword.put(:skill_details, %{
        "repo-review" =>
          {:ok,
           %{
             "slug" => "repo-review",
             "name" => "Repo Review",
             "description" => "Review repositories",
             "content" => "Inspect the complete diff."
           }}
      })

    assert {:ok, resynced} =
             Sync.run(connection.id,
               client: MockClient,
               client_opts: changed_opts,
               mcp_runtime: MockMCPRuntime
             )

    assert resynced.artifacts == first_artifacts

    assert {:ok, [same_provider]} = Providers.list()
    assert same_provider.id == provider.id
    assert same_provider.enabled == false
    assert same_provider.config["available_models"] == [%{"id" => "coding-v2"}]

    assert [same_skill] = Skills.list()
    assert same_skill.id == skill.id
    assert same_skill.enabled == false
    assert same_skill.system_prompt_fragment == "Inspect the complete diff."
    assert [same_mcp] = MCPConfigs.list()
    assert same_mcp.id == mcp.id
    assert same_mcp.enabled == false
  end

  test "a failed surface preserves last-known-good imports and marks only that surface unavailable" do
    {:ok, connection} =
      Connection.create(%{name: "partial", base_url: "https://backplane.example.test"})

    good = [
      models: {:ok, [%{"id" => "stable-model"}]},
      skills: {:ok, []},
      skill_details: %{},
      tools: {:ok, []}
    ]

    assert {:ok, ready} =
             Sync.run(connection.id,
               client: MockClient,
               client_opts: good,
               mcp_runtime: MockMCPRuntime
             )

    assert ready.status == "ready"

    degraded = Keyword.put(good, :models, {:error, :unavailable})

    assert {:ok, result} =
             Sync.run(connection.id,
               client: MockClient,
               client_opts: degraded,
               mcp_runtime: MockMCPRuntime
             )

    assert result.status == "degraded"
    assert result.unavailable == ["models"]
    assert result.last_error =~ "models"

    assert {:ok, provider} = Providers.get_by_name("backplane-partial")
    assert provider.config["available_models"] == [%{"id" => "stable-model"}]
  end

  test "a successful scan retains disappeared capabilities as unavailable without changing local enablement" do
    {:ok, connection} =
      Connection.create(%{name: "prune", base_url: "https://backplane.example.test"})

    initial = [
      models: {:ok, [%{"id" => "gone-model"}]},
      skills:
        {:ok,
         [
           %{"slug" => "keep", "name" => "Keep"},
           %{"slug" => "gone", "name" => "Gone"}
         ]},
      skill_details: %{
        "keep" => {:ok, %{"slug" => "keep", "name" => "Keep", "content" => "keep"}},
        "gone" => {:ok, %{"slug" => "gone", "name" => "Gone", "content" => "gone"}}
      },
      tools: {:ok, [%{"name" => "gone-tool"}]}
    ]

    assert {:ok, first} =
             Sync.run(connection.id,
               client: MockClient,
               client_opts: initial,
               mcp_runtime: MockMCPRuntime
             )

    gone_id = first.artifacts["skill_ids"]["gone"]
    assert Skills.get(gone_id)

    current =
      initial
      |> Keyword.put(:models, {:ok, []})
      |> Keyword.put(:skills, {:ok, [%{"slug" => "keep", "name" => "Keep"}]})
      |> Keyword.put(:skill_details, %{
        "keep" => {:ok, %{"slug" => "keep", "name" => "Keep", "content" => "keep"}}
      })
      |> Keyword.put(:tools, {:ok, []})

    assert {:ok, synced} =
             Sync.run(connection.id,
               client: MockClient,
               client_opts: current,
               mcp_runtime: MockMCPRuntime
             )

    assert synced.artifacts["skill_ids"]["gone"] == gone_id
    assert %{enabled: true} = gone = Skills.get(gone_id)
    assert gone.config_overrides["backplane_available"] == false

    assert [%{name: "Gone", enabled: true}, %{name: "Keep", enabled: true}] = Skills.list()

    assert {:ok, provider} = Providers.get_by_name("backplane-prune")
    assert provider.enabled == true
    assert provider.config["backplane_available"] == false

    assert mcp = MCPConfigs.get_by_name("backplane-prune")
    assert mcp.enabled == true
    assert mcp.config["backplane_available"] == false
    assert_receive {:mcp_stopped, "backplane-prune"}
  end

  test "sync errors and status never expose the connection credential" do
    {:ok, connection} =
      Connection.create(%{
        name: "redacted",
        base_url: "https://backplane.example.test",
        credential: "never-print-this"
      })

    opts = [
      models: {:error, {:rejected, "never-print-this"}},
      skills: {:ok, []},
      skill_details: %{},
      tools: {:ok, []}
    ]

    assert {:ok, result} =
             Sync.run(connection.id,
               client: MockClient,
               client_opts: opts,
               mcp_runtime: MockMCPRuntime
             )

    refute result.last_error =~ "never-print-this"
    assert result.last_error =~ "[REDACTED]"
    assert {:ok, status} = Sync.status(connection.id)
    refute inspect(status) =~ "never-print-this"
  end

  test "real client uses audited paths and nonblank Bearer credential" do
    bypass = Bypass.open()

    {:ok, connection} =
      Connection.new(%{
        name: "http",
        base_url: endpoint_url(bypass.port),
        credential: "client-secret"
      })

    Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer client-secret"]
      json(conn, %{"object" => "list", "data" => [%{"id" => "model-a"}]})
    end)

    Bypass.expect_once(bypass, "GET", "/skills", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer client-secret"]
      json(conn, %{"data" => [%{"slug" => "review", "name" => "Review"}]})
    end)

    Bypass.expect_once(bypass, "GET", "/skills/review", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer client-secret"]
      json(conn, %{"slug" => "review", "name" => "Review", "content" => "Review it."})
    end)

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer client-secret"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body)["method"] do
        "initialize" ->
          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "session-1")
          |> json(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "result" => %{"protocolVersion" => "2025-03-26"}
          })

        "notifications/initialized" ->
          assert Plug.Conn.get_req_header(conn, "mcp-session-id") == ["session-1"]
          Plug.Conn.send_resp(conn, 202, "")

        "tools/list" ->
          assert Plug.Conn.get_req_header(conn, "mcp-session-id") == ["session-1"]

          json(conn, %{
            "jsonrpc" => "2.0",
            "id" => 2,
            "result" => %{"tools" => [%{"name" => "memory::search"}]}
          })
      end
    end)

    assert {:ok, [%{"id" => "model-a"}]} = Client.fetch_models(connection, timeout: 500)
    assert {:ok, [%{"slug" => "review"}]} = Client.list_skills(connection, timeout: 500)

    assert {:ok, %{"content" => "Review it."}} =
             Client.fetch_skill(connection, "review", timeout: 500)

    assert {:ok, [%{"name" => "memory::search"}]} =
             Client.list_tools(connection, timeout: 500)
  end

  test "real client omits authorization for a blank credential" do
    bypass = Bypass.open()

    {:ok, connection} =
      Connection.new(%{
        name: "keyless",
        base_url: endpoint_url(bypass.port),
        credential: "  "
      })

    Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      json(conn, %{"data" => []})
    end)

    assert {:ok, []} = Client.fetch_models(connection, timeout: 500)
  end

  defp endpoint_url(port), do: "http://localhost:#{port}"

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
