defmodule Synapsis.Workflow.LiveProvenanceFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workflow.JSON, as: WorkflowJSON
  alias Synapsis.Workflow.Provenance.Owner
  alias Synapsis.Workflow.Schema.PortSession
  alias Synapsis.Workflow.{Live, Machine, Pipeline, Value}

  @timeout 15_000
  @moduletag timeout: 120_000
  @text ~S({"model":"fixture","usage":{"inputTokens":2},"answer":"ok"})

  # State and invoke ACKs are positive semantic fixtures only. There is no
  # filesystem adapter, actual native invocation, trusted LLM producer or billing
  # authority in this file. The ask test uses the existing real schema helper.
  setup do
    %{owner: start_supervised!({Owner, name: nil})}
  end

  test "ordinary observed map transitions equal the existing API and carry no observations", %{
    owner: owner
  } do
    {root, heap} = item()
    machine = new("map 'answer=updated' | pick answer", [root], heap)
    binding = open(owner, machine)
    {{:complete, result, final}, binding, observations, _trace} = boundary(binding, machine)
    assert observations == []
    assert [projected] = result["items"]
    assert projected != root
    assert WorkflowJSON.stringify(projected, final["heap"]) == {:ok, ~S({"answer":"updated"})}
    assert Owner.provenance_of(binding, projected, @timeout) == {:ok, nil}
    assert Live.release(binding, @timeout) == :ok
  end

  test "matching set and get ACKs produce exact observations while polling remains inert", %{
    owner: owner
  } do
    {root, heap} = item()
    machine = new("state.set record | state.get record", [root], heap)
    binding = open(owner, machine)
    binding = mark(binding, heap, root, "ack-call")
    {{:request, write, pending}, binding, [], _trace} = boundary(binding, machine)
    assert write["value"] == root

    assert write["text"] ==
             "{\n  \"model\": \"fixture\",\n  \"usage\": {\n    \"inputTokens\": 2\n  },\n  \"answer\": \"ok\"\n}\n"

    assert Machine.advance_observed(pending) == {{:request, write, pending}, []}
    {{:request, ^write, ^pending}, binding, []} = step(binding, pending)
    event = %{"id" => write["id"], "kind" => "state_set", "result" => "ok"}
    context = source(write, "/ordinary/record.json")
    {{:continue, next}, binding, observations} = step(binding, pending, event, context)
    assert observations == [{:state_written, write["id"], root, write["text"]}]

    {{:request, read, pending}, binding, [], _trace} = boundary(binding, next)
    assert Machine.advance_observed(pending) == {{:request, read, pending}, []}

    event = %{
      "id" => read["id"],
      "kind" => "state_get",
      "result" => "ok",
      "text" => write["text"]
    }

    {{:continue, next}, binding, observations} =
      step(binding, pending, event, source(read, "/ordinary/record.json"))

    assert [{:state_read, id, fresh, captured}] = observations
    assert id == read["id"]
    assert captured == write["text"]
    assert fresh != root
    assert_mark(binding, fresh, "ack-call", true)
    {{:complete, result, _final}, binding, [], _trace} = boundary(binding, next)
    assert result["items"] == [fresh]
    assert_mark(binding, root, "ack-call", false)
    assert Live.release(binding, @timeout) == :ok
  end

  test "separate live runs share the same lexical cache after normal source release", %{
    owner: owner
  } do
    {root, heap} = item()
    machine = new("state.set shared", [root], heap)
    binding = open(owner, machine)
    binding = mark(binding, heap, root, "cross-run")
    {text, binding, final} = write_to_completion(binding, machine, "/ordinary/shared.json")
    assert final["items"] == [root]
    assert Live.release(binding, @timeout) == :ok

    machine = new("state.get shared", [], Value.new())
    binding = open(owner, machine)
    {read, binding, final} = read_to_completion(binding, machine, "/ordinary/shared.json", text)
    assert_mark(binding, read, "cross-run", true)
    assert_mark(binding, Value.object_get(read, "usage", final["heap"]), "cross-run", true)
    assert Live.release(binding, @timeout) == :ok
  end

  test "real map mutation updates a remembered graph before later exact-text carry", %{
    owner: owner
  } do
    {root, heap} = item()
    old_usage = Value.object_get(root, "usage", heap)
    # state.get is eager at construction and does not demand lazy map upstream.
    # A state.set drain demands the actual map assignment before the final get.
    machine =
      new(
        "state.set remembered | map 'usage=changed' | state.set drain | state.get remembered",
        [root],
        heap
      )

    binding = open(owner, machine)
    binding = mark(binding, heap, root, "actual-map")
    {{:request, write, pending}, binding, [], _} = boundary(binding, machine)

    {{:continue, next}, binding, _} =
      step(
        binding,
        pending,
        %{"id" => write["id"], "kind" => "state_set", "result" => "ok"},
        source(write, "/ordinary/mutated.json")
      )

    original_text = write["text"]
    {{:request, drain, pending}, binding, [], _} = boundary(binding, next)
    assert drain["key"] == "drain"
    assert Value.object_get(root, "usage", pending["heap"]) == string("changed")

    {{:continue, next}, binding, _} =
      step(
        binding,
        pending,
        %{"id" => drain["id"], "kind" => "state_set", "result" => "ok"},
        source(drain, "/ordinary/drain.json")
      )

    {{:request, read, pending}, binding, [], _} = boundary(binding, next)

    event = %{
      "id" => read["id"],
      "kind" => "state_get",
      "result" => "ok",
      "text" => original_text
    }

    {{:continue, next}, binding, [{:state_read, _, fresh, ^original_text}]} =
      step(binding, pending, event, source(read, "/ordinary/mutated.json"))

    assert_mark(binding, fresh, "actual-map", true)
    parsed_usage = Value.object_get(fresh, "usage", next["heap"])
    assert Owner.provenance_of(binding, parsed_usage, @timeout) == {:ok, nil}
    assert_mark(binding, old_usage, "actual-map", false)
    {{:complete, result, _}, binding, [], _} = boundary(binding, next)
    assert result["items"] == [fresh]
    assert Live.release(binding, @timeout) == :ok
  end

  test "actual invoke-each shallow spread emits copy_mark and shares replay identity", %{
    owner: owner
  } do
    machine =
      new(
        ~S(openclaw.invoke --tool fixture.echo --action echo --each --args-json '{"usage":{"inputTokens":2},"keep":"base"}'),
        [string("a")],
        Value.new()
      )

    binding = open(owner, machine)

    {binding, machine} =
      seek(binding, machine, fn state ->
        case state["frames"] do
          [frame | _] -> is_map(get_in(frame, ["locals", "tool_args"]))
          _ -> false
        end
      end)

    tool_args = get_in(hd(machine["frames"]), ["locals", "tool_args"])
    usage = Value.object_get(tool_args, "usage", machine["heap"])
    binding = mark(binding, machine["heap"], tool_args, "spread-live")
    {{:request, request, pending}, binding, observations, _} = boundary(binding, machine)
    assert [{:copy_mark, ^tool_args, spread}] = observations
    assert spread != tool_args

    assert request["body"] ==
             ~S({"tool":"fixture.echo","action":"echo","args":{"usage":{"inputTokens":2},"keep":"base","item":"a"}})

    assert Value.object_get(spread, "usage", pending["heap"]) == usage
    assert_mark(binding, spread, "spread-live", false)
    binding = publish(binding, pending["heap"], [{:mark_replayed, spread}])
    assert_mark(binding, tool_args, "spread-live", true)
    assert_mark(binding, usage, "spread-live", true)
    assert Machine.advance_observed(pending) == {{:request, request, pending}, []}
    event = %{"id" => request["id"], "response_json" => ~S({"ok":true,"result":"done"})}
    {{:continue, next}, binding, []} = step(binding, pending, event)
    {{:complete, result, _}, binding, [], _} = boundary(binding, next)
    assert result["items"] == [string("done")]
    assert Live.release(binding, @timeout) == :ok
  end

  test "real groupBy append publishes changed existing array nodes to the owner", %{owner: owner} do
    {:ok, array, heap} = Value.decode_json(~S([{"k":"same","id":"a"},{"k":"same","id":"b"}]))
    [first, second] = Value.array_items(array, heap)
    machine = new("groupBy --key k", [first, second], heap)
    binding = open(owner, machine)
    binding = mark(binding, heap, second, "group-second")
    {{:complete, result, final}, binding, [], trace} = boundary(binding, machine)
    assert [group] = result["items"]
    members = Value.object_get(group, "items", final["heap"])
    assert Value.array_items(members, final["heap"]) == [first, second]

    assert Enum.any?(trace, fn {before, after_machine} ->
             id = members["id"]

             get_in(before, ["heap", "nodes", id, "items"]) == [first] and
               get_in(after_machine, ["heap", "nodes", id, "items"]) == [first, second]
           end)

    # Narrow shape evidence for direct array writes, which bypass object_put.
    assert [graph] = owner |> :sys.get_state() |> Map.fetch!(:graphs) |> Map.values()
    assert graph.nodes == final["heap"]["nodes"]
    assert Owner.provenance_of(binding, group, @timeout) == {:ok, nil}
    assert Owner.provenance_of(binding, members, @timeout) == {:ok, nil}
    assert_mark(binding, second, "group-second", false)
    assert Live.release(binding, @timeout) == :ok
  end

  test "a real diff ACK emits no cache observation and leaves earlier remembered provenance intact",
       %{owner: owner} do
    {original, heap} = item()
    machine = new("state.set kept", [original], heap)
    a = open(owner, machine)
    a = mark(a, heap, original, "state-set-call")
    {text, a, _final} = write_to_completion(a, machine, "/ordinary/diff.json")
    assert Live.release(a, @timeout) == :ok

    {other, heap} = item()
    machine = new("diff.last kept | state.get kept", [other], heap)
    binding = open(owner, machine)
    binding = mark(binding, heap, other, "diff-call")
    {{:request, diff, pending}, binding, [], _} = boundary(binding, machine)
    assert diff["kind"] == "state_diff"

    event = %{
      "id" => diff["id"],
      "kind" => "state_diff",
      "result" => "ok",
      "before_text" => text,
      "changed" => false
    }

    {{:continue, next}, binding, []} =
      step(binding, pending, event, source(diff, "/ordinary/diff.json"))

    {read, binding, _final} = read_to_completion(binding, next, "/ordinary/diff.json", text)
    assert_mark(binding, read, "state-set-call", true)
    assert_mark(binding, other, "diff-call", false)
    assert Live.release(binding, @timeout) == :ok
  end

  test "genuine schema-backed checkpoint and in-memory resume preserve ordinary results and reused roots",
       %{owner: owner} do
    session = schema_session()
    {root, heap} = item()

    machine =
      new(
        ~S(ask --prompt Review --schema '{"type":"string"}' --subject-from-stdin | json),
        [root],
        heap,
        "array"
      )

    binding = open(owner, machine)
    binding = mark(binding, heap, root, "before-resume")

    try do
      {{:checkpoint, checkpoint, saved}, binding} = schema_boundary(binding, machine, session)
      assert checkpoint["mode"] == "same_stage"
      assert [snapshot] = checkpoint["replay_items"]
      assert snapshot != root
      assert_mark(binding, root, "before-resume", false)
      assert Owner.provenance_of(binding, snapshot, @timeout) == {:ok, nil}
      response = string("accepted")
      ordinary = Machine.resume(saved, response)
      assert Machine.resume_observed(saved, response) == {ordinary, []}
      assert {:ok, ^ordinary, next_binding} = Live.resume(binding, saved, response, @timeout)
      binding = next_binding
      assert {:ok, resumed} = ordinary
      assert resumed["segment"] == saved["segment"] + 1
      assert_mark(binding, root, "before-resume", false)
      assert Owner.provenance_of(binding, snapshot, @timeout) == {:ok, nil}
      {{:complete, result, final}, binding} = schema_boundary(binding, resumed, session)
      assert result["items"] == [response]
      assert final |> Jason.encode!() |> Jason.decode!() == final
      assert Live.release(binding, @timeout) == :ok
    after
      PortSession.close(session)
    end
  end

  test "ordinary JSON reopening starts unmarked while the released source remains cache-rooted",
       %{owner: owner} do
    {root, heap} = item()
    machine = new("state.set saved", [root], heap)
    binding = open(owner, machine)
    binding = mark(binding, heap, root, "prior-live")
    {_text, binding, final} = write_to_completion(binding, machine, "/ordinary/saved.json")
    restored = final |> Jason.encode!() |> Jason.decode!()
    assert restored == final
    assert Live.release(binding, @timeout) == :ok

    reopened = open(owner, restored)
    assert Owner.provenance_of(reopened, root, @timeout) == {:ok, nil}

    assert Owner.provenance_of(
             reopened,
             Value.object_get(root, "usage", restored["heap"]),
             @timeout
           ) == {:ok, nil}

    assert Live.release(reopened, @timeout) == :ok
    state = :sys.get_state(owner)
    assert state.leases == %{}
    assert map_size(state.graphs) == 1
    assert map_size(state.remembered) == 1
    assert map_size(state.calls) == 1
  end

  defp item do
    {:ok, root, heap} = Value.decode_json(@text)
    {root, heap}
  end

  defp new(pipeline, roots, heap, kind \\ "iterator_items") do
    assert {:ok, program} = Pipeline.parse(pipeline)

    assert {:ok, machine} =
             Machine.new(program, %{"kind" => kind, "items" => roots}, heap, %{
               "render_output" => false
             })

    machine
  end

  defp open(owner, machine) do
    assert {:ok, binding} = Live.open(owner, machine, @timeout)
    binding
  end

  defp mark(binding, heap, root, key),
    do: publish(binding, heap, [{:mark_item, root, string(key), false}])

  defp publish(binding, heap, actions) do
    assert {:ok, next} = Owner.publish(binding, Value.heap_delta(heap, heap), actions, @timeout)
    next
  end

  defp assert_mark(binding, root, key, replayed) do
    assert Owner.provenance_of(binding, root, @timeout) ==
             {:ok, %{cache_key: string(key), replayed: replayed}}
  end

  defp source(request, path), do: %{request_id: request["id"], lexical_path: path}

  # Each comparison runs independent pure transitions from the same immutable
  # value. Only Live.advance publishes once to the owner; no host effect runs.
  defp step(binding, machine, event \\ nil, source_context \\ nil) do
    ordinary = Machine.advance(machine, event)
    assert {^ordinary, observations} = Machine.advance_observed(machine, event)

    assert {:ok, ^ordinary, next_binding} =
             Live.advance(binding, machine, event, source_context, @timeout)

    next_machine = elem(ordinary, tuple_size(ordinary) - 1)
    assert next_machine |> Jason.encode!() |> Jason.decode!() == next_machine
    {ordinary, next_binding, observations}
  end

  defp boundary(binding, machine, observations \\ [], trace \\ [], remaining \\ 4_000)

  defp boundary(_binding, _machine, _observations, _trace, 0),
    do: flunk("ordinary finite transition bound exceeded")

  defp boundary(binding, machine, observations, trace, remaining) do
    {transition, next_binding, current} = step(binding, machine)
    next = elem(transition, tuple_size(transition) - 1)
    observations = observations ++ current
    trace = trace ++ [{machine, next}]

    case transition do
      {:continue, next} -> boundary(next_binding, next, observations, trace, remaining - 1)
      {:request, _, _} -> {transition, next_binding, observations, trace}
      {:complete, _, _} -> {transition, next_binding, observations, trace}
      {:checkpoint, _, _} -> {transition, next_binding, observations, trace}
      other -> flunk("unexpected ordinary transition: #{inspect(other)}")
    end
  end

  defp seek(binding, machine, predicate, remaining \\ 4_000)
  defp seek(_binding, _machine, _predicate, 0), do: flunk("ordinary finite seek bound exceeded")

  defp seek(binding, machine, predicate, remaining) do
    if predicate.(machine) do
      {binding, machine}
    else
      assert {{:continue, next}, next_binding, []} = step(binding, machine)
      seek(next_binding, next, predicate, remaining - 1)
    end
  end

  defp write_to_completion(binding, machine, path) do
    {{:request, request, pending}, binding, [], _} = boundary(binding, machine)
    assert request["kind"] == "state_set"

    {{:continue, next}, binding, [{:state_written, _, _, _}]} =
      step(
        binding,
        pending,
        %{"id" => request["id"], "kind" => "state_set", "result" => "ok"},
        source(request, path)
      )

    {{:complete, _result, final}, binding, [], _} = boundary(binding, next)
    {request["text"], binding, final}
  end

  defp read_to_completion(binding, machine, path, text) do
    {{:request, request, pending}, binding, [], _} = boundary(binding, machine)
    assert request["kind"] == "state_get"
    event = %{"id" => request["id"], "kind" => "state_get", "result" => "ok", "text" => text}

    {{:continue, next}, binding, [{:state_read, _, read, ^text}]} =
      step(binding, pending, event, source(request, path))

    {{:complete, result, final}, binding, [], _} = boundary(binding, next)
    assert result["items"] == [read]
    {read, binding, final}
  end

  defp schema_session do
    node = System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
    assert Path.type(node) == :absolute

    start_supervised!(
      {PortSession,
       owner_pid: self(),
       node_executable: node,
       helper_path:
         Path.expand("../../../../../packages/tool-host/src/workflow/schema-stdio.mjs", __DIR__)}
    )
  end

  defp schema_boundary(binding, machine, session) do
    case boundary(binding, machine) do
      {{:request, %{"kind" => kind} = request, pending}, binding, [], _}
      when kind in ["compile_schema", "validate_response"] ->
        assert {:ok, receipt} = PortSession.fulfill(session, request, pending["heap"], @timeout)
        assert receipt["id"] == request["id"]
        assert receipt["result"] == "ok"
        assert receipt["outcome"] == if(kind == "compile_schema", do: "compiled", else: "valid")

        {{:continue, next}, binding, []} =
          step(binding, pending, %{"id" => request["id"], "result" => "ok"})

        schema_boundary(binding, next, session)

      {transition, binding, [], _} ->
        {transition, binding}
    end
  end

  defp string(value), do: Value.key_string(value)
end
