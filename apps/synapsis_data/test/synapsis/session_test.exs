defmodule Synapsis.SessionTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{Repo, Session}

  describe "changeset/2" do
    test "valid with required agent-owned fields" do
      cs =
        %Session{}
        |> Session.changeset(%{provider: "anthropic", model: "claude-sonnet", agent: "main"})

      assert cs.valid?
    end

    test "invalid without provider" do
      cs = %Session{} |> Session.changeset(%{model: "test", agent: "main"})
      refute cs.valid?
      assert %{provider: ["can't be blank"]} = errors_on(cs)
    end

    test "invalid without model" do
      cs = %Session{} |> Session.changeset(%{provider: "test", agent: "main"})
      refute cs.valid?
      assert %{model: ["can't be blank"]} = errors_on(cs)
    end

    test "invalid without agent" do
      cs = %Session{} |> Session.changeset(%{provider: "test", model: "test", agent: nil})
      refute cs.valid?
      assert %{agent: ["can't be blank"]} = errors_on(cs)
    end

    test "validates status inclusion" do
      cs =
        %Session{}
        |> Session.changeset(%{
          provider: "test",
          model: "test",
          agent: "main",
          status: "invalid"
        })

      refute cs.valid?
      assert %{status: ["is invalid"]} = errors_on(cs)
    end
  end

  describe "persistence" do
    test "inserts and reads back an agent-owned session" do
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{
          provider: "anthropic",
          model: "claude-sonnet",
          agent: "main",
          title: "Agent session"
        })
        |> Repo.insert()

      found = Repo.get!(Session, session.id)
      assert found.agent == "main"
      assert found.title == "Agent session"
      assert found.status == "idle"
    end
  end
end
