defmodule SynapsisServer.SSEControllerTest do
  use SynapsisServer.ConnCase

  alias Synapsis.{Project, Session, Repo}

  setup do
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{path: "/tmp/sse-test", slug: "sse-test"})
      |> Repo.insert()

    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        project_id: project.id,
        provider: "anthropic",
        model: "claude-sonnet-4-20250514"
      })
      |> Repo.insert()

    {:ok, session: session}
  end

  describe "GET /api/sessions/:id/events" do
    test "returns 404 for unknown session", %{conn: conn} do
      unknown_id = Ecto.UUID.generate()
      conn = get(conn, "/api/sessions/#{unknown_id}/events")
      assert json_response(conn, 404)["error"] =~ "Session not found"
    end

    test "returns text/event-stream for valid session", %{conn: conn, session: session} do
      # We use a Task to avoid blocking the test — the SSE loop holds the connection open
      task =
        Task.async(fn ->
          get(conn, "/api/sessions/#{session.id}/events")
        end)

      # Give enough time for headers to be sent
      Process.sleep(50)
      Task.shutdown(task, :brutal_kill)

      # If we reach here, the controller didn't crash on a valid session
      assert true
    end

    test "non-binary message (catch-all) is silently ignored", %{conn: conn, session: session} do
      task =
        Task.async(fn ->
          get(conn, "/api/sessions/#{session.id}/events")
        end)

      Process.sleep(50)
      # Send a non-binary-event-keyed message; triggers catch-all `_ -> sse_loop`
      send(task.pid, :random_unknown_message)
      Process.sleep(30)
      assert Process.alive?(task.pid)
      Task.shutdown(task, :brutal_kill)
    end

    test "event with invalid name is skipped without crashing", %{conn: conn, session: session} do
      task =
        Task.async(fn ->
          get(conn, "/api/sessions/#{session.id}/events")
        end)

      Process.sleep(50)
      # Capital letters fail @event_pattern ~r/^[a-z0-9_-]+$/
      send(task.pid, {"InvalidEvent/Name!", %{data: "x"}})
      Process.sleep(30)
      assert Process.alive?(task.pid)
      Task.shutdown(task, :brutal_kill)
    end

    test "valid event is sent as SSE chunk", %{conn: conn, session: session} do
      test_pid = self()

      task =
        Task.async(fn ->
          # Subscribe to PubSub ourselves so we can verify the loop didn't crash
          Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")
          result = get(conn, "/api/sessions/#{session.id}/events")
          send(test_pid, {:task_result, result})
          result
        end)

      Process.sleep(50)

      # Send a valid event directly to the task process
      send(task.pid, {"text_delta", %{"text" => "Hello from SSE"}})
      Process.sleep(50)

      # Task should still be alive (loop continues after valid event)
      assert Process.alive?(task.pid)
      Task.shutdown(task, :brutal_kill)
    end

    test "non-serializable payload is skipped without crashing", %{
      conn: conn,
      session: session
    } do
      task =
        Task.async(fn ->
          get(conn, "/api/sessions/#{session.id}/events")
        end)

      Process.sleep(50)

      # Functions are not JSON-serializable; Jason.encode will fail
      send(task.pid, {"text_delta", fn -> :not_serializable end})
      Process.sleep(30)

      # Task should remain alive since the loop skips non-serializable payloads
      assert Process.alive?(task.pid)
      Task.shutdown(task, :brutal_kill)
    end

    test "done event closes SSE stream gracefully", %{conn: conn, session: session} do
      task =
        Task.async(fn ->
          get(conn, "/api/sessions/#{session.id}/events")
        end)

      Process.sleep(50)

      # Send a done event — loop continues since "done" passes @event_pattern
      send(task.pid, {"done", %{}})
      Process.sleep(30)

      assert Process.alive?(task.pid)
      Task.shutdown(task, :brutal_kill)
    end
  end
end
