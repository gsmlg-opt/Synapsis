defmodule Synapsis.MessageTest do
  use Synapsis.DataCase

  alias Synapsis.{Message, Session, Project, Repo}

  setup do
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        path: "/tmp/msg_test_#{:rand.uniform(100_000)}",
        slug: "msg-test-#{:rand.uniform(100_000)}"
      })
      |> Repo.insert()

    {:ok, session} =
      %Session{}
      |> Session.changeset(%{provider: "test", model: "test", project_id: project.id})
      |> Repo.insert()

    %{session: session}
  end

  describe "changeset/2" do
    test "valid with required fields", %{session: session} do
      cs = %Message{} |> Message.changeset(%{role: "user", session_id: session.id})
      assert cs.valid?
    end

    test "invalid without role", %{session: session} do
      cs = %Message{} |> Message.changeset(%{session_id: session.id})
      refute cs.valid?
      assert %{role: ["can't be blank"]} = errors_on(cs)
    end

    test "invalid without session_id" do
      cs = %Message{} |> Message.changeset(%{role: "user"})
      refute cs.valid?
      assert %{session_id: ["can't be blank"]} = errors_on(cs)
    end

    test "validates role inclusion", %{session: session} do
      cs = %Message{} |> Message.changeset(%{role: "invalid_role", session_id: session.id})
      refute cs.valid?
      assert %{role: [_]} = errors_on(cs)
    end

    test "allows valid roles", %{session: session} do
      for role <- ~w(user assistant system) do
        cs = %Message{} |> Message.changeset(%{role: role, session_id: session.id})
        assert cs.valid?, "Expected role #{role} to be valid"
      end
    end

    test "sets defaults", %{session: session} do
      cs = %Message{} |> Message.changeset(%{role: "user", session_id: session.id})
      assert get_field(cs, :parts) == []
      assert get_field(cs, :token_count) == 0
    end
  end

  describe "persistence" do
    test "inserts and retrieves message", %{session: session} do
      {:ok, msg} =
        %Message{}
        |> Message.changeset(%{role: "user", session_id: session.id, token_count: 10})
        |> Repo.insert()

      found = Repo.get!(Message, msg.id)
      assert found.role == "user"
      assert found.token_count == 10
    end

    test "stores and retrieves parts", %{session: session} do
      parts = [%{"type" => "text", "content" => "Hello"}]

      {:ok, msg} =
        %Message{}
        |> Message.changeset(%{role: "user", session_id: session.id, parts: parts})
        |> Repo.insert()

      found = Repo.get!(Message, msg.id)
      assert length(found.parts) == 1
    end

    test "preloads session association", %{session: session} do
      {:ok, msg} =
        %Message{}
        |> Message.changeset(%{role: "assistant", session_id: session.id})
        |> Repo.insert()

      loaded = Repo.preload(msg, :session)
      assert loaded.session.id == session.id
    end
  end
end
