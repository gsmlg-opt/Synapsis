defmodule Synapsis.Session.NativeAgentSwitchFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Part.Text
  alias Synapsis.Provider.ToolName
  alias Synapsis.Runtime.Store, as: Journal
  alias Synapsis.Session.Worker
  alias Synapsis.Session.Worker.PendingInputs

  @moduletag :tmp_dir
  @answer "selected saved agent completed"

  test "public agent selection updates durable and live identity and the next provider catalog",
       %{
         tmp_dir: tmp_dir
       } do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        text: @answer,
        session_config: %{"memory_context" => false}
      )

    id = harness.session.id

    on_exit(fn ->
      SessionHarness.cleanup!(harness)
      cleanup_runtime(id)
    end)

    assert {:ok, target} =
             Synapsis.AgentConfigs.create(%{
               name: "selected_agent_#{System.unique_integer([:positive, :monotonic])}",
               provider: harness.provider.name,
               model: "characterization-model",
               tools: ["list_agents"],
               tool_contract_version: 1,
               config: %{"workspace_path" => tmp_dir}
             })

    on_exit(fn -> Synapsis.AgentConfigs.delete(target) end)
    SessionHarness.subscribe!(id)
    SessionHarness.ensure_running!(id)
    await_selection_ready(id, System.monotonic_time(:millisecond) + 5_000)

    assert :ok = Worker.switch_agent(id, target.name)
    assert {:ok, meta} = Synapsis.Session.Store.get_meta(id)
    assert meta.agent == target.name
    assert {:ok, reloaded} = Synapsis.Sessions.get(id)
    assert reloaded.agent == target.name
    assert Worker.snapshot(id).session.agent == target.name

    assert :ok = Worker.send_message(id, "Use the selected saved agent")
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000

    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_status, data} = :sys.get_state(worker)
    adapter = :sys.get_state(data.runtime_pid)
    assert adapter.context.agent.id == target.id
    assert adapter.context.agent.name == target.name
    assert adapter.context.agent.tools == ["list_agents"]
    assert adapter.context.session.agent == target.name

    assert [request] = Agent.get(harness.counter, & &1.provider_requests)
    assert request["model"] == target.model
    assert Enum.map(request["tools"], &ToolName.decode(&1["function"]["name"])) == ["list_agents"]

    assert [@answer] =
             for(
               message <- Synapsis.Sessions.get_messages(id),
               message.role == "assistant",
               %Text{content: content} <- message.parts,
               do: content
             )
  end

  defp await_selection_ready(id, deadline) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {state, data} = :sys.get_state(worker, 1_000)

    if state == :idle and data.pending_inputs.booted and not data.runtime_active and
         not PendingInputs.changing_agent?(data) do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        receive do
        after
          10 -> await_selection_ready(id, deadline)
        end
      else
        flunk("Worker did not finish its ordinary selection readiness lane")
      end
    end
  end

  defp cleanup_runtime(id) do
    {:ok, locators} = Journal.list_facts(id, :run_locator)

    prefixes =
      ["coord/runtime/facts/" <> segment(id) <> "/"] ++
        Enum.map(
          Enum.uniq_by(locators, & &1.namespace),
          &("coord/runtime/runs/" <> segment(&1.namespace) <> "/")
        )

    for prefix <- prefixes do
      {:ok, pairs} = Concord.Turso.prefix_scan(prefix, timeout: 5_000)
      for {key, _} <- pairs, do: Concord.Turso.delete(key, timeout: 5_000)
    end

    Concord.Turso.delete("coord/runtime/projections/" <> segment(id), timeout: 5_000)
  end

  defp segment(value), do: value |> to_string() |> Base.url_encode64(padding: false)
end
