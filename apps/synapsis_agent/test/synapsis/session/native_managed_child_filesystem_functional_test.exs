defmodule Synapsis.Session.NativeManagedChildFilesystemFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Codex.Backend
  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Agent.TestSupport.{AbortableHTTP, DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.Filesystem
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{Store, Worker}

  @moduletag :tmp_dir
  @filesystem ~w(synapsis::read synapsis::write synapsis::edit synapsis::ls)
  @collaboration ~w(spawn_agent wait_agent followup_task)
  @names @filesystem ++ @collaboration
  @node "/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node"
  @read_pages Path.expand("../../fixtures/openclaw/488631c/read-pages.json", __DIR__)
  @child_name "/root/filesystem_child"
  @initial "managed filesystem initial task marker"
  @followup "managed filesystem followup task marker"
  @first_final "managed filesystem initial complete: BETA"
  @second_final "managed filesystem followup complete: BETA"
  @parent_final "managed filesystem parent complete"
  @lines %{"path" => "files/lines.txt", "offset" => 2, "limit" => 1}
  @child_calls [
    {"child-read", "synapsis::read", @lines},
    {"child-write", "synapsis::write", %{"path" => "files/child.txt", "content" => "alpha\n"}},
    {"child-edit", "synapsis::edit",
     %{"path" => "files/child.txt", "edits" => [%{"oldText" => "alpha", "newText" => "BETA"}]}},
    {"child-ls", "synapsis::ls", %{"path" => "files"}}
  ]
  @fresh_read {"child-followup-read", "synapsis::read", %{"path" => "files/child.txt"}}
  @root_calls [
    {"root-read", "synapsis::read", @lines},
    {"spawn-child", "spawn_agent",
     %{"task_name" => "filesystem_child", "message" => @initial, "fork_turns" => "none"}},
    {"wait-first", "wait_agent", %{"timeout_ms" => 10_000}},
    {"follow-child", "followup_task", %{"target" => @child_name, "message" => @followup}},
    {"wait-second", "wait_agent", %{"timeout_ms" => 10_000}}
  ]

  setup do
    previous = Application.fetch_env(:synapsis_agent, :filesystem_node)
    Application.put_env(:synapsis_agent, :filesystem_node, @node)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:synapsis_agent, :filesystem_node, value)
        :error -> Application.delete_env(:synapsis_agent, :filesystem_node)
      end
    end)

    :ok
  end

  # Only ordinary local success is qualified. HTTP gates expose production-built
  # scopes before normal terminal cleanup; they do not replace Policy or Store.
  test "managed filesystem children and followup own fresh scopes and durable native calls", %{
    tmp_dir: root
  } do
    File.mkdir_p!(Path.join(root, "files"))
    File.write!(Path.join(root, "files/lines.txt"), "alpha\nbeta\ngamma\n")
    harness = harness(root)
    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok =
             Worker.send_message(
               harness.session.id,
               "Read then delegate canonical filesystem work"
             )

    {first_root, root_http} = request(:root)
    runtime = runtime(harness.session.id)
    root_scope = scope(runtime.root, runtime.binding)
    assert_catalog(first_root, root_scope, harness, root)
    assert_fresh(runtime.adapter, root_scope)
    respond(root_http, Enum.at(@root_calls, 0))

    {root_after_read, root_http} = request(:root)
    root_journal = journal(runtime, root_scope.run_id, [Enum.at(@root_calls, 0)])
    assert_filesystem_history(root_after_read, root_journal, [Enum.at(@root_calls, 0)])
    assert_records(runtime.adapter, root_scope, root_journal, [Enum.at(@root_calls, 0)], root)
    respond(root_http, Enum.at(@root_calls, 1))

    {child_first, child_http} = request(:child)
    child = child(runtime.manager)
    child_binding = Keyword.fetch!(child.opts, :session_binding)
    child_scope = scope(child.pid, child_binding)
    assert child.incarnation == 1
    assert child.run_id == child_scope.run_id
    assert child.request.options["fork_turns"] == "none"
    assert_catalog(child_first, child_scope, harness, root)
    assert_distinct_scope(root_scope, child_scope)
    assert_fresh(runtime.adapter, child_scope)
    owners = :sys.get_state(runtime.adapter).child_sessions
    assert owners[child.id].binding == child_binding
    assert owners[child.id].session != runtime.session
    assert user_texts(child_first) == [@initial]

    child_last =
      Enum.reduce(@child_calls, {child_first, child_http}, fn call, {_wire, http} ->
        respond(http, call)
        {wire, next_http} = request(:child)
        {wire, next_http}
      end)

    {child_after_tools, child_http} = child_last
    child_journal = journal(runtime, child_scope.run_id, @child_calls)
    assert_filesystem_history(child_after_tools, child_journal, @child_calls)
    assert_records(runtime.adapter, child_scope, child_journal, @child_calls, root)
    assert_records(runtime.adapter, root_scope, root_journal, [Enum.at(@root_calls, 0)], root)
    assert File.read!(Path.join(root, "files/lines.txt")) == "alpha\nbeta\ngamma\n"
    assert File.read!(Path.join(root, "files/child.txt")) == "BETA\n"
    respond(child_http, {:answer, @first_final})
    completed_child(runtime.manager, 1, @first_final)

    {_root_after_spawn, root_http} = request(:root)
    respond(root_http, Enum.at(@root_calls, 2))
    {root_after_wait, root_http} = request(:root)
    assert inspect(root_after_wait["messages"]) =~ @first_final
    respond(root_http, Enum.at(@root_calls, 3))

    {followup_first, followup_http} = request(:followup)
    replacement = child(runtime.manager)
    followup_binding = Keyword.fetch!(replacement.opts, :session_binding)
    followup_scope = scope(replacement.pid, followup_binding)
    assert replacement.id == child.id
    assert replacement.name == @child_name
    assert replacement.incarnation == 2
    assert replacement.run_id == followup_scope.run_id
    assert_catalog(followup_first, followup_scope, harness, root)
    assert_distinct_scope(child_scope, followup_scope)
    assert_distinct_scope(root_scope, followup_scope)
    assert_fresh(runtime.adapter, followup_scope)
    assert :sys.get_state(runtime.adapter).child_sessions[child.id].binding == followup_binding
    assert user_texts(followup_first) == [@initial, @followup]
    assert inspect(followup_first["messages"]) =~ @first_final
    assert_filesystem_history(followup_first, child_journal, @child_calls)
    respond(followup_http, @fresh_read)

    {followup_after_read, followup_http} = request(:followup)
    followup_journal = journal(runtime, followup_scope.run_id, [@fresh_read])
    assert_filesystem_history(followup_after_read, child_journal, @child_calls)
    assert_filesystem_history(followup_after_read, followup_journal, [@fresh_read])
    assert_records(runtime.adapter, followup_scope, followup_journal, [@fresh_read], root)
    assert File.read!(Path.join(root, "files/child.txt")) == "BETA\n"
    respond(followup_http, {:answer, @second_final})
    completed_child(runtime.manager, 2, @second_final)

    {_root_after_followup, root_http} = request(:root)
    respond(root_http, Enum.at(@root_calls, 4))
    {root_after_second_wait, root_http} = request(:root)
    assert inspect(root_after_second_wait["messages"]) =~ @first_final
    assert inspect(root_after_second_wait["messages"]) =~ @second_final
    respond(root_http, {:answer, @parent_final})
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    await(fn -> Worker.get_status(harness.session.id) == :waiting end)

    assert [%{name: @child_name, incarnation: 2, status: :completed}] =
             Worker.snapshot(harness.session.id).subagents.agents

    root_journal = journal(runtime, root_scope.run_id, @root_calls)
    child_journal = journal(runtime, child_scope.run_id, @child_calls)
    followup_journal = journal(runtime, followup_scope.run_id, [@fresh_read])
    assert_wire_calls(root_after_second_wait, @root_calls)
    assert_filesystem_history(root_after_second_wait, root_journal, [Enum.at(@root_calls, 0)])

    for {aggregate, marker} <- [
          {root_journal, @parent_final},
          {child_journal, @first_final},
          {followup_journal, @second_final}
        ] do
      assert inspect(aggregate.run.context.conversation.messages) =~ marker
    end

    assert inspect(root_journal.run.context.conversation.messages) =~ @first_final
    assert inspect(root_journal.run.context.conversation.messages) =~ @second_final
    assert inspect(followup_journal.run.context.conversation.messages) =~ @first_final
    assert_native_history(followup_journal, @child_calls ++ [@fresh_read])

    assert {:ok, intents} =
             Synapsis.Runtime.Store.list_facts(harness.session.id, :admission_intent)

    assert {:ok, receipts} =
             Synapsis.Runtime.Store.list_facts(harness.session.id, :admission_receipt)

    assert length(intents) == 2
    assert Enum.count(receipts, &(&1.status == :created and &1.process_started)) == 2
    assert_parent_parts(harness.session.id, root_journal)
  end

  defp harness(root) do
    assert {:ok, counter} = Agent.start_link(fn -> %{provider_requests: []} end)
    provider = DeterministicProvider.start!(install?: false)
    name = "managed-filesystem-#{System.unique_integer([:positive, :monotonic])}"

    assert {:ok, agent_config} =
             Synapsis.AgentConfigs.create(%{
               name: name,
               provider: provider.name,
               model: "gpt-4o",
               tools: @names,
               tool_contract_version: 1,
               permission_mode: "yolo",
               config: %{"workspace_path" => root}
             })

    assert {:ok, session} =
             Synapsis.Sessions.create(name, %{
               agent: name,
               provider: provider.name,
               model: "gpt-4o",
               config: %{"subagents" => true, "memory_context" => false}
             })

    harness = %{
      session: session,
      agent_config: agent_config,
      agent_name: name,
      provider: provider,
      counter: counter,
      tool_name: nil,
      tmp_dir: root
    }

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    permission = Store.get_value(session.id, "permission")

    # Ordinary all-allow configuration is a prerequisite, not permission coverage.
    assert :ok =
             Store.put_value(session.id, "permission", %{
               permission
               | tool_contract_version: 1,
                 allow_read: :allow,
                 allow_write: :allow,
                 allow_execute: :allow,
                 allow_destructive: :allow
             })

    harness
  end

  defp install_provider(harness) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      wire = Jason.decode!(body)
      Agent.update(harness.counter, &%{&1 | provider_requests: &1.provider_requests ++ [wire]})
      users = user_texts(wire)

      scope =
        cond do
          @followup in users -> :followup
          @initial in users -> :child
          true -> :root
        end

      send(owner, {:managed_filesystem_request, scope, wire, self()})
      {:released, conn} = AbortableHTTP.await(conn, :release_filesystem_response, 30_000, owner)

      receive do
        {:filesystem_response, {:answer, text}} ->
          DeterministicProvider.send_sse(conn, [
            DeterministicProvider.text_chunk(text),
            DeterministicProvider.finish_chunk("stop")
          ])

        {:filesystem_response, {id, name, arguments}} ->
          DeterministicProvider.send_sse(conn, [
            DeterministicProvider.tool_call_chunk(ToolName.encode(name), id, arguments),
            DeterministicProvider.finish_chunk("tool_calls")
          ])
      after
        5_000 -> raise "ordinary filesystem provider response was not supplied"
      end
    end)
  end

  defp request(scope) do
    assert_receive {:managed_filesystem_request, ^scope, wire, http}, 15_000
    {wire, http}
  end

  defp respond(http, response) do
    send(http, {:filesystem_response, response})
    send(http, :release_filesystem_response)
  end

  defp user_texts(wire) do
    for %{"role" => "user", "content" => content} <- wire["messages"], do: wire_text(content)
  end

  defp wire_text(content) when is_binary(content), do: content
  defp wire_text(parts) when is_list(parts), do: Enum.map_join(parts, &(&1["text"] || ""))

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker)
    state = :sys.get_state(data.runtime_pid)

    Map.merge(Map.take(state, [:root, :manager, :binding, :session, :store]), %{
      adapter: data.runtime_pid
    })
  end

  defp child(manager), do: :sys.get_state(manager).agents[@child_name]

  defp scope(pid, binding) do
    state = :sys.get_state(pid)

    %{
      catalog: state.catalog,
      run_id: binding.run_id,
      incarnation: binding.run_incarnation,
      binding: binding,
      callbacks: Keyword.fetch!(state.opts, :host_context).filesystem_preparation
    }
  end

  defp assert_catalog(wire, scope, harness, root) do
    assert wire["model"] == "gpt-4o"
    assert scope.catalog.revision == 1

    assert Enum.sort(Enum.map(wire["tools"], &ToolName.decode(&1["function"]["name"]))) ==
             Enum.sort(@names)

    assert Enum.sort(Map.keys(scope.catalog.registry.tools)) == Enum.sort(@names)

    for {name, arity} <- [reserve: 3, seal: 5, fetch: 3, abandon: 3],
        do: assert(is_function(scope.callbacks[name], arity))

    for name <- @filesystem do
      descriptor = scope.catalog.registry.tools[name]
      context = descriptor.backend_context
      assert descriptor.backend == Filesystem
      assert descriptor.tool_revision == 1
      assert context.root == root
      assert context.run_id == scope.run_id
      assert context.incarnation == scope.incarnation
      assert context.catalog_revision == scope.catalog.revision

      assert context.workspace == %{
               role: :session,
               agent_id: harness.agent_name,
               session_id: harness.session.id
             }

      assert context.path_environment.cwd == root
      assert context.prepared_target_resolver == scope.callbacks.fetch
      assert context.execution_options[:node_executable] == @node
      assert context.execution_options[:model_has_vision] == true
    end

    for name <- @collaboration do
      descriptor = scope.catalog.registry.tools[name]
      assert descriptor.backend == Backend
      assert descriptor.tool_revision == 1
      assert descriptor.backend_context.session_binding == scope.binding
    end
  end

  defp assert_distinct_scope(previous, current) do
    assert previous.run_id != current.run_id
    assert previous.binding != current.binding

    for name <- [:reserve, :seal, :fetch, :abandon],
        do: assert(previous.callbacks[name] != current.callbacks[name])
  end

  defp assert_fresh(adapter, scope) do
    entry = :sys.get_state(adapter).tool_contexts[{scope.run_id, scope.incarnation}]
    assert entry.prepared_targets == %{}
    assert entry.prepared_target_bytes == 0
    assert entry.prepared_targets_closed? == false
  end

  defp journal(runtime, run_id, calls) do
    assert {:ok, aggregate} = Synapsis.Runtime.Store.load(runtime.store.namespace, run_id)
    operations = operations(aggregate)

    assert Enum.sort(Enum.map(operations, & &1.tool_call_id)) ==
             Enum.sort(Enum.map(calls, &elem(&1, 0)))

    for {id, name, arguments} <- calls do
      operation = Enum.find(operations, &(&1.tool_call_id == id))
      assert operation.run_id == run_id
      assert operation.tool_name == name
      assert operation.tool_revision == 1
      assert operation.arguments == arguments
      assert aggregate.run.tool_results[operation.invocation_id].is_error == false
    end

    assert_native_history(aggregate, calls)
    aggregate
  end

  defp operations(aggregate) do
    for {_, intent} <- aggregate.run.execution_intents, intent.type == :tool, do: intent.operation
  end

  defp assert_native_history(aggregate, calls) do
    messages = aggregate.run.context.conversation.messages

    native_calls =
      Enum.flat_map(messages, fn message ->
        blocks = if is_list(message[:content]), do: message.content, else: []
        Enum.filter(blocks, &(&1[:type] == :tool_call)) ++ Map.get(message, :tool_calls, [])
      end)

    for {id, name, arguments} <- calls do
      assert Enum.count(
               native_calls,
               &(&1.id == id and &1.name == name and &1.arguments == arguments)
             ) == 1

      assert Enum.count(messages, &(&1[:role] == :tool and &1[:tool_call_id] == id)) == 1
    end
  end

  defp assert_records(adapter, scope, aggregate, calls, root) do
    entry = :sys.get_state(adapter).tool_contexts[{scope.run_id, scope.incarnation}]
    assert entry.prepared_targets_closed? == false
    assert map_size(entry.prepared_targets) == length(calls)

    for {id, name, arguments} <- calls do
      operation = Enum.find(operations(aggregate), &(&1.tool_call_id == id))

      key =
        {scope.run_id, scope.incarnation, scope.catalog.revision, operation.invocation_id, name,
         1}

      envelope = entry.prepared_targets[key]
      assert envelope.state == :sealed
      record = envelope.record
      assert record.key == key
      assert record.version == 1

      assert record.correlation == %{
               turn_id: operation.turn_id,
               step_id: operation.step_id,
               attempt_id: operation.attempt_id,
               tool_call_id: id,
               enclosing_invocation_id: operation.invocation_id
             }

      assert envelope.correlation == record.correlation

      for field <- [:turn_id, :step_id, :attempt_id, :invocation_id],
          do: assert(is_binary(operation[field]) and operation[field] != "")

      path = arguments["path"]
      absolute = Path.join(root, path)
      assert record.original_path == path
      assert record.public_path == path
      assert record.source_path == path
      assert record.requested_absolute == absolute
      assert record.target == {:local, absolute, path}
      assert record.source_prefix == ""

      verb =
        if name == "synapsis::ls", do: "list", else: String.replace_prefix(name, "synapsis::", "")

      assert record.action == "filesystem." <> verb
      assert record.resource == "filesystem:" <> absolute
      digest = :crypto.hash(:sha256, :erlang.term_to_binary(arguments, [:deterministic]))
      assert record.raw_arguments_digest == digest
      assert record.prepared_arguments_digest == digest
      assert envelope.raw_arguments_digest == digest
    end
  end

  defp assert_wire_calls(wire, calls) do
    wire_calls =
      for message <- wire["messages"], call <- Map.get(message, "tool_calls", []), do: call

    for {id, name, arguments} <- calls do
      assert Enum.count(wire_calls, fn call ->
               call["id"] == id and ToolName.decode(call["function"]["name"]) == name and
                 Jason.decode!(call["function"]["arguments"]) == arguments
             end) == 1
    end
  end

  defp assert_filesystem_history(wire, aggregate, calls) do
    assert_wire_calls(wire, calls)

    for {id, name, _arguments} <- calls do
      operation = Enum.find(operations(aggregate), &(&1.tool_call_id == id))
      native = aggregate.run.tool_results[operation.invocation_id]
      assert {:ok, part} = ProviderMessages.tool_result_part(id, native, name)
      expected = expected_result(id)
      assert part.is_error == false
      assert part.projection == %{"version" => 1, "result" => expected}
      assert part.content == Enum.map_join(expected["content"], "\n", & &1["text"])

      assert Enum.count(
               wire["messages"],
               &(&1["role"] == "tool" and &1["tool_call_id"] == id and
                   &1["content"] == part.content)
             ) == 1
    end
  end

  defp expected_result(id) when id in ["root-read", "child-read"] do
    captured =
      @read_pages
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("cases")
      |> Enum.find(&(&1["id"] == "one-based-slice"))
      |> Map.fetch!("result")

    result(captured["text"], captured["details"])
  end

  defp expected_result("child-write"),
    do:
      result("Successfully wrote 6 bytes to files/child.txt", %{
        "diff" => "+1 alpha",
        "firstChangedLine" => 1,
        "patch" => "--- files/child.txt\n+++ files/child.txt\n@@ -0,0 +1,1 @@\n+alpha\n",
        "changed" => true,
        "created" => true
      })

  defp expected_result("child-edit"),
    do:
      result("Successfully replaced 1 block(s) in files/child.txt.", %{
        "diff" => "-1 alpha\n+1 BETA",
        "firstChangedLine" => 1,
        "patch" => "--- files/child.txt\n+++ files/child.txt\n@@ -1,1 +1,1 @@\n-alpha\n+BETA\n",
        "changed" => true
      })

  defp expected_result("child-ls"),
    do: result("\"child.txt\"\n\"lines.txt\"", %{"content" => "\"child.txt\"\n\"lines.txt\""})

  defp expected_result("child-followup-read"),
    do: result("BETA\n", %{"kind" => "text", "content" => "BETA\n"})

  defp result(text, details),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "details" => details,
      "is_error" => false
    }

  defp assert_parent_parts(id, root_journal) do
    parts = for message <- Synapsis.Sessions.get_messages(id), part <- message.parts, do: part
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input}) == @root_calls
    assert Enum.map(results, & &1.tool_use_id) == Enum.map(@root_calls, &elem(&1, 0))

    for {id, name, _arguments} <- @root_calls do
      operation = Enum.find(operations(root_journal), &(&1.tool_call_id == id))

      assert {:ok, expected} =
               ProviderMessages.tool_result_part(
                 id,
                 root_journal.run.tool_results[operation.invocation_id],
                 name
               )

      assert Enum.find(results, &(&1.tool_use_id == id)) == expected
    end

    text = for %Text{content: content} <- parts, do: content

    for marker <- [@first_final, @second_final, @parent_final],
        do: assert(Enum.any?(text, &String.contains?(&1, marker)))

    assert {:ok, turns} = Store.list_turns(id)
    durable = for turn <- turns, part <- turn.parts, do: part
    assert Enum.count(durable, &(&1[:type] == "tool_use")) == length(@root_calls)
    assert Enum.count(durable, &(&1[:type] == "tool_result")) == length(@root_calls)

    for use <- uses do
      assert Enum.any?(
               durable,
               &(&1[:type] == "tool_use" and &1[:id] == use.tool_use_id and &1[:name] == use.tool and
                   &1[:input] == use.input)
             )
    end

    for result <- results do
      assert Enum.any?(
               durable,
               &(&1[:type] == "tool_result" and &1[:tool_use_id] == result.tool_use_id and
                   &1[:content] == result.content and &1[:projection] == result.projection and
                   &1[:is_error] == false)
             )
    end

    for marker <- [@first_final, @second_final, @parent_final],
        do: assert(inspect(durable) =~ marker)

    for part <- uses ++ results do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end
  end

  defp completed_child(manager, incarnation, final) do
    await(fn ->
      current = child(manager)

      current.incarnation == incarnation and current.status == :completed and
        current.final == [%{type: :text, text: final}] and
        (current.result_delivery || %{})[:status] == :accepted
    end)
  end

  defp await(predicate), do: await(predicate, System.monotonic_time(:millisecond) + 10_000)

  defp await(predicate, deadline) do
    if predicate.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "ordinary managed filesystem progress was not observed"

      Process.sleep(10)
      await(predicate, deadline)
    end
  end
end
