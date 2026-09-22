defmodule Synapsis.Tool.SkillTest do
  use ExUnit.Case, async: true

  alias Synapsis.SkillCatalog.Entry
  alias Synapsis.SkillCatalog
  alias Synapsis.Tool.Skill

  test "metadata accepts locator and temporary name compatibility" do
    params = Skill.parameters()
    assert params["type"] == "object"
    assert Map.has_key?(params["properties"], "locator")
    assert Map.has_key?(params["properties"], "name")
    assert Skill.permission_level() == :none
    assert Skill.category() == :orchestration
  end

  test "loads an assigned inline Skill by locator and wraps it" do
    content = canonical("review", "Full body")
    entry = entry(%{body: content, loader: %{type: :inline, canonical?: true}})

    assert {:ok, loaded} = Skill.execute(%{"locator" => entry.locator}, %{skill_catalog: [entry]})
    assert loaded =~ "<skill>"
    assert loaded =~ content
  end

  test "temporarily supports an assigned legacy inline body" do
    entry = entry(%{body: "Legacy body", loader: %{type: :inline, canonical?: false}})
    assert {:ok, loaded} = Skill.execute(%{"name" => entry.name}, %{skill_catalog: [entry]})
    assert loaded =~ "Legacy body"
  end

  test "rejects ambiguous name-only and unassigned locator lookups" do
    entries = [
      entry(%{}),
      entry(%{source_id: "other", skill_id: "other", locator: "skill:other"})
    ]

    assert {:error, message} = Skill.execute(%{"name" => "review"}, %{skill_catalog: entries})
    assert message =~ "ambiguous"

    assert {:error, message} =
             Skill.execute(%{"locator" => "skill:unassigned"}, %{skill_catalog: entries})

    assert message =~ "not assigned"
  end

  test "discovers and reads canonical local SKILL.md under its approved root" do
    root =
      Path.join(System.tmp_dir!(), "skill_protocol_local_#{System.unique_integer([:positive])}")

    skill_root = Path.join(root, "review")
    File.mkdir_p!(skill_root)
    content = canonical("review", "Local full body")
    File.write!(Path.join(skill_root, "SKILL.md"), content)
    on_exit(fn -> File.rm_rf!(root) end)

    persisted_skill = %Synapsis.Skill{
      id: Ecto.UUID.generate(),
      name: "review",
      enabled: true,
      config_overrides: %{
        "source" => "local",
        "source_id" => "project",
        "external_id" => "review",
        "root" => root
      }
    }

    assert [entry] = SkillCatalog.snapshot([persisted_skill])
    assert entry.skill_id == "review"
    assert entry.locator == "local://project/review"

    assert {:ok, loaded} = Skill.execute(%{"locator" => entry.locator}, %{skill_catalog: [entry]})
    assert loaded =~ "Local full body"
  end

  test "delegates exact remote loading through the host-owned callback" do
    entry =
      entry(%{
        authority: :backplane,
        source_id: "source-1",
        skill_id: "review",
        revision: "rev-7",
        locator: "backplane://source-1/review?revision=rev-7",
        body: nil,
        loader: %{type: :backplane, connection_id: "source-1"}
      })

    loader = fn selected, _context ->
      assert selected.revision == "rev-7"
      {:ok, canonical("review", "Remote full body")}
    end

    assert {:ok, loaded} =
             Skill.execute(%{"locator" => entry.locator}, %{
               skill_catalog: [entry],
               skill_loader: loader
             })

    assert loaded =~ "Remote full body"
  end

  defp entry(overrides) do
    struct!(
      Entry,
      Map.merge(
        %{
          authority: :synapsis,
          source_id: "synapsis",
          skill_id: "review",
          revision: nil,
          artifact_digest: nil,
          name: "review",
          description: "Review code",
          locator: "synapsis://skills/review",
          enabled: true,
          prompt_visible: true,
          scope: :agent,
          loader: %{type: :inline, canonical?: false},
          body: "Legacy body"
        },
        overrides
      )
    )
  end

  defp canonical(name, body) do
    """
    ---
    name: #{name}
    description: Review code carefully
    ---
    #{body}
    """
  end
end
