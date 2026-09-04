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

  defmodule FlakyMCPRuntime do
    def configure(stop_results), do: Process.put({__MODULE__, :stop_results}, stop_results)

    def restart(config) do
      send(self(), {:mcp_restarted, config})
      :ok
    end

    def stop(name) do
      [result | remaining] = Process.get({__MODULE__, :stop_results}, [:ok])
      Process.put({__MODULE__, :stop_results}, remaining)
      send(self(), {:mcp_stop_attempt, name, result})
      result
    end
  end

  defmodule FailingRestartMCPRuntime do
    def restart(config) do
      send(self(), {:mcp_restart_failed, config.id})
      {:error, :restart_failed}
    end

    def stop(_name), do: :ok
  end

  defmodule StatefulMCPRuntime do
    def configure(pid, restart_results) do
      Process.put({__MODULE__, :pid}, pid)

      Agent.update(pid, fn _state ->
        %{active: nil, restart_results: restart_results, restart_calls: [], stop_calls: []}
      end)
    end

    def restart(config) do
      pid = Process.get({__MODULE__, :pid}) || raise "stateful MCP runtime is not configured"

      result =
        Agent.get_and_update(pid, fn state ->
          [result | remaining] = state.restart_results
          active = if result == :ok, do: config, else: nil

          {result,
           %{
             state
             | active: active,
               restart_results: remaining,
               restart_calls: state.restart_calls ++ [config]
           }}
        end)

      result
    end

    def stop(name) do
      pid = Process.get({__MODULE__, :pid}) || raise "stateful MCP runtime is not configured"

      Agent.update(pid, fn state ->
        %{state | active: nil, stop_calls: state.stop_calls ++ [name]}
      end)

      :ok
    end
  end

  defmodule FailingProviderStore do
    def configure(results), do: Process.put({__MODULE__, :results}, results)

    def list, do: Synapsis.Providers.list()

    def update(id, attrs) do
      case next_result() do
        :ok -> Synapsis.Providers.update(id, attrs)
        {:error, _reason} = error -> error
      end
    end

    defp next_result do
      case Process.get({__MODULE__, :results}, []) do
        [result | remaining] ->
          Process.put({__MODULE__, :results}, remaining)
          result

        [] ->
          :ok
      end
    end
  end

  defmodule FailingSkillStore do
    def configure(failures) do
      Process.put({__MODULE__, :state}, %{call: 0, failures: Map.new(failures)})
    end

    def list, do: Synapsis.Skills.list()
    def get(id), do: Synapsis.Skills.get(id)
    def create(attrs), do: write(fn -> Synapsis.Skills.create(attrs) end)
    def update(skill, attrs), do: write(fn -> Synapsis.Skills.update(skill, attrs) end)
    def delete(skill), do: write(fn -> Synapsis.Skills.delete(skill) end)

    defp write(callback) do
      state = Process.get({__MODULE__, :state}, %{call: 0, failures: %{}})
      call = state.call + 1
      Process.put({__MODULE__, :state}, %{state | call: call})

      case Map.fetch(state.failures, call) do
        {:ok, reason} -> {:error, reason}
        :error -> callback.()
      end
    end
  end

  defmodule FailingMCPStore do
    def configure(failures) do
      Process.put({__MODULE__, :state}, %{call: 0, failures: Map.new(failures)})
    end

    def list, do: Synapsis.MCPConfigs.list()
    def create(attrs), do: Synapsis.MCPConfigs.create(attrs)
    def delete(config), do: Synapsis.MCPConfigs.delete(config)

    def update(config, attrs) do
      state = Process.get({__MODULE__, :state}, %{call: 0, failures: %{}})
      call = state.call + 1
      Process.put({__MODULE__, :state}, %{state | call: call})

      case Map.fetch(state.failures, call) do
        {:ok, reason} -> {:error, reason}
        :error -> Synapsis.MCPConfigs.update(config, attrs)
      end
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

  test "set_available true does not claim a never-synced or failed connection is ready" do
    {:ok, never_synced} =
      Connection.create(%{name: "never-ready", endpoint: "https://backplane.example.test"})

    assert {:ok, unchanged} =
             Sync.set_available(never_synced.id, true, mcp_runtime: MockMCPRuntime)

    assert unchanged.status == "never_synced"
    assert unchanged.stale == true
    assert unchanged.last_success_at == nil

    assert {:ok, failed} =
             Sync.run(never_synced.id,
               client: MockClient,
               client_opts: [snapshot: {:error, :offline}],
               mcp_runtime: MockMCPRuntime
             )

    assert failed.status == "degraded"
    assert failed.last_error =~ "offline"

    assert {:ok, still_failed} =
             Sync.set_available(failed.id, true, mcp_runtime: MockMCPRuntime)

    assert still_failed.status == "degraded"
    assert still_failed.stale == true
    assert still_failed.last_success_at == nil
    assert still_failed.last_error == failed.last_error
    assert still_failed.metadata["surface_errors"] == failed.metadata["surface_errors"]
  end

  test "explicit disable attempts every surface and persists provider failures" do
    {:ok, connection} =
      Connection.create(%{
        name: "availability-failure",
        endpoint: "https://backplane.example.test"
      })

    snapshot =
      snapshot!(connection,
        models: [%{"id" => "coding"}],
        skills: [generated_skill("skill-42", "Review", "prompt")],
        mcp_tools: [%{"name" => "memory::search"}]
      )

    assert {:ok, ready} = run_sync(connection, snapshot)
    assert_receive {:mcp_restarted, _config}
    [skill] = Skills.list()
    [mcp] = MCPConfigs.list()
    FailingProviderStore.configure([{:error, :provider_write_failed}])
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:daemon")

    assert {:error, {:availability_failed, %{"models" => :provider_write_failed}}} =
             Sync.set_available(ready.id, false,
               provider_store: FailingProviderStore,
               mcp_runtime: MockMCPRuntime
             )

    assert_receive {:mcp_stopped, _name}
    assert Skills.get(skill.id).config_overrides["backplane_available"] == false
    assert MCPConfigs.get(mcp.id).config["backplane_available"] == false
    assert {:ok, degraded} = Connection.get(ready.id)
    assert degraded.status == "degraded"
    assert degraded.stale == true
    assert degraded.unavailable == ~w(models skills tools)
    assert degraded.metadata["surface_errors"]["models"] =~ "provider_write_failed"
    assert_receive {:agent_daemon_event, %{event: "backplane.capabilities.updated"}}
  end

  test "explicit disable persists skill failures while making other surfaces unavailable" do
    {:ok, connection} =
      Connection.create(%{
        name: "skill-availability-failure",
        endpoint: "https://backplane.example.test"
      })

    snapshot =
      snapshot!(connection,
        models: [%{"id" => "coding"}],
        skills: [generated_skill("skill-42", "Review", "prompt")],
        mcp_tools: [%{"name" => "memory::search"}]
      )

    assert {:ok, ready} = run_sync(connection, snapshot)
    assert_receive {:mcp_restarted, _config}
    [skill] = Skills.list()
    [mcp] = MCPConfigs.list()
    FailingSkillStore.configure([{1, :skill_availability_write_failed}])

    assert {:error, {:availability_failed, %{"skills" => :skill_availability_write_failed}}} =
             Sync.set_available(ready.id, false,
               skill_store: FailingSkillStore,
               mcp_runtime: MockMCPRuntime
             )

    assert_receive {:mcp_stopped, _name}
    assert Skills.get(skill.id).config_overrides["backplane_available"] == true
    assert MCPConfigs.get(mcp.id).config["backplane_available"] == false
    assert {:ok, [provider]} = Providers.list()
    assert provider.config["backplane_available"] == false
    assert {:ok, degraded} = Connection.get(ready.id)
    assert degraded.status == "degraded"
    assert degraded.metadata["surface_errors"]["skills"] =~ "skill_availability_write_failed"
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

  test "a forged already_locked option cannot bypass the connection lock" do
    {:ok, connection} =
      Connection.create(%{name: "forged-lock", endpoint: "https://backplane.example.test"})

    parent = self()

    holder =
      Task.async(fn ->
        Sync.with_lock(connection.id, [lock_retries: 20], fn ->
          send(parent, :lock_held)
          receive do: (:release_lock -> :ok)
        end)
      end)

    assert_receive :lock_held

    forged =
      Task.async(fn ->
        Sync.set_available(connection.id, false,
          already_locked: true,
          mcp_runtime: MockMCPRuntime,
          lock_retries: 20
        )
      end)

    assert Task.yield(forged, 50) == nil
    send(holder.pid, :release_lock)
    assert :ok = Task.await(holder)
    assert {:ok, %{status: "degraded"}} = Task.await(forged)
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

  test "source-disabled-only models and tools keep their owners out of runtime APIs" do
    {:ok, connection} =
      Connection.create(%{name: "disabled-only", endpoint: "https://backplane.example.test"})

    snapshot =
      snapshot!(connection,
        models: [%{"id" => "disabled-model", "enabled" => false}],
        skills: [],
        mcp_tools: [%{"name" => "disabled-tool", "enabled" => false}]
      )

    assert {:ok, synced} = run_sync(connection, snapshot)
    assert {:ok, provider} = Providers.get(synced.artifacts["provider_id"])
    refute Providers.runtime_available?(provider)
    assert provider.config["available_models"] == []
    assert {:error, :provider_unavailable} = Providers.models_for(provider.name)

    assert [model] = provider.config["backplane_models"]
    assert model["external_id"] == "disabled-model"
    assert model["source_available"] == false
    assert model["backplane_available"] == false

    assert mcp = MCPConfigs.get(synced.artifacts["mcp_id"])
    refute MCPConfigs.runtime_available?(mcp)
    assert MCPConfigs.enabled() == []
    assert_receive {:mcp_stopped, mcp_name}
    assert mcp_name == mcp.name

    assert [tool] = mcp.config["backplane_tools"]
    assert tool["external_id"] == "disabled-tool"
    assert tool["source_available"] == false
    assert tool["backplane_available"] == false
  end

  test "mixed model and tool surfaces expose only source-enabled entries" do
    {:ok, connection} =
      Connection.create(%{name: "mixed-enabled", endpoint: "https://backplane.example.test"})

    snapshot =
      snapshot!(connection,
        models: [
          %{"id" => "disabled-model", "enabled" => false},
          %{"id" => "enabled-model", "enabled" => true}
        ],
        skills: [],
        mcp_tools: [
          %{"name" => "disabled-tool", "enabled" => false},
          %{"name" => "enabled-tool", "enabled" => true}
        ]
      )

    assert {:ok, synced} = run_sync(connection, snapshot)
    assert {:ok, provider} = Providers.get(synced.artifacts["provider_id"])
    assert Providers.runtime_available?(provider)
    assert provider.config["available_models"] == [%{"enabled" => true, "id" => "enabled-model"}]
    assert {:ok, [%{id: "enabled-model"}]} = Providers.models_for(provider.name)

    models = Map.new(provider.config["backplane_models"], &{&1["external_id"], &1})
    assert models["enabled-model"]["backplane_available"] == true
    assert models["disabled-model"]["backplane_available"] == false

    assert mcp = MCPConfigs.get(synced.artifacts["mcp_id"])
    assert MCPConfigs.runtime_available?(mcp)
    assert [enabled_mcp] = MCPConfigs.enabled()
    assert enabled_mcp.id == mcp.id
    assert_receive {:mcp_restarted, %{id: mcp_id}}
    assert mcp_id == mcp.id

    tools = Map.new(mcp.config["backplane_tools"], &{&1["external_id"], &1})
    assert tools["enabled-tool"]["backplane_available"] == true
    assert tools["disabled-tool"]["backplane_available"] == false
  end

  test "a malformed skill surface retains all skill LKG while models and tools reconcile" do
    {:ok, connection} =
      Connection.create(%{name: "contained", endpoint: "https://backplane.example.test"})

    initial =
      snapshot!(connection,
        models: [%{"id" => "coding", "revision" => "model-v1"}],
        skills: [generated_skill("a-skill", "Review", "Prompt v1")],
        mcp_tools: [%{"name" => "memory::search", "revision" => "tool-v1"}]
      )

    assert {:ok, ready} = run_sync(connection, initial)
    skill_id = ready.artifacts["skill_ids"]["a-skill"]
    revisions_v1 = ready.metadata["surface_revisions"]
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:daemon")

    malformed =
      generated_skill("z-invalid", String.duplicate("x", 256), "invalid")

    update =
      snapshot!(connection,
        models: [%{"id" => "coding", "revision" => "model-v2"}],
        skills: [generated_skill("a-skill", "Review", "Prompt v2"), malformed],
        mcp_tools: [%{"name" => "memory::search", "revision" => "tool-v2"}]
      )

    assert {:ok, degraded} = run_sync(connection, update)
    assert degraded.status == "degraded"
    assert degraded.stale == true
    assert degraded.unavailable == ["skills"]
    assert degraded.counts == %{"models" => 1, "skills" => 1, "tools" => 1}
    assert degraded.metadata["surface_revisions"]["skills"] == revisions_v1["skills"]
    refute degraded.metadata["surface_revisions"]["models"] == revisions_v1["models"]
    refute degraded.metadata["surface_revisions"]["mcp_tools"] == revisions_v1["mcp_tools"]
    assert degraded.artifacts["skill_ids"] == ready.artifacts["skill_ids"]

    assert Skills.get(skill_id).system_prompt_fragment == "Prompt v1"
    assert length(Skills.list()) == 1

    assert {:ok, provider} = Providers.get(degraded.artifacts["provider_id"])
    assert provider.config["available_models"] == [%{"id" => "coding", "revision" => "model-v2"}]

    assert mcp = MCPConfigs.get(degraded.artifacts["mcp_id"])
    assert [tool] = mcp.config["backplane_tools"]
    assert tool["source_metadata"]["revision"] == "tool-v2"

    assert_receive {:agent_daemon_event, %{event: "backplane.sync.started"}}
    assert_receive {:agent_daemon_event, %{event: "backplane.sync.failed"}}
    assert_receive {:agent_daemon_event, %{event: "backplane.capabilities.updated"}}
    refute_receive {:agent_daemon_event, %{event: "backplane.sync.completed"}}
  end

  test "a mid-write skill failure rolls the whole surface back while later surfaces reconcile" do
    {:ok, connection} =
      Connection.create(%{name: "skill-write-lkg", endpoint: "https://backplane.example.test"})

    v1 =
      snapshot!(connection,
        models: [%{"id" => "coding", "revision" => "model-v1"}],
        skills: [
          generated_skill("skill-a", "Alpha", "Alpha v1"),
          generated_skill("skill-b", "Beta", "Beta v1")
        ],
        mcp_tools: [%{"name" => "memory::search", "revision" => "tool-v1"}]
      )

    assert {:ok, ready} = run_sync(connection, v1)
    original_skills = Skills.list()
    revisions_v1 = ready.metadata["surface_revisions"]
    FailingSkillStore.configure([{2, :second_skill_write_failed}])

    v2 =
      snapshot!(connection,
        models: [%{"id" => "coding", "revision" => "model-v2"}],
        skills: [
          generated_skill("skill-a", "Alpha", "Alpha v2"),
          generated_skill("skill-b", "Beta", "Beta v2")
        ],
        mcp_tools: [%{"name" => "memory::search", "revision" => "tool-v2"}]
      )

    assert {:ok, degraded} = run_sync(connection, v2, skill_store: FailingSkillStore)
    assert degraded.unavailable == ["skills"]
    assert degraded.last_error =~ "second_skill_write_failed"
    assert degraded.metadata["surface_revisions"]["skills"] == revisions_v1["skills"]
    refute degraded.metadata["surface_revisions"]["models"] == revisions_v1["models"]
    refute degraded.metadata["surface_revisions"]["mcp_tools"] == revisions_v1["mcp_tools"]
    assert Skills.list() == original_skills
  end

  test "a disappearance write failure rolls the complete skill surface back" do
    {:ok, connection} =
      Connection.create(%{
        name: "skill-disappear-lkg",
        endpoint: "https://backplane.example.test"
      })

    v1 =
      snapshot!(connection,
        models: [%{"id" => "coding"}],
        skills: [
          generated_skill("skill-a", "Alpha", "Alpha v1"),
          generated_skill("skill-b", "Beta", "Beta v1")
        ],
        mcp_tools: []
      )

    assert {:ok, ready} = run_sync(connection, v1)
    original_skills = Skills.list()
    revision_v1 = ready.metadata["surface_revisions"]["skills"]
    FailingSkillStore.configure([{2, :disappearance_write_failed}])

    v2 = snapshot!(connection, models: [%{"id" => "coding"}], skills: [], mcp_tools: [])

    assert {:ok, degraded} = run_sync(connection, v2, skill_store: FailingSkillStore)
    assert degraded.unavailable == ["skills"]
    assert degraded.last_error =~ "disappearance_write_failed"
    assert degraded.metadata["surface_revisions"]["skills"] == revision_v1
    assert Skills.list() == original_skills
  end

  test "a failed skill rollback is reported and leaves owned skills unavailable" do
    {:ok, connection} =
      Connection.create(%{name: "skill-fail-closed", endpoint: "https://backplane.example.test"})

    v1 =
      snapshot!(connection,
        models: [%{"id" => "coding"}],
        skills: [
          generated_skill("skill-a", "Alpha", "Alpha v1"),
          generated_skill("skill-b", "Beta", "Beta v1")
        ],
        mcp_tools: []
      )

    assert {:ok, _ready} = run_sync(connection, v1)
    FailingSkillStore.configure([{2, :surface_write_failed}, {3, :rollback_write_failed}])

    v2 =
      snapshot!(connection,
        models: [%{"id" => "coding"}],
        skills: [
          generated_skill("skill-a", "Alpha", "Alpha v2"),
          generated_skill("skill-b", "Beta", "Beta v2")
        ],
        mcp_tools: []
      )

    assert {:ok, degraded} = run_sync(connection, v2, skill_store: FailingSkillStore)
    assert degraded.unavailable == ["skills"]
    assert degraded.last_error =~ "surface_write_failed"
    assert degraded.last_error =~ "rollback_write_failed"

    assert Enum.all?(Skills.list(), fn skill ->
             skill.config_overrides["backplane_available"] == false
           end)
  end

  test "an MCP runtime reconciliation error retains the complete tool surface LKG" do
    {:ok, connection} =
      Connection.create(%{name: "tool-lkg", endpoint: "https://backplane.example.test"})

    initial =
      snapshot!(connection,
        models: [%{"id" => "coding"}],
        skills: [],
        mcp_tools: [%{"name" => "memory::search", "revision" => "tool-v1"}]
      )

    assert {:ok, ready} = run_sync(connection, initial)
    assert mcp_v1 = MCPConfigs.get(ready.artifacts["mcp_id"])
    tools_revision_v1 = ready.metadata["surface_revisions"]["mcp_tools"]

    update =
      snapshot!(connection,
        models: [%{"id" => "coding"}],
        skills: [],
        mcp_tools: [%{"name" => "memory::search", "revision" => "tool-v2"}]
      )

    assert {:ok, degraded} =
             run_sync(connection, update, mcp_runtime: FailingRestartMCPRuntime)

    assert_receive {:mcp_restart_failed, mcp_id}
    assert mcp_id == mcp_v1.id
    assert degraded.status == "degraded"
    assert degraded.unavailable == ["tools"]
    assert degraded.counts["tools"] == 1
    assert degraded.metadata["surface_revisions"]["mcp_tools"] == tools_revision_v1
    fail_closed = MCPConfigs.get(mcp_v1.id)
    refute MCPConfigs.runtime_available?(fail_closed)
    assert fail_closed.config["external_revision"] == mcp_v1.config["external_revision"]
    assert fail_closed.config["backplane_available"] == false
    assert tool_revision(fail_closed) == "tool-v1"
  end

  test "a failed v2 restart restores both persisted and active v1 tool state" do
    {:ok, runtime_state} = Agent.start_link(fn -> %{} end)

    StatefulMCPRuntime.configure(runtime_state, [
      :ok,
      {:error, :v2_restart_failed},
      :ok
    ])

    {:ok, connection} =
      Connection.create(%{name: "runtime-lkg", endpoint: "https://backplane.example.test"})

    v1 =
      snapshot!(connection,
        models: [%{"id" => "coding"}],
        skills: [],
        mcp_tools: [%{"name" => "memory::search", "revision" => "tool-v1"}]
      )

    assert {:ok, ready} =
             run_sync(connection, v1, mcp_runtime: StatefulMCPRuntime)

    mcp_v1 = MCPConfigs.get(ready.artifacts["mcp_id"])
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:daemon")

    v2 =
      snapshot!(connection,
        models: [%{"id" => "coding"}],
        skills: [],
        mcp_tools: [%{"name" => "memory::search", "revision" => "tool-v2"}]
      )

    assert {:ok, degraded} =
             run_sync(connection, v2, mcp_runtime: StatefulMCPRuntime)

    assert degraded.status == "degraded"
    assert degraded.unavailable == ["tools"]
    assert degraded.last_error =~ "v2_restart_failed"
    assert MCPConfigs.get(mcp_v1.id) == mcp_v1

    state = Agent.get(runtime_state, & &1)
    assert state.active == mcp_v1
    assert [^mcp_v1, attempted_v2, ^mcp_v1] = state.restart_calls
    assert tool_revision(attempted_v2) == "tool-v2"
    assert tool_revision(state.active) == "tool-v1"

    assert_receive {:agent_daemon_event, %{event: "backplane.sync.started"}}
    assert_receive {:agent_daemon_event, %{event: "backplane.sync.failed"}}
    refute_receive {:agent_daemon_event, %{event: "backplane.sync.completed"}}
    refute_receive {:agent_daemon_event, %{event: "backplane.capabilities.updated"}}
  end

  test "a failed rollback restart durably disables restored v1 until a successful refresh" do
    {:ok, runtime_state} = Agent.start_link(fn -> %{} end)

    StatefulMCPRuntime.configure(runtime_state, [
      :ok,
      {:error, :v2_restart_failed},
      {:error, :v1_rollback_failed}
    ])

    {:ok, connection} =
      Connection.create(%{
        name: "runtime-fail-closed",
        endpoint: "https://backplane.example.test"
      })

    v1 =
      snapshot!(connection,
        models: [%{"id" => "coding"}],
        skills: [],
        mcp_tools: [%{"name" => "memory::search", "revision" => "tool-v1"}]
      )

    assert {:ok, ready} =
             run_sync(connection, v1, mcp_runtime: StatefulMCPRuntime)

    mcp_v1 = MCPConfigs.get(ready.artifacts["mcp_id"])

    assert {:ok, mcp_v1} =
             MCPConfigs.update(mcp_v1, %{
               headers: %{"x-local" => "keep"},
               config: Map.put(mcp_v1.config, "local_option", "keep")
             })

    Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:daemon")

    v2 =
      snapshot!(connection,
        models: [%{"id" => "coding"}],
        skills: [],
        mcp_tools: [%{"name" => "memory::search", "revision" => "tool-v2"}]
      )

    assert {:ok, degraded} =
             run_sync(connection, v2, mcp_runtime: StatefulMCPRuntime)

    assert degraded.status == "degraded"
    assert degraded.unavailable == ["tools"]
    assert degraded.last_error =~ "v2_restart_failed"
    assert degraded.last_error =~ "v1_rollback_failed"

    fail_closed = MCPConfigs.get(mcp_v1.id)
    refute MCPConfigs.runtime_available?(fail_closed)
    assert fail_closed.name == mcp_v1.name
    assert fail_closed.headers == %{"x-local" => "keep"}
    assert fail_closed.config["local_option"] == "keep"
    assert fail_closed.config["external_revision"] == mcp_v1.config["external_revision"]
    assert fail_closed.config["backplane_available"] == false
    assert tool_revision(fail_closed) == "tool-v1"
    assert [fail_closed_tool] = fail_closed.config["backplane_tools"]
    assert fail_closed_tool["source_available"] == true
    assert fail_closed_tool["backplane_available"] == false

    assert {:error, :mcp_unavailable} = Synapsis.MCP.start(fail_closed)
    assert :ok = Synapsis.MCP.start_enabled()
    refute fail_closed.name in Synapsis.MCP.list()

    state = Agent.get(runtime_state, & &1)
    assert state.active == nil
    assert state.stop_calls == [mcp_v1.name]
    assert [initial_v1, attempted_v2, ^mcp_v1] = state.restart_calls
    assert initial_v1.id == mcp_v1.id
    assert tool_revision(attempted_v2) == "tool-v2"

    assert_receive {:agent_daemon_event, %{event: "backplane.sync.started"}}
    assert_receive {:agent_daemon_event, %{event: "backplane.sync.failed"}}
    assert_receive {:agent_daemon_event, %{event: "backplane.capabilities.updated"}}
    refute_receive {:agent_daemon_event, %{event: "backplane.sync.completed"}}

    StatefulMCPRuntime.configure(runtime_state, [:ok])

    assert {:ok, recovered} =
             run_sync(connection, v2, mcp_runtime: StatefulMCPRuntime)

    assert recovered.status == "ready"
    available_v2 = MCPConfigs.get(mcp_v1.id)
    assert MCPConfigs.runtime_available?(available_v2)
    assert available_v2.config["local_option"] == "keep"
    assert available_v2.headers == %{"x-local" => "keep"}
    assert available_v2.config["backplane_available"] == true
    assert tool_revision(available_v2) == "tool-v2"
  end

  test "a fail-closed persistence error is compounded and the runtime remains stopped" do
    {:ok, runtime_state} = Agent.start_link(fn -> %{} end)

    StatefulMCPRuntime.configure(runtime_state, [
      :ok,
      {:error, :v2_restart_failed},
      {:error, :v1_rollback_failed}
    ])

    {:ok, connection} =
      Connection.create(%{
        name: "runtime-fail-closed-persist",
        endpoint: "https://backplane.example.test"
      })

    v1 =
      snapshot!(connection,
        models: [%{"id" => "coding"}],
        skills: [],
        mcp_tools: [%{"name" => "memory::search", "revision" => "tool-v1"}]
      )

    assert {:ok, ready} =
             run_sync(connection, v1, mcp_runtime: StatefulMCPRuntime)

    mcp_v1 = MCPConfigs.get(ready.artifacts["mcp_id"])
    FailingMCPStore.configure([{3, :fail_closed_persist_failed}])

    v2 =
      snapshot!(connection,
        models: [%{"id" => "coding"}],
        skills: [],
        mcp_tools: [%{"name" => "memory::search", "revision" => "tool-v2"}]
      )

    assert {:ok, degraded} =
             run_sync(connection, v2,
               mcp_runtime: StatefulMCPRuntime,
               mcp_store: FailingMCPStore
             )

    assert degraded.status == "degraded"
    assert degraded.unavailable == ["tools"]
    assert degraded.last_error =~ "v2_restart_failed"
    assert degraded.last_error =~ "v1_rollback_failed"
    assert degraded.last_error =~ "fail_closed_persist_failed"
    assert MCPConfigs.get(mcp_v1.id) == mcp_v1

    state = Agent.get(runtime_state, & &1)
    assert state.active == nil
    assert state.stop_calls == [mcp_v1.name]
  end

  test "MCP stop failure persists degraded availability and a successful retry clears it" do
    {:ok, connection} =
      Connection.create(%{name: "stop-retry", endpoint: "https://backplane.example.test"})

    snapshot =
      snapshot!(connection,
        models: [%{"id" => "coding"}],
        skills: [generated_skill("skill-42", "Review", "prompt")],
        mcp_tools: [%{"name" => "memory::search"}]
      )

    assert {:ok, ready} = run_sync(connection, snapshot)
    assert_receive {:mcp_restarted, _config}
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:daemon")
    FlakyMCPRuntime.configure([{:error, :stop_failed}, :ok])

    assert {:error,
            {:availability_failed, %{"tools" => {:runtime_reconcile_failed, :stop_failed}}}} =
             Sync.set_available(connection.id, false, mcp_runtime: FlakyMCPRuntime)

    assert_receive {:mcp_stop_attempt, _name, {:error, :stop_failed}}
    assert {:ok, failed} = Connection.get(connection.id)
    assert failed.status == "degraded"
    assert failed.stale == true
    assert failed.unavailable == ["models", "skills", "tools"]
    assert failed.last_success_at == ready.last_success_at
    assert failed.last_error =~ "stop_failed"
    assert failed.metadata["surface_errors"]["tools"] =~ "stop_failed"

    assert_receive {:agent_daemon_event,
                    %{event: "backplane.capabilities.updated"} = failed_event}

    assert failed_event.status == "degraded"
    assert failed_event.error =~ "stop_failed"
    refute_receive {:agent_daemon_event, %{event: "backplane.sync.started"}}
    refute_receive {:agent_daemon_event, %{event: "backplane.sync.completed"}}
    refute_receive {:agent_daemon_event, %{event: "backplane.sync.failed"}}

    assert {:ok, retried} =
             Sync.set_available(connection.id, false, mcp_runtime: FlakyMCPRuntime)

    assert_receive {:mcp_stop_attempt, _name, :ok}
    assert retried.status == "degraded"
    assert retried.stale == true
    assert retried.unavailable == ["models", "skills", "tools"]
    assert retried.last_error == nil
    assert retried.metadata["surface_errors"] == %{}
    assert_receive {:agent_daemon_event, %{event: "backplane.capabilities.updated"} = retry_event}
    assert retry_event.error == nil
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

  defp tool_revision(mcp) do
    [tool] = mcp.config["backplane_tools"]
    tool["source_metadata"]["revision"]
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
