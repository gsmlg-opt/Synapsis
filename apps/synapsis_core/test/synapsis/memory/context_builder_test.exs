defmodule Synapsis.Memory.ContextBuilderTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.Memory.ContextBuilder
  alias Synapsis.{SemanticMemory, Repo}

  describe "build/1" do
    test "returns empty string when no memories exist" do
      result = ContextBuilder.build(%{project_id: "nonexistent", agent_id: "none"})
      assert result == ""
    end

    test "includes shared memories in context" do
      %SemanticMemory{}
      |> SemanticMemory.changeset(%{
        scope: "shared",
        scope_id: "",
        kind: "fact",
        title: "Global rule",
        summary: "Always validate input"
      })
      |> Repo.insert!()

      result = ContextBuilder.build(%{project_id: "some-proj", agent_id: "some-agent"})
      # format_entries renders summary, not title
      assert result =~ "Always validate input"
      assert result =~ "<memory>"
    end

    test "includes project-scoped memories" do
      project_id = Ecto.UUID.generate()

      %SemanticMemory{}
      |> SemanticMemory.changeset(%{
        scope: "project",
        scope_id: project_id,
        kind: "decision",
        title: "Use Ecto",
        summary: "Database layer uses Ecto"
      })
      |> Repo.insert!()

      result = ContextBuilder.build(%{project_id: project_id, agent_id: "agent-1"})
      assert result =~ "Database layer uses Ecto"
      assert result =~ "<project"
    end

    test "does not include other project memories" do
      %SemanticMemory{}
      |> SemanticMemory.changeset(%{
        scope: "project",
        scope_id: "other-project",
        kind: "fact",
        title: "Other project fact",
        summary: "Should not appear"
      })
      |> Repo.insert!()

      result = ContextBuilder.build(%{project_id: "my-project", agent_id: "agent-1"})
      refute result =~ "Should not appear"
    end

    test "wraps output in memory XML tags" do
      %SemanticMemory{}
      |> SemanticMemory.changeset(%{
        scope: "shared",
        scope_id: "",
        kind: "fact",
        title: "Test",
        summary: "Content"
      })
      |> Repo.insert!()

      result = ContextBuilder.build(%{project_id: "proj", agent_id: "agent"})
      assert result =~ "<memory>"
      assert result =~ "</memory>"
    end
  end
end
