defmodule Synapsis.Agent.ContextBuilderSkillsTest do
  use Synapsis.DataCase

  alias Synapsis.Agent.ContextBuilder
  alias Synapsis.Skill

  test "injects only assigned agent skills into the system prompt" do
    assigned = %Skill{
      name: "concise-review",
      description: "Review style",
      system_prompt_fragment: "Keep reviews concise and specific."
    }

    prompt =
      ContextBuilder.build_system_prompt(:coding,
        agent_config: %{
          system_prompt: "Base prompt",
          tools: [],
          skills: [assigned]
        }
      )

    assert prompt =~ "Base prompt"
    assert prompt =~ "<assigned_skills>"
    assert prompt =~ "concise-review"
    assert prompt =~ "Keep reviews concise and specific."
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

    refute prompt =~ "<assigned_skills>"
  end
end
