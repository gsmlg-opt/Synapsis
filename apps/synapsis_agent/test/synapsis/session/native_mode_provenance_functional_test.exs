defmodule Synapsis.Session.NativeModeProvenanceFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Conversation
  alias Synapsis.Agent.Runtime.RunInventory
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Runtime.Store, as: Journal
  alias Synapsis.Session.{DynamicSupervisor, Worker}
  alias Synapsis.Session.Worker.PendingInputs

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @plan %{version: 1, mode: :plan, source: :user_mode, selected_mode: "plan_mode"}
  @execution %{
    version: 1,
    mode: :execution,
    source: :user_mode,
    selected_mode: "bypass_permissions"
  }
  @default %{version: 1, mode: :execution, source: :default, selected_mode: nil}
  @call_ids ~w(mode-spawn mode-wait-one mode-followup mode-wait-two)

  test "human mode persists, follows the admitting root, and survives settled owner recreation",
       %{
         tmp_dir: tmp_dir
       } do
    harness = setup_session(tmp_dir, ~w(spawn_agent wait_agent followup_task))
    id = harness.session.id
    trace = trace_startups(id)
    {_worker, initial_data, _adapter} = runtime(id)
    engine = initial_data.execution_mode

    select_mode(id, harness, "plan_mode")
    assert :ok = Worker.send_message(id, "mode plan root")
    assert_receive {:run_event, %{type: "session.completed"}}, 25_000
    {worker, plan_data, plan} = runtime(id)
    assert plan_data.execution_mode == engine
    assert plan.context.mode_provenance == @plan
    plan_root = plan.run_id

    assert [%{name: "/root/child", incarnation: 1, status: :completed}] =
             Worker.snapshot(id).subagents.agents

    assert {:ok, first_locators} = Journal.list_facts(id, :run_locator)
    assert length(first_locators) == 2
    assert Enum.all?(first_locators, &(&1.mode_provenance == @plan))
    assert_run_contexts(plan, first_locators)

    select_mode(id, harness, "bypass_permissions")
    assert :ok = Worker.send_message(id, "mode execution root")
    assert_receive {:run_event, %{type: "session.completed"}}, 25_000
    {^worker, execution_data, execution} = runtime(id)
    assert execution_data.execution_mode == engine
    assert execution.run_id != plan_root
    assert execution.context.mode_provenance == @execution

    assert [%{name: "/root/child", incarnation: 2, status: :completed}] =
             Worker.snapshot(id).subagents.agents

    assert {:ok, locators} = Journal.list_facts(id, :run_locator)
    assert length(locators) == 4
    assert Enum.all?(first_locators, &(&1 in locators))
    new_locators = locators -- first_locators
    assert Enum.all?(new_locators, &(&1.mode_provenance == @execution))
    assert Enum.find(new_locators, &(&1.kind == :child)).parent_run_id == execution.run_id
    assert_run_contexts(execution, locators)
    assert_tool_history(id)
    before_recreation = requests(harness)
    assert length(before_recreation) == 8
    assert Enum.count(before_recreation, fn {phase, _, _} -> phase == :child_first end) == 1
    assert Enum.count(before_recreation, fn {phase, _, _} -> phase == :child_followup end) == 1

    assert {:ok, inventory} = RunInventory.load(id)
    assert Enum.all?(inventory.entries, &(&1.availability == :present))
    stop_settled(id, worker, execution_data.runtime_pid, execution.session)
    assert {:ok, retained} = RunInventory.load(id)
    SessionHarness.ensure_running!(id)
    assert Worker.snapshot(id).session.config["user_mode"] == "bypass_permissions"
    assert :ok = Worker.send_message(id, "mode recreated root")
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    {new_worker, _data, recreated} = runtime(id)
    assert new_worker != worker
    assert recreated.context.mode_provenance == @execution
    assert recreated.recovery_inventory == retained
    assert recreated.store.namespace != execution.store.namespace
    assert {:ok, final_locators} = Journal.list_facts(id, :run_locator)
    assert Enum.all?(locators, &(&1 in final_locators))
    assert [fresh_locator] = final_locators -- locators
    assert fresh_locator.mode_provenance == @execution
    assert fresh_locator.kind == :root
    assert_run_contexts(recreated, [fresh_locator])
    assert load_aggregates(locators) == Map.new(retained.entries, &{&1.locator, &1.aggregate})

    assert requests(harness) ==
             before_recreation ++ [{:root_recreated, @call_ids, "mode recreated complete"}]

    assert_tool_history(id)
    assert {:ok, fresh_aggregate} = Journal.load(fresh_locator.namespace, fresh_locator.run_id)
    assert Enum.count(Map.values(fresh_aggregate.run.execution_intents), &(&1.type == :tool)) == 0
    assert_startups(observed(trace), final_locators)
  end

  test "an ordinary turn with no human mode choice records the default snapshot", %{
    tmp_dir: tmp_dir
  } do
    harness = setup_session(tmp_dir, [])
    id = harness.session.id
    trace = trace_startups(id)
    assert {:ok, meta} = Synapsis.Session.Store.get_meta(id)
    assert meta.config == %{"memory_context" => false, "preserved" => %{"value" => 283}}
    assert :ok = Worker.send_message(id, "mode default root")
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    {_worker, data, adapter} = runtime(id)
    assert data.execution_mode in [:graph, :query_loop]
    assert adapter.context.mode_provenance == @default
    assert {:ok, [locator]} = Journal.list_facts(id, :run_locator)
    assert locator.mode_provenance == @default
    assert locator.kind == :root
    assert_run_contexts(adapter, [locator])

    assert {:ok, %{entries: [%{locator: ^locator, availability: :present}]}} =
             RunInventory.load(id)

    assert requests(harness) == [{:root_default, [], "mode default complete"}]
    assert_startups(observed(trace), [locator])
  end

  defp setup_session(tmp_dir, tools) do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        install_provider?: false,
        session_config: %{"memory_context" => false, "preserved" => %{"value" => 283}}
      )

    {:ok, _} = Synapsis.AgentConfigs.update(harness.agent_config, %{tools: tools})

    on_exit(fn ->
      SessionHarness.cleanup!(harness)
      cleanup_runtime(harness.session.id)
    end)

    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    harness
  end

  defp select_mode(id, harness, mode) do
    await_selection_ready(id, System.monotonic_time(:millisecond) + 5_000)
    assert :ok = Worker.switch_mode(id, mode)
    assert {:ok, meta} = Synapsis.Session.Store.get_meta(id)

    assert meta.config == %{
             "memory_context" => false,
             "preserved" => %{"value" => 283},
             "user_mode" => mode
           }

    assert {:ok, reloaded} = Synapsis.Sessions.get(id)
    assert reloaded.config == meta.config
    assert :ok = Worker.switch_agent(id, harness.agent_name)
    assert Worker.snapshot(id).session.config == meta.config
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

  defp install_provider(harness) do
    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      users = for message <- request["messages"], message["role"] == "user", do: text(message)

      phase =
        cond do
          "mode recreated root" in users -> :root_recreated
          "mode execution root" in users -> :root_execution
          "mode child followup" in users -> :child_followup
          "mode child first" in users -> :child_first
          "mode plan root" in users -> :root_plan
          "mode default root" in users -> :root_default
        end

      ids =
        for message <- request["messages"],
            message["role"] == "tool" and message["tool_call_id"] in @call_ids,
            do: message["tool_call_id"]

      response =
        case {phase, ids} do
          {:root_plan, []} ->
            {"spawn_agent", "mode-spawn",
             %{
               "task_name" => "child",
               "message" => "mode child first",
               "fork_turns" => "none"
             }}

          {:root_plan, ["mode-spawn"]} ->
            {"wait_agent", "mode-wait-one", %{"timeout_ms" => 10_000}}

          {:root_plan, ["mode-spawn", "mode-wait-one"]} ->
            "mode plan complete"

          {:child_first, []} ->
            "mode child first complete"

          {:root_execution, ["mode-spawn", "mode-wait-one"]} ->
            {"followup_task", "mode-followup",
             %{
               "target" => "child",
               "message" => "mode child followup"
             }}

          {:root_execution, ["mode-spawn", "mode-wait-one", "mode-followup"]} ->
            {"wait_agent", "mode-wait-two", %{"timeout_ms" => 10_000}}

          {:root_execution, @call_ids} ->
            "mode execution complete"

          {:child_followup, []} ->
            "mode child followup complete"

          {:root_recreated, @call_ids} ->
            "mode recreated complete"

          {:root_default, []} ->
            "mode default complete"
        end

      Agent.update(harness.counter, fn state ->
        Map.update(
          state,
          :mode_requests,
          [{phase, ids, response}],
          &(&1 ++ [{phase, ids, response}])
        )
      end)

      respond(conn, response)
    end)
  end

  defp respond(conn, {name, id, arguments}),
    do:
      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.tool_call_chunk(name, id, arguments),
        DeterministicProvider.finish_chunk("tool_calls")
      ])

  defp respond(conn, answer),
    do:
      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.text_chunk(answer),
        DeterministicProvider.finish_chunk("stop")
      ])

  defp assert_tool_history(id) do
    parts = for message <- Synapsis.Sessions.get_messages(id), part <- message.parts, do: part

    assert for(%ToolUse{} = part <- parts, do: {part.tool, part.tool_use_id}) ==
             Enum.zip(~w(spawn_agent wait_agent followup_task wait_agent), @call_ids)

    assert for(%ToolResult{} = part <- parts, do: {part.tool_use_id, part.is_error}) ==
             Enum.map(@call_ids, &{&1, false})
  end

  defp assert_run_contexts(adapter, locators) do
    for locator <- locators do
      assert adapter.runs[locator.run_id].context.mode_provenance == locator.mode_provenance

      assert {:ok, ^locator} =
               Journal.get_fact(locator.session_id, :run_locator, identity(locator))
    end
  end

  defp load_aggregates(locators),
    do:
      Map.new(locators, fn locator ->
        assert {:ok, aggregate} = Journal.load(locator.namespace, locator.run_id)
        {locator, aggregate}
      end)

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_status, data} = :sys.get_state(worker)
    adapter = if is_pid(data.runtime_pid), do: :sys.get_state(data.runtime_pid)
    {worker, data, adapter}
  end

  defp stop_settled(id, worker, adapter, native) do
    monitored = for pid <- [worker, adapter, native], do: {pid, Process.monitor(pid)}
    assert :ok = DynamicSupervisor.stop_session(id)

    for {pid, ref} <- monitored do
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 10_000
      assert reason in [:normal, :shutdown]
    end
  end

  defp trace_startups(id) do
    for module <- [Journal, Conversation], do: Code.ensure_loaded!(module)
    trace = :trace.session_create(:mode_provenance283, self(), [])
    on_exit(fn -> :trace.session_destroy(trace) end)

    :trace.function(
      trace,
      {Journal, :put_fact, 4},
      [{[id, :run_locator, :_, :_], [], [{:return_trace}]}],
      [:local]
    )

    :trace.function(trace, {Conversation, :start_link, 1}, [{:_, [], []}], [:local])
    :trace.process(trace, :all, true, [:call, :monotonic_timestamp])
    trace
  end

  defp observed(trace) do
    barrier = :trace.delivered(trace, :all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    drain([])
  end

  defp drain(events) do
    receive do
      {:trace_ts, pid, :call, {Conversation, :start_link, [opts]}, at} ->
        drain([
          %{
            pid: pid,
            kind: :call,
            module: Conversation,
            function: :start_link,
            namespace: opts[:context].namespace,
            run_id: opts[:run_id],
            incarnation: opts[:incarnation],
            mode_provenance: opts[:host_context][:mode_provenance],
            at: at
          }
          | events
        ])

      {:trace_ts, pid, :call, {module, function, args}, at} ->
        drain([
          %{pid: pid, kind: :call, module: module, function: function, args: args, at: at}
          | events
        ])

      {:trace_ts, pid, :return_from, {module, function, _arity}, result, at} ->
        drain([
          %{pid: pid, kind: :return, module: module, function: function, result: result, at: at}
          | events
        ])
    after
      0 -> Enum.sort_by(events, & &1.at)
    end
  end

  defp assert_startups(events, locators) do
    for locator <- locators do
      [startup] =
        for %{kind: :call, module: Conversation, function: :start_link} = event <-
              events,
            event.run_id == locator.run_id and event.incarnation == locator.incarnation and
              event.namespace == locator.namespace,
            do: event

      assert startup.mode_provenance == locator.mode_provenance

      retained =
        Enum.find(events, fn event ->
          event.kind == :call and event.module == Journal and event.function == :put_fact and
            event.args == [locator.session_id, :run_locator, identity(locator), locator]
        end)

      assert is_map(retained)

      acknowledged =
        Enum.find(events, fn event ->
          event.kind == :return and event.module == Journal and event.function == :put_fact and
            event.pid == retained.pid and event.at > retained.at
        end)

      assert acknowledged.result == :ok
      assert acknowledged.at < startup.at
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

  defp identity(locator),
    do:
      Base.url_encode64(
        :erlang.term_to_binary({locator.namespace, locator.run_id, locator.incarnation}),
        padding: false
      )

  defp segment(value), do: value |> to_string() |> Base.url_encode64(padding: false)
  defp requests(harness), do: Agent.get(harness.counter, & &1.mode_requests)
  defp text(%{"content" => content}) when is_binary(content), do: content

  defp text(%{"content" => parts}) when is_list(parts),
    do: Enum.map_join(parts, &(&1["text"] || ""))

  defp text(_), do: ""
end
