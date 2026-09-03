defmodule Synapsis.Agent.SessionBridgeTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Events.Emitter

  test "UI projections still accompany typed completion" do
    session_id = "bridge-ui-#{System.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session_id}")

    Emitter.emit_session_completed(session_id)

    assert_receive {:run_event, %{type: "session.completed"}}, 1_000
    assert_receive {"done", %{}}, 1_000
    assert_receive {"session_status", %{status: "idle"}}, 1_000
  end

  test "UI projections still accompany typed failure" do
    session_id = "bridge-err-#{System.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session_id}")

    Emitter.emit_session_failed(session_id, "Provider error: boom")

    assert_receive {:run_event, %{type: "session.failed"}}, 1_000
    assert_receive {"error", %{message: "Provider error: boom"}}, 1_000
    assert_receive {"session_status", %{status: "error"}}, 1_000
  end

  test "completion watcher receives typed terminal when subscribed in the same process" do
    session_id = "bridge-watch-#{System.unique_integer([:positive])}"
    parent = self()
    ready_ref = make_ref()
    notify_ref = "ref-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Task.Supervisor.start_child(Synapsis.Tool.TaskSupervisor, fn ->
        topic = "session:#{session_id}"
        :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, topic)
        send(parent, {:watching, ready_ref})

        receive do
          {:run_event, %{type: "session.completed", session_id: ^session_id}} ->
            send(parent, {:coding_session_completed, notify_ref, session_id})
        after
          5_000 ->
            send(parent, {:coding_session_timeout, notify_ref, session_id})
        end
      end)

    assert_receive {:watching, ^ready_ref}, 1_000
    Emitter.emit_session_completed(session_id)
    assert_receive {:coding_session_completed, ^notify_ref, ^session_id}, 2_000
  end
end
