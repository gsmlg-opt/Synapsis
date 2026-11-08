defmodule Synapsis.Agent.Tools.DisplayCatalogTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Tools.{DisplayCatalog, Profiles}

  @expected ~w(
    exec_command write_stdin clock::curr_time clock::sleep apply_patch
    spawn_agent send_message followup_task interrupt_agent list_agents wait_agent
    synapsis::file_read synapsis::file_write synapsis::file_edit synapsis::multi_edit
    synapsis::file_delete synapsis::file_move synapsis::list_dir synapsis::grep synapsis::glob
    synapsis::workspace_memory_search synapsis::workspace_memory_get
    synapsis::memory_source_search synapsis::memory_save synapsis::memory_update
    synapsis::skills_search synapsis::skills_read synapsis::skill synapsis::ask_user
    synapsis::todo_read synapsis::todo_write synapsis::enter_plan_mode synapsis::exit_plan_mode
    synapsis::session_summarize synapsis::sessions_history synapsis::sessions_list synapsis::session_status
    synapsis::agent_send synapsis::agent_ask synapsis::agent_reply synapsis::agent_inbox
    synapsis::swarm_message synapsis::teammate synapsis::team_delete
    synapsis::agent_discover synapsis::agent_status synapsis::agent_handoff synapsis::agents_list synapsis::automations
    synapsis::suggest_task synapsis::dismiss_task
  )

  @tag :agent_directory_production
  test "display catalog covers every supported static native name exactly once" do
    names = Enum.map(DisplayCatalog.list(), & &1.name)
    assert length(names) == 51
    assert length(Enum.uniq(names)) == 51
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
    swarm = Enum.find(DisplayCatalog.list(), &(&1.name == "synapsis::swarm_message"))
    assert collaboration.description =~ "collaboration"
    assert swarm.description =~ "swarm"
  end
end
