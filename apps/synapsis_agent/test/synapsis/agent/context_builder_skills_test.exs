defmodule Synapsis.Agent.ContextBuilderSkillsTest do
  use Synapsis.DataCase

  alias Synapsis.Agent.ContextBuilder
  alias Synapsis.Skill

  test "injects only frozen assigned Skill metadata into the system prompt" do
    assigned = %Skill{
      name: "concise-review",
      description: "Review style",
      system_prompt_fragment: "Keep reviews concise and specific."
    }

    catalog = Synapsis.SkillCatalog.snapshot([assigned])

    prompt =
      ContextBuilder.build_system_prompt(:coding,
        agent_config: %{
          system_prompt: "Base prompt",
          tools: [],
          skill_catalog: catalog
        }
      )

    assert prompt =~ "Base prompt"
    assert prompt =~ "<system-reminder>\n<skills_instructions>"
    assert prompt =~ "concise-review"
    refute prompt =~ "Keep reviews concise and specific."
    assert length(Regex.scan(~r/<skills_instructions>/, prompt)) == 1
  end

  test "omits assigned skill layer when no skills are assigned" do
    prompt =
      ContextBuilder.build_system_prompt(:coding,
        agent_config: %{
          system_prompt: "Base prompt",
          tools: [],
          skills: []
        }
      )

    refute prompt =~ "<skills_instructions>"
  end

  test "resolves known model windows for two-percent catalog budgeting" do
    context_window = ContextBuilder.skill_context_window([], %{model: "gpt-4o"})

    assert context_window == 128_000

    assert Synapsis.SkillCatalog.render([], model_context_window: context_window).report.budget ==
             %{unit: :tokens, value: 2_560}
  end

  test "uses the character fallback for an unknown model" do
    context_window = ContextBuilder.skill_context_window([], %{"model" => "unknown-model"})

    assert context_window == nil

    assert Synapsis.SkillCatalog.render([], model_context_window: context_window).report.budget ==
             %{unit: :characters, value: 8_000}
  end

  test "prefers an explicit context window over model registry metadata" do
    assert ContextBuilder.skill_context_window([model_context_window: 64_000], %{
             model: "gpt-4o"
           }) == 64_000
  end
end
