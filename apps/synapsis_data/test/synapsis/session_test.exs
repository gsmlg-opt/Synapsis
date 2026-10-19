defmodule Synapsis.SessionTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.Session
  alias Synapsis.Session.Store

  describe "subagents_enabled?/1" do
    test "enables new and older session shapes without an explicit opt-out" do
      assert Session.subagents_enabled?(%Session{})
      assert Session.subagents_enabled?(%Session{config: nil})
      assert Session.subagents_enabled?(%{})
      assert Session.subagents_enabled?(%{config: %{}})
      assert Session.subagents_enabled?(%{config: %{"subagents" => true}})
      assert Session.subagents_enabled?(Session.from_meta(%{id: Ecto.UUID.generate()}))
    end

    test "preserves an explicit opt-out through durable metadata" do
      session = %Session{config: %{"subagents" => false}}
      refute Session.subagents_enabled?(session)
      refute Session.subagents_enabled?(%{config: %{"subagents" => false}})
      refute Session.subagents_enabled?(Session.from_meta(Session.to_meta(session)))
    end
  end

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

  describe "Concord meta round-trip" do
    test "writes and reads back an agent-owned session via the Session.Store" do
      session = %Session{
        id: Ecto.UUID.generate(),
        provider: "anthropic",
        model: "claude-sonnet",
        agent: "main",
        title: "Agent session",
        status: "idle"
      }

      :ok = Store.put_meta(session.id, Session.to_meta(session))

      {:ok, meta} = Store.get_meta(session.id)
      found = Session.from_meta(meta)
      assert found.agent == "main"
      assert found.title == "Agent session"
      assert found.status == "idle"
    end
  end
end
