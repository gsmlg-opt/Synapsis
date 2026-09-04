defmodule Synapsis.Agent.DaemonToolsetsTest do
  use ExUnit.Case, async: false

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
  @dream @basic ++ ~w(memory_save memory_update)

  test "resolves explicit safe daemon toolsets" do
    assert {:ok, @basic} = Toolsets.resolve("assistant_basic")
    assert {:ok, @workspace} = Toolsets.resolve("assistant_workspace")
    assert {:ok, @coding} = Toolsets.resolve("assistant_coding")
    assert {:ok, @dream} = Toolsets.resolve("assistant_dream")
    assert {:ok, @dream ++ ["todo_write"]} = Toolsets.resolve("assistant_dream_todo")
  end

  test "appends only enabled non-deferred read-only MCP tools to basic-derived profiles" do
    suffix = System.unique_integer([:positive])
    safe_read = "mcp:notes-#{suffix}:read"
    safe_none = "mcp:notes-#{suffix}:status"
    unsafe_write = "mcp:notes-#{suffix}:write"
    disabled_read = "mcp:notes-#{suffix}:disabled"
    deferred_read = "mcp:notes-#{suffix}:deferred"
    names = [safe_read, safe_none, unsafe_write, disabled_read, deferred_read]

    on_exit(fn -> Enum.each(names, &Synapsis.Tool.Registry.unregister/1) end)

    :ok =
      Synapsis.Tool.Registry.register_process(safe_read, self(), permission_level: :read)

    :ok =
      Synapsis.Tool.Registry.register_process(safe_none, self(), permission_level: :none)

    :ok =
      Synapsis.Tool.Registry.register_process(unsafe_write, self(), permission_level: :write)

    :ok =
      Synapsis.Tool.Registry.register_process(disabled_read, self(),
        permission_level: :read,
        enabled: false
      )

    :ok =
      Synapsis.Tool.Registry.register_process(deferred_read, self(),
        permission_level: :read,
        deferred: true
      )

    for profile <-
          ~w(assistant_basic assistant_workspace assistant_coding assistant_dream assistant_dream_todo) do
      assert {:ok, tools} = Toolsets.resolve(profile)
      assert safe_read in tools
      assert safe_none in tools
      refute unsafe_write in tools
      refute disabled_read in tools
      refute deferred_read in tools
    end
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
    for profile <-
          ~w(assistant_basic assistant_workspace assistant_coding assistant_dream assistant_dream_todo) do
      assert {:ok, tools} = Toolsets.resolve(profile)
      refute "file_delete" in tools
      refute "team_delete" in tools
      refute "computer" in tools
    end

    assert {:ok, dream_tools} = Toolsets.resolve("assistant_dream")
    refute "todo_write" in dream_tools
    refute "file_write" in dream_tools
    refute "bash" in dream_tools
  end

  test "AgentRun accepts v1 profiles and defaults new runs to assistant_basic" do
    attrs = %{kind: "manual", source: "web", prompt: "safe run"}

    assert %{valid?: true} = AgentRun.changeset(%AgentRun{}, attrs)

    assert %AgentRun{tool_profile: "assistant_basic"} =
             Ecto.Changeset.apply_changes(AgentRun.changeset(%AgentRun{}, attrs))

    for profile <-
          ~w(assistant_basic assistant_workspace assistant_coding assistant_dream assistant_dream_todo) do
      assert %{valid?: true} =
               AgentRun.changeset(%AgentRun{}, Map.put(attrs, :tool_profile, profile))
    end
  end

  test "dream routines use the dream-only profile and grant todo writes only explicitly" do
    opts = %{routine_id: Ecto.UUID.generate(), prompt: "reflect"}

    assert {:ok, %{tool_profile: "assistant_dream"}} = Execution.routine_attrs(:dream, opts)

    assert {:ok, %{tool_profile: "assistant_dream_todo"}} =
             Execution.routine_attrs(:dream, Map.put(opts, :allow_todo_write, true))

    assert {:error, :invalid_options} =
             Execution.routine_attrs(:dream, Map.put(opts, :tool_profile, "assistant_coding"))
  end

  test "manual submissions default to basic and reject unsafe profiles before persistence" do
    assert {:ok, %{tool_profile: "assistant_basic"}} = Execution.manual_attrs("safe run", %{})

    assert {:error, :invalid_options} =
             Execution.manual_attrs("unsafe run", %{tool_profile: "dangerous"})

    assert {:error, :invalid_options} =
             Execution.manual_attrs("unknown run", %{tool_profile: "unrestricted"})
  end
end
