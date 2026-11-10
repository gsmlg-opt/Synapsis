defmodule Synapsis.Agent.Tools.DisplayCatalogTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Tools.{DisplayCatalog, Profiles}

  @expected ~w(
    apply_patch clock::curr_time clock::sleep exec exec_command followup_task interrupt_agent
    list_agents list_mcp_resource_templates list_mcp_resources memory::get read_mcp_resource
    send_message spawn_agent synapsis::agents_list synapsis::ask_user synapsis::automations
    synapsis::automations_create synapsis::automations_manage synapsis::automations_remove
    synapsis::automations_update synapsis::automations_wake synapsis::browser synapsis::edit
    synapsis::enter_plan_mode synapsis::exit_plan_mode synapsis::firecrawl_search synapsis::ls
    synapsis::memory_save synapsis::memory_source_search synapsis::memory_update
    synapsis::process synapsis::read synapsis::session_status synapsis::session_summarize
    synapsis::sessions_history synapsis::sessions_list synapsis::skill
    synapsis::skill_workshop synapsis::skills_read synapsis::skills_search
    synapsis::tavily_search synapsis::todo_read synapsis::todo_write synapsis::tool_describe
    synapsis::web_search synapsis::workspace_memory_get synapsis::workspace_memory_search
    synapsis::write view_image wait wait_agent web::fetch write_stdin
  )

  @tag :agent_directory_production
  test "display catalog covers every supported static native name exactly once" do
    names = Enum.map(DisplayCatalog.list(), & &1.name)
    assert length(names) == length(@expected)
    assert length(Enum.uniq(names)) == length(names)
    assert Enum.sort(names) == Enum.sort(@expected)
    assert Enum.sort(names) == Enum.sort(Profiles.supported_names())
  end

  @tag :automation_production
  test "automation metadata states read-only route configuration visibility" do
    entry = Enum.find(DisplayCatalog.list(), &(&1.name == "synapsis::automations"))
    assert entry.description =~ "Read-only"
    assert entry.description =~ "routine"
    assert entry.description =~ "heartbeat"
    refute entry.description =~ "creator"
  end

  test "entries expose only display metadata, without runtime contexts or readiness claims" do
    assert DisplayCatalog.list() == DisplayCatalog.list()

    for entry <- DisplayCatalog.list() do
      assert Enum.sort(Map.keys(entry)) == [:category, :description, :name, :source]
      assert is_binary(entry.description) and String.trim(entry.description) != ""
      assert is_atom(entry.category)
      assert entry.source == "built-in"
    end

    refute Enum.any?(DisplayCatalog.list(), &(&1.name in ~w(file_read bash computer task fetch)))
    collaboration = Enum.find(DisplayCatalog.list(), &(&1.name == "send_message"))
    assert collaboration.description =~ "collaboration"
  end
end
