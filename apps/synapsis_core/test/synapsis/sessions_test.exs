defmodule Synapsis.SessionsTest do
  use Synapsis.DataCase

  alias Synapsis.Sessions

  describe "create/2" do
    test "creates a session for a new project" do
      {:ok, session} =
        Sessions.create("/tmp/test_sessions_create", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      assert session.id
      assert session.status == "idle"
      assert session.agent == "build"
      assert session.project.path == "/tmp/test_sessions_create"
    end

    test "reuses existing project" do
      {:ok, s1} =
        Sessions.create("/tmp/test_sessions_reuse", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      {:ok, s2} =
        Sessions.create("/tmp/test_sessions_reuse", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      assert s1.project_id == s2.project_id
      assert s1.id != s2.id
    end
  end

  describe "get/1" do
    test "returns session with messages" do
      {:ok, session} =
        Sessions.create("/tmp/test_sessions_get", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      {:ok, found} = Sessions.get(session.id)
      assert found.id == session.id
      assert is_list(found.messages)
    end

    test "returns error for missing session" do
      assert {:error, :not_found} = Sessions.get(Ecto.UUID.generate())
    end
  end

  describe "list/2" do
    test "lists sessions for a project" do
      {:ok, _} =
        Sessions.create("/tmp/test_sessions_list", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      {:ok, _} =
        Sessions.create("/tmp/test_sessions_list", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      {:ok, sessions} = Sessions.list("/tmp/test_sessions_list")
      assert length(sessions) >= 2
    end
  end

  describe "delete/1" do
    test "deletes a session" do
      {:ok, session} =
        Sessions.create("/tmp/test_sessions_del", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      assert {:ok, _} = Sessions.delete(session.id)
      assert {:error, :not_found} = Sessions.get(session.id)
    end
  end
end
