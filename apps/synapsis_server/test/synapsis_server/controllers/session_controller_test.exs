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
  describe "GET /api/sessions/:id (serialize_part types)" do
    setup %{conn: conn} do
      create_conn =
        post(conn, "/api/sessions", %{
          project_path: "/tmp/test_ctrl_parts_#{:rand.uniform(100_000)}",
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      %{"data" => %{"id" => session_id}} = json_response(create_conn, 201)
      {:ok, session} = Synapsis.Sessions.get(session_id)
      %{session: session}
    end

    test "serializes ToolUse parts", %{conn: conn, session: session} do
      %Synapsis.Message{}
      |> Synapsis.Message.changeset(%{
        session_id: session.id,
        role: "assistant",
        parts: [
          %Synapsis.Part.ToolUse{
            tool: "bash",
            tool_use_id: "tool_abc_123",
            input: %{"command" => "ls"},
            status: "pending"
          }
        ],
        token_count: 10
      })
      |> Synapsis.Repo.insert!()

      conn = get(conn, "/api/sessions/#{session.id}")
      %{"data" => %{"messages" => messages}} = json_response(conn, 200)

      part = messages |> List.last() |> Map.get("parts") |> hd()
      assert part["type"] == "tool_use"
      assert part["tool"] == "bash"
      assert part["tool_use_id"] == "tool_abc_123"
      assert part["status"] == "pending"
    end

    test "serializes ToolResult parts", %{conn: conn, session: session} do
      %Synapsis.Message{}
      |> Synapsis.Message.changeset(%{
        session_id: session.id,
        role: "user",
        parts: [
          %Synapsis.Part.ToolResult{
            tool_use_id: "tool_abc_123",
            content: "files: a.txt b.txt",
            is_error: false
          }
        ],
        token_count: 10
      })
      |> Synapsis.Repo.insert!()

      conn = get(conn, "/api/sessions/#{session.id}")
      %{"data" => %{"messages" => messages}} = json_response(conn, 200)

      part = messages |> List.last() |> Map.get("parts") |> hd()
      assert part["type"] == "tool_result"
      assert part["tool_use_id"] == "tool_abc_123"
      assert part["content"] == "files: a.txt b.txt"
      assert part["is_error"] == false
    end

    test "serializes Reasoning parts", %{conn: conn, session: session} do
      %Synapsis.Message{}
      |> Synapsis.Message.changeset(%{
        session_id: session.id,
        role: "assistant",
        parts: [%Synapsis.Part.Reasoning{content: "Thinking step by step..."}],
        token_count: 5
      })
      |> Synapsis.Repo.insert!()

      conn = get(conn, "/api/sessions/#{session.id}")
      %{"data" => %{"messages" => messages}} = json_response(conn, 200)

      part = messages |> List.last() |> Map.get("parts") |> hd()
      assert part["type"] == "reasoning"
      assert part["content"] == "Thinking step by step..."
    end

    test "serializes File parts", %{conn: conn, session: session} do
      %Synapsis.Message{}
      |> Synapsis.Message.changeset(%{
        session_id: session.id,
        role: "assistant",
        parts: [%Synapsis.Part.File{path: "/tmp/hello.txt", content: "hello world"}],
        token_count: 5
      })
      |> Synapsis.Repo.insert!()

      conn = get(conn, "/api/sessions/#{session.id}")
      %{"data" => %{"messages" => messages}} = json_response(conn, 200)

      part = messages |> List.last() |> Map.get("parts") |> hd()
      assert part["type"] == "file"
      assert part["path"] == "/tmp/hello.txt"
      assert part["content"] == "hello world"
    end

    test "serializes Agent parts", %{conn: conn, session: session} do
      %Synapsis.Message{}
      |> Synapsis.Message.changeset(%{
        session_id: session.id,
        role: "assistant",
        parts: [%Synapsis.Part.Agent{agent: "build", message: "Starting build..."}],
        token_count: 5
      })
      |> Synapsis.Repo.insert!()

      conn = get(conn, "/api/sessions/#{session.id}")
      %{"data" => %{"messages" => messages}} = json_response(conn, 200)

      part = messages |> List.last() |> Map.get("parts") |> hd()
      assert part["type"] == "agent"
      assert part["agent"] == "build"
      assert part["message"] == "Starting build..."
    end
  end
end
