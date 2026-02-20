defmodule Synapsis.SkillTest do
  use Synapsis.DataCase

  alias Synapsis.{Skill, Repo}

  describe "changeset/2" do
    test "valid with required fields" do
      cs = %Skill{} |> Skill.changeset(%{name: "test-skill", scope: "global"})
      assert cs.valid?
    end

    test "invalid without name" do
      cs = %Skill{} |> Skill.changeset(%{scope: "global"})
      refute cs.valid?
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "uses default scope when omitted" do
      cs = %Skill{} |> Skill.changeset(%{name: "test"})
      assert cs.valid?
      assert get_field(cs, :scope) == "global"
    end

    test "validates scope inclusion" do
      cs = %Skill{} |> Skill.changeset(%{name: "test", scope: "invalid"})
      refute cs.valid?
      assert %{scope: [_]} = errors_on(cs)
    end

    test "allows valid scopes" do
      for scope <- ~w(global project) do
        cs = %Skill{} |> Skill.changeset(%{name: "test", scope: scope})
        assert cs.valid?, "Expected scope #{scope} to be valid"
      end
    end

    test "sets defaults" do
      cs = %Skill{} |> Skill.changeset(%{name: "test", scope: "global"})
      assert get_field(cs, :tool_allowlist) == []
      assert get_field(cs, :config_overrides) == %{}
      assert get_field(cs, :is_builtin) == false
    end
  end

  describe "persistence" do
    test "inserts and retrieves skill" do
      {:ok, skill} =
        %Skill{}
        |> Skill.changeset(%{
          name: "persist-skill",
          scope: "global",
          description: "A test skill"
        })
        |> Repo.insert()

      found = Repo.get!(Skill, skill.id)
      assert found.name == "persist-skill"
      assert found.description == "A test skill"
    end

    test "allows duplicate names when project_id differs (NULL is distinct)" do
      # PostgreSQL treats NULL as distinct in unique indexes
      attrs = %{name: "unique-skill", scope: "global"}

      {:ok, _} = %Skill{} |> Skill.changeset(attrs) |> Repo.insert()
      {:ok, _} = %Skill{} |> Skill.changeset(attrs) |> Repo.insert()
    end
  end
end
