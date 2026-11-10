defmodule Synapsis.Session.NativeSkillWorkshopFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Conversation
  alias Backplane.AgentRuntime.Codex.Session, as: NativeSession
  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.{ExplicitSkill, Skills}
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Worker}
  alias Synapsis.SkillWorkshop.Changes

  @moduletag timeout: 240_000
  @search "synapsis::skills_search"
  @read "synapsis::skills_read"
  @explicit "synapsis::skill"
  @workshop "synapsis::skill_workshop"
  @reference "488631c18fae7cc541ba8fc8beff6cbb0438787b"
  @fixture Path.expand("../../fixtures/openclaw/488631c/skill-workshop.json", __DIR__)
  @source_rows ~w(list-empty create view-initial write-reference write-template patch-main patch-reference view-reference view-saved remove-reference write-extra restore-explicit view-restored archive list-archived restore-newest list-restored)

  # These tests exercise only ordinary successful foreground operations. The
  # coordinator owns execution, checked partitions and the shared services.
  setup do
    partition = System.fetch_env!("MIX_TEST_PARTITION")
    root = Path.join(System.tmp_dir!(), "synapsis-skills348-#{partition}-#{Ecto.UUID.generate()}")
    refute File.exists?(root)
    File.mkdir!(root)

    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        provider_fixture_options: [
          limits: %{max_bytes: 32 * 1_024 * 1_024},
          http_limits: %{max_body_bytes: 8 * 1_024 * 1_024}
        ],
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    assert {:ok, provider} =
             Synapsis.Providers.create(%{
               name: harness.provider.name,
               type: "openai_responses",
               base_url: harness.provider.base_url,
               api_key_encrypted: "fixture-key"
             })

    selected = [@search, @read, @explicit, @workshop, "exec", "clock::curr_time"]
    assert {:ok, _} = Synapsis.AgentConfigs.update(harness.agent_config, %{tools: selected})
    assert {:ok, scope} = Synapsis.SkillWorkshop.capture(harness.agent_config.id)
    private_parent = Path.dirname(scope.root)
    refute File.exists?(private_parent)

    on_exit(fn ->
      SessionHarness.cleanup!(harness)
      Synapsis.Providers.delete(provider.id)
      File.rm_rf!(private_parent)
      File.rm_rf!(root)
    end)

    SessionHarness.subscribe!(harness.session.id)
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "skill_workshop:" <> harness.agent_config.id)
    %{harness: harness, root: root, scope: scope, selected: selected}
  end

  test "whole inert assigned and learned instructions survive direct and actual nested native consumption",
       ctx do
    document =
      "---\nname: release-guide\ndescription: Inspect release evidence.\n---\n\n" <>
        String.duplicate("1. Read \"青空雪😀\".\n", 2_800) <>
        "Keep the final instruction café.\n"

    assert byte_size(document) > 65_536
    assigned = assigned(ctx, "release-guide", document)

    manual_document =
      "---\nname: manual-guide\ndescription: Review a named release.\ndisable-model-invocation: true\n---\n\n" <>
        "Read this only when explicitly selected.\n"

    manual = assigned(ctx, "manual-guide", manual_document, [assigned.id])

    learned =
      String.replace(document, "Inspect release evidence.", "Inspect private release evidence.") <>
        Enum.map_join(1..4, "\n", fn chapter ->
          "\n## Release review chapter #{chapter}\n\n" <>
            String.duplicate(
              "Read the reviewed release record, compare \"青空雪😀\", and retain the café evidence.\n",
              850
            ) <>
            "Record the complete findings for chapter #{chapter}.\n"
        end)

    support = String.duplicate("Reference \"青空\" café 雪 😀.\n", 2_800) <> "Final reference line.\n"
    seed(ctx.scope.root, "release-guide/SKILL.md", learned)
    seed(ctx.scope.root, "release-guide/references/notes.md", support)
    trace = trace_runtime()
    install_provider(ctx)
    first = start_turn(ctx, "Read the complete assigned and private guides as inert instructions")
    initial = first.runtime
    snapshot = assert_pair(ctx, first)
    [learned_entry] = snapshot.learned.bindings |> Enum.map(& &1.entry)
    assert learned_entry.name == assigned.name
    refute learned_entry.locator == "synapsis://skills/#{assigned.id}"
    assert snapshot.assigned.assignment_ids == [assigned.id, manual.id]

    {search, next} =
      invoke(ctx, first, "automatic-search", @search, %{"query" => "release evidence"})

    automatic = search.projection["result"]["structured"]["results"]
    assert Enum.any?(automatic, &(&1["locator"] == learned_entry.locator))
    assert Enum.any?(automatic, &(&1["record_id"] == assigned.id))
    refute Enum.any?(automatic, &(&1["record_id"] == manual.id))

    {global, next} =
      invoke(ctx, next, "assigned-read", @read, %{"locator" => "synapsis://skills/#{assigned.id}"})

    assert_read(global, document, "synapsis://skills/#{assigned.id}", assigned.id)

    {private, next} =
      invoke(ctx, next, "private-read", @read, %{"locator" => learned_entry.locator})

    assert_read(private, learned, learned_entry.locator, nil)
    page = private.projection["result"]["structured"]
    assert page["source_authority"] == "workshop"
    assert page["source_id"] == ctx.harness.agent_config.id
    assert page["revision"] == learned_entry.revision
    assert page["document_digest"] == digest(learned)

    {manual_result, next} =
      invoke(ctx, next, "manual-explicit", @explicit, %{
        "locator" => "synapsis://skills/#{manual.id}"
      })

    assert_read(manual_result, manual_document, "synapsis://skills/#{manual.id}", manual.id)

    nested_source = """
    const result = await tools.synapsis__skills_read({locator: #{Jason.encode!(learned_entry.locator)}});
    return {content: result.content, structured: result.structured};
    """

    {nested, next} = invoke(ctx, next, "nested-private", "exec", nested_source)
    assert nested.projection["result"]["status"] == "completed"

    assert nested.projection["result"]["value"] ==
             Map.take(private.projection["result"], ["content", "structured"])

    support_args = %{
      "action" => "view",
      "name" => "release-guide",
      "file_path" => "references/notes.md"
    }

    {view, next} = invoke(ctx, next, "support-view", @workshop, support_args)
    assert view.content == support <> "\n\n[Other files: SKILL.md]"

    assert source_result(view) == %{
             "content" => [%{"type" => "text", "text" => view.content}],
             "details" => %{
               "name" => "release-guide",
               "filePath" => "references/notes.md",
               "files" => ["SKILL.md", "references/notes.md"]
             }
           }

    nested_view = """
    const result = await tools.synapsis__skill_workshop(#{Jason.encode!(support_args)});
    return {content: result.content, structured: result.structured};
    """

    {nested_support, next} = invoke(ctx, next, "nested-support", "exec", nested_view)
    assert nested_support.projection["result"]["status"] == "completed"

    assert nested_support.projection["result"]["value"] ==
             Map.take(view.projection["result"], ["content", "structured"])

    {_clock, next} = invoke(ctx, next, "ordinary-clock", "clock::curr_time", %{})
    original = complete(ctx, next)

    assert_contracts(
      initial,
      ["assigned-read", "private-read", "manual-explicit", "support-view"],
      2
    )

    assert_normal_replay(ctx, initial, next.index + 1, original, trace)
    assert Synapsis.Skills.get(assigned.id) == assigned
    assert Synapsis.Skills.get(manual.id) == manual
    assert Synapsis.Skills.list_skill_ids(ctx.harness.agent_config.id) == [assigned.id, manual.id]
    assert File.read!(Path.join(ctx.scope.root, "release-guide/SKILL.md")) == learned
    assert File.read!(Path.join(ctx.scope.root, "release-guide/references/notes.md")) == support
  end

  test "all source workshop actions publish exact successors and survive ordinary completed history replay",
       ctx do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    assert fixture["referencePin"] == @reference
    assert Enum.map(fixture["observations"], & &1["id"]) == @source_rows
    assigned = assigned(ctx, "deploy-guide", "Read the unchanged assigned release procedure.\n")
    assigned_file = File.read!(Synapsis.Config.Store.file_path(:skill))
    trace = trace_runtime()
    install_provider(ctx)
    first = start_turn(ctx, "Author, revise, archive and restore the learned deploy guide")
    initial = first.runtime
    assert_pair(ctx, first)
    frozen = :erlang.term_to_binary(initial.catalog, [:deterministic])

    state = %{boundary: first, changes: [], change_symbols: %{}, version_symbols: %{}}

    state =
      Enum.reduce(fixture["observations"], state, fn row, state ->
        before = state.boundary
        args = actual_arguments(row["argumentsBefore"], state)
        {part, after_call} = invoke(ctx, before, row["id"], @workshop, args)
        result = source_result(part)
        state = register_symbols(state, result, row["result"])
        assert normalize(result, state) == row["result"], row["id"]
        assert normalize(file_tree(ctx.scope.root), state) == row["tree"], row["id"]
        assert_source_metadata(result, ctx)

        if change = result["details"]["change"] do
          assert {:ok, _} = Ecto.UUID.cast(change["id"])
          assert change["agentId"] == ctx.harness.agent_config.id
          assert change["sessionKey"] == ctx.harness.session.id
          assert change["runId"] == initial.run_id
          assert change["actor"] == "agent"
          assert_receive {:skill_workshop_changed, ^change}, 5_000

          assert {:ok, [^change | _]} =
                   Changes.list(ctx.harness.agent_config.id, [run_id: initial.run_id], deadline())

          assert_successor(before, after_call, row["id"], trace)
        else
          assert after_call.runtime.catalog === before.runtime.catalog
        end

        assert :erlang.term_to_binary(initial.catalog, [:deterministic]) == frozen

        assert Enum.sort(Map.keys(after_call.runtime.catalog.registry.tools)) ==
                 Enum.sort(ctx.selected)

        after_discovery = exercise_discovery(ctx, after_call, row, before)
        %{state | boundary: after_discovery}
      end)

    assert length(state.changes) == 10
    assert map_size(state.version_symbols) == 8

    assert {:ok, changes} =
             Changes.list(ctx.harness.agent_config.id, [run_id: initial.run_id], deadline())

    assert changes == Enum.reverse(state.changes)
    assert normalize(Enum.reverse(changes), state) == fixture["changeLedger"]

    {global, last} =
      invoke(ctx, state.boundary, "assigned-after-mutations", @read, %{
        "locator" => "synapsis://skills/#{assigned.id}"
      })

    assert_read(
      global,
      assigned.system_prompt_fragment,
      "synapsis://skills/#{assigned.id}",
      assigned.id
    )

    original = complete(ctx, last)
    assert_contracts(initial, @source_rows ++ ["assigned-after-mutations"], 0)
    assert_normal_replay(ctx, initial, last.index + 1, original, trace)

    assert {:ok, ^changes} =
             Changes.list(ctx.harness.agent_config.id, [run_id: initial.run_id], deadline())

    assert Synapsis.Skills.get(assigned.id) == assigned
    assert Synapsis.Skills.list_skill_ids(ctx.harness.agent_config.id) == [assigned.id]
    assert File.read!(Synapsis.Config.Store.file_path(:skill)) == assigned_file
  end

  defp assigned(ctx, name, body, previous \\ []) do
    assert {:ok, record} =
             Synapsis.Skills.create(%{
               name: name,
               description: "Inspect release evidence.",
               system_prompt_fragment: body
             })

    on_exit(fn -> Synapsis.Config.Store.delete(:skill, record.id) end)
    current = Synapsis.AgentConfigs.get(ctx.harness.agent_config.id)
    assert {:ok, _} = Synapsis.Skills.assign_skills(current, previous ++ [record.id])
    record
  end

  defp seed(root, relative, content) do
    path = Path.join(root, relative)
    refute File.exists?(path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp start_turn(ctx, prompt) do
    SessionHarness.ensure_running!(ctx.harness.session.id)
    assert :ok = Worker.send_message(ctx.harness.session.id, prompt)
    request(0)
  end

  defp assert_pair(ctx, boundary) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, ctx.harness.session.id)
    {_, data} = :sys.get_state(worker)
    snapshot = data.agent.skill_snapshot
    assert snapshot.schema == 2
    assert Synapsis.SkillDiscovery.valid_snapshot?(snapshot)
    entries = Synapsis.SkillDiscovery.entries(snapshot)
    assert data.agent.skill_catalog == entries
    rendered = Synapsis.SkillCatalog.render(entries).text
    assert Enum.any?(strings(boundary.request), &String.contains?(&1, rendered))

    for name <- [@search, @read, @explicit] do
      descriptor = boundary.runtime.catalog.registry.tools[name]
      assert descriptor.tool_revision == 2
      assert descriptor.backend_context.snapshot === snapshot
    end

    assert boundary.runtime.catalog.registry.tools[@workshop].tool_revision == 1
    snapshot
  end

  defp invoke(_ctx, before, id, name, args) do
    send(before.handler, {:deliver, {id, name, args}})
    following = request(before.index + 1)

    assert {:ok, messages} =
             ProviderMessages.to_host(Conversation.status(following.runtime.root).messages)

    [part] =
      for message <- messages,
          part = %ToolResult{} <- message.parts,
          part.tool_use_id == id,
          do: part

    assert part.is_error == false

    output =
      Enum.find(
        following.request["input"],
        &(&1["type"] in ~w(function_call_output custom_tool_call_output) and &1["call_id"] == id)
      )

    assert output["output"] == part.content
    {part, following}
  end

  defp request(index) do
    receive do
      {:workshop_request, ^index, request, handler, runtime} ->
        %{index: index, request: request, handler: handler, runtime: runtime}

      {:workshop_handler_failure, diagnostic} ->
        flunk(
          "Gaoxy workshop handler failed before request #{index}: " <>
            inspect(diagnostic) <> "; journal: " <> inspect(provider_journal())
        )
    after
      20_000 ->
        flunk(
          "No Gaoxy workshop request #{index} after 20000ms; journal: " <>
            inspect(provider_journal())
        )
    end
  end

  defp install_provider(ctx) do
    owner = self()
    Process.put({__MODULE__, :fixture}, ctx.harness.provider.fixture)

    Gaoxy.Test.stub(ctx.harness.provider.fixture, "POST", "/v1/responses", fn conn ->
      try do
        provider_response(ctx, conn, owner)
      rescue
        exception ->
          stacktrace = __STACKTRACE__

          send(
            owner,
            {:workshop_handler_failure, handler_diagnostic(:error, exception, stacktrace)}
          )

          reraise exception, stacktrace
      catch
        kind, reason ->
          stacktrace = __STACKTRACE__
          send(owner, {:workshop_handler_failure, handler_diagnostic(kind, reason, stacktrace)})
          :erlang.raise(kind, reason, stacktrace)
      end
    end)
  end

  defp provider_response(ctx, conn, owner) do
    Process.put({__MODULE__, :handler_stage}, :read_body)
    {:ok, body, conn} = read_body(conn, "")
    Process.put({__MODULE__, :handler_stage}, :decode_request)
    request = Jason.decode!(body)

    index =
      Agent.get_and_update(ctx.harness.counter, fn state ->
        {length(state.provider_requests),
         %{state | provider_requests: state.provider_requests ++ [request]}}
      end)

    Process.put({__MODULE__, :handler_stage}, {:runtime_snapshot, index})
    runtime = runtime(ctx.harness.session.id)
    send(owner, {:workshop_request, index, request, self(), runtime})
    Process.put({__MODULE__, :handler_stage}, {:respond, index})

    receive do
      {:deliver, {id, "exec", raw}} ->
        custom_call(conn, id, raw)

      {:deliver, {id, name, args}} ->
        function_call(conn, id, name, args)

      :complete ->
        sse(conn, [
          %{"type" => "response.output_text.delta", "delta" => "Workshop complete"},
          completed([])
        ])
    after
      20_000 -> raise "ordinary workshop provider handshake timed out"
    end
  end

  # Keep exception values and journal headers/body out of failure output. Match
  # errors retain symbolic terms (for example {:error, :timeout}) and byte counts;
  # stack frames retain only module/function/arity/source location, never args.
  defp handler_diagnostic(kind, reason, stacktrace) do
    exception = Exception.normalize(kind, reason, stacktrace)

    %{
      kind: kind,
      module: if(is_exception(exception), do: exception.__struct__, else: nil),
      stage: Process.get({__MODULE__, :handler_stage}),
      message: diagnostic_message(exception),
      stack:
        Enum.map(stacktrace, fn {module, function, arity, location} ->
          %{
            module: module,
            function: function,
            arity: if(is_list(arity), do: length(arity), else: arity),
            file: Keyword.get(location, :file),
            line: Keyword.get(location, :line)
          }
        end)
    }
  end

  defp diagnostic_message(%MatchError{term: term}),
    do: "no match of right hand side value: " <> inspect(symbolic_term(term))

  defp diagnostic_message(%CaseClauseError{term: term}),
    do: "no case clause matching: " <> inspect(symbolic_term(term))

  defp diagnostic_message(%FunctionClauseError{}), do: "no function clause matching"
  defp diagnostic_message(%KeyError{}), do: "key not found (key and term omitted)"

  defp diagnostic_message(%RuntimeError{
         message: "ordinary workshop provider handshake timed out"
       }),
       do: "ordinary workshop provider handshake timed out"

  defp diagnostic_message(_), do: "exception detail omitted; inspect module, stage and stack"

  defp symbolic_term(value) when is_atom(value) or is_number(value), do: value
  defp symbolic_term(value) when is_binary(value), do: %{type: :binary, bytes: byte_size(value)}

  defp symbolic_term(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.take(8) |> Enum.map(&symbolic_term/1) |> List.to_tuple()

  defp symbolic_term(value) when is_list(value), do: %{type: :list, length: length(value)}
  defp symbolic_term(value) when is_map(value), do: %{type: :map, size: map_size(value)}
  defp symbolic_term(_), do: :opaque

  defp provider_journal do
    try do
      journal = Gaoxy.Test.requests(Process.get({__MODULE__, :fixture}))

      %{
        cursor: journal.cursor,
        dropped: journal.dropped,
        truncated: journal.truncated,
        entries:
          Enum.map(journal.entries, fn entry ->
            %{
              id: entry.id,
              method: entry.method,
              path: entry.path,
              outcome: journal_outcome(entry.outcome)
            }
          end)
      }
    rescue
      exception -> handler_diagnostic(:error, exception, __STACKTRACE__)
    catch
      kind, reason -> handler_diagnostic(kind, reason, __STACKTRACE__)
    end
  end

  defp journal_outcome({:failure, kind, reason, stacktrace}),
    do: handler_diagnostic(kind, reason, stacktrace)

  defp journal_outcome(outcome), do: symbolic_term(outcome)

  defp read_body(conn, acc) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> {:ok, acc <> body, conn}
      {:more, body, conn} -> read_body(conn, acc <> body)
    end
  end

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker)
    native = :sys.get_state(data.runtime_pid)

    %{
      worker: worker,
      adapter: data.runtime_pid,
      root: native.root,
      store: native.store,
      run_id: native.run_id,
      session: native.session,
      catalog: :sys.get_state(native.root).catalog
    }
  end

  defp assert_read(part, content, locator, record_id) do
    assert part.content ==
             "Skill location: #{locator}\nResolve relative resource paths from the directory containing this SKILL.md.\n\n#{content}"

    page = part.projection["result"]["structured"]
    assert page["content"] == content
    assert page["citation"] == locator
    assert page["locator"] == locator
    assert page["document_digest"] == digest(content)

    if record_id,
      do: assert(page["record_id"] == record_id),
      else: refute(Map.has_key?(page, "record_id"))
  end

  defp source_result(part) do
    source = part.projection["result"]["structured"]
    assert part.content == Enum.map_join(source["content"], "\n", & &1["text"])
    source
  end

  defp assert_successor(before, after_call, call_id, trace) do
    predecessor = before.runtime.catalog
    successor = after_call.runtime.catalog
    assert successor.revision == predecessor.revision + 1

    assert {:ok, aggregate} =
             Synapsis.Agent.Runtime.Store.load(
               after_call.runtime.store,
               after_call.runtime.run_id
             )

    [intent] =
      for {_, intent} <- aggregate.run.execution_intents,
          intent.type == :tool,
          intent.operation.tool_call_id == call_id,
          do: intent

    assert intent.status == :consumed
    assert intent.operation.catalog_revision == predecessor.revision
    state = :sys.get_state(after_call.runtime.root)
    assert state.pending_catalog == nil
    [receipt | _] = state.catalog_receipts
    assert receipt.receipt.status == :published
    assert receipt.receipt.catalog_revision == successor.revision
    assert receipt.update.expected_revision == predecessor.revision
    assert receipt.update.catalog.registry === successor.registry

    observed = traced(trace)

    staged =
      for {:trace, _, :return_from, {Conversation, :stage_catalog, 3}, {:ok, receipt, state}} <-
            observed,
          receipt.status == :staged,
          do: state

    [staging] = staged
    assert staging.catalog === predecessor
    assert staging.pending_catalog.catalog.registry === successor.registry
    assert staging.pending_catalog.producer_invocation_id == intent.operation.invocation_id
    assert staging.pending_catalog.producer_settled? == false

    [publishing] =
      for {:trace, _, :call, {Conversation, :publish_catalog, [state, _]}} <- observed,
          state.pending_catalog != nil,
          do: state

    assert publishing.pending_catalog.producer_invocation_id == intent.operation.invocation_id
    assert publishing.pending_catalog.producer_settled? == true

    for name <- [@search, @read, @explicit] do
      old = predecessor.registry.tools[name].backend_context
      fresh = successor.registry.tools[name].backend_context
      assert fresh.catalog_revision == successor.revision
      assert fresh.snapshot.assigned === old.snapshot.assigned
      assert fresh.snapshot.generation != old.snapshot.generation
    end

    assert successor.registry.tools[@read].backend_context.snapshot ===
             successor.registry.tools[@search].backend_context.snapshot
  end

  defp exercise_discovery(ctx, boundary, row, before) do
    if row["id"] in ~w(create write-reference patch-main archive restore-newest) do
      snapshot = boundary.runtime.catalog.registry.tools[@read].backend_context.snapshot
      previous = before.runtime.catalog.registry.tools[@read].backend_context.snapshot
      entries = Enum.map(snapshot.learned.bindings, & &1.entry)

      {search, next} =
        invoke(ctx, boundary, row["id"] <> "-search", @search, %{"query" => "deploy"})

      learned_hits =
        Enum.filter(
          search.projection["result"]["structured"]["results"],
          &(&1["source_authority"] == "workshop")
        )

      assert Enum.map(learned_hits, & &1["locator"]) == Enum.map(entries, & &1.locator)

      if row["id"] == "write-reference" do
        [old] = previous.learned.bindings
        [fresh] = snapshot.learned.bindings
        refute old.entry.revision == fresh.entry.revision
        assert old.entry.artifact_digest == fresh.entry.artifact_digest

        refute before.runtime.catalog.registry.tools[@search].backend_context.body_cache ===
                 boundary.runtime.catalog.registry.tools[@search].backend_context.body_cache
      end

      case entries do
        [entry] ->
          body = File.read!(Path.join([ctx.scope.root, entry.name, "SKILL.md"]))

          {read, next} =
            invoke(ctx, next, row["id"] <> "-read", @read, %{"locator" => entry.locator})

          assert_read(read, body, entry.locator, nil)
          next

        [] ->
          next
      end
    else
      boundary
    end
  end

  defp assert_contracts(runtime, direct_ids, nested_count) do
    assert {:ok, aggregate} = Synapsis.Agent.Runtime.Store.load(runtime.store, runtime.run_id)
    assert aggregate.run.state == :completed
    intents = for {_, intent} <- aggregate.run.execution_intents, intent.type == :tool, do: intent

    for id <- direct_ids do
      [intent] = Enum.filter(intents, &(&1.operation.tool_call_id == id))
      assert intent.status == :consumed

      assert intent.operation.tool_revision ==
               if(intent.operation.tool_name == @workshop, do: 1, else: 2)

      assert %{schema_version: 1, output_limit: output, json_limit: json} =
               intent.operation.result_contract

      assert is_integer(output) and output > 0
      assert is_integer(json) and json > 0
      result = Map.fetch!(aggregate.run.tool_results, intent.operation.invocation_id)
      assert :erlang.external_size(result) <= output
      assert byte_size(Jason.encode!(result)) <= json
    end

    nested =
      Enum.filter(intents, &(&1.operation.invocation_id != &1.operation.enclosing_invocation_id))

    assert length(nested) == nested_count

    for intent <- nested do
      assert intent.status == :consumed
      assert intent.operation.result_contract.schema_version == 1

      [direct] =
        Enum.filter(intents, fn other ->
          other.operation.invocation_id == other.operation.enclosing_invocation_id and
            other.operation.tool_name == intent.operation.tool_name and
            other.operation.arguments == intent.operation.arguments
        end)

      assert intent.operation.result_contract == direct.operation.result_contract

      assert aggregate.run.tool_results[intent.operation.invocation_id] ==
               aggregate.run.tool_results[direct.operation.invocation_id]
    end

    for intent <- intents,
        intent.operation.tool_name in ["exec", "clock::curr_time"],
        do: assert(Map.get(intent.operation, :result_contract) == nil)
  end

  defp complete(ctx, boundary) do
    send(boundary.handler, :complete)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    original = parts(ctx.harness.session.id)
    assert_durable(ctx.harness.session.id, original)
    dump_completed_parts(original)
    original
  end

  defp dump_completed_parts(original) do
    if directory = System.get_env("SYNAPSIS_SKILLS348_EVIDENCE_DIR") do
      assert File.dir?(directory)
      partition = System.fetch_env!("MIX_TEST_PARTITION")

      destination =
        Path.join(directory, "completed-parts-#{partition}-#{Ecto.UUID.generate()}.json")

      refute File.exists?(destination)

      dumped =
        Enum.map(original, fn part ->
          assert {:ok, dumped} = Synapsis.Part.dump(part)
          dumped
        end)

      File.write!(destination, Jason.encode!(dumped), [:exclusive])
    end
  end

  defp assert_normal_replay(ctx, initial, index, original, trace) do
    assert %{phase: :idle} = NativeSession.status(initial.session)
    traced(trace)

    monitored =
      for pid <- [initial.worker, initial.adapter, initial.session],
          do: {pid, Process.monitor(pid)}

    assert :ok = DynamicSupervisor.stop_session(ctx.harness.session.id)

    for {pid, monitor} <- monitored,
        do: assert_receive({:DOWN, ^monitor, :process, ^pid, _}, 10_000)

    SessionHarness.ensure_running!(ctx.harness.session.id)
    assert :ok = Worker.send_message(ctx.harness.session.id, "Recall the completed workshop turn")
    replay = request(index)
    refute replay.runtime.worker == initial.worker
    assert_pair(ctx, replay)

    for %ToolResult{} = result <- original do
      output =
        Enum.find(
          replay.request["input"],
          &(&1["type"] in ~w(function_call_output custom_tool_call_output) and
              &1["call_id"] == result.tool_use_id)
        )

      assert output["output"] == result.content
    end

    send(replay.handler, :complete)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000

    assert parts(ctx.harness.session.id) ==
             original ++
               [
                 %Text{content: "Recall the completed workshop turn"},
                 %Text{content: "Workshop complete"}
               ]

    assert_durable(ctx.harness.session.id, original)

    refute Enum.any?(traced(trace), fn
             {:trace, _, :call, {module, :execute, [_]}}
             when module in [Skills, ExplicitSkill, Synapsis.Agent.Tools.SkillWorkshop] ->
               true

             {:trace, _, :call, {Synapsis.SkillWorkshop, :run, _}} ->
               true

             _ ->
               false
           end)
  end

  defp parts(id),
    do: for(message <- Synapsis.Message.list_by_session(id), part <- message.parts, do: part)

  defp assert_durable(id, original) do
    tools = Enum.filter(original, &(match?(%ToolUse{}, &1) or match?(%ToolResult{}, &1)))

    for part <- tools do
      assert {:ok, dumped} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dumped |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert {:ok, turns} = Synapsis.Session.Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert(Synapsis.Session.Store.get_turn(id, index) == {:ok, turn})

    persisted =
      for turn <- turns, part <- turn.parts, part[:type] in ~w(tool_use tool_result), do: part

    assert Enum.map(persisted, fn part ->
             if part.type == "tool_use",
               do: {:use, part.id, part.name, part.input},
               else: {:result, part.tool_use_id, part.content, part.projection}
           end) ==
             Enum.map(tools, fn
               %ToolUse{} = part -> {:use, part.tool_use_id, part.tool, part.input}
               %ToolResult{} = part -> {:result, part.tool_use_id, part.content, part.projection}
             end)
  end

  defp trace_runtime do
    trace = :trace.session_create(:skills348_ordinary, self(), [])
    on_exit(fn -> :trace.session_destroy(trace) end)

    for {module, function, arity} <- [
          {Skills, :execute, 1},
          {ExplicitSkill, :execute, 1},
          {Synapsis.Agent.Tools.SkillWorkshop, :execute, 1},
          {Synapsis.SkillWorkshop, :run, 3},
          {Conversation, :stage_catalog, 3},
          {Conversation, :publish_catalog, 2}
        ] do
      Code.ensure_loaded!(module)
      :trace.function(trace, {module, function, arity}, [{:_, [], [{:return_trace}]}], [:local])
    end

    :trace.process(trace, :all, true, [:call])
    trace
  end

  defp traced(trace) do
    barrier = :trace.delivered(trace, :all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    drain_trace([])
  end

  defp drain_trace(acc) do
    receive do
      {:trace, _, :call, _} = event -> drain_trace([event | acc])
      {:trace, _, :return_from, _, _} = event -> drain_trace([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp actual_arguments(args, state) do
    if version = args["version"] do
      {actual, ^version} =
        Enum.find(state.version_symbols, fn {_, symbol} -> symbol == version end)

      Map.put(args, "version", actual)
    else
      args
    end
  end

  defp register_symbols(state, result, expected) do
    if change = result["details"]["change"] do
      source = expected["details"]["change"]

      state = %{
        state
        | changes: state.changes ++ [change],
          change_symbols: Map.put(state.change_symbols, change["id"], source["id"])
      }

      if version = change["versionId"],
        do: %{
          state
          | version_symbols: Map.put(state.version_symbols, version, source["versionId"])
        },
        else: state
    else
      state
    end
  end

  defp normalize(value, state) when is_list(value), do: Enum.map(value, &normalize(&1, state))

  defp normalize(%{"skillName" => _, "agentId" => _, "id" => id} = change, state) do
    symbol = Map.fetch!(state.change_symbols, id)

    change
    |> Map.put("id", symbol)
    |> Map.put("agentId", "agent292")
    |> Map.put("sessionKey", "agent:agent292:source")
    |> Map.put("runId", "run292")
    |> Map.put("createdAtMs", symbol <> "::time")
    |> Map.new(fn {key, value} -> {key, normalize(value, state)} end)
  end

  defp normalize(%{"id" => id, "action" => _, "createdAtMs" => _} = version, state) do
    symbol = Map.fetch!(state.version_symbols, id)
    version |> Map.put("id", symbol) |> Map.put("createdAtMs", symbol <> "::time")
  end

  defp normalize(%{} = value, state) do
    value
    |> Map.new(fn {key, item} -> {key, normalize(item, state)} end)
    |> then(fn result ->
      if Map.has_key?(result, "updatedAtMs"),
        do: Map.put(result, "updatedAtMs", "$LIVE_TREE_MTIME"),
        else: result
    end)
  end

  defp normalize(value, state) when is_binary(value),
    do:
      Enum.reduce(state.version_symbols, value, fn {actual, symbol}, text ->
        String.replace(text, actual, symbol)
      end)

  defp normalize(value, _), do: value

  defp file_tree(root, prefix \\ "workshop-skills") do
    if File.dir?(root) do
      root
      |> File.ls!()
      |> Enum.flat_map(fn name ->
        absolute = Path.join(root, name)
        path = prefix <> "/" <> name

        if File.dir?(absolute) do
          file_tree(absolute, path)
        else
          content = File.read!(absolute)

          [
            %{
              "path" => path,
              "content" => content,
              "bytes" => byte_size(content),
              "sha256" => Base.encode16(:crypto.hash(:sha256, content), case: :lower)
            }
          ]
        end
      end)
      |> Enum.sort_by(& &1["path"])
    else
      []
    end
  end

  defp assert_source_metadata(result, ctx) do
    for skill <- result["details"]["skills"] || [] do
      paths = Enum.map(skill["files"], &Path.join([ctx.scope.root, skill["name"], &1]))
      assert skill["sizeBytes"] == Enum.sum(Enum.map(paths, &File.stat!(&1).size))
      assert is_integer(skill["updatedAtMs"])
    end
  end

  defp function_call(conn, id, name, args) do
    item = %{
      "type" => "function_call",
      "id" => id <> "-item",
      "call_id" => id,
      "name" => ToolName.encode(name),
      "arguments" => Jason.encode!(args)
    }

    sse(conn, [
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => Map.put(item, "arguments", "")
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "item_id" => item["id"],
        "delta" => item["arguments"]
      },
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      completed([item])
    ])
  end

  defp custom_call(conn, id, raw) do
    item = %{
      "type" => "custom_tool_call",
      "id" => id <> "-item",
      "call_id" => id,
      "name" => "exec",
      "input" => raw
    }

    sse(conn, [
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => Map.put(item, "input", "")
      },
      %{
        "type" => "response.custom_tool_call_input.delta",
        "item_id" => item["id"],
        "delta" => raw
      },
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      completed([item])
    ])
  end

  defp completed(output),
    do: %{
      "type" => "response.completed",
      "response" => %{"status" => "completed", "output" => output}
    }

  defp sse(conn, events),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
      )

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp strings(value) when is_map(value), do: value |> Map.values() |> Enum.flat_map(&strings/1)
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)
  defp strings(value) when is_binary(value), do: [value]
  defp strings(_), do: []
end
