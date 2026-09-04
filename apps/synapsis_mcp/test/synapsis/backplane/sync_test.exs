defmodule Synapsis.Backplane.SyncTest do
  use ExUnit.Case, async: false

  alias Synapsis.Backplane.{Client, Connection, Snapshot, Sync}
  alias Synapsis.{Config.Store, MCPConfigs, Providers, Skills}

  defmodule MockClient do
    @behaviour Synapsis.Backplane.Client

    def fetch_snapshot(connection, opts) do
      case Keyword.fetch!(opts, :snapshot) do
        callback when is_function(callback, 1) -> callback.(connection)
        result -> result
      end
    end

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

  test "imports a normalized snapshot with durable source identity markers" do
    {:ok, connection} =
      Connection.create(%{
        name: "team",
        endpoint: "https://backplane.example.test",
        credential: "source-secret"
      })

    snapshot =
      snapshot!(connection,
        models: [%{"id" => "coding", "owned_by" => "team"}],
        skills: [
          %{
            "id" => "skill-42",
            "slug" => "repo-review",
            "name" => "Repo Review",
            "description" => "Review repositories",
            "content" => "Inspect the diff before reporting.",
            "content_available" => true,
            "source_kind" => "generated"
          }
        ],
        mcp_tools: [%{"name" => "memory::search", "description" => "Search memory"}]
      )

    assert {:ok, synced} =
             Sync.run(connection.id,
               client: MockClient,
               client_opts: [snapshot: {:ok, snapshot}],
               mcp_runtime: MockMCPRuntime,
               now: fn -> ~U[2026-09-04 12:00:00Z] end
             )

    assert synced.status == "ready"
    assert synced.stale == false
    assert synced.counts == %{"models" => 1, "skills" => 1, "tools" => 1}
    assert synced.last_attempt_at == "2026-09-04T12:00:00Z"
    assert synced.last_success_at == "2026-09-04T12:00:00Z"
    assert synced.last_synced_at == "2026-09-04T12:00:00Z"
    assert synced.source_revision == snapshot.source_revision

    assert {:ok, [provider]} = Providers.list()
    assert provider.type == "openai"
    assert provider.base_url == connection.endpoint <> "/v1"
    assert provider.config["available_models"] == [%{"id" => "coding", "owned_by" => "team"}]
    assert_markers(provider.config, connection.id, "openai-compatible", "provider", true)

    assert [skill] = Skills.list()
    assert skill.system_prompt_fragment == "Inspect the diff before reporting."
    assert_markers(skill.config_overrides, connection.id, "skill-42", "skill", true)

    assert [mcp] = MCPConfigs.list()
    assert mcp.url == connection.endpoint <> "/mcp"
    assert_markers(mcp.config, connection.id, "mcp", "mcp_server", true)

    assert synced.artifacts == %{
             "mcp_id" => mcp.id,
             "provider_id" => provider.id,
             "skill_ids" => %{"skill-42" => skill.id}
           }
  end

  test "reconciles by source identity after cache loss and preserves local-managed fields" do
    {:ok, connection} =
      Connection.create(%{name: "identity", endpoint: "https://backplane.example.test"})

    initial =
      snapshot!(connection,
        models: [%{"id" => "coding", "revision" => "model-v1"}],
        skills: [generated_skill("skill-42", "Repo Review", "Prompt v1")],
        mcp_tools: [%{"name" => "memory::search", "revision" => "tool-v1"}]
      )

    assert {:ok, first} = run_sync(connection, initial)
    assert {:ok, repeated} = run_sync(connection, initial)
    assert repeated.artifacts == first.artifacts
    assert {:ok, [provider]} = Providers.list()
    assert [skill] = Skills.list()
    assert [mcp] = MCPConfigs.list()

    provider_config = Map.put(provider.config, "aliases", %{"fast" => "coding"})

    assert {:ok, _provider} =
             Providers.update(provider.id, %{
               name: "local-provider",
               enabled: false,
               config: provider_config
             })

    skill_config = Map.put(skill.config_overrides, "local_override", true)

    assert {:ok, _skill} =
             Skills.update(skill, %{
               name: "Local Skill Name",
               enabled: false,
               tool_allowlist: ["workspace.read"],
               config_overrides: skill_config
             })

    mcp_config = Map.put(mcp.config, "local_option", "keep")

    assert {:ok, _mcp} =
             MCPConfigs.update(mcp, %{
               name: "local-mcp",
               enabled: false,
               headers: %{"x-local" => "keep"},
               config: mcp_config
             })

    {:ok, renamed} = Connection.update(repeated, %{name: "renamed", artifacts: %{}})

    changed =
      snapshot!(renamed,
        models: [%{"id" => "coding", "revision" => "model-v2"}],
        skills: [generated_skill("skill-42", "Upstream Renamed", "Prompt v2")],
        mcp_tools: [%{"name" => "memory::search", "revision" => "tool-v2"}]
      )

    assert {:ok, resynced} = run_sync(renamed, changed)
    assert resynced.source_revision == changed.source_revision
    assert resynced.artifacts == first.artifacts

    assert {:ok, [same_provider]} = Providers.list()
    assert same_provider.id == provider.id
    assert same_provider.name == "local-provider"
    assert same_provider.enabled == false
    assert same_provider.config["aliases"] == %{"fast" => "coding"}

    assert same_provider.config["available_models"] == [
             %{"id" => "coding", "revision" => "model-v2"}
           ]

    assert [same_skill] = Skills.list()
    assert same_skill.id == skill.id
    assert same_skill.name == "Local Skill Name"
    assert same_skill.enabled == false
    assert same_skill.tool_allowlist == ["workspace.read"]
    assert same_skill.config_overrides["local_override"] == true
    assert same_skill.system_prompt_fragment == "Prompt v2"

    assert [same_mcp] = MCPConfigs.list()
    assert same_mcp.id == mcp.id
    assert same_mcp.name == "local-mcp"
    assert same_mcp.enabled == false
    assert same_mcp.headers == %{"x-local" => "keep"}
    assert same_mcp.config["local_option"] == "keep"
  end

  test "does not overwrite unowned capabilities with colliding local names" do
    {:ok, connection} =
      Connection.create(%{name: "collision", endpoint: "https://backplane.example.test"})

    assert {:ok, local_provider} =
             Providers.create(%{
               name: "backplane-collision",
               type: "openai",
               base_url: "https://local.example.test/v1",
               config: %{"local" => true}
             })

    assert {:ok, local_skill} =
             Skills.create(%{
               name: "Same Skill",
               system_prompt_fragment: "local prompt",
               config_overrides: %{"local" => true}
             })

    assert {:ok, local_mcp} =
             MCPConfigs.create(%{
               name: "backplane-collision",
               transport: "streamable_http",
               url: "https://local.example.test/mcp",
               config: %{"local" => true}
             })

    snapshot =
      snapshot!(connection,
        models: [%{"id" => "coding"}],
        skills: [generated_skill("skill-42", "Same Skill", "source prompt")],
        mcp_tools: [%{"name" => "memory::search"}]
      )

    assert {:ok, _synced} = run_sync(connection, snapshot)

    assert {:ok, providers} = Providers.list()
    assert [_, _] = providers
    persisted_local_provider = Enum.find(providers, &(&1.id == local_provider.id))
    assert persisted_local_provider.base_url == local_provider.base_url
    assert persisted_local_provider.config == %{"local" => true}
    managed_provider = Enum.find(providers, &(&1.id != local_provider.id))
    assert managed_provider.name != local_provider.name
    assert_markers(managed_provider.config, connection.id, "openai-compatible", "provider", true)

    assert [_, _] = skills = Skills.list()
    persisted_local_skill = Enum.find(skills, &(&1.id == local_skill.id))
    managed_skill = Enum.find(skills, &(&1.id != local_skill.id))
    assert persisted_local_skill.system_prompt_fragment == "local prompt"
    assert managed_skill.name == "Same Skill"
    assert_markers(managed_skill.config_overrides, connection.id, "skill-42", "skill", true)

    assert [_, _] = mcps = MCPConfigs.list()
    persisted_local_mcp = Enum.find(mcps, &(&1.id == local_mcp.id))
    managed_mcp = Enum.find(mcps, &(&1.id != local_mcp.id))
    assert managed_mcp.name != local_mcp.name
    assert persisted_local_mcp.url == "https://local.example.test/mcp"
    assert_markers(managed_mcp.config, connection.id, "mcp", "mcp_server", true)
  end

  test "set_available changes source availability without changing local enablement" do
    {:ok, connection} =
      Connection.create(%{name: "availability", endpoint: "https://backplane.example.test"})

    snapshot =
      snapshot!(connection,
        models: [%{"id" => "coding"}],
        skills: [generated_skill("skill-42", "Review", "prompt")],
        mcp_tools: [%{"name" => "memory::search"}]
      )

    assert {:ok, _synced} = run_sync(connection, snapshot)
    assert_receive {:mcp_restarted, _config}
    assert {:ok, [provider]} = Providers.list()
    assert [skill] = Skills.list()
    assert [mcp] = MCPConfigs.list()
    assert {:ok, _provider} = Providers.update(provider.id, %{enabled: false})
    assert {:ok, _skill} = Skills.update(skill, %{enabled: false})

    assert {:ok, unavailable} =
             Sync.set_available(connection.id, false, mcp_runtime: MockMCPRuntime)

    assert unavailable.stale == true
    assert_receive {:mcp_stopped, name}
    assert name == mcp.name
    assert {:ok, offline_provider} = Providers.get(provider.id)
    assert offline_provider.enabled == false
    assert offline_provider.config["backplane_available"] == false
    assert offline_skill = Skills.get(skill.id)
    assert offline_skill.enabled == false
    assert offline_skill.config_overrides["backplane_available"] == false
    assert offline_mcp = MCPConfigs.get(mcp.id)
    assert offline_mcp.enabled == true
    assert offline_mcp.config["backplane_available"] == false

    assert {:ok, available} =
             Sync.set_available(connection.id, true, mcp_runtime: MockMCPRuntime)

    assert available.stale == false
    assert_receive {:mcp_restarted, %{id: mcp_id}}
    assert mcp_id == mcp.id
    assert {:ok, online_provider} = Providers.get(provider.id)
    assert online_provider.enabled == false
    assert online_provider.config["backplane_available"] == true
    assert online_skill = Skills.get(skill.id)
    assert online_skill.enabled == false
    assert online_skill.config_overrides["backplane_available"] == true
    assert online_mcp = MCPConfigs.get(mcp.id)
    assert online_mcp.enabled == true
    assert online_mcp.config["backplane_available"] == true
  end

  test "concurrent refreshes for one connection are serialized" do
    {:ok, connection} =
      Connection.create(%{name: "serialized", endpoint: "https://backplane.example.test"})

    snapshot =
      snapshot!(connection,
        models: [%{"id" => "coding"}],
        skills: [generated_skill("skill-42", "Review", "prompt")],
        mcp_tools: [%{"name" => "memory::search"}]
      )

    {:ok, tracker} = Agent.start_link(fn -> %{active: 0, max_active: 0, calls: 0} end)

    callback = fn _connection ->
      Agent.update(tracker, fn state ->
        active = state.active + 1

        %{
          state
          | active: active,
            max_active: max(state.max_active, active),
            calls: state.calls + 1
        }
      end)

      Process.sleep(75)
      Agent.update(tracker, &%{&1 | active: &1.active - 1})
      {:ok, snapshot}
    end

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Sync.run(connection.id,
            client: MockClient,
            client_opts: [snapshot: callback],
            mcp_runtime: MockMCPRuntime,
            lock_retries: 20
          )
        end)
      end

    assert [{:ok, _first}, {:ok, _second}] = Enum.map(tasks, &Task.await(&1, 5_000))
    assert %{calls: 2, max_active: 1} = Agent.get(tracker, & &1)
  end

  test "set_available waits for an in-flight refresh on the same connection" do
    {:ok, connection} =
      Connection.create(%{name: "availability-race", endpoint: "https://backplane.example.test"})

    snapshot =
      snapshot!(connection,
        models: [%{"id" => "coding"}],
        skills: [generated_skill("skill-42", "Review", "prompt")],
        mcp_tools: [%{"name" => "memory::search"}]
      )

    assert {:ok, _synced} = run_sync(connection, snapshot)
    parent = self()

    blocking_client = fn _connection ->
      send(parent, :refresh_blocked)
      receive do: (:release_refresh -> {:ok, snapshot})
    end

    refresh =
      Task.async(fn ->
        Sync.run(connection.id,
          client: MockClient,
          client_opts: [snapshot: blocking_client],
          mcp_runtime: MockMCPRuntime,
          lock_retries: 20
        )
      end)

    assert_receive :refresh_blocked

    disable =
      Task.async(fn ->
        Sync.set_available(connection.id, false,
          mcp_runtime: MockMCPRuntime,
          lock_retries: 20
        )
      end)

    assert Task.yield(disable, 50) == nil
    send(refresh.pid, :release_refresh)
    assert {:ok, _refreshed} = Task.await(refresh, 5_000)
    assert {:ok, unavailable} = Task.await(disable, 5_000)
    assert unavailable.status == "degraded"

    assert {:ok, [provider]} = Providers.list()
    assert provider.config["backplane_available"] == false
    assert [skill] = Skills.list()
    assert skill.config_overrides["backplane_available"] == false
    assert [mcp] = MCPConfigs.list()
    assert mcp.config["backplane_available"] == false
  end

  test "a failed surface preserves last-known-good imports and marks only that surface unavailable" do
    {:ok, connection} =
      Connection.create(%{
        name: "partial",
        endpoint: "https://backplane.example.test",
        credential: "never-print-this"
      })

    good =
      snapshot!(connection,
        models: [%{"id" => "stable-model"}],
        skills: [generated_skill("skill-42", "Review", "Prompt v1")],
        mcp_tools: [%{"name" => "memory::search"}]
      )

    assert {:ok, ready} = run_sync(connection, good)
    assert {:ok, provider_before} = Providers.get(ready.artifacts["provider_id"])
    revisions_before = ready.metadata["surface_revisions"]

    {:ok, partial} =
      Snapshot.normalize(
        connection,
        %{
          models: {:error, {:rejected, "never-print-this"}},
          skills: {:ok, [generated_skill("skill-42", "Review", "Prompt v2")]},
          mcp_tools: {:ok, [%{"name" => "memory::search", "revision" => "tool-v2"}]}
        },
        fetched_at: "2026-09-04T13:00:00Z"
      )

    assert {:ok, result} =
             run_sync(connection, partial, now: fn -> ~U[2026-09-04 13:00:00Z] end)

    assert result.status == "degraded"
    assert result.stale == true
    assert result.unavailable == ["models"]
    assert result.last_attempt_at == "2026-09-04T13:00:00Z"
    assert result.last_success_at == ready.last_success_at
    assert result.last_synced_at == ready.last_synced_at
    assert result.counts == %{"models" => 1, "skills" => 1, "tools" => 1}
    assert result.metadata["surface_revisions"]["models"] == revisions_before["models"]
    refute result.metadata["surface_revisions"]["skills"] == revisions_before["skills"]
    refute result.last_error =~ "never-print-this"
    assert result.last_error =~ "[REDACTED]"

    assert {:ok, provider_after} = Providers.get(provider_before.id)
    assert provider_after.config == provider_before.config

    assert Skills.get(result.artifacts["skill_ids"]["skill-42"]).system_prompt_fragment ==
             "Prompt v2"
  end

  test "a successful scan retains disappeared capabilities as unavailable without changing local enablement" do
    {:ok, connection} =
      Connection.create(%{name: "prune", endpoint: "https://backplane.example.test"})

    initial =
      snapshot!(connection,
        models: [%{"id" => "keep-model"}, %{"id" => "gone-model"}],
        skills: [
          generated_skill("keep-skill", "Keep", "keep"),
          generated_skill("gone-skill", "Gone", "gone")
        ],
        mcp_tools: [%{"name" => "keep-tool"}, %{"name" => "gone-tool"}]
      )

    assert {:ok, first} = run_sync(connection, initial)
    gone_id = first.artifacts["skill_ids"]["gone-skill"]
    gone = Skills.get(gone_id)
    assert {:ok, _gone} = Skills.update(gone, %{enabled: false})

    current =
      snapshot!(connection,
        models: [%{"id" => "keep-model"}],
        skills: [generated_skill("keep-skill", "Keep", "keep")],
        mcp_tools: [%{"name" => "keep-tool"}]
      )

    assert {:ok, synced} = run_sync(connection, current)

    assert synced.artifacts["skill_ids"]["gone-skill"] == gone_id
    assert %{enabled: false} = gone = Skills.get(gone_id)
    assert gone.config_overrides["backplane_available"] == false
    assert gone.config_overrides["source_available"] == false

    assert {:ok, provider} = Providers.get(synced.artifacts["provider_id"])
    assert provider.config["backplane_available"] == true
    assert provider.config["available_models"] == [%{"id" => "keep-model"}]
    models = Map.new(provider.config["backplane_models"], &{&1["external_id"], &1})
    assert models["keep-model"]["backplane_available"] == true
    assert models["gone-model"]["backplane_available"] == false
    assert models["gone-model"]["source_available"] == false

    assert mcp = MCPConfigs.get(synced.artifacts["mcp_id"])
    assert mcp.config["backplane_available"] == true
    tools = Map.new(mcp.config["backplane_tools"], &{&1["external_id"], &1})
    assert tools["keep-tool"]["backplane_available"] == true
    assert tools["gone-tool"]["backplane_available"] == false
    assert tools["gone-tool"]["source_available"] == false
    assert synced.counts == %{"models" => 1, "skills" => 1, "tools" => 1}

    empty = snapshot!(connection, models: [], skills: [], mcp_tools: [])
    assert {:ok, empty_sync} = run_sync(connection, empty)
    assert empty_sync.counts == %{"models" => 0, "skills" => 0, "tools" => 0}

    assert {:ok, empty_provider} = Providers.get(synced.artifacts["provider_id"])
    assert empty_provider.enabled == true
    assert empty_provider.config["backplane_available"] == false

    assert Enum.all?(
             empty_provider.config["backplane_models"],
             &(&1["backplane_available"] == false)
           )

    assert empty_mcp = MCPConfigs.get(synced.artifacts["mcp_id"])
    assert empty_mcp.enabled == true
    assert empty_mcp.config["backplane_available"] == false
    assert Enum.all?(empty_mcp.config["backplane_tools"], &(&1["backplane_available"] == false))
    assert_receive {:mcp_stopped, mcp_name}
    assert mcp_name == empty_mcp.name
  end

  test "metadata-only skills remain disabled and explicitly unavailable" do
    {:ok, connection} =
      Connection.create(%{name: "metadata", endpoint: "https://backplane.example.test"})

    metadata_only = %{
      "id" => "database-skill",
      "slug" => "database-skill",
      "name" => "Database Skill",
      "source_kind" => "database",
      "content_available" => false,
      "content_unavailable_reason" => "source_kind_not_exportable",
      "content_reference" => %{
        "slug" => "database-skill",
        "source_kind" => "database",
        "upstream_issue" => "gsmlg-opt/backplane#30"
      }
    }

    snapshot =
      snapshot!(connection,
        models: [%{"id" => "coding"}],
        skills: [metadata_only],
        mcp_tools: [%{"name" => "memory::search"}]
      )

    assert {:ok, synced} = run_sync(connection, snapshot)
    assert synced.status == "ready"
    assert [skill] = Skills.list()
    assert skill.enabled == false
    assert skill.system_prompt_fragment == nil
    assert skill.config_overrides["backplane_available"] == false
    assert skill.config_overrides["source_available"] == true
    assert skill.config_overrides["source_contents_available"] == false

    assert skill.config_overrides["source_metadata"]["content_reference"] ==
             metadata_only["content_reference"]

    assert {:ok, _available} =
             Sync.set_available(connection.id, true, mcp_runtime: MockMCPRuntime)

    assert Skills.get(skill.id).config_overrides["backplane_available"] == false
  end

  test "sync errors and status never expose the connection credential" do
    {:ok, connection} =
      Connection.create(%{
        name: "redacted",
        base_url: "https://backplane.example.test",
        credential: "never-print-this"
      })

    assert {:ok, result} =
             Sync.run(connection.id,
               client: MockClient,
               client_opts: [snapshot: {:error, {:rejected, "never-print-this"}}],
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

  defp run_sync(connection, snapshot, opts \\ []) do
    sync_opts =
      Keyword.merge(
        [
          client: MockClient,
          client_opts: [snapshot: {:ok, snapshot}],
          mcp_runtime: MockMCPRuntime,
          now: fn -> ~U[2026-09-04 12:00:00Z] end
        ],
        opts
      )

    Sync.run(connection.id, sync_opts)
  end

  defp generated_skill(id, name, content) do
    %{
      "id" => id,
      "slug" => String.downcase(String.replace(name, " ", "-")),
      "name" => name,
      "description" => "#{name} description",
      "content" => content,
      "content_available" => true,
      "source_kind" => "generated"
    }
  end

  defp snapshot!(connection, overrides) do
    surfaces = %{
      models: {:ok, Keyword.get(overrides, :models, [])},
      skills: {:ok, Keyword.get(overrides, :skills, [])},
      mcp_tools: {:ok, Keyword.get(overrides, :mcp_tools, [])}
    }

    {:ok, snapshot} =
      Snapshot.normalize(connection, surfaces, fetched_at: "2026-09-04T12:00:00Z")

    snapshot
  end

  defp assert_markers(markers, connection_id, external_id, kind, available) do
    assert markers["managed_by"] == "backplane"
    assert markers["source"] == "backplane"
    assert markers["backplane_source_id"] == connection_id
    assert markers["connection_id"] == connection_id
    assert markers["external_id"] == external_id
    assert markers["kind"] == kind
    assert markers["backplane_available"] == available
    assert is_binary(markers["external_revision"])
    assert is_map(markers["source_metadata"])
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
