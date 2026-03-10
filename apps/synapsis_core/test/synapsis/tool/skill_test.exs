defmodule Synapsis.Tool.SkillTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.Skill

  describe "tool metadata" do
    test "has correct name" do
      assert Skill.name() == "skill"
    end

    test "has a description string" do
      assert is_binary(Skill.description())
      assert String.length(Skill.description()) > 0
    end

    test "has valid parameters schema" do
      params = Skill.parameters()
      assert params["type"] == "object"
      assert is_map(params["properties"])
      assert "name" in params["required"]
    end

    test "permission_level is :none" do
      assert Skill.permission_level() == :none
    end

    test "category is :orchestration" do
      assert Skill.category() == :orchestration
    end
  end

  describe "execute/2 — skill discovery" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "skill_test_#{:erlang.unique_integer([:positive])}")
      skills_dir = Path.join(tmp_dir, ".synapsis/skills")
      File.mkdir_p!(skills_dir)

      skill_content = "# My Skill\n\nThis is a test skill definition."
      File.write!(Path.join(skills_dir, "test_skill.md"), skill_content)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{tmp_dir: tmp_dir, skill_content: skill_content}
    end

    test "finds skill from project path", %{tmp_dir: tmp_dir, skill_content: expected} do
      input = %{"name" => "test_skill"}
      context = %{project_path: tmp_dir}

      assert {:ok, ^expected} = Skill.execute(input, context)
    end

    test "returns error when skill not found" do
      input = %{"name" => "nonexistent_skill"}
      context = %{project_path: System.tmp_dir!()}

      assert {:error, msg} = Skill.execute(input, context)
      assert msg =~ "not found"
    end

    test "returns error when skill name does not match any file" do
      input = %{"name" => "definitely_missing"}
      context = %{project_path: "/tmp/no_such_project"}

      assert {:error, _} = Skill.execute(input, context)
    end
  end

  describe "execute/2 — fallback context" do
    test "uses current directory when project_path not in context" do
      input = %{"name" => "nonexistent"}
      context = %{}

      # Should not crash, just return not found
      assert {:error, _} = Skill.execute(input, context)
    end
  end
end
