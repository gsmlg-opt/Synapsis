defmodule SynapsisWeb.AgentLive.AgentsTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.{AgentConfigs, AgentSkills, Providers, Skills, Toolsets}

  setup do
    Synapsis.DataCase.clear_config_store(:provider)
    Synapsis.DataCase.clear_config_store(:agent)
    :ok
  end

  describe "agent routes" do
    test "/agent redirects to /agent/agents", %{conn: conn} do
      conn = get(conn, ~p"/agent")
      assert redirected_to(conn, 302) == ~p"/agent/agents"
    end

    test "lists agents inside the Agent module shell", %{conn: conn} do
      {:ok, agent} = AgentConfigs.create(%{name: "planner", label: "Planner"})
      {:ok, second_agent} = AgentConfigs.create(%{name: "reviewer", label: "Reviewer"})

      {:ok, view, html} = live(conn, ~p"/agent/agents")

      assert html =~ "Agents"
      assert html =~ "Planner"
      assert html =~ "Reviewer"
      assert has_element?(view, "aside", "Tools")
      assert has_element?(view, "a[href='/agent/agents/new']", "New Agent")
      assert has_element?(view, "el-dm-card[data-agent-card='planner']", "Planner")
      assert has_element?(view, "el-dm-card[data-agent-card='reviewer']", "Reviewer")
      assert has_element?(view, "a[href='/agent/agents/planner/sessions']", "Sessions")
      assert has_element?(view, "a[href='/agent/agents/reviewer/sessions']", "Sessions")
      assert has_element?(view, "a[href='/agent/agents/#{agent.id}/config']", "Config")
      assert has_element?(view, "a[href='/agent/agents/#{second_agent.id}/config']", "Config")
      refute html =~ ">Edit<"
      refute html =~ ">Remove<"
    end

    test "creates an agent", %{conn: conn} do
      insert_provider("openai", "openai")
      {:ok, toolset} = Toolsets.create(%{name: "readers", tool_names: ["file_read"]})

      {:ok, view, _html} = live(conn, ~p"/agent/agents/new")

      render_submit(view, "save_agent", %{
        "agent" => %{
          "name" => "researcher",
          "label" => "Researcher",
          "description" => "Finds facts",
          "provider_model_state" => Jason.encode!(%{provider: "openai", model: "gpt-4.1"}),
          "system_prompt" => "Research carefully.",
          "toolset_ids" => [toolset.id],
          "permission_mode" => "restrict",
          "enabled" => "true"
        },
        "skill_ids" => []
      })

      agent = AgentConfigs.get_by_name("researcher")
      assert agent.label == "Researcher"
      assert agent.toolset_id == toolset.id
      assert agent.toolset_ids == [toolset.id]
      assert agent.permission_mode == "restrict"
      assert_redirect(view, ~p"/agent/agents")
    end

    test "updates an agent", %{conn: conn} do
      insert_provider("openai", "openai")

      {:ok, agent} =
        AgentConfigs.create(%{
          name: "editor",
          label: "Editor",
          provider: "openai",
          model: "gpt-4.1"
        })

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
          "toolset_ids" => [""],
          "permission_mode" => "yolo",
          "enabled" => "true"
        },
        "skill_ids" => []
      })
      |> render_submit()

      updated = AgentConfigs.get(agent.id)
      assert updated.label == "Updated Editor"
      assert updated.config["workspace_path"] == "~/.synapsis/agents/editor"
      assert updated.toolset_ids == []
      assert updated.permission_mode == "yolo"
      :ok = refute_redirected(view)
      assert has_element?(view, "form#agent-config-form")
      assert render(view) =~ "Updated Editor"
    end

    test "opens config page by agent name from sessions links", %{conn: conn} do
      {:ok, agent} = AgentConfigs.create(%{name: "main", label: "Main Agent"})

      {:ok, view, html} = live(conn, ~p"/agent/agents/main/config")

      assert html =~ "Main Agent"
      assert html =~ agent.id
      assert has_element?(view, "form#agent-config-form")
      assert has_element?(view, "button[phx-click='switch_config_tab'][phx-value-tab='overview']")
    end

    test "does not reset permission mode when save payload omits the select", %{conn: conn} do
      {:ok, agent} =
        AgentConfigs.create(%{
          name: "reviewer",
          label: "Reviewer",
          permission_mode: "restrict"
        })

      {:ok, view, _html} = live(conn, ~p"/agent/agents/#{agent.id}/config")

      render_submit(view, "save_agent", %{
        "agent" => %{
          "label" => "Reviewer",
          "enabled" => "true"
        },
        "skill_ids" => []
      })

      assert AgentConfigs.get(agent.id).permission_mode == "restrict"
      :ok = refute_redirected(view)
      assert has_element?(view, "select[name='agent[permission_mode]']")
    end

    test "saves provider model from client-managed picker state when hidden values are stale",
         %{conn: conn} do
      insert_provider("openai", "openai")

      {:ok, agent} =
        AgentConfigs.create(%{
          name: "picker",
          label: "Picker"
        })

      {:ok, view, _html} = live(conn, ~p"/agent/agents/#{agent.id}/config")

      render_submit(view, "save_agent", %{
        "agent" => %{
          "label" => "Picker",
          "provider" => "",
          "model" => "",
          "provider_model_state" => Jason.encode!(%{provider: "openai", model: "gpt-4.1"})
        },
        "skill_ids" => []
      })

      updated = AgentConfigs.get(agent.id)
      assert updated.provider == "openai"
      assert updated.model == "gpt-4.1"
      :ok = refute_redirected(view)
    end

    test "configures an agent from a rich vertical-tab workspace", %{conn: conn} do
      insert_provider("openai", "openai")

      {:ok, toolset} =
        Toolsets.create(%{
          name: "workspace",
          description: "Workspace tools",
          tool_names: ["file_read", "bash"]
        })

      {:ok, skill} =
        Skills.create(%{
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
          permission_mode: "ask",
          max_tokens: 16_384,
          read_only: true,
          toolset_ids: [toolset.id],
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
      assert cascader_value(html) == ["openai", "gpt-4.1"]

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
      assert has_element?(view, "#agent-provider-model-picker[phx-hook='AgentModelPicker']")
      assert has_element?(view, "input[name='agent[provider]']")
      assert has_element?(view, "input[name='agent[model]']")
      assert has_element?(view, "input[name='agent[fallback_models]']")
      assert has_element?(view, "input[name='agent[workspace_path]']")
      assert has_element?(view, "select[name='agent[reasoning_effort]']")
      assert has_element?(view, "select[name='agent[model_tier]']")
      assert has_element?(view, "input[name='agent[max_tokens]']")
      assert has_element?(view, "input[name='agent[read_only]'][value='true']")
      assert has_element?(view, "select[name='agent[permission_mode]']")
      assert has_element?(view, "[data-testid='agent-toolset-list']")

      assert has_element?(
               view,
               "input[name='agent[toolset_ids][]'][value='#{toolset.id}'][checked]"
             )

      assert has_element?(view, "form#agent-config-form el-dm-button[type='submit']", "Save")
    end

    test "config tools tab can add and remove multiple toolsets", %{conn: conn} do
      {:ok, reader_toolset} =
        Toolsets.create(%{
          name: "readers",
          description: "Read tools",
          tool_names: ["file_read"]
        })

      {:ok, mcp_toolset} =
        Toolsets.create(%{
          name: "docs-mcp",
          description: "Docs MCP tools",
          tool_names: ["mcp:docs:search"]
        })

      {:ok, agent} =
        AgentConfigs.create(%{
          name: "tool-user",
          label: "Tool User",
          toolset_ids: [reader_toolset.id],
          toolset_id: reader_toolset.id
        })

      {:ok, view, _html} = live(conn, ~p"/agent/agents/#{agent.id}/config")

      view
      |> element("button[phx-click='switch_config_tab'][phx-value-tab='tools']")
      |> render_click()

      assert has_element?(
               view,
               "input[name='agent[toolset_ids][]'][value='#{reader_toolset.id}'][checked]"
             )

      refute has_element?(
               view,
               "input[name='agent[toolset_ids][]'][value='#{mcp_toolset.id}'][checked]"
             )

      view
      |> form("form[phx-submit='save_agent']", %{
        "agent" => %{
          "label" => "Tool User",
          "toolset_ids" => [reader_toolset.id, mcp_toolset.id],
          "permission_mode" => "ask",
          "enabled" => "true"
        },
        "skill_ids" => []
      })
      |> render_submit()

      updated = AgentConfigs.get(agent.id)
      assert updated.toolset_ids == [reader_toolset.id, mcp_toolset.id]
      assert updated.toolset_id == reader_toolset.id
      assert render(view) =~ "mcp:docs:search"

      view
      |> form("form[phx-submit='save_agent']", %{
        "agent" => %{
          "label" => "Tool User",
          "toolset_ids" => [mcp_toolset.id],
          "permission_mode" => "ask",
          "enabled" => "true"
        },
        "skill_ids" => []
      })
      |> render_submit()

      updated = AgentConfigs.get(agent.id)
      assert updated.toolset_ids == [mcp_toolset.id]
      assert updated.toolset_id == mcp_toolset.id

      refute has_element?(
               view,
               "input[name='agent[toolset_ids][]'][value='#{reader_toolset.id}'][checked]"
             )
    end

    test "provider model cascader lists enabled provider configs", %{conn: conn} do
      Providers.create(%{
        name: "custom-anthropic",
        type: "anthropic",
        base_url: "https://api.example.com/anthropic",
        enabled: true
      })

      Providers.create(%{
        name: "custom-openai",
        type: "openai",
        base_url: "https://api.example.com/openai",
        enabled: true
      })

      Providers.create(%{
        name: "disabled-openai",
        type: "openai",
        base_url: "https://api.example.com/disabled",
        enabled: false
      })

      {:ok, view, html} = live(conn, ~p"/agent/agents/new")
      provider_values = cascader_options(html) |> Enum.map(& &1["value"])

      assert has_element?(view, "#agent-provider-model-picker[phx-hook='AgentModelPicker']")
      assert provider_values == ["custom-anthropic", "custom-openai"]
      refute "disabled-openai" in provider_values
    end

    test "provider model cascader prefers provider family models over transport type models",
         %{conn: conn} do
      Providers.create(%{
        name: "minimax-cn",
        type: "anthropic",
        base_url: "https://api.minimaxi.com/anthropic",
        api_key_encrypted: "sk-test",
        enabled: true
      })

      {:ok, _view, html} = live(conn, ~p"/agent/agents/new")
      minimax_models = cascader_options(html) |> cascader_model_values("minimax-cn")

      assert "MiniMax-M2" in minimax_models
      refute "claude-sonnet-4-6" in minimax_models
    end

    test "provider model cascader only lists models supported by each provider", %{conn: conn} do
      Providers.create(%{
        name: "anthropic",
        type: "anthropic",
        base_url: "https://api.anthropic.com",
        api_key_encrypted: "sk-ant-test",
        enabled: true
      })

      Providers.create(%{
        name: "openai",
        type: "openai",
        base_url: "https://api.openai.com",
        api_key_encrypted: "sk-openai-test",
        config: %{"enabled_models" => ["gpt-4.1-mini"]},
        enabled: true
      })

      {:ok, view, html} = live(conn, ~p"/agent/agents/new")
      options = cascader_options(html)
      openai_models = cascader_model_values(options, "openai")
      anthropic_models = cascader_model_values(options, "anthropic")

      assert has_element?(view, "#agent-provider-model-picker[phx-hook='AgentModelPicker']")
      assert openai_models == ["gpt-4.1-mini"]
      assert "claude-sonnet-4-6" in anthropic_models
      refute "gpt-4.1" in openai_models
      refute "claude-sonnet-4-6" in openai_models
    end

    test "provider model cascader uses saved provider model filters when registry has no match",
         %{conn: conn} do
      Providers.create(%{
        name: "custom-anthropic",
        type: "anthropic",
        base_url: "https://api.example.com/anthropic",
        api_key_encrypted: "sk-test",
        config: %{"enabled_models" => ["vendor-alpha", "vendor-beta"]},
        enabled: true
      })

      {:ok, _view, html} = live(conn, ~p"/agent/agents/new")
      custom_models = cascader_options(html) |> cascader_model_values("custom-anthropic")

      assert custom_models == ["vendor-alpha", "vendor-beta"]
      refute "claude-sonnet-4-6" in custom_models
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

      refute AgentConfigs.get(agent.id).enabled

      view
      |> element("el-dm-button[phx-click='set_agent_enabled'][phx-value-enabled='true']")
      |> render_click()

      assert AgentConfigs.get(agent.id).enabled
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

      assert AgentConfigs.get(agent.id)
      assert render(view) =~ "Type delete agent temporary to confirm"

      view
      |> form("form[phx-submit='delete_agent']", %{
        "confirmation" => "delete agent temporary"
      })
      |> render_submit()

      refute AgentConfigs.get(agent.id)
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

  defp insert_provider(name, type) do
    {:ok, provider} =
      Providers.create(%{
        name: name,
        type: type,
        base_url: "https://api.example.com",
        api_key_encrypted: "sk-test",
        enabled: true
      })

    provider
  end

  defp cascader_options(html) do
    ~r/<div[^>]*id="agent-provider-model-picker"[^>]*data-options="([^"]*)"/
    |> Regex.run(html)
    |> List.last()
    |> html_attribute_unescape()
    |> Jason.decode!()
  end

  defp cascader_value(html) do
    state =
      ~r/<input[^>]*id="agent-provider-model-state"[^>]*value="([^"]*)"/
      |> Regex.run(html)
      |> List.last()
      |> html_attribute_unescape()
      |> Jason.decode!()

    [state["provider"], state["model"]]
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp html_attribute_unescape(value) do
    value
    |> String.replace("&quot;", "\"")
    |> String.replace("&#34;", "\"")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end

  defp cascader_model_values(options, provider) do
    options
    |> Enum.find(%{"children" => []}, &(&1["value"] == provider))
    |> Map.get("children", [])
    |> Enum.map(& &1["value"])
  end
end
