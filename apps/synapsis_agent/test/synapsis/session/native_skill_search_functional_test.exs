defmodule Synapsis.Session.NativeSkillSearchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Codex.Session, as: NativeSession
  alias Synapsis.Agent.Runtime.Store, as: NativeStore
  alias Synapsis.Agent.TestSupport.{AbortableHTTP, DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.Skills, as: NativeSkills
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @search "synapsis::skills_search"
  @read "synapsis::skills_read"

  test "assigned skill relevance reaches real native search/read, provider history and settled owner replay",
       %{tmp_dir: root} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    [weak, relevant] = assigned_skills(harness)
    selected = Synapsis.AgentConfigs.get(harness.agent_config.id)
    assert {:ok, _} = Synapsis.AgentConfigs.update(selected, %{tools: [@search, @read]})
    locator = "synapsis://skills/#{relevant.id}"

    calls = [
      {"ranked-search", @search, %{"query" => "  changes repository  "}},
      {"ranked-read", @read, %{"locator" => locator}}
    ]

    trace = trace_effects()
    install_provider(harness, calls)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok =
             Worker.send_message(
               harness.session.id,
               "Find the repository changes skill and read it"
             )

    first_request = request(0)
    assert_receive {:skill_runtime, started, handler}, 5_000
    initial_root = started.root
    assert is_pid(initial_root)
    root_monitor = Process.monitor(initial_root)
    send(handler, :release_skill_response)
    requests = [first_request | for(index <- 1..2, do: request(index))]
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_receive {:skill_descriptors, descriptors}, 5_000
    assert Enum.sort(Map.keys(descriptors)) == Enum.sort([@search, @read])

    for name <- [@search, @read] do
      assert descriptors[name].backend == NativeSkills
      assert descriptors[name].tool_revision == 1
      assert descriptors[name].backend_context.snapshot.agent_id == harness.agent_config.id
    end

    assert Enum.map(hd(requests)["tools"], &ToolName.decode(&1["function"]["name"]))
           |> Enum.sort() == Enum.sort([@search, @read])

    original = parts(harness.session.id)
    uses = Enum.filter(original, &match?(%ToolUse{}, &1))
    results = Enum.filter(original, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input}) == calls
    assert Enum.map(results, & &1.tool_use_id) == ["ranked-search", "ranked-read"]
    assert Enum.all?(results, &(&1.is_error == false))

    assert Enum.map(Enum.filter(original, &tool_part?/1), fn
             %ToolUse{tool_use_id: id} -> {:use, id}
             %ToolResult{tool_use_id: id} -> {:result, id}
           end) == [
             {:use, "ranked-search"},
             {:result, "ranked-search"},
             {:use, "ranked-read"},
             {:result, "ranked-read"}
           ]

    [search, read] = results

    assert search.projection["result"]["structured"] == %{
             "results" => Enum.map([relevant, weak], &public_metadata/1),
             "truncated" => false
           }

    assert search.content ==
             "workflow: Review repository changes\nSource: #{locator}\n" <>
               "alpha: Review repository reference\nSource: synapsis://skills/#{weak.id}"

    read_page = read.projection["result"]["structured"]

    assert read_page ==
             Map.merge(public_metadata(relevant), %{
               "content" => relevant.system_prompt_fragment,
               "citation" => locator,
               "document_digest" =>
                 "sha256:" <>
                   Base.encode16(:crypto.hash(:sha256, relevant.system_prompt_fragment),
                     case: :lower
                   )
             })

    assert read.content == relevant.system_prompt_fragment <> "\nSource: " <> locator

    for {req, count} <- Enum.with_index(requests) do
      assert_wire(req, Enum.take(calls, count), Enum.take(results, count))
    end

    for part <- uses ++ results do
      assert {:ok, dumped} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dumped |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert_durable(harness.session.id, uses, results)
    first_effects = observed_effects(trace, harness.agent_config.id)

    assert Enum.map(first_effects, &{&1.tool_name, &1.arguments}) ==
             Enum.map(calls, &{elem(&1, 1), elem(&1, 2)})

    assert Enum.map(first_effects, & &1.tool_call_id) == Enum.map(calls, &elem(&1, 0))

    {old_worker, old_adapter, native} = runtime(harness.session.id)
    assert_receive {:DOWN, ^root_monitor, :process, ^initial_root, :shutdown}, 5_000
    assert native.root == nil
    assert native.busy == false
    assert native.session == started.session
    assert native.run_id == started.run_id
    assert %{phase: :idle} = NativeSession.status(native.session)
    assert {:ok, aggregate} = NativeStore.load(started.store, started.run_id)
    assert aggregate.run.state == :completed

    tool_intents =
      aggregate.run.execution_intents
      |> Map.values()
      |> Enum.filter(&(&1.type == :tool))

    assert Enum.map(tool_intents, fn intent ->
             {intent.operation.tool_call_id, intent.operation.tool_name,
              intent.operation.arguments}
           end)
           |> Enum.sort() == Enum.sort(calls)

    monitored =
      for pid <- [old_worker, old_adapter, native.session], do: {pid, Process.monitor(pid)}

    assert :ok = DynamicSupervisor.stop_session(harness.session.id)

    for {pid, ref} <- monitored do
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 10_000
      assert reason in [:normal, :shutdown]
    end

    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute old_worker == new_worker
    assert :ok = Worker.send_message(harness.session.id, "Recall the selected skill instructions")
    replay = request(3)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_wire(replay, calls, results)
    assert observed_effects(trace, harness.agent_config.id) == []

    assert parts(harness.session.id) ==
             original ++
               [
                 %Text{content: "Recall the selected skill instructions"},
                 %Text{content: "Selected skill read"}
               ]

    assert_durable(harness.session.id, uses, results)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 4
    assert Synapsis.Skills.get(relevant.id) == relevant
    assert Synapsis.Skills.get(weak.id) == weak
  end

  defp assigned_skills(harness) do
    records =
      for {name, description, content} <- [
            {"alpha", "Review repository reference", "Reference instructions"},
            {"workflow", "Review repository changes", "Review the selected change carefully."}
          ] do
        {:ok, record} =
          Synapsis.Skills.create(%{
            name: name,
            description: description,
            scope: "global",
            system_prompt_fragment: content
          })

        on_exit(fn -> Synapsis.Config.Store.delete(:skill, record.id) end)
        record
      end

    assert {:ok, _} =
             Synapsis.Skills.assign_skills(harness.agent_config, Enum.map(records, & &1.id))

    records
  end

  defp public_metadata(record) do
    %{
      "record_id" => record.id,
      "source_authority" => "synapsis",
      "source_id" => "synapsis",
      "skill_id" => record.id,
      "revision" => nil,
      "artifact_digest" => nil,
      "name" => record.name,
      "description" => record.description,
      "locator" => "synapsis://skills/#{record.id}"
    }
  end

  defp install_provider(harness, calls) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [req]}}
        end)

      send(owner, {:skill_request, index, req})

      conn =
        if index == 0 do
          {_, _, native} = runtime(harness.session.id)
          send(owner, {:skill_descriptors, :sys.get_state(native.root).catalog.registry.tools})

          send(
            owner,
            {:skill_runtime, Map.take(native, [:root, :store, :run_id, :session]), self()}
          )

          {:released, conn} = AbortableHTTP.await(conn, :release_skill_response, 5_000, owner)
          conn
        else
          conn
        end

      completed = Enum.count(req["messages"], &(&1["role"] == "tool"))

      chunks =
        case Enum.at(calls, completed) do
          {id, name, args} ->
            [
              DeterministicProvider.tool_call_chunk(ToolName.encode(name), id, args),
              DeterministicProvider.finish_chunk("tool_calls")
            ]

          nil ->
            [
              DeterministicProvider.text_chunk("Selected skill read"),
              DeterministicProvider.finish_chunk("stop")
            ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)
  end

  defp request(index) do
    assert_receive {:skill_request, ^index, request}, 15_000
    request
  end

  defp parts(id),
    do: for(message <- Synapsis.Message.list_by_session(id), part <- message.parts, do: part)

  defp tool_part?(%ToolUse{}), do: true
  defp tool_part?(%ToolResult{}), do: true
  defp tool_part?(_), do: false

  defp assert_wire(req, calls, results) do
    uses = for message <- req["messages"], call <- List.wrap(message["tool_calls"]), do: call

    assert Enum.map(uses, fn call ->
             {call["id"], ToolName.decode(call["function"]["name"]),
              Jason.decode!(call["function"]["arguments"])}
           end) == calls

    actual = for message <- req["messages"], message["role"] == "tool", do: message

    assert actual ==
             Enum.map(
               results,
               &%{"role" => "tool", "tool_call_id" => &1.tool_use_id, "content" => &1.content}
             )
  end

  defp assert_durable(id, uses, results) do
    assert {:ok, turns} = Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert(Store.get_turn(id, index) == {:ok, turn})

    raw = for turn <- turns, part <- turn.parts, do: part

    assert Enum.map(Enum.filter(raw, &(&1[:type] == "tool_use")), &{&1.id, &1.name, &1.input}) ==
             Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input})

    assert Enum.map(
             Enum.filter(raw, &(&1[:type] == "tool_result")),
             &{&1.tool_use_id, &1.content, &1.projection}
           ) ==
             Enum.map(results, &{&1.tool_use_id, &1.content, &1.projection})
  end

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker)
    {worker, data.runtime_pid, :sys.get_state(data.runtime_pid)}
  end

  # An OTP trace session observes the actual native backend across both owners.
  # It neither replaces the backend nor changes the shared tracing configuration.
  defp trace_effects do
    Code.ensure_loaded!(NativeSkills)
    trace = :trace.session_create(:skill_search289, self(), [])
    on_exit(fn -> :trace.session_destroy(trace) end)
    :trace.function(trace, {NativeSkills, :execute, 1}, [{:_, [], []}], [:local])
    :trace.process(trace, :all, true, [:call])
    trace
  end

  defp observed_effects(trace, agent_id) do
    barrier = :trace.delivered(trace, :all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    drain_effects(agent_id, [])
  end

  defp drain_effects(agent_id, calls) do
    receive do
      {:trace, _, :call,
       {NativeSkills, :execute,
        [%{backend_context: %{snapshot: %{agent_id: ^agent_id}}} = operation]}} ->
        drain_effects(agent_id, [operation | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end
end
