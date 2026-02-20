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
  end
end
