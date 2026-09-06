defmodule Synapsis.Session.DaemonRunConfigTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Session
  alias Synapsis.Session.Worker.Config

  @override_key "daemon_run_tool_names"
  @profile_key "daemon_run_tool_profile"

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
