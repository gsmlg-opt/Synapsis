defmodule Synapsis.Agent.DaemonToolsetsTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Daemon.Toolsets
  alias Synapsis.Agent.Daemon.Execution
  alias Synapsis.AgentRun

  test "rejects dangerous and unknown profiles" do
    assert {:error, :dangerous_tool_profile} = Toolsets.resolve("dangerous")
    assert {:error, :unknown_tool_profile} = Toolsets.resolve("unrestricted")
    assert {:error, :unknown_tool_profile} = Toolsets.resolve(nil)
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
