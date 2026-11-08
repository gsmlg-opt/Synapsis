defmodule Synapsis.Session.NativeSkillBodySearchFunctionalTest do
  use ExUnit.Case, async: false

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

  test "assigned inline and local bodies reach repeated native search, whole read and settled owner replay",
       %{tmp_dir: root} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    [inline, local, local_content] = assigned_skills(harness, root)
    selected = Synapsis.AgentConfigs.get(harness.agent_config.id)
    assert {:ok, _} = Synapsis.AgentConfigs.update(selected, %{tools: [@search, @read]})
    locator = "local://project/playbook"

    calls = [
      {"body-search", @search, %{"query" => "  canary  "}},
      {"local-search", @search, %{"query" => "volcanic"}},
      {"body-repeat", @search, %{"query" => "canary"}},
      {"whole-read", @read, %{"locator" => locator}}
    ]

    trace = trace_effects()
    install_provider(harness, calls)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok =
             Worker.send_message(
               harness.session.id,
               "Find canary and volcanic instructions, repeat the first search, then read the local skill"
             )

    first_request = request(0)
    assert_receive {:skill_runtime, started, handler}, 5_000
    initial_root = started.root
    assert is_pid(initial_root)
    root_monitor = Process.monitor(initial_root)
    send(handler, :release_skill_response)
    requests = [first_request | for(index <- 1..4, do: request(index))]
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
    assert Enum.map(results, & &1.tool_use_id) == Enum.map(calls, &elem(&1, 0))
    assert Enum.all?(results, &(&1.is_error == false))

    assert Enum.map(Enum.filter(original, &tool_part?/1), fn
             %ToolUse{tool_use_id: id} -> {:use, id}
             %ToolResult{tool_use_id: id} -> {:result, id}
           end) == Enum.flat_map(calls, fn {id, _, _} -> [{:use, id}, {:result, id}] end)

    [search, local_search, repeated, read] = results

    assert search.projection["result"]["structured"] == %{
             "results" => Enum.map([inline, local], &public_metadata/1),
             "truncated" => false
           }

    assert local_search.projection["result"]["structured"] == %{
             "results" => [public_metadata(local)],
             "truncated" => false
           }

    assert repeated.projection["result"]["structured"] ==
             search.projection["result"]["structured"]

    assert search.content ==
             "guide: Operations\nSource: synapsis://skills/#{inline.id}\n" <>
               "playbook: Local operations\nSource: #{locator}"

    assert local_search.content == "playbook: Local operations\nSource: #{locator}"
    assert repeated.content == search.content

    read_page = read.projection["result"]["structured"]

    assert read_page ==
             Map.merge(public_metadata(local), %{
               "content" => local_content,
               "citation" => locator,
               "document_digest" => digest(local_content)
             })

    assert read.content == local_content <> "\nSource: " <> locator

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

    body_reads = observed_bodies(trace, harness.agent_config.id)

    assert Enum.map(body_reads, fn {binding, bytes} -> {binding.record_id, bytes} end)
           |> Enum.sort() == Enum.sort([{inline.id, 16_384}, {local.id, 16_384}])

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
    replay = request(5)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_wire(replay, calls, results)
    assert observed_effects(trace, harness.agent_config.id) == []
    assert observed_bodies(trace, harness.agent_config.id) == []

    assert parts(harness.session.id) ==
             original ++
               [
                 %Text{content: "Recall the selected skill instructions"},
                 %Text{content: "Selected skill read"}
               ]

    assert_durable(harness.session.id, uses, results)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 6
    assert Synapsis.Skills.get(inline.id) == inline
    assert Synapsis.Skills.get(local.id) == local
    assert File.read!(Path.join([root, "playbook", "SKILL.md"])) == local_content
  end

  test "native discovery publishes the paired reader before cached body search with opaque coverage",
       %{tmp_dir: root} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    source_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Synapsis.Config.Store.put(:backplane, %{
               "id" => source_id,
               "enabled" => true,
               "endpoint" => "http://127.0.0.1:9"
             })

    on_exit(fn -> Synapsis.Config.Store.delete(:backplane, source_id) end)
    content = "Use raven deployment. Preserve the complete rollback procedure."

    attributes = [
      %{name: "guide", description: "Operations", system_prompt_fragment: content},
      %{
        name: "remote",
        description: "External documentation",
        config_overrides: %{
          "source" => "backplane",
          "managed_by" => "backplane",
          "backplane_source_id" => source_id,
          "external_id" => "reference",
          "external_revision" => "rev-7",
          "artifact_digest" => "sha256:artifact"
        }
      }
    ]

    [inline, opaque] =
      records =
      for attrs <- attributes do
        assert {:ok, record} = Synapsis.Skills.create(Map.put(attrs, :scope, "global"))
        on_exit(fn -> Synapsis.Config.Store.delete(:skill, record.id) end)
        record
      end

    assert {:ok, _} =
             Synapsis.Skills.assign_skills(harness.agent_config, Enum.map(records, & &1.id))

    selected = Synapsis.AgentConfigs.get(harness.agent_config.id)

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(selected, %{
               tools: [@search, @read],
               config: Map.put(selected.config, "deferred_tool_names", [@read])
             })

    assert Synapsis.AgentConfigs.get(selected.id).config["deferred_tool_names"] == [@read]
    locator = "synapsis://skills/#{inline.id}"

    calls = [
      {"publish-reader", "tool_search", %{"query" => @read, "limit" => 1}},
      {"published-body", @search, %{"query" => "raven"}},
      {"published-repeat", @search, %{"query" => "raven"}},
      {"published-read", @read, %{"locator" => locator}}
    ]

    trace = trace_effects()
    :trace.function(trace, {Synapsis.SkillReader, :load, 2}, [{:_, [], []}], [:local])
    Code.ensure_loaded!(Synapsis.Backplane.SkillLoader)
    :trace.function(trace, {Synapsis.Backplane.SkillLoader, :load, 2}, [{:_, [], []}], [:local])
    install_deferred_provider(harness, calls)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok =
             Worker.send_message(
               harness.session.id,
               "Publish the reader, find raven twice and read it"
             )

    first = request(0)
    assert_receive {:skill_runtime, started, handler}, 5_000
    assert_receive {:issued_skill_reader, issued_reader}, 5_000
    initial_root = started.root
    root_monitor = Process.monitor(initial_root)

    assert Enum.map(first["tools"], &ToolName.decode(&1["function"]["name"]))
           |> Enum.sort() == Enum.sort([@search, "tool_search"])

    send(handler, :release_skill_response)
    requests = [first | for(index <- 1..4, do: request(index))]
    assert_receive {:published_skill_catalog, published}, 5_000
    assert published.revision == 2
    assert published.registry.tools[@read] === issued_reader
    assert issued_reader.backend == NativeSkills
    assert issued_reader.backend_context.snapshot.agent_id == selected.id
    assert issued_reader.backend_context.catalog_revision == 1

    for request <- tl(requests) do
      assert Enum.map(request["tools"], &ToolName.decode(&1["function"]["name"]))
             |> Enum.sort() == Enum.sort([@search, @read, "tool_search"])
    end

    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    original = parts(harness.session.id)
    uses = Enum.filter(original, &match?(%ToolUse{}, &1))
    results = Enum.filter(original, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input}) == calls
    assert Enum.map(results, & &1.tool_use_id) == Enum.map(calls, &elem(&1, 0))
    assert Enum.all?(results, &(&1.is_error == false))

    assert Enum.map(Enum.filter(original, &tool_part?/1), fn
             %ToolUse{tool_use_id: id} -> {:use, id}
             %ToolResult{tool_use_id: id} -> {:result, id}
           end) == Enum.flat_map(calls, fn {id, _, _} -> [{:use, id}, {:result, id}] end)

    [discovery, search, repeated, read] = results
    assert discovery.content =~ "staged"
    coverage = %{"bodyIndexed" => 1, "metadataOnly" => 1, "truncatedBodies" => 0}

    expected = %{
      "results" => [public_metadata(inline)],
      "truncated" => false,
      "coverage" => coverage
    }

    assert search.projection["result"]["structured"] == expected
    assert repeated.projection["result"]["structured"] == expected

    expected_text =
      "guide: Operations\nSource: #{locator}\n" <>
        "Instruction search coverage: 1 body indexed, 1 metadata only, 0 truncated bodies."

    assert search.content == expected_text
    assert repeated.content == expected_text

    assert read.projection["result"]["structured"] ==
             Map.merge(public_metadata(inline), %{
               "content" => content,
               "citation" => locator,
               "document_digest" => digest(content)
             })

    assert read.content == content <> "\nSource: " <> locator

    for {request, count} <- Enum.with_index(requests) do
      assert_wire(request, Enum.take(calls, count), Enum.take(results, count))
    end

    for part <- uses ++ results do
      assert {:ok, dumped} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dumped |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert_durable(harness.session.id, uses, results)
    effects = observed_effects(trace, selected.id)

    assert Enum.map(effects, &{&1.tool_name, &1.arguments}) ==
             Enum.map(tl(calls), &{elem(&1, 1), elem(&1, 2)})

    assert Enum.all?(effects, &(&1.catalog_revision == 2))
    body_reads = observed_bodies(trace, selected.id)

    assert Enum.map(body_reads, fn {binding, bytes} -> {binding.record_id, bytes} end)
           |> Enum.sort() == Enum.sort([{inline.id, 16_384}, {opaque.id, 16_384}])

    assert Enum.map(observed_whole_loads(trace, selected.id), fn {module, entry} ->
             {module, entry.authority, entry.skill_id}
           end) == [{Synapsis.SkillReader, :synapsis, inline.id}]

    {old_worker, old_adapter, native} = runtime(harness.session.id)
    assert_receive {:DOWN, ^root_monitor, :process, ^initial_root, :shutdown}, 5_000
    assert native.root == nil
    assert native.busy == false
    assert %{phase: :idle} = NativeSession.status(native.session)
    assert {:ok, aggregate} = NativeStore.load(started.store, started.run_id)
    assert aggregate.run.state == :completed

    operations =
      aggregate.run.execution_intents
      |> Map.values()
      |> Enum.filter(&(&1.type == :tool))
      |> Enum.map(& &1.operation)

    assert Enum.map(operations, &{&1.tool_call_id, &1.tool_name, &1.arguments})
           |> Enum.sort() == Enum.sort(calls)

    assert Enum.find(operations, &(&1.tool_call_id == "publish-reader")).catalog_revision == 1

    assert Enum.all?(
             Enum.reject(operations, &(&1.tool_name == "tool_search")),
             &(&1.catalog_revision == 2)
           )

    monitored =
      for pid <- [old_worker, old_adapter, native.session], do: {pid, Process.monitor(pid)}

    assert :ok = DynamicSupervisor.stop_session(harness.session.id)

    for {pid, ref} <- monitored do
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 10_000
      assert reason in [:normal, :shutdown]
    end

    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 5
    assert Synapsis.Skills.get(inline.id) == inline
    assert Synapsis.Skills.get(opaque.id) == opaque
  end

  defp assigned_skills(harness, root) do
    content =
      "---\nname: playbook\ndescription: Local operations\n---\n" <>
        "Canary deployment. Volcanic rollout preserves a complete recovery procedure.\n"

    path = Path.join([root, "playbook", "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)

    attrs = [
      %{
        name: "guide",
        description: "Operations",
        system_prompt_fragment: "Canary deployment. Preserve rollback procedure."
      },
      %{
        name: "playbook",
        description: "Local operations",
        config_overrides: %{
          "source" => "local",
          "source_id" => "project",
          "skill_id" => "playbook",
          "root" => root,
          "artifact_digest" => digest(content)
        }
      }
    ]

    records =
      for attributes <- attrs do
        assert {:ok, record} = Synapsis.Skills.create(Map.put(attributes, :scope, "global"))
        on_exit(fn -> Synapsis.Config.Store.delete(:skill, record.id) end)
        record
      end

    assert {:ok, _} =
             Synapsis.Skills.assign_skills(harness.agent_config, Enum.map(records, & &1.id))

    records ++ [content]
  end

  defp public_metadata(record) do
    local? = record.config_overrides["source"] == "local"

    %{
      "record_id" => record.id,
      "source_authority" => if(local?, do: "local", else: "synapsis"),
      "source_id" => if(local?, do: "project", else: "synapsis"),
      "skill_id" => if(local?, do: "playbook", else: record.id),
      "revision" => nil,
      "artifact_digest" => if(local?, do: record.config_overrides["artifact_digest"], else: nil),
      "name" => record.name,
      "description" => record.description,
      "locator" =>
        if(local?, do: "local://project/playbook", else: "synapsis://skills/#{record.id}")
    }
  end

  defp digest(content),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)

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
    trace = :trace.session_create(:skill_body_search290, self(), [])
    on_exit(fn -> :trace.session_destroy(trace) end)
    :trace.function(trace, {NativeSkills, :execute, 1}, [{:_, [], []}], [:local])
    Code.ensure_loaded!(Synapsis.SkillReader)
    :trace.function(trace, {Synapsis.SkillReader, :search_body, 4}, [{:_, [], []}], [:local])
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

  defp observed_bodies(trace, agent_id) do
    barrier = :trace.delivered(trace, :all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    drain_bodies(agent_id, [])
  end

  defp drain_bodies(agent_id, calls) do
    receive do
      {:trace, _, :call,
       {Synapsis.SkillReader, :search_body, [%{agent_id: ^agent_id}, binding, bytes, _opts]}} ->
        drain_bodies(agent_id, [{binding, bytes} | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end

  defp install_deferred_provider(harness, calls) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:skill_request, index, request})

      conn =
        case index do
          0 ->
            {_, _, native} = runtime(harness.session.id)
            entry = native.tool_contexts[{native.run_id, 1}]
            send(owner, {:issued_skill_reader, entry.snapshot.issued_descriptors[@read]})

            send(
              owner,
              {:skill_runtime, Map.take(native, [:root, :store, :run_id, :session]), self()}
            )

            {:released, conn} = AbortableHTTP.await(conn, :release_skill_response, 5_000, owner)
            conn

          1 ->
            {_, _, native} = runtime(harness.session.id)
            send(owner, {:published_skill_catalog, :sys.get_state(native.root).catalog})
            conn

          _ ->
            conn
        end

      completed = Enum.count(request["messages"], &(&1["role"] == "tool"))

      chunks =
        case Enum.at(calls, completed) do
          {id, name, arguments} ->
            [
              DeterministicProvider.tool_call_chunk(ToolName.encode(name), id, arguments),
              DeterministicProvider.finish_chunk("tool_calls")
            ]

          nil ->
            [
              DeterministicProvider.text_chunk("Published skill read"),
              DeterministicProvider.finish_chunk("stop")
            ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)
  end

  defp observed_whole_loads(trace, agent_id) do
    barrier = :trace.delivered(trace, :all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    drain_whole_loads(agent_id, [])
  end

  defp drain_whole_loads(agent_id, calls) do
    receive do
      {:trace, _, :call, {module, :load, [entry, %{agent_id: ^agent_id}]}}
      when module in [Synapsis.SkillReader, Synapsis.Backplane.SkillLoader] ->
        drain_whole_loads(agent_id, [{module, entry} | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end
end
