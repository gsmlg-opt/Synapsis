defmodule Synapsis.Session.DaemonRunConfigTest do
  use Synapsis.Agent.DataCase, async: false

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
end
