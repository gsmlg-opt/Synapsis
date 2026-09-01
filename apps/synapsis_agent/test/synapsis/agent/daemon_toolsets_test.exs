defmodule Synapsis.Agent.DaemonToolsetsTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Daemon.Toolsets
  alias Synapsis.Agent.Daemon.Execution
  alias Synapsis.AgentRun

  @basic ~w(
    file_read list_dir grep glob memory_search todo_read session_summarize skill tool_search
    agent_status agent_discover agent_inbox
  )
  @workspace @basic ++
               ~w(memory_save memory_update todo_write file_write file_edit multi_edit file_move)
  @coding @workspace ++ ~w(bash task)

  test "resolves explicit safe daemon toolsets" do
    assert {:ok, @basic} = Toolsets.resolve("assistant_basic")
    assert {:ok, @workspace} = Toolsets.resolve("assistant_workspace")
    assert {:ok, @coding} = Toolsets.resolve("assistant_coding")
  end

  test "maps legacy profiles onto safe daemon toolsets" do
    assert {:ok, @basic} = Toolsets.resolve("read_only")
    assert {:ok, @workspace} = Toolsets.resolve("reflect")
    assert {:ok, @workspace} = Toolsets.resolve("heartbeat")
    assert {:ok, @coding} = Toolsets.resolve("coding")
    assert {:ok, @coding} = Toolsets.resolve("maintenance")
  end

  test "rejects dangerous and unknown profiles" do
    assert {:error, :dangerous_tool_profile} = Toolsets.resolve("dangerous")
    assert {:error, :unknown_tool_profile} = Toolsets.resolve("unrestricted")
    assert {:error, :unknown_tool_profile} = Toolsets.resolve(nil)
  end

  test "never includes explicitly destructive tools" do
    for profile <- ~w(assistant_basic assistant_workspace assistant_coding) do
      assert {:ok, tools} = Toolsets.resolve(profile)
      refute "file_delete" in tools
      refute "team_delete" in tools
      refute "computer" in tools
    end
  end

  test "AgentRun accepts v1 profiles and defaults new runs to assistant_basic" do
    attrs = %{kind: "manual", source: "web", prompt: "safe run"}

    assert %{valid?: true} = AgentRun.changeset(%AgentRun{}, attrs)

    assert %AgentRun{tool_profile: "assistant_basic"} =
             Ecto.Changeset.apply_changes(AgentRun.changeset(%AgentRun{}, attrs))

    for profile <- ~w(assistant_basic assistant_workspace assistant_coding) do
      assert %{valid?: true} =
               AgentRun.changeset(%AgentRun{}, Map.put(attrs, :tool_profile, profile))
    end
  end

  test "manual submissions default to basic and reject unsafe profiles before persistence" do
    assert {:ok, %{tool_profile: "assistant_basic"}} = Execution.manual_attrs("safe run", %{})

    assert {:error, :invalid_options} =
             Execution.manual_attrs("unsafe run", %{tool_profile: "dangerous"})

    assert {:error, :invalid_options} =
             Execution.manual_attrs("unknown run", %{tool_profile: "unrestricted"})
  end
end
