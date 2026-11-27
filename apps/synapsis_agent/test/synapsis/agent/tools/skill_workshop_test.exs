defmodule Synapsis.Agent.Tools.SkillWorkshopTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Tools.SkillWorkshop
  alias Synapsis.AgentConfigs
  alias Synapsis.Config.Store

  test "listing an empty workshop fits its filesystem worker budget with a large pinned catalog" do
    {:ok, agent} =
      AgentConfigs.create(%{name: "workshop-budget-#{System.unique_integer([:positive])}"})

    on_exit(fn -> Store.delete(:agent, agent.id) end)
    {:ok, scope} = Synapsis.SkillWorkshop.capture(agent.id)

    context = %{
      scope: scope,
      session_id: "session",
      run_id: "run",
      incarnation: 1,
      catalog_revision: 1,
      prepare_successor: fn _, _ -> flunk("list cannot publish a catalog") end
    }

    {:ok, [descriptor]} = SkillWorkshop.descriptors(context)
    name = descriptor.tool_name
    # Shared terms expand when the registry is copied into a new BEAM process.
    other = %{schema: %{enum: List.duplicate("option", 2048)}}
    tools = Map.put(Map.new(1..1024, &{"tool-#{&1}", other}), name, descriptor)

    catalog = %{
      revision: 1,
      authority: %{caller: "agent", run_id: "run"},
      registry: %{tools: tools}
    }

    deadline = System.monotonic_time(:millisecond) + 5_000

    native =
      Map.merge(context, %{
        catalog_snapshot: catalog,
        stage_catalog: fn _ -> flunk("list cannot stage a catalog") end,
        effect_deadline: fn ->
          :erlang.garbage_collect()

          {:ok,
           %{
             deadline_ms: deadline,
             remaining_ms: deadline - System.monotonic_time(:millisecond),
             paused: false
           }}
        end
      })

    operation = %{
      tool_name: name,
      tool_revision: 1,
      catalog_revision: 1,
      incarnation: 1,
      run_id: "run",
      arguments: %{"action" => "list"},
      backend_context: native
    }

    assert {:ok, %{structured: %{"details" => %{"skills" => [], "archived" => []}}}} =
             SkillWorkshop.execute(operation)
  end
end
