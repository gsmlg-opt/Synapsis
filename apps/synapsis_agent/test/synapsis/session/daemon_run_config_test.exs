defmodule Synapsis.Session.DaemonRunConfigTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Session
  alias Synapsis.Session.Worker.Config

  @override_key "daemon_run_tool_names"

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

  test "resolve_agent applies only the daemon run tool-name override" do
    baseline = Synapsis.Agent.Resolver.resolve("main", %{})

    ordinary = %Session{agent: "main", provider: "anthropic", model: "test-model", config: %{}}
    assert Config.resolve_agent(ordinary).tools == baseline.tools

    overridden = %{
      ordinary
      | config: %{@override_key => ["file_read", "grep"]}
    }

    assert Config.resolve_agent(overridden).tools == ["file_read", "grep"]

    unrelated = %{ordinary | config: %{"tool_names" => ["bash"]}}
    assert Config.resolve_agent(unrelated).tools == baseline.tools
  end
end
