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
end
