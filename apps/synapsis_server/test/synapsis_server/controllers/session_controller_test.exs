defmodule SynapsisServer.SessionControllerTest do
  use SynapsisServer.ConnCase

  describe "POST /api/sessions" do
    test "creates a session", %{conn: conn} do
      conn =
        post(conn, "/api/sessions", %{
          project_path: "/tmp/test_ctrl_#{:rand.uniform(100_000)}",
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      assert %{"data" => %{"id" => id, "status" => "idle"}} = json_response(conn, 201)
      assert is_binary(id)
    end
  end

  describe "GET /api/sessions" do
    test "lists sessions", %{conn: conn} do
      path = "/tmp/test_ctrl_list_#{:rand.uniform(100_000)}"

      post(conn, "/api/sessions", %{
        project_path: path,
        provider: "anthropic",
        model: "claude-sonnet-4-20250514"
      })

      conn = get(conn, "/api/sessions", %{project_path: path})
      assert %{"data" => sessions} = json_response(conn, 200)
      assert is_list(sessions)
    end
  end

  describe "GET /api/sessions/:id" do
    test "shows a session", %{conn: conn} do
      create_conn =
        post(conn, "/api/sessions", %{
          project_path: "/tmp/test_ctrl_show_#{:rand.uniform(100_000)}",
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      %{"data" => %{"id" => id}} = json_response(create_conn, 201)

      conn = get(conn, "/api/sessions/#{id}")
      assert %{"data" => %{"id" => ^id}} = json_response(conn, 200)
    end

    test "returns 404 for missing session", %{conn: conn} do
      conn = get(conn, "/api/sessions/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end
  end

  describe "DELETE /api/sessions/:id" do
    test "deletes a session", %{conn: conn} do
      create_conn =
        post(conn, "/api/sessions", %{
          project_path: "/tmp/test_ctrl_del_#{:rand.uniform(100_000)}",
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      %{"data" => %{"id" => id}} = json_response(create_conn, 201)

      conn = delete(conn, "/api/sessions/#{id}")
      assert response(conn, 204)
    end
  end

  describe "POST /api/sessions/:id/messages" do
    test "returns 400 when content is missing", %{conn: conn} do
      create_conn =
        post(conn, "/api/sessions", %{
          project_path: "/tmp/test_ctrl_msg_#{:rand.uniform(100_000)}",
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      %{"data" => %{"id" => id}} = json_response(create_conn, 201)

      conn = post(conn, "/api/sessions/#{id}/messages", %{})
      assert %{"error" => "content is required"} = json_response(conn, 400)
    end
  end

  describe "POST /api/sessions/:id/compact" do
    test "returns ok status when session has no messages", %{conn: conn} do
      create_conn =
        post(conn, "/api/sessions", %{
          project_path: "/tmp/test_ctrl_compact_#{:rand.uniform(100_000)}",
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      %{"data" => %{"id" => id}} = json_response(create_conn, 201)

      conn = post(conn, "/api/sessions/#{id}/compact", %{})
      assert %{"status" => "ok", "compacted" => false} = json_response(conn, 200)
    end
  end

  describe "POST /api/sessions/:id/fork" do
    test "creates a new forked session", %{conn: conn} do
      create_conn =
        post(conn, "/api/sessions", %{
          project_path: "/tmp/test_ctrl_fork_#{:rand.uniform(100_000)}",
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      %{"data" => %{"id" => original_id}} = json_response(create_conn, 201)

      conn = post(conn, "/api/sessions/#{original_id}/fork", %{})
      assert %{"data" => %{"id" => forked_id}} = json_response(conn, 201)
      assert forked_id != original_id
    end
  end

  describe "GET /api/sessions/:id/export" do
    test "exports session as JSON", %{conn: conn} do
      create_conn =
        post(conn, "/api/sessions", %{
          project_path: "/tmp/test_ctrl_export_#{:rand.uniform(100_000)}",
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      %{"data" => %{"id" => id}} = json_response(create_conn, 201)

      conn = get(conn, "/api/sessions/#{id}/export")
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
      body = conn.resp_body |> Jason.decode!()
      assert body["version"] == "1.0"
      assert is_map(body["session"])
      assert is_list(body["messages"])
    end
  end

  describe "POST /api/sessions/:id/compact (error case)" do
    test "returns error for unknown session", %{conn: conn} do
      unknown_id = Ecto.UUID.generate()
      conn = post(conn, "/api/sessions/#{unknown_id}/compact", %{})
      # compact returns 422 with error message for unknown sessions
      response = json_response(conn, 422)
      assert is_binary(response["error"])
    end
  end
end
