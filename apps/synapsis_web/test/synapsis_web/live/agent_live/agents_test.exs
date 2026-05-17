defmodule SynapsisWeb.AgentLive.AgentsTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.{AgentConfig, AgentConfigs, AgentSkills, Repo, Skill, Toolsets}

  setup do
    Repo.delete_all(AgentConfig)
    :ok
  end

  describe "agent routes" do
    test "/agent redirects to /agent/agents", %{conn: conn} do
      conn = get(conn, ~p"/agent")
      assert redirected_to(conn, 302) == ~p"/agent/agents"
    end

    test "lists agents inside the Agent module shell", %{conn: conn} do
      {:ok, agent} = AgentConfigs.create(%{name: "planner", label: "Planner"})

      {:ok, view, html} = live(conn, ~p"/agent/agents")

      assert html =~ "Agents"
      assert html =~ "Planner"
      assert has_element?(view, "aside", "Tools")
      assert has_element?(view, "a[href='/agent/agents/new']", "New Agent")
      assert has_element?(view, "a[href='/agent/agents/#{agent.id}/config']", "Config")
      refute html =~ ">Edit<"
      refute html =~ ">Remove<"
    end

    test "creates an agent", %{conn: conn} do
      {:ok, toolset} = Toolsets.create(%{name: "readers", tool_names: ["file_read"]})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/new")

      view
      |> form("form[phx-submit='save_agent']", %{
        "agent" => %{
          "name" => "researcher",
          "label" => "Researcher",
          "description" => "Finds facts",
          "provider" => "openai",
          "model" => "gpt-4.1",
          "system_prompt" => "Research carefully.",
          "toolset_id" => toolset.id,
          "enabled" => "true"
        },
        "skill_ids" => []
      })
      |> render_submit()

      agent = Repo.get_by!(AgentConfig, name: "researcher")
      assert agent.label == "Researcher"
      assert agent.toolset_id == toolset.id
      assert_redirect(view, ~p"/agent/agents")
    end

    test "updates an agent", %{conn: conn} do
      {:ok, agent} = AgentConfigs.create(%{name: "editor", label: "Editor"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/#{agent.id}/config")

      view
      |> form("form[phx-submit='save_agent']", %{
        "agent" => %{
          "label" => "Updated Editor",
          "description" => "Updated",
          "provider" => "openai",
          "model" => "gpt-4.1",
          "system_prompt" => "Edit carefully.",
          "workspace_path" => "~/.synapsis/agents/editor",
          "toolset_id" => "",
          "enabled" => "true"
        },
        "skill_ids" => []
      })
      |> render_submit()

      updated = Repo.get!(AgentConfig, agent.id)
      assert updated.label == "Updated Editor"
      assert updated.config["workspace_path"] == "~/.synapsis/agents/editor"
      assert_redirect(view, ~p"/agent/agents")
    end

    test "configures an agent from a rich vertical-tab workspace", %{conn: conn} do
      {:ok, toolset} =
        Toolsets.create(%{
          name: "workspace",
          description: "Workspace tools",
          tool_names: ["file_read", "bash"]
        })

      skill =
        Repo.insert!(%Skill{
          name: "code-review",
          description: "Review code before shipping.",
          system_prompt_fragment: "Check for regressions."
        })

      {:ok, agent} =
        AgentConfigs.create(%{
          name: "builder",
          label: "Builder",
          description: "Builds changes",
          provider: "openai",
          model: "gpt-4.1",
          fallback_models: "gpt-4o, o3",
          reasoning_effort: "high",
          model_tier: "expert",
          max_tokens: 16_384,
          read_only: true,
          toolset_id: toolset.id
        })

      {:ok, _} = AgentSkills.assign_skills(agent, [skill.id])

      {:ok, view, html} = live(conn, ~p"/agent/agents/#{agent.id}/config")

      assert html =~ "Agent workspace"
      assert html =~ "Overview"
      assert html =~ "Runtime"
      assert html =~ "Workspace"
      assert html =~ "Tools 2"
      assert html =~ "Skills 1"
      assert html =~ "Management"
      assert html =~ "Configuration Wizard"
      assert html =~ "Primary Model"
      assert html =~ "openai/gpt-4.1 (+2 fallback)"
      assert html =~ "Workspace tools"
      assert html =~ "~/.synapsis/agents/builder"
      assert html =~ "code-review"

      assert has_element?(view, "button[phx-click='switch_config_tab'][phx-value-tab='overview']")

      assert has_element?(
               view,
               "button[phx-click='switch_config_tab'][phx-value-tab='workspace']"
             )

      assert has_element?(view, "button[phx-click='switch_config_tab'][phx-value-tab='runtime']")
      assert has_element?(view, "button[phx-click='switch_config_tab'][phx-value-tab='tools']")
      assert has_element?(view, "button[phx-click='switch_config_tab'][phx-value-tab='skills']")
      assert has_element?(view, "button[phx-click='switch_config_tab'][phx-value-tab='prompt']")

      assert has_element?(
               view,
               "button[phx-click='switch_config_tab'][phx-value-tab='management']"
             )

      refute has_element?(view, "button[phx-click='switch_config_tab'][phx-value-tab='delete']")
      assert has_element?(view, "el-dm-button[phx-click='start_wizard']", "Start Wizard")
      assert has_element?(view, "select[name='agent[provider]']")
      assert has_element?(view, "select[name='agent[model]']")
      assert has_element?(view, "input[name='agent[fallback_models]']")
      assert has_element?(view, "input[name='agent[workspace_path]']")
      assert has_element?(view, "select[name='agent[reasoning_effort]']")
      assert has_element?(view, "select[name='agent[model_tier]']")
      assert has_element?(view, "input[name='agent[max_tokens]']")
      assert has_element?(view, "input[name='agent[read_only]'][value='true']")
    end

    test "wizard button starts step-by-step configuration", %{conn: conn} do
      {:ok, agent} = AgentConfigs.create(%{name: "wizard", label: "Wizard"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/#{agent.id}/config")

      view
      |> element("button[phx-click='switch_config_tab'][phx-value-tab='management']")
      |> render_click()

      view
      |> element("el-dm-button[phx-click='start_wizard']")
      |> render_click()

      html = render(view)
      assert html =~ "Wizard step 1 of 6"
      assert html =~ "Next Step"
    end

    test "management tab can disable and enable an agent", %{conn: conn} do
      {:ok, agent} = AgentConfigs.create(%{name: "toggleable", label: "Toggleable"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/#{agent.id}/config")

      view
      |> element("button[phx-click='switch_config_tab'][phx-value-tab='management']")
      |> render_click()

      view
      |> element("el-dm-button[phx-click='set_agent_enabled'][phx-value-enabled='false']")
      |> render_click()

      refute Repo.get!(AgentConfig, agent.id).enabled

      view
      |> element("el-dm-button[phx-click='set_agent_enabled'][phx-value-enabled='true']")
      |> render_click()

      assert Repo.get!(AgentConfig, agent.id).enabled
    end

    test "removes an agent only after exact long confirmation", %{conn: conn} do
      {:ok, agent} = AgentConfigs.create(%{name: "temporary", label: "Temporary"})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/#{agent.id}/config")

      view
      |> element("button[phx-click='switch_config_tab'][phx-value-tab='management']")
      |> render_click()

      view
      |> form("form[phx-submit='delete_agent']", %{
        "confirmation" => "delete temporary"
      })
      |> render_submit()

      assert Repo.get(AgentConfig, agent.id)
      assert render(view) =~ "Type delete agent temporary to confirm"

      view
      |> form("form[phx-submit='delete_agent']", %{
        "confirmation" => "delete agent temporary"
      })
      |> render_submit()

      refute Repo.get(AgentConfig, agent.id)
      assert_redirect(view, ~p"/agent/agents")
    end

    test "default main agent has no delete controls in management", %{conn: conn} do
      {:ok, agent} = AgentConfigs.create(%{name: "main", label: "Main", is_default: true})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/#{agent.id}/config")

      view
      |> element("button[phx-click='switch_config_tab'][phx-value-tab='management']")
      |> render_click()

      html = render(view)
      refute html =~ "Delete Agent"
      refute has_element?(view, "form[phx-submit='delete_agent']")
      assert html =~ "Default agent cannot be deleted"
    end
  end
end
