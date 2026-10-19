defmodule Synapsis.Session.DaemonRunConfigTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Session
  alias Synapsis.Session.Worker.Config

  @override_key "daemon_run_tool_names"
  @profile_key "daemon_run_tool_profile"

  def refresh_mcp, do: %{}

  test "daemon MCP refresh preserves explicit exclusions and trusted read-only eligibility" do
    alias Synapsis.Tool.Registry

    previous = Application.get_env(:synapsis_core, :mcp_refresh)
    Application.put_env(:synapsis_core, :mcp_refresh, {__MODULE__, :refresh_mcp, []})
    source = Ecto.UUID.generate()
    excluded = Ecto.UUID.generate()
    prefix = "mcp:daemon_#{source}:"
    names = Enum.map(~w(read future excluded write untrusted deferred), &(prefix <> &1))

    register = fn raw, opts ->
      Registry.register_process(
        prefix <> raw,
        self(),
        Keyword.merge(
          [
            permission_level: :read,
            trust_annotations: true,
            mcp_config_id: source,
            mcp_tool_name: raw,
            parameters: %{"type" => "object", "properties" => %{}}
          ],
          opts
        )
      )
    end

    register.("read", [])
    register.("excluded", mcp_config_id: excluded)
    register.("write", permission_level: :write)
    register.("untrusted", trust_annotations: false)
    register.("deferred", deferred: true)

    {:ok, agent} =
      Synapsis.AgentConfigs.create(%{
        name: "daemon-policy-#{source}",
        provider: "anthropic",
        model: "test-model",
        tools: [],
        config: %{
          "mcp_selection" => %{
            "default" => "all",
            "sources" => %{excluded => %{"mode" => "none"}}
          }
        }
      })

    on_exit(fn ->
      Enum.each(names, &Registry.unregister/1)
      Synapsis.AgentConfigs.delete(agent)

      if previous,
        do: Application.put_env(:synapsis_core, :mcp_refresh, previous),
        else: Application.delete_env(:synapsis_core, :mcp_refresh)
    end)

    session = %Session{
      agent: agent.name,
      provider: "anthropic",
      model: "test-model",
      config: %{@override_key => names, @profile_key => "assistant_basic"}
    }

    initial = Config.resolve_agent(session)
    assert Enum.filter(initial.tools, &String.starts_with?(&1, prefix)) == [prefix <> "read"]

    register.("future", [])
    refreshed = Config.refresh_turn_tools(initial)

    assert Enum.sort(Enum.filter(refreshed.tools, &String.starts_with?(&1, prefix))) ==
             Enum.sort([prefix <> "read", prefix <> "future"])

    assert "file_read" in refreshed.tools

    for tool <- refreshed.resolved_tools,
        do: assert(tool.registration == refreshed.tool_modules[tool.name])
  end

  test "Sessions.create preserves an optional session config map" do
    config = %{@override_key => ["file_read", "grep"]}

    assert {:ok, session} =
             Synapsis.Sessions.create("main", %{
               provider: "anthropic",
               model: "test-model",
               config: config
             })

    on_exit(fn -> Synapsis.Sessions.delete(session.id) end)

    assert session.config == config
    assert {:ok, persisted} = Synapsis.Sessions.get(session.id)
    assert persisted.config == config
  end

  test "resolve_agent applies only the daemon run tool-name and profile overrides" do
    baseline = Synapsis.Agent.Resolver.resolve("main", %{})

    ordinary = %Session{agent: "main", provider: "anthropic", model: "test-model", config: %{}}
    assert Config.resolve_agent(ordinary).tools == baseline.tools

    overridden = %{
      ordinary
      | config: %{
          @override_key => ["file_read", "grep"],
          @profile_key => "assistant_basic"
        }
    }

    resolved = Config.resolve_agent(overridden)

    assert resolved.tools ==
             ~w(file_read list_dir grep glob memory_search todo_read session_summarize skill tool_search agent_status agent_discover agent_inbox)

    assert resolved.daemon_tool_profile == "assistant_basic"
    assert Enum.map(resolved.resolved_tools, & &1.name) == resolved.tools

    assert %{
             "file_read" => {:module, Synapsis.Tool.FileRead, _opts},
             "grep" => {:module, Synapsis.Tool.Grep, _grep_opts}
           } = resolved.tool_modules

    unrelated = %{ordinary | config: %{"tool_names" => ["bash"]}}
    assert Config.resolve_agent(unrelated).tools == baseline.tools
  end
end
