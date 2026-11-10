defmodule SynapsisWeb.AgentLive.BrowserSettingsFunctionalTest do
  use SynapsisWeb.ConnCase
  @moduletag :functional

  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.AgentConfigs

  test "Tools includes Browser setup in the ordinary agent form", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/agent/agents/new")
    render_click(view, "switch_config_tab", %{"tab" => "tools"})

    assert has_element?(view, "#agent-browser-settings", "Browser configuration")
    assert has_element?(view, ~s(input[name="browser_settings[node_executable]"]))
    assert has_element?(view, ~s(input[name="browser_settings[helper_path]"]))
    assert has_element?(view, ~s(input[name="browser_settings[profiles][7][name]"]))
    assert has_element?(view, "#agent-browser-settings", "managed-host")
    assert has_element?(view, "#agent-browser-settings", "select the Browser tool")

    initial = values(view)["browser_settings"]
    assert initial["profiles"]["0"]["timeout_ms"] == ""
    assert initial["profiles"]["0"]["max_image_bytes"] == ""
  end

  test "blank Browser editor stays absent on ordinary create", %{conn: conn} do
    name = unique_name()
    on_exit(fn -> if agent = AgentConfigs.get_by_name(name), do: AgentConfigs.delete(agent) end)
    {:ok, view, _} = live(conn, ~p"/agent/agents/new")
    react_form_submit(view, "agent-config-form", %{"agent" => %{"name" => name}})
    assert_redirect(view, ~p"/agent/agents")
    assert :error = Map.fetch(AgentConfigs.get_by_name(name).config, "browser")
  end

  test "create, reopen, edit and remove profiles through ordinary saves", %{conn: conn} do
    name = unique_name()
    on_exit(fn -> if agent = AgentConfigs.get_by_name(name), do: AgentConfigs.delete(agent) end)
    {:ok, view, _} = live(conn, ~p"/agent/agents/new")

    react_form_submit(view, "agent-config-form", %{
      "agent" => %{"name" => name},
      "browser_settings" => editor()
    })

    assert_redirect(view, ~p"/agent/agents")
    agent = AgentConfigs.get_by_name(name)
    assert agent.config["browser"] == browser()
    assert agent.tools == []
    assert agent.tool_contract_version == 1

    {:ok, reopened, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
    assert values(reopened)["browser_settings"]["profiles"]["0"]["name"] == "managed"

    react_form_submit(reopened, "agent-config-form", %{
      "browser_settings" => %{
        "default_profile" => "work",
        "profiles" => %{
          "0" => %{"timeout_ms" => "21000"},
          "1" => slot("work", %{"max_image_bytes" => "65536"})
        }
      }
    })

    expected =
      browser()
      |> Map.put("default_profile", "work")
      |> put_in(["profiles", "managed", "timeout_ms"], 21000)
      |> put_in(["profiles", "work"], Map.put(profile("work"), "max_image_bytes", 65536))

    assert AgentConfigs.get(agent.id).config["browser"] == expected
    assert values(reopened)["browser_settings"]["profiles"]["1"]["name"] == "work"
    assert values(reopened)["browser_settings"]["profiles"]["0"]["timeout_ms"] == "21000"

    {:ok, reopened_multiple, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
    assert values(reopened_multiple)["browser_settings"]["profiles"]["1"]["name"] == "work"

    react_form_submit(reopened_multiple, "agent-config-form", %{
      "browser_settings" => %{"profiles" => %{"0" => %{"remove" => true}}}
    })

    assert AgentConfigs.get(agent.id).config["browser"]["profiles"] == %{
             "work" => Map.put(profile("work"), "max_image_bytes", 65536)
           }

    react_form_submit(reopened_multiple, "agent-config-form", %{
      "browser_settings" => %{"remove" => true}
    })

    assert :error = Map.fetch(AgentConfigs.get(agent.id).config, "browser")
    assert values(reopened_multiple)["browser_settings"]["default_profile"] == ""
  end

  test "ordinary unchanged and unrelated edits preserve Browser values and omitted defaults", %{
    conn: conn
  } do
    for raw <- [nil, browser(), Map.put(browser(), "future_option", %{"keep" => true})] do
      agent = agent(%{"browser" => raw, "other" => %{"keep" => [1, 2]}})
      {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
      react_form_submit(view, "agent-config-form", %{})
      assert AgentConfigs.get(agent.id).config["browser"] == raw

      react_form_change(view, "agent-config-form", %{"agent" => %{"label" => "New label"}})
      react_form_submit(view, "agent-config-form", %{})
      saved = AgentConfigs.get(agent.id)
      assert saved.label == "New label"
      assert saved.config["browser"] == raw
      assert saved.config["other"] == %{"keep" => [1, 2]}
      assert saved.tools == agent.tools
      assert saved.tool_contract_version == agent.tool_contract_version
    end
  end

  test "read-only Browser controls retain saved numeric text on an unrelated save", %{conn: conn} do
    saved_browser = put_in(browser(), ["profiles", "managed", "timeout_ms"], "0010")
    agent = agent(%{"browser" => saved_browser})
    {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
    render_click(view, "switch_config_tab", %{"tab" => "tools"})

    assert has_element?(view, "#agent-browser-settings fieldset[disabled]")
    assert has_element?(view, "#browser-profile-0-timeout-ms[value='0010']")

    controls =
      view
      |> element("#agent-browser-settings fieldset")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input[name]")
      |> LazyHTML.to_tree()

    assert [_ | _] = controls

    for {"input", attrs, _} <- controls do
      assert Map.has_key?(Map.new(attrs), "disabled")
    end

    assert values(view)["browser_settings"]["profiles"]["0"]["timeout_ms"] == "0010"
    react_form_change(view, "agent-config-form", %{"agent" => %{"label" => "Keep saved text"}})
    react_form_submit(view, "agent-config-form", %{})
    assert AgentConfigs.get(agent.id).label == "Keep saved text"
    assert AgentConfigs.get(agent.id).config["browser"] == saved_browser
  end

  test "Browser drafts survive tab remounts, catalog updates and save reset", %{conn: conn} do
    agent = agent(%{})
    {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
    react_form_change(view, "agent-config-form", %{"browser_settings" => editor()})
    render_click(view, "switch_config_tab", %{"tab" => "tools"})
    assert values(view)["browser_settings"]["profiles"]["0"]["data_dir"] == "/tmp/browser-managed"

    send(view.pid, {:provider_catalog_changed})
    send(view.pid, {:tool_registry_changed, %{}})
    render(view)
    render_click(view, "switch_config_tab", %{"tab" => "overview"})
    assert values(view)["browser_settings"]["helper_path"] == "/opt/synapsis/browser/stdio.mjs"
    react_form_submit(view, "agent-config-form", %{})
    assert AgentConfigs.get(agent.id).config["browser"] == browser()
    assert values(view)["browser_settings"]["remove"] == false
    assert values(view)["browser_settings"]["profiles"]["0"]["timeout_ms"] == ""
  end

  test "unrelated save keeps Browser refreshed by another editor", %{conn: conn} do
    agent = agent(%{"browser" => browser()})
    {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.id}/config")
    refreshed = put_in(browser(), ["profiles", "managed", "timeout_ms"], 20000)
    {:ok, _} = AgentConfigs.update(agent, %{config: %{"browser" => refreshed}})
    react_form_submit(view, "agent-config-form", %{"agent" => %{"label" => "Keep refreshed"}})
    assert AgentConfigs.get(agent.id).config["browser"] == refreshed
    assert values(view)["browser_settings"]["profiles"]["0"]["timeout_ms"] == "20000"
  end

  defp agent(config) do
    {:ok, agent} =
      AgentConfigs.create(%{
        name: unique_name(),
        tool_contract_version: 1,
        tools: [],
        config: config
      })

    on_exit(fn -> AgentConfigs.delete(agent) end)
    agent
  end

  defp unique_name, do: "browser-editor-#{System.unique_integer([:positive, :monotonic])}"

  defp values(view) do
    view
    |> element(~s([data-form-id="agent-config-form"]))
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-form-id]")
    |> LazyHTML.attribute("data-initial-values")
    |> hd()
    |> Jason.decode!()
  end

  defp editor do
    %{
      "default_profile" => "managed",
      "node_executable" => "/usr/bin/node",
      "helper_path" => "/opt/synapsis/browser/stdio.mjs",
      "profiles" => %{"0" => slot("managed")}
    }
  end

  defp slot(name, extra \\ %{}) do
    Map.merge(
      %{
        "name" => name,
        "executable" => "/usr/bin/chromium",
        "data_dir" => "/tmp/browser-#{name}"
      },
      extra
    )
  end

  defp browser do
    %{
      "default_profile" => "managed",
      "node_executable" => "/usr/bin/node",
      "helper_path" => "/opt/synapsis/browser/stdio.mjs",
      "profiles" => %{"managed" => profile("managed")}
    }
  end

  defp profile(name) do
    %{
      "target" => "host",
      "driver" => "managed-host",
      "executable" => "/usr/bin/chromium",
      "data_dir" => "/tmp/browser-#{name}"
    }
  end
end
