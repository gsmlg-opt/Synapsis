defmodule SynapsisWeb.AgentLive.AgentsTest do
  use SynapsisWeb.ConnCase

  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.{AgentConfigs, AgentSkills, Providers, Skills, Toolsets}

  def refresh_mcp, do: %{}

  def notify_legacy_refresh do
    send(
      Application.fetch_env!(:synapsis_web, :native_refresh_owner),
      :legacy_discovery_requested
    )

    %{}
  end

  defmodule SnapshotSource do
    use GenServer

    def start_link({id, owner, tools}) do
      GenServer.start_link(__MODULE__, {id, owner, tools},
        name: {:via, Registry, {Synapsis.MCP.Registry, {:config_id, id}}}
      )
    end

    def init(state), do: {:ok, state}

    def handle_call(:runtime_snapshot, _from, {id, owner, tools} = state) do
      send(owner, {:agent_display_snapshot, id})
      {:reply, {:ok, %{source_id: id, tools: tools}}, state}
    end

    def handle_call(request, _from, {_id, owner, _tools} = state) do
      send(owner, {:unexpected_agent_mcp_request, request})
      {:reply, {:error, :unexpected_request}, state}
    end
  end

  defp native_snapshot_source(name, raw_name) do
    {:ok, source} = Synapsis.MCPConfigs.create(%{name: name, command: "false"})
    on_exit(fn -> Synapsis.MCPConfigs.delete(source) end)
    tools = [%{raw_name: raw_name, description: "Native snapshot tool", permission_level: :read}]

    start_supervised!(
      Supervisor.child_spec({SnapshotSource, {source.id, self(), tools}}, id: source.id)
    )

    source
  end

  describe "effective selection source" do
    for version <- [0, 1] do
      @tag :native_catalog_provenance
      test "Agent v#{version} native Toolset links override ignored direct MCP and use native guidance without legacy discovery",
           %{conn: conn} do
        Application.put_env(:synapsis_web, :native_refresh_owner, self())

        Application.put_env(
          :synapsis_core,
          :mcp_refresh,
          {__MODULE__, :notify_legacy_refresh, []}
        )

        on_exit(fn -> Application.delete_env(:synapsis_web, :native_refresh_owner) end)
        raw_name = "linked::namespace::read"
        source = native_snapshot_source("effective-native-source", raw_name)
        ignored_source = Ecto.UUID.generate()

        direct = [
          "mcp::#{ignored_source}::ignored::raw",
          "send_message",
          "mcp::#{ignored_source}::ignored::raw"
        ]

        {:ok, linked} =
          Toolsets.create(%{
            name: "effective-native-v#{unquote(version)}",
            tool_contract_version: 1,
            tool_names: ["synapsis::file_read", "mcp::#{source.id}::#{raw_name}"]
          })

        {:ok, agent} =
          AgentConfigs.create(%{
            name: "effective-linked-v#{unquote(version)}",
            tool_contract_version: unquote(version),
            tools: direct,
            toolset_ids: [linked.id, linked.id],
            toolset_id: linked.id,
            config: %{
              "workspace_path" => "~/.synapsis/agents/effective-linked-v#{unquote(version)}",
              "skill_ids" => []
            }
          })

        {:ok, view, html} = live(conn, ~p"/agent/agents/#{agent.id}/config")
        render_async(view)
        refute html =~ "Legacy selection"
        assert html =~ "Native contract v1"
        refute has_element?(view, "[data-toolset-id='#{linked.id}']", "incompatible")

        assert has_element?(
                 view,
                 "[data-mcp-source='#{source.id}'] input[value='#{raw_name}'][checked]"
               )

        refute has_element?(view, "[data-mcp-source='#{ignored_source}']")
        refute has_element?(view, "input[value='ignored::raw']")
        view |> element("el-dm-button[phx-click='refresh_mcp_tools']") |> render_click()
        render_async(view)
        refute_receive :legacy_discovery_requested
        assert_receive {:agent_display_snapshot, _}

        native_agent_event(
          view,
          "save_agent",
          &put_native_value(&1, "agent[label]", "Effective source retained")
        )

        saved = AgentConfigs.get(agent.id)
        assert saved.tools === direct
        assert saved.toolset_ids === agent.toolset_ids
        assert saved.toolset_id === agent.toolset_id
        assert saved.tool_contract_version === unquote(version)

        expected =
          Map.put(agent.config, "mcp_selection", %{
            "default" => "selected",
            "sources" => %{
              source.id => %{"mode" => "selected", "tools" => [raw_name]}
            }
          })

        assert saved.config === expected
      end
    end

    @tag :native_catalog_provenance
    test "Agent v0 with a legacy Toolset labels the effective selection as requiring migration",
         %{conn: conn} do
      {:ok, linked} = Toolsets.create(%{name: "effective-legacy", tool_names: ["send_message"]})

      {:ok, agent} =
        AgentConfigs.create(%{
          name: "effective-legacy-agent",
          tool_contract_version: 0,
          toolset_ids: [linked.id]
        })

      {:ok, view, html} = live(conn, ~p"/agent/agents/#{agent.id}/config")
      assert html =~ "Legacy selection"
      assert has_element?(view, "[data-toolset-id='#{linked.id}']", "migration required")

      assert has_element?(
               view,
               "[data-toolset-id='#{linked.id}'] input[value='#{linked.id}'][checked]"
             )
    end
  end

  describe "native contract editor" do
    test "new agents author v1 with explicit empty direct tools and retain user-facing defaults",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/agent/agents/new")
      assert html =~ "Native contract v1"

      native_agent_event(view, "change_agent_form", fn pairs ->
        pairs
        |> put_native_value("agent[name]", "native-empty")
        |> put_native_value("agent[tool_contract_version]", "0")
      end)

      render_hook(view, "switch_config_tab", %{"tab" => "tools"})
      view |> element("el-dm-button[phx-click='refresh_mcp_tools']") |> render_click()
      render_async(view)

      native_agent_event(
        view,
        "save_agent",
        &put_native_value(&1, "agent[tool_contract_version]", "0")
      )

      saved = AgentConfigs.get_by_name("native-empty")
      assert saved.tool_contract_version === 1
      assert saved.tools === []
      assert saved.toolset_ids === []
      assert saved.toolset_id === nil
      assert saved.enabled === true
      assert saved.read_only === false
      assert saved.permission_mode == "ask"
      assert saved.reasoning_effort == "medium"
      assert saved.max_tokens == 8192
      assert saved.config["mcp_selection"] == %{"default" => "all", "sources" => %{}}
    end

    for version <- [0, 1] do
      test "saved v#{version} keeps version and same-spelled send_message on forged ordinary save",
           %{conn: conn} do
        {:ok, agent} =
          AgentConfigs.create(%{
            name: "contract-save-v#{unquote(version)}",
            tool_contract_version: unquote(version),
            tools: ["send_message", "synapsis::swarm_message", "send_message", "file_read"],
            config: %{
              "mcp_selection" => %{"default" => "selected", "sources" => %{}},
              "workspace_path" => "~/.synapsis/agents/contract-save-v#{unquote(version)}",
              "skill_ids" => []
            }
          })

        {:ok, view, html} = live(conn, ~p"/agent/agents/#{agent.id}/config")

        if unquote(version) == 0 do
          assert html =~ "Legacy selection"
          assert html =~ "migration"
        else
          assert html =~ "Native contract v1"
        end

        native_agent_event(view, "change_agent_form", fn pairs ->
          pairs
          |> put_native_value("agent[label]", "Version preserved")
          |> put_native_value("agent[tool_contract_version]", to_string(1 - unquote(version)))
        end)

        render_hook(view, "switch_config_tab", %{"tab" => "tools"})
        view |> element("el-dm-button[phx-click='refresh_mcp_tools']") |> render_click()
        render_async(view)

        native_agent_event(
          view,
          "save_agent",
          &put_native_value(&1, "agent[tool_contract_version]", to_string(1 - unquote(version)))
        )

        saved = AgentConfigs.get(agent.id)
        assert saved.tool_contract_version === unquote(version)
        assert saved.tools === agent.tools
        assert saved.toolset_ids === agent.toolset_ids
        assert saved.toolset_id === agent.toolset_id
        assert saved.config === agent.config
        assert saved.label == "Version preserved"
      end
    end

    @tag :native_catalog_provenance
    test "native agents keep saved incompatible legacy toolsets visible and label their versions",
         %{conn: conn} do
      {:ok, legacy} = Toolsets.create(%{name: "legacy-saved-link", tool_names: ["send_message"]})

      {:ok, native} =
        Toolsets.create(%{
          name: "native-saved-link",
          tool_contract_version: 1,
          tool_names: ["send_message"]
        })

      {:ok, agent} =
        AgentConfigs.create(%{
          name: "native-legacy-link",
          tool_contract_version: 1,
          tools: [],
          toolset_ids: [legacy.id, native.id, legacy.id],
          toolset_id: legacy.id,
          config: %{"mcp_selection" => %{"default" => "selected", "sources" => %{}}}
        })

      {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
      assert has_element?(view, "[data-toolset-id='#{legacy.id}']", "Legacy contract v0")
      assert has_element?(view, "[data-toolset-id='#{legacy.id}']", "migration required")

      assert has_element?(
               view,
               "[data-toolset-id='#{legacy.id}'] input[value='#{legacy.id}'][checked]"
             )

      assert has_element?(view, "[data-toolset-id='#{native.id}']", "Native contract v1")

      native_agent_event(
        view,
        "save_agent",
        &put_native_value(&1, "agent[label]", "Link retained")
      )

      saved = AgentConfigs.get(agent.id)
      assert saved.tools === []
      assert saved.tool_contract_version === 1
      assert saved.toolset_ids === agent.toolset_ids
      assert saved.toolset_id === agent.toolset_id
    end

    test "native MCP choices use snapshot source UUID and entire nested raw name across rename and duplicate labels",
         %{conn: conn} do
      raw_name = "namespace::read::documents"
      first = native_snapshot_source("same-agent-label", raw_name)
      second = native_snapshot_source("same-agent-label", raw_name)

      policy = %{
        "default" => "selected",
        "sources" => %{
          first.id => %{"mode" => "selected", "tools" => [raw_name, raw_name]},
          second.id => %{"mode" => "none", "tools" => []}
        }
      }

      {:ok, agent} =
        AgentConfigs.create(%{
          name: "native-source-rules",
          tool_contract_version: 1,
          tools: [],
          config: %{
            "mcp_selection" => policy,
            "workspace_path" => "~/.synapsis/agents/native-source-rules",
            "skill_ids" => []
          }
        })

      # A Registry record with the same label must never supply a native choice.
      legacy_name = "mcp:same-agent-label:legacy-only"

      assert :ok =
               Synapsis.Tool.Registry.register_process(legacy_name, self(),
                 mcp_config_id: first.id,
                 mcp_tool_name: "legacy-only",
                 description: "Legacy only"
               )

      on_exit(fn -> Synapsis.Tool.Registry.unregister(legacy_name) end)
      {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
      render_async(view)

      assert has_element?(
               view,
               "[data-mcp-source='#{first.id}'] input[value='#{raw_name}'][checked]"
             )

      refute has_element?(view, "[data-mcp-source='#{first.id}'] input[value='legacy-only']")
      assert has_element?(view, "[data-mcp-source='#{second.id}']", "same-agent-label")

      native_agent_event(
        view,
        "change_agent_form",
        &put_native_value(&1, "agent[label]", "UUID draft")
      )

      {:ok, _} = Synapsis.MCPConfigs.update(first, %{name: "renamed-agent-label"})
      view |> element("el-dm-button[phx-click='refresh_mcp_tools']") |> render_click()
      render_async(view)
      assert has_element?(view, "[data-mcp-source='#{first.id}']", "renamed-agent-label")
      native_agent_event(view, "save_agent")
      saved = AgentConfigs.get(agent.id)
      assert saved.config === agent.config
      assert saved.tools === []
      assert saved.label == "UUID draft"
      assert_receive {:agent_display_snapshot, _}
      refute_receive {:unexpected_agent_mcp_request, _}
    end

    test "native direct MCP names initialize source rules by UUID while retaining nested raw suffix and orphan selections",
         %{conn: conn} do
      {:ok, source} =
        Synapsis.MCPConfigs.create(%{
          name: "native-direct-label",
          command: "false",
          enabled: false
        })

      on_exit(fn -> Synapsis.MCPConfigs.delete(source) end)
      orphan = Ecto.UUID.generate()

      names = [
        "mcp::#{source.id}::namespace::raw",
        "mcp::#{orphan}::gone::raw",
        "mcp::#{source.id}::namespace::raw"
      ]

      {:ok, agent} =
        AgentConfigs.create(%{
          name: "native-direct-source",
          tool_contract_version: 1,
          tools: names
        })

      {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")

      assert has_element?(
               view,
               "[data-mcp-source='#{source.id}'] input[value='namespace::raw'][checked]"
             )

      assert has_element?(view, "[data-mcp-source='#{orphan}'] input[value='gone::raw'][checked]")

      native_agent_event(
        view,
        "save_agent",
        &put_native_value(&1, "agent[label]", "Direct retained")
      )

      saved = AgentConfigs.get(agent.id)
      assert saved.tools === names
      assert saved.tool_contract_version === 1

      assert saved.config["mcp_selection"] == %{
               "default" => "selected",
               "sources" => %{
                 source.id => %{
                   "mode" => "selected",
                   "tools" => ["namespace::raw", "namespace::raw"]
                 },
                 orphan => %{"mode" => "selected", "tools" => ["gone::raw"]}
               }
             }
    end

    test "new native agent labels legacy toolset choices before any link is saved", %{conn: conn} do
      {:ok, legacy} = Toolsets.create(%{name: "legacy-new-choice", tool_names: ["send_message"]})
      {:ok, view, _} = live(conn, ~p"/agent/agents/new")
      assert has_element?(view, "[data-toolset-id='#{legacy.id}']", "Legacy contract v0")
      assert has_element?(view, "[data-toolset-id='#{legacy.id}']", "migration required")
      refute has_element?(view, "input[value='#{legacy.id}'][checked]")
    end
  end

  for version <- [0, 1] do
    @saved_version version
    test "native metadata saves preserve unavailable selections and raw v#{version} configuration",
         %{
           conn: conn
         } do
      {:ok, present} = Toolsets.create(%{name: "present-saved", tool_names: ["file_read"]})
      missing = Ecto.UUID.generate()
      selected_source = Ecto.UUID.generate()
      denied_source = Ecto.UUID.generate()
      all_source = Ecto.UUID.generate()

      policy = %{
        "default" => "all",
        "sources" => %{
          selected_source => %{"mode" => "selected", "tools" => ["z:raw", "a/raw", "z:raw"]},
          denied_source => %{"mode" => "none", "tools" => ["denied/raw"]},
          all_source => %{"mode" => "all", "tools" => ["remembered/raw"]}
        }
      }

      {:ok, agent} =
        AgentConfigs.create(%{
          name: "raw-saved-v#{@saved_version}",
          tool_contract_version: @saved_version,
          tools: ["unknown/native", "file_read", "unknown/native"],
          toolset_ids: [missing, present.id, missing],
          toolset_id: present.id,
          config: %{
            "unknown" => %{"keep" => ["raw", "raw"]},
            "mcp_selection" => policy,
            "workspace_path" => "~/.synapsis/agents/raw-saved-v#{@saved_version}",
            "skill_ids" => []
          }
        })

      {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
      render_async(view)

      assert has_element?(
               view,
               "input[type='checkbox'][name='agent[toolset_ids][]'][value='#{missing}'][checked]"
             )

      assert has_element?(view, "[data-unavailable-toolset='#{missing}']", "unavailable")
      assert has_element?(view, "[data-unavailable-toolset='#{missing}']", missing)

      for {id, rule} <- policy["sources"] do
        assert has_element?(view, "[data-mcp-source='#{id}']", "unavailable")
        assert has_element?(view, "[data-mcp-source='#{id}']", id)

        assert has_element?(
                 view,
                 "select[name='mcp_selection[sources][#{id}][mode]'] option[value='#{rule["mode"]}'][selected]"
               )
      end

      native_agent_event(
        view,
        "change_agent_form",
        &put_native_value(&1, "agent[label]", "Draft label")
      )

      original_mount = agent_form_mount(view)
      render_hook(view, "switch_config_tab", %{"tab" => "tools"})
      assert agent_form_mount(view) != original_mount
      view |> element("el-dm-button[phx-click='refresh_mcp_tools']") |> render_click()
      render_async(view)
      render_hook(view, "switch_config_tab", %{"tab" => "overview"})
      assert agent_managed_values(view)["agent"]["label"] == "Draft label"
      native_agent_event(view, "save_agent")

      saved = AgentConfigs.get(agent.id)
      assert saved.label == "Draft label"
      assert saved.tool_contract_version == @saved_version
      assert saved.tools == agent.tools
      assert saved.toolset_ids == agent.toolset_ids
      assert saved.toolset_id == agent.toolset_id
      assert saved.config == agent.config
    end
  end

  test "native unchecks and inherited orphan rules persist after reopening", %{conn: conn} do
    {:ok, present} = Toolsets.create(%{name: "retained-saved", tool_names: ["file_read"]})
    missing = Ecto.UUID.generate()
    removed_source = Ecto.UUID.generate()
    selected_source = Ecto.UUID.generate()

    {:ok, agent} =
      AgentConfigs.create(%{
        name: "explicit-unavailable-removal",
        toolset_ids: [missing, present.id, missing],
        toolset_id: missing,
        config: %{
          "mcp_selection" => %{
            "default" => "all",
            "sources" => %{
              removed_source => %{"mode" => "none", "tools" => []},
              selected_source => %{
                "mode" => "selected",
                "tools" => ["keep/raw", "gone/raw", "keep/raw"]
              }
            }
          }
        }
      })

    {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
    render_async(view)

    native_agent_event(view, "change_agent_form", fn pairs ->
      pairs
      |> Enum.reject(&(&1 == {"agent[toolset_ids][]", missing}))
      |> Enum.reject(&(&1 == {"mcp_selection[sources][#{selected_source}][tools][]", "gone/raw"}))
      |> put_native_value("mcp_selection[sources][#{removed_source}][mode]", "inherit")
    end)

    view |> element("el-dm-button[phx-click='refresh_mcp_tools']") |> render_click()
    render_async(view)
    render_hook(view, "switch_config_tab", %{"tab" => "runtime"})
    native_agent_event(view, "save_agent")

    saved = AgentConfigs.get(agent.id)
    assert saved.toolset_ids == [present.id]
    assert saved.toolset_id == present.id

    assert saved.config["mcp_selection"] == %{
             "default" => "all",
             "sources" => %{
               selected_source => %{"mode" => "selected", "tools" => ["keep/raw", "keep/raw"]}
             }
           }

    {:ok, reopened, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
    render_async(reopened)
    refute has_element?(reopened, "[data-unavailable-toolset='#{missing}']")
    refute has_element?(reopened, "[data-mcp-source='#{removed_source}']")
    refute has_element?(reopened, "input[value='gone/raw']")
    assert has_element?(reopened, "input[value='keep/raw'][checked]")
  end

  test "native metadata save preserves a singular-only unavailable toolset", %{conn: conn} do
    missing = Ecto.UUID.generate()
    {:ok, agent} = AgentConfigs.create(%{name: "singular-missing", toolset_id: missing})
    {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
    render_async(view)

    native_agent_event(
      view,
      "save_agent",
      &put_native_value(&1, "agent[label]", "Singular saved")
    )

    saved = AgentConfigs.get(agent.id)
    assert saved.label == "Singular saved"
    assert saved.toolset_ids == []
    assert saved.toolset_id == missing

    native_agent_event(
      view,
      "save_agent",
      &Enum.reject(&1, fn pair -> pair == {"agent[toolset_ids][]", missing} end)
    )

    saved = AgentConfigs.get(agent.id)
    assert saved.toolset_ids == []
    assert saved.toolset_id == nil
  end

  test "an open agent editor refreshes model options while retaining its selected model", %{
    conn: conn
  } do
    {:ok, provider} =
      Providers.create(%{
        name: "live-agent-provider",
        type: "openai",
        config: %{"model_catalog_migrated" => true}
      })

    {:ok, first} = Synapsis.Models.create(%{provider_id: provider.id, model: "saved-model"})

    {:ok, agent} =
      AgentConfigs.create(%{name: "live-agent", provider: provider.name, model: first.model})

    {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
    {:ok, second} = Synapsis.Models.create(%{provider_id: provider.id, model: "new-model"})
    Phoenix.PubSub.broadcast(Synapsis.PubSub, "providers:catalog", {:provider_catalog_changed})
    assert_push_event(view, "agent:model-options", %{options: options})

    assert Enum.any?(options, fn provider ->
             Enum.any?(provider.children, &(&1.value == second.model))
           end)

    assert has_element?(view, "#agent-provider-model-picker[data-model='#{first.model}']")
    assert {:ok, _} = Providers.delete(provider.id)
    Phoenix.PubSub.broadcast(Synapsis.PubSub, "providers:catalog", {:provider_catalog_changed})
    assert_push_event(view, "agent:model-options", %{options: []})
  end

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
    assert {:ok, _} =
             Synapsis.Config.Store.put(:backplane, %{"id" => "source-group", "enabled" => true})

    on_exit(fn -> Synapsis.Config.Store.delete(:backplane, "source-group") end)

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

  # Serialize successful native controls as FormData does in the browser. Only
  # React-managed markers obtain their mounted values from initial-values; never
  # merge that map over native controls or restore a missing native selection.
  defp native_agent_event(view, event, transform \\ &Function.identity/1) do
    html =
      view
      |> element("[data-form-id='agent-config-form']")
      |> render()
      |> LazyHTML.from_fragment()

    [id] = html |> LazyHTML.query("[data-form-id]") |> LazyHTML.attribute("id")

    values =
      html
      |> LazyHTML.query("input[name], textarea[name], select[name]")
      |> LazyHTML.to_tree()
      |> Enum.flat_map(fn {tag, attrs, children} ->
        attrs = Map.new(attrs)

        cond do
          Map.has_key?(attrs, "disabled") ->
            []

          attrs["type"] in ["checkbox", "radio"] and not Map.has_key?(attrs, "checked") ->
            []

          attrs["type"] in ["submit", "button", "reset", "file"] ->
            []

          tag == "textarea" ->
            [{attrs["name"], children |> LazyHTML.from_tree() |> LazyHTML.text()}]

          tag == "select" ->
            options =
              children |> LazyHTML.from_tree() |> LazyHTML.query("option") |> LazyHTML.to_tree()

            selected = Enum.filter(options, fn {_, a, _} -> List.keymember?(a, "selected", 0) end)
            selected = if selected == [], do: Enum.take(options, 1), else: selected

            Enum.map(selected, fn {_, a, c} ->
              {attrs["name"], Map.new(a)["value"] || c |> LazyHTML.from_tree() |> LazyHTML.text()}
            end)

          true ->
            [{attrs["name"], attrs["value"] || ""}]
        end
      end)
      |> Kernel.++(agent_managed_pairs(html))
      |> transform.()
      |> native_snapshot()

    render_hook(view, event, %{
      "id" => id,
      "values" => values,
      "revision" => System.unique_integer([:positive, :monotonic])
    })
  end

  defp put_native_value(pairs, name, value) do
    Enum.reject(pairs, fn {key, _} -> key == name end) ++ [{name, value}]
  end

  # The native hook initializes every rendered [] group, filters empty hidden
  # sentinels, and collects each checked value once before sending its snapshot.
  defp native_snapshot(pairs) do
    values = pairs |> URI.encode_query() |> Plug.Conn.Query.decode()

    pairs
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&String.ends_with?(&1, "[]"))
    |> Enum.uniq()
    |> Enum.reduce(values, fn name, values ->
      selected = for {^name, value} <- pairs, value != "", do: value

      path =
        name
        |> String.trim_trailing("[]")
        |> String.replace("]", "")
        |> String.split("[")
        |> Enum.map(&Access.key(&1, %{}))

      put_in(values, path, Enum.uniq(selected))
    end)
  end

  defp agent_form_mount(view) do
    view
    |> element("[data-form-id='agent-config-form']")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-form-id]")
    |> LazyHTML.attribute("id")
    |> hd()
  end

  defp agent_managed_values(view) do
    view
    |> element("[data-form-id='agent-config-form']")
    |> render()
    |> LazyHTML.from_fragment()
    |> agent_managed_pairs()
    |> URI.encode_query()
    |> Plug.Conn.Query.decode()
  end

  defp agent_managed_pairs(html) do
    initial =
      html
      |> LazyHTML.query("[data-initial-values]")
      |> LazyHTML.attribute("data-initial-values")
      |> hd()
      |> Jason.decode!()

    html
    |> LazyHTML.query("[data-dm-react-field]")
    |> LazyHTML.attribute("data-dm-react-field")
    |> Enum.map(&Jason.decode!/1)
    |> Enum.reject(& &1["disabled"])
    |> Enum.map(fn field ->
      path = field["name"] |> String.replace("]", "") |> String.split("[")
      {field["name"], get_in(initial, path) || ""}
    end)
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
