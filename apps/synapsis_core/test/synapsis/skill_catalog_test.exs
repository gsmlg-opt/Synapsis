defmodule Synapsis.SkillCatalogTest do
  use ExUnit.Case, async: true

  alias Synapsis.SkillCatalog
  alias Synapsis.SkillCatalog.Entry

  test "renders metadata only and keeps same-name entries from different sources" do
    entries = [
      entry(%{
        authority: :synapsis,
        source_id: "local",
        skill_id: "one",
        locator: "synapsis://skills/one",
        body: "SECRET BODY"
      }),
      entry(%{
        authority: :backplane,
        source_id: "remote",
        skill_id: "one",
        locator: "backplane://remote/one?revision=7",
        body: nil
      })
    ]

    result = SkillCatalog.render(entries, max_context_tokens: 10_000)

    assert result.report.included_count == 2
    assert result.text =~ "synapsis://skills/one"
    assert result.text =~ "backplane://remote/one?revision=7"
    refute result.text =~ "SECRET BODY"
  end

  test "filters disabled and manual-only entries without conflating them" do
    entries = [
      entry(%{skill_id: "visible", locator: "skill:visible"}),
      entry(%{skill_id: "manual", locator: "skill:manual", prompt_visible: false}),
      entry(%{skill_id: "disabled", locator: "skill:disabled", enabled: false})
    ]

    result = SkillCatalog.render(entries, max_context_tokens: 10_000)

    assert result.report.total_count == 1
    assert result.text =~ "skill:visible"
    refute result.text =~ "skill:manual"
    refute result.text =~ "skill:disabled"
  end

  test "preserves an exact non-hex Backplane revision for locator resolution" do
    skill = %Synapsis.Skill{
      id: "local-id",
      name: "review",
      enabled: true,
      config_overrides: %{
        "source" => "backplane",
        "backplane_source_id" => "source-1",
        "external_id" => "review",
        "external_revision" => "compatibility-hash",
        "source_metadata" => %{
          "revision" => "release/2026-09-22",
          "artifact_digest" => "sha256:" <> String.duplicate("a", 64)
        }
      }
    }

    assert [entry] = SkillCatalog.snapshot([skill])
    assert entry.revision == "release/2026-09-22"
    assert entry.locator =~ "revision=release%2F2026-09-22"
  end

  test "budgeting truncates Unicode safely and still considers later short entries" do
    entries = [
      entry(%{
        skill_id: "long",
        name: "a-" <> String.duplicate("long", 30),
        description: String.duplicate("技", 2_000),
        locator: "skill:" <> String.duplicate("x", 100)
      }),
      entry(%{skill_id: "short", name: "z", description: "short", locator: "s:z"})
    ]

    result = SkillCatalog.render(entries, max_context_tokens: 8)

    assert result.text =~ "s:z"
    refute result.text =~ String.duplicate("技", 1_025)
    assert result.report.omitted_count == 1
  end

  test "uses two percent defaults and caps explicit token budgets" do
    assert SkillCatalog.render([], model_context_window: 1_000).report.budget ==
             %{unit: :tokens, value: 20}

    assert SkillCatalog.render([], max_context_tokens: 50_000).report.budget ==
             %{unit: :tokens, value: 10_000}
  end

  test "uses character fallback when model window is unknown" do
    entries =
      for index <- 1..5 do
        entry(%{
          skill_id: "cjk-#{index}",
          locator: "skill:cjk-#{index}",
          description: String.duplicate("技", 1_000)
        })
      end

    result = SkillCatalog.render(entries, model_context_window: nil)
    assert result.report.budget == %{unit: :characters, value: 8_000}
    assert result.report.included_count == 5
    assert result.report.truncated_description_count == 0
  end

  defp entry(overrides) do
    struct!(
      Entry,
      Map.merge(
        %{
          authority: :synapsis,
          source_id: "source",
          skill_id: "skill",
          revision: nil,
          artifact_digest: nil,
          name: "skill",
          description: "description",
          locator: "skill:skill",
          enabled: true,
          prompt_visible: true,
          scope: :agent,
          loader: %{type: :inline},
          body: "body"
        },
        overrides
      )
    )
  end
end
