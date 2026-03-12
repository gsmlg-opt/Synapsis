defmodule Synapsis.SemanticMemoryTest do
  use Synapsis.DataCase

  alias Synapsis.{SemanticMemory, Repo}

  describe "changeset/2" do
    test "valid with required fields" do
      cs =
        %SemanticMemory{}
        |> SemanticMemory.changeset(%{
          scope: "shared",
          scope_id: "",
          kind: "fact",
          title: "test",
          summary: "value"
        })

      assert cs.valid?
    end

    test "invalid without scope" do
      cs =
        %SemanticMemory{}
        |> SemanticMemory.changeset(%{scope_id: "", kind: "fact", title: "t", summary: "s"})

      refute cs.valid?
      assert %{scope: ["can't be blank"]} = errors_on(cs)
    end

    test "invalid without title" do
      cs =
        %SemanticMemory{}
        |> SemanticMemory.changeset(%{scope: "shared", scope_id: "", kind: "fact", summary: "s"})

      refute cs.valid?
      assert %{title: ["can't be blank"]} = errors_on(cs)
    end

    test "validates scope inclusion" do
      cs =
        %SemanticMemory{}
        |> SemanticMemory.changeset(%{
          scope: "invalid",
          scope_id: "",
          kind: "fact",
          title: "t",
          summary: "s"
        })

      refute cs.valid?
      assert %{scope: [_]} = errors_on(cs)
    end

    test "validates kind inclusion" do
      cs =
        %SemanticMemory{}
        |> SemanticMemory.changeset(%{
          scope: "shared",
          scope_id: "",
          kind: "invalid",
          title: "t",
          summary: "s"
        })

      refute cs.valid?
      assert %{kind: [_]} = errors_on(cs)
    end

    test "allows valid scopes" do
      for scope <- ~w(shared project agent) do
        cs =
          %SemanticMemory{}
          |> SemanticMemory.changeset(%{
            scope: scope,
            scope_id: "",
            kind: "fact",
            title: "t",
            summary: "s"
          })

        assert cs.valid?, "Expected scope #{scope} to be valid"
      end
    end

    test "allows valid kinds" do
      for kind <- ~w(fact decision lesson preference pattern warning summary policy) do
        cs =
          %SemanticMemory{}
          |> SemanticMemory.changeset(%{
            scope: "shared",
            scope_id: "",
            kind: kind,
            title: "t",
            summary: "s"
          })

        assert cs.valid?, "Expected kind #{kind} to be valid"
      end
    end

    test "sets defaults" do
      cs =
        %SemanticMemory{}
        |> SemanticMemory.changeset(%{
          scope: "shared",
          scope_id: "",
          kind: "fact",
          title: "t",
          summary: "s"
        })

      assert get_field(cs, :importance) == 0.5
      assert get_field(cs, :confidence) == 0.5
      assert get_field(cs, :freshness) == 1.0
      assert get_field(cs, :source) == "agent"
      assert get_field(cs, :tags) == []
    end
  end

  describe "persistence" do
    test "inserts and retrieves semantic memory" do
      {:ok, memory} =
        %SemanticMemory{}
        |> SemanticMemory.changeset(%{
          scope: "shared",
          scope_id: "",
          kind: "fact",
          title: "test-title",
          summary: "test-summary",
          tags: ["tag1", "tag2"]
        })
        |> Repo.insert()

      found = Repo.get!(SemanticMemory, memory.id)
      assert found.title == "test-title"
      assert found.summary == "test-summary"
      assert found.scope == "shared"
      assert found.tags == ["tag1", "tag2"]
    end

    test "update_changeset updates allowed fields" do
      {:ok, memory} =
        %SemanticMemory{}
        |> SemanticMemory.changeset(%{
          scope: "project",
          scope_id: "proj1",
          kind: "decision",
          title: "old title",
          summary: "old summary"
        })
        |> Repo.insert()

      {:ok, updated} =
        memory
        |> SemanticMemory.update_changeset(%{
          title: "new title",
          summary: "new summary",
          importance: 0.9
        })
        |> Repo.update()

      assert updated.title == "new title"
      assert updated.summary == "new summary"
      assert updated.importance == 0.9
    end
  end
end
