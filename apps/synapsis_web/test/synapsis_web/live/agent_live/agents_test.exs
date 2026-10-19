defmodule SynapsisWeb.AgentLive.AgentsTest do
  use SynapsisWeb.ConnCase

  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.{AgentConfigs, AgentSkills, Providers, Skills, Toolsets}

  def refresh_mcp, do: %{}

  setup do
    previous = Application.get_env(:synapsis_core, :mcp_refresh)
    Application.put_env(:synapsis_core, :mcp_refresh, {__MODULE__, :refresh_mcp, []})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:synapsis_core, :mcp_refresh, previous),
        else: Application.delete_env(:synapsis_core, :mcp_refresh)
    end)

    Synapsis.DataCase.clear_config_store(:provider)
    Synapsis.DataCase.clear_config_store(:model)
    Synapsis.DataCase.clear_config_store(:agent)
    :ok
  end

  test "skill assignment groups preserve source UUID and skill identity", %{conn: conn} do
    {:ok, skill} =
      Skills.create(%{
        name: "remote-grouped",
        scope: "global",
        config_overrides: %{
          "managed_by" => "backplane",
          "backplane_source_id" => "source-group",
          "external_id" => "review",
          "external_revision" => "rev1"
        }
      })

    {:ok, view, html} = live(conn, ~p"/agent/agents/new")
    assert html =~ "source-group"

    assert has_element?(
             view,
             "[data-skill-source='source-group'] input[name='skill_ids[]'][value='#{skill.id}']"
           )
  end

  test "new agents save a dynamic default-all MCP policy", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/agent/agents/new")

    assert has_element?(
             view,
             "select[name='mcp_selection[default]'] option[value='all'][selected]"
           )

    react_form_submit(view, "agent-config-form", %{"agent" => %{"name" => "default-all"}})

    assert AgentConfigs.get_by_name("default-all").config["mcp_selection"] == %{
             "default" => "all",
             "sources" => %{}
           }
  end

  test "inherited MCP groups initialize the native form and stay inherited after ordinary edits",
       %{conn: conn} do
    {:ok, source} =
      Synapsis.MCPConfigs.create(%{
        name: "inherited-mcp",
        transport: "stdio",
        command: "false",
        enabled: false
      })

    {:ok, agent} =
      AgentConfigs.create(%{
        name: "inherited-policy",
        config: %{"mcp_selection" => %{"default" => "all", "sources" => %{}}}
      })

    on_exit(fn -> Synapsis.MCPConfigs.delete(source) end)
    {:ok, view, _html} = live(conn, ~p"/agent/agents/#{agent.id}/config")

    values =
      view
      |> element("[data-form-id='agent-config-form']")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-initial-values]")
      |> LazyHTML.attribute("data-initial-values")
      |> hd()
      |> Jason.decode!()

    assert values["mcp_selection"]["sources"][source.id]["mode"] == "inherit"

    react_form_submit(view, "agent-config-form", %{
      "agent" => %{"label" => "Ordinary edit"},
      "mcp_selection" => %{
        "default" => "all",
        "sources" => %{source.id => %{"mode" => "", "tools" => []}}
      }
    })

    assert AgentConfigs.get(agent.id).config["mcp_selection"] == %{
             "default" => "all",
             "sources" => %{}
           }
  end

  test "new MCP groups inherit the default when discovery remounts a pending draft", %{conn: conn} do
    {:ok, agent} =
      AgentConfigs.create(%{
        name: "new-group-draft",
        config: %{"mcp_selection" => %{"default" => "all", "sources" => %{}}}
      })

    {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
    render_async(view)
    react_form_change(view, "agent-config-form", %{"agent" => %{"label" => "Keep this draft"}})

    {:ok, source} =
      Synapsis.MCPConfigs.create(%{
        name: "new-draft-mcp",
        transport: "stdio",
        command: "false",
        enabled: false
      })

    on_exit(fn -> Synapsis.MCPConfigs.delete(source) end)
    view |> element("el-dm-button[phx-click='refresh_mcp_tools']") |> render_click()
    render_async(view)

    values =
      view
      |> element("[data-form-id='agent-config-form']")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-initial-values]")
      |> LazyHTML.attribute("data-initial-values")
      |> hd()
      |> Jason.decode!()

    assert values["mcp_selection"]["sources"][source.id]["mode"] == "inherit"
    assert values["agent"]["label"] == "Keep this draft"
    react_form_submit(view, "agent-config-form", %{})
    saved = AgentConfigs.get(agent.id)
    assert saved.label == "Keep this draft"
    assert saved.config["mcp_selection"] == %{"default" => "all", "sources" => %{}}
  end

  test "legacy MCP choices become selected rules and keep unavailable names", %{conn: conn} do
    {:ok, source} =
      Synapsis.MCPConfigs.create(%{
        name: "legacy-source",
        transport: "stdio",
        command: "false",
        enabled: false
      })

    {:ok, agent} =
      AgentConfigs.create(%{name: "legacy-mcp", tools: ["file_read", "mcp:legacy-source:gone"]})

    {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
    assert has_element?(view, "[data-mcp-source='#{source.id}']", "unavailable")
    react_form_submit(view, "agent-config-form", %{"agent" => %{"label" => "Changed label"}})
    saved = AgentConfigs.get(agent.id)
    assert saved.tools == agent.tools

    assert saved.config["mcp_selection"] == %{
             "default" => "selected",
             "sources" => %{source.id => %{"mode" => "selected", "tools" => ["gone"]}}
           }

    {:ok, _} = Synapsis.MCPConfigs.delete(source)
  end

  test "group modes and selected tools survive live refresh with other form drafts", %{conn: conn} do
    {:ok, first} =
      Synapsis.MCPConfigs.create(%{
        name: "first-mcp",
        transport: "stdio",
        command: "false",
        enabled: false
      })

    {:ok, second} =
      Synapsis.MCPConfigs.create(%{
        name: "second-mcp",
        transport: "stdio",
        command: "false",
        enabled: false
      })

    {:ok, agent} = AgentConfigs.create(%{name: "mcp-draft", tools: ["file_read"]})
    {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
    render_async(view)

    policy = %{
      "default" => "all",
      "sources" => %{
        first.id => %{"mode" => "none"},
        second.id => %{"mode" => "selected", "tools" => ["saved-but-gone"]}
      }
    }

    react_form_change(view, "agent-config-form", %{
      "agent" => %{"label" => "Pending draft"},
      "mcp_selection" => policy
    })

    view |> element("el-dm-button[phx-click='refresh_mcp_tools']") |> render_click()
    render_async(view)
    react_form_submit(view, "agent-config-form", %{})
    saved = AgentConfigs.get(agent.id)
    assert saved.label == "Pending draft"
    assert saved.config["mcp_selection"]["sources"][first.id]["mode"] == "none"
    assert saved.config["mcp_selection"]["sources"][second.id]["tools"] == ["saved-but-gone"]
    assert Synapsis.Agent.Resolver.resolve(saved.name).tools == ["file_read"]
    {:ok, _} = Synapsis.MCPConfigs.delete(first)
    {:ok, _} = Synapsis.MCPConfigs.delete(second)
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
      assert has_element?(view, ".card[data-agent-card='planner']", "Planner")
      assert has_element?(view, ".card[data-agent-card='reviewer']", "Reviewer")
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

      react_form_submit(view, "agent-config-form", %{
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
      |> react_form_submit("agent-config-form", %{
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

      updated = AgentConfigs.get(agent.id)
      assert updated.label == "Updated Editor"
      assert updated.config["workspace_path"] == "~/.synapsis/agents/editor"
      assert updated.toolset_ids == []
      assert updated.permission_mode == "yolo"
      :ok = refute_redirected(view)
      assert has_element?(view, "[data-form-id='agent-config-form']")
      assert render(view) =~ "Updated Editor"
    end

    test "preserves typed fields and grouped selections across config tabs", %{conn: conn} do
      {:ok, agent} = AgentConfigs.create(%{name: "draft-agent", label: "Draft Agent"})
      {:ok, toolset} = Toolsets.create(%{name: "draft-readers", tool_names: ["file_read"]})
      {:ok, skill} = Skills.create(%{name: "draft-style", scope: "global"})
      {:ok, view, _html} = live(conn, ~p"/agent/agents/#{agent.id}/config")

      react_form_change(view, "agent-config-form", %{
        "agent" => %{
          "label" => "Edited draft",
          "toolset_ids" => [toolset.id],
          "max_tokens" => 1024
        },
        "skill_ids" => [skill.id]
      })

      view
      |> element("button[phx-click='switch_config_tab'][phx-value-tab='runtime']")
      |> render_click()

      react_form_submit(view, "agent-config-form", %{})
      updated = AgentConfigs.get(agent.id)
      assert updated.label == "Edited draft"
      assert updated.max_tokens == 1024
      assert updated.toolset_ids == [toolset.id]
      assert AgentSkills.list_skill_ids(agent.id) == [skill.id]
    end

    test "availability changes preserve pending skill and configuration drafts", %{conn: conn} do
      {:ok, agent} = AgentConfigs.create(%{name: "availability-draft", label: "Original"})
      {:ok, toolset} = Toolsets.create(%{name: "availability-readers", tool_names: ["file_read"]})
      {:ok, skill} = Skills.create(%{name: "availability-style", scope: "global"})
      {:ok, view, _html} = live(conn, ~p"/agent/agents/#{agent.id}/config")

      react_form_change(view, "agent-config-form", %{
        "agent" => %{
          "label" => "Pending label",
          "toolset_ids" => [toolset.id],
          "max_tokens" => 2048
        },
        "skill_ids" => [skill.id]
      })

      view
      |> element("button[phx-click='switch_config_tab'][phx-value-tab='management']")
      |> render_click()

      view
      |> element("el-dm-button[phx-click='set_agent_enabled'][phx-value-enabled='false']")
      |> render_click()

      view
      |> element("button[phx-click='switch_config_tab'][phx-value-tab='overview']")
      |> render_click()

      react_form_submit(view, "agent-config-form", %{})
      updated = AgentConfigs.get(agent.id)
      refute updated.enabled
      assert updated.label == "Pending label"
      assert updated.max_tokens == 2048
      assert updated.toolset_ids == [toolset.id]
      assert AgentSkills.list_skill_ids(agent.id) == [skill.id]
    end

    test "external Save Agent targets the current native form after remounts", %{conn: conn} do
      {:ok, agent} = AgentConfigs.create(%{name: "external-save", label: "External Save"})
      {:ok, view, _html} = live(conn, ~p"/agent/agents/#{agent.id}/config")

      assert_save_target = fn ->
        [mount_id] =
          view
          |> element("[data-form-id='agent-config-form']")
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.query("[data-form-id]")
          |> LazyHTML.attribute("id")

        assert has_element?(
                 view,
                 "button[type='submit'][form='#{mount_id}-native']",
                 "Save Agent"
               )

        mount_id
      end

      initial_mount = assert_save_target.()

      view
      |> element("button[phx-click='switch_config_tab'][phx-value-tab='runtime']")
      |> render_click()

      runtime_mount = assert_save_target.()
      refute runtime_mount == initial_mount

      react_form_submit(view, "agent-config-form", %{"agent" => %{"label" => "Saved externally"}})
      refute assert_save_target.() == runtime_mount
      assert AgentConfigs.get(agent.id).label == "Saved externally"
    end

    test "opens config page by agent name from sessions links", %{conn: conn} do
      {:ok, agent} = AgentConfigs.create(%{name: "main", label: "Main Agent"})

      {:ok, view, html} = live(conn, ~p"/agent/agents/main/config")

      assert html =~ "Main Agent"
      assert html =~ agent.id
      assert has_element?(view, "[data-form-id='agent-config-form']")
      assert has_element?(view, "button[phx-click='switch_config_tab'][phx-value-tab='overview']")
      assert_unique_form_ids(html)
    end

    test "does not reset permission mode when save payload omits the select", %{conn: conn} do
      {:ok, agent} =
        AgentConfigs.create(%{
          name: "reviewer",
          label: "Reviewer",
          permission_mode: "restrict"
        })

      {:ok, view, _html} = live(conn, ~p"/agent/agents/#{agent.id}/config")

      render_hook(view, "save_agent", %{
        "id" => "agent-config-form",
        "values" => %{
          "agent" => %{
            "label" => "Reviewer",
            "enabled" => "true"
          },
          "skill_ids" => []
        },
        "revision" => 1
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

      react_form_submit(view, "agent-config-form", %{
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

    test "saves backup model from client-managed provider/model picker state when hidden value is stale",
         %{conn: conn} do
      insert_provider("openai", "openai")

      {:ok, agent} =
        AgentConfigs.create(%{
          name: "fallback_picker",
          label: "Fallback Picker",
          provider: "openai",
          model: "gpt-4.1"
        })

      {:ok, view, _html} = live(conn, ~p"/agent/agents/#{agent.id}/config")

      react_form_submit(view, "agent-config-form", %{
        "agent" => %{
          "label" => "Fallback Picker",
          "fallback_models" => "",
          "fallback_model_state" => Jason.encode!(%{provider: "openai", model: "gpt-4o"})
        },
        "skill_ids" => []
      })

      updated = AgentConfigs.get(agent.id)
      assert updated.fallback_models == "openai/gpt-4o"
      :ok = refute_redirected(view)
    end

    test "editing another agent field preserves an unavailable saved default", %{conn: conn} do
      provider =
        insert_provider("unavailable-default", "openai", %{
          config: %{"model_catalog_migrated" => true}
        })

      {:ok, model} =
        Synapsis.Models.create(%{
          provider_id: provider.id,
          model: "saved",
          context_window: 4096,
          enabled: false
        })

      {:ok, agent} =
        AgentConfigs.create(%{
          name: "preserved-default",
          provider: provider.name,
          model: model.model
        })

      {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
      react_form_change(view, "agent-config-form", %{"agent" => %{"label" => "Changed label"}})
      render_hook(view, "switch_config_tab", %{"tab" => "runtime"})
      render_hook(view, "switch_config_tab", %{"tab" => "overview"})
      assert has_element?(view, "#agent-model-hidden[value='saved']")

      react_form_submit(view, "agent-config-form", %{
        "agent" => %{"label" => "Changed label", "enabled" => true}
      })

      updated = AgentConfigs.get(agent.id)
      assert updated.provider == provider.name
      assert updated.model == "saved"
    end

    test "default model picker uses the configured catalog including manual IDs and excludes disabled choices",
         %{conn: conn} do
      provider =
        insert_provider("catalog-agent-provider", "openai", %{
          config: %{
            "model_catalog_migrated" => true,
            "available_models" => [%{"id" => "discovered-only"}]
          }
        })

      {:ok, _} =
        Synapsis.Models.create(%{
          provider_id: provider.id,
          model: "manual",
          name: "My manual model",
          context_window: 4096
        })

      {:ok, _} =
        Synapsis.Models.create(%{
          provider_id: provider.id,
          model: "disabled",
          context_window: 4096,
          enabled: false
        })

      {:ok, _view, html} = live(conn, ~p"/agent/agents/new")
      assert html =~ "Default model"
      assert cascader_options(html) |> cascader_model_values(provider.name) == ["manual"]
    end

    test "config page lists provider available_models in model picker", %{conn: conn} do
      insert_provider("backplane", "openai", %{
        config: %{
          "available_models" => [
            %{"id" => "openai-codex/gpt-5.5", "name" => "openai-codex/gpt-5.5"},
            %{"id" => "fast", "name" => "fast"}
          ]
        }
      })

      {:ok, agent} =
        AgentConfigs.create(%{
          name: "backplane-agent",
          label: "Backplane Agent",
          provider: "backplane",
          model: "openai-codex/gpt-5.5"
        })

      {:ok, _view, html} = live(conn, ~p"/agent/agents/#{agent.id}/config")
      options = cascader_options(html)

      assert cascader_model_values(options, "backplane") == [
               "fast",
               "openai-codex/gpt-5.5"
             ]

      refute "gpt-4.1" in cascader_model_values(options, "backplane")
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
          fallback_models: "openai/gpt-4o",
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
      assert html =~ "Default model"
      assert html =~ "openai/gpt-4.1 (+1 backup)"
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
      assert has_element?(view, "#agent-backup-model-picker[phx-hook='AgentBackupModelPicker']")
      assert has_element?(view, "input[name='agent[provider]']")
      assert has_element?(view, "input[name='agent[model]']")
      assert has_element?(view, "input[name='agent[fallback_models]']")
      assert has_element?(view, "input[name='agent[fallback_model_state]']")
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

      assert has_element?(
               view,
               "[data-form-id='agent-config-form'] el-dm-button[type='submit']",
               "Save"
             )
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
      |> react_form_submit("agent-config-form", %{
        "agent" => %{
          "label" => "Tool User",
          "toolset_ids" => [reader_toolset.id, mcp_toolset.id],
          "permission_mode" => "ask",
          "enabled" => "true"
        },
        "skill_ids" => []
      })

      updated = AgentConfigs.get(agent.id)
      assert updated.toolset_ids == [reader_toolset.id, mcp_toolset.id]
      assert updated.toolset_id == reader_toolset.id
      assert render(view) =~ "mcp:docs:search"

      view
      |> react_form_submit("agent-config-form", %{
        "agent" => %{
          "label" => "Tool User",
          "toolset_ids" => [mcp_toolset.id],
          "permission_mode" => "ask",
          "enabled" => "true"
        },
        "skill_ids" => []
      })

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
      {:ok, anthropic} =
        Providers.create(%{
          name: "anthropic",
          type: "anthropic",
          base_url: "https://api.anthropic.com",
          api_key_encrypted: "sk-ant-test",
          config: %{"model_catalog_migrated" => true},
          enabled: true
        })

      {:ok, openai} =
        Providers.create(%{
          name: "openai",
          type: "openai",
          base_url: "https://api.openai.com",
          api_key_encrypted: "sk-openai-test",
          config: %{"model_catalog_migrated" => true},
          enabled: true
        })

      for {provider, model, enabled} <- [
            {anthropic, "claude-sonnet-4-6", true},
            {openai, "gpt-4.1-mini", true},
            {openai, "gpt-4.1", false}
          ] do
        assert {:ok, _} =
                 Synapsis.Models.create(%{
                   provider_id: provider.id,
                   model: model,
                   context_window: 128_000,
                   enabled: enabled
                 })
      end

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

    test "backup model picker selects a provider and model separately from the primary picker",
         %{conn: conn} do
      Providers.create(%{
        name: "openai",
        type: "openai",
        base_url: "https://api.openai.com",
        api_key_encrypted: "sk-openai-test",
        config: %{"enabled_models" => ["gpt-4.1", "gpt-4o", "o3"]},
        enabled: true
      })

      {:ok, agent} =
        AgentConfigs.create(%{
          name: "fallback_options",
          label: "Fallback Options",
          provider: "openai",
          model: "gpt-4.1",
          fallback_models: "openai/gpt-4o"
        })

      {:ok, view, html} = live(conn, ~p"/agent/agents/#{agent.id}/config")
      options = cascader_options(html)

      assert has_element?(view, "#agent-provider-model-picker[phx-hook='AgentModelPicker']")
      assert has_element?(view, "#agent-backup-model-picker[phx-hook='AgentBackupModelPicker']")
      refute has_element?(view, "#agent-provider-model-picker input#agent-fallback-models-hidden")

      assert has_element?(
               view,
               "#agent-backup-model-picker input#agent-fallback-models-hidden[name='agent[fallback_models]']"
             )

      assert has_element?(
               view,
               "#agent-backup-model-picker input#agent-fallback-model-state[name='agent[fallback_model_state]']"
             )

      assert cascader_model_values(options, "openai") == ["gpt-4.1", "gpt-4o", "o3"]
      assert fallback_model_state(html) == %{"provider" => "openai", "model" => "gpt-4o"}
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
      |> react_form_submit("agent-delete-form", %{
        "confirmation" => "delete temporary"
      })

      assert AgentConfigs.get(agent.id)
      assert render(view) =~ "Type delete agent temporary to confirm"

      view
      |> react_form_submit("agent-delete-form", %{
        "confirmation" => "delete agent temporary"
      })

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
      refute has_element?(view, "[data-form-id='agent-delete-form']")
      assert html =~ "Default agent cannot be deleted"
    end
  end

  defp insert_provider(name, type, attrs \\ %{}) do
    {:ok, provider} =
      %{
        name: name,
        type: type,
        base_url: "https://api.example.com",
        api_key_encrypted: "sk-test",
        enabled: true
      }
      |> Map.merge(attrs)
      |> Providers.create()

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

  defp fallback_model_state(html) do
    ~r/<input[^>]*id="agent-fallback-model-state"[^>]*value="([^"]*)"/
    |> Regex.run(html)
    |> List.last()
    |> html_attribute_unescape()
    |> Jason.decode!()
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
