defmodule Synapsis.Memory.WriterTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Memory
  alias Synapsis.Memory.Writer

  @pubsub Synapsis.PubSub

  setup do
    session_id = Ecto.UUID.generate()
    Writer.subscribe_session(session_id)
    # Give time for subscription to complete
    Process.sleep(50)
    {:ok, session_id: session_id}
  end

  describe "subscribe_session/1" do
    test "subscribes to session and tool_effects topics", %{session_id: session_id} do
      # Verify that broadcasting on the session topic reaches Writer
      Phoenix.PubSub.broadcast(
        @pubsub,
        "session:#{session_id}",
        {:status_changed, session_id, :streaming}
      )

      # Give Writer time to process
      Process.sleep(100)

      events = Memory.list_events(scope: "session", scope_id: session_id)
      assert length(events) >= 1
      assert Enum.any?(events, fn e -> e.type == "run_created" end)
    end
  end

  describe "tool effect handling" do
    test "persists tool effect events", %{session_id: session_id} do
      Phoenix.PubSub.broadcast(
        @pubsub,
        "tool_effects:#{session_id}",
        {:tool_effect, :file_changed, %{session_id: session_id, path: "/tmp/test.ex"}}
      )

      Process.sleep(100)

      events = Memory.list_events(scope: "session", scope_id: session_id)
      assert Enum.any?(events, fn e -> e.type == "tool_succeeded" end)
    end
  end

  describe "status change handling" do
    test "records task_completed on idle transition", %{session_id: session_id} do
      Phoenix.PubSub.broadcast(
        @pubsub,
        "session:#{session_id}",
        {:status_changed, session_id, :idle}
      )

      Process.sleep(100)

      events = Memory.list_events(scope: "session", scope_id: session_id)
      assert Enum.any?(events, fn e -> e.type == "task_completed" end)
    end

    test "records task_failed on error transition", %{session_id: session_id} do
      Phoenix.PubSub.broadcast(
        @pubsub,
        "session:#{session_id}",
        {:status_changed, session_id, :error}
      )

      Process.sleep(100)

      events = Memory.list_events(scope: "session", scope_id: session_id)
      failed = Enum.find(events, fn e -> e.type == "task_failed" end)
      assert failed != nil
      assert failed.importance == 0.8
    end
  end

  describe "unsubscribe_session/1" do
    test "stops receiving events after unsubscribe", %{session_id: session_id} do
      Writer.unsubscribe_session(session_id)
      Process.sleep(50)

      Phoenix.PubSub.broadcast(
        @pubsub,
        "session:#{session_id}",
        {:status_changed, session_id, :streaming}
      )

      Process.sleep(100)

      events = Memory.list_events(scope: "session", scope_id: session_id)
      refute Enum.any?(events, fn e -> e.type == "run_created" end)
    end
  end
end
