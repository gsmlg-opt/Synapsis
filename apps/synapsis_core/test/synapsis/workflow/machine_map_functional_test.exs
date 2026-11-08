defmodule Synapsis.Workflow.MachineMapFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workflow.JSON, as: WorkflowJSON
  alias Synapsis.Workflow.Schema.PortSession
  alias Synapsis.Workflow.{Machine, Pipeline, Schema, Value}

  @root Path.expand("../../../../..", __DIR__)
  @operation_timeout 15_000
  @moduletag timeout: 120_000

  # Independent literals from Lobster 2026.9.16 map.js and value_path.js.
  # Ordinary finite JSON values only; each input domain stays homogeneous.
  # The parent freezes this file before production implementation begins.

  test "map construction and downstream zero demand leave the source unopened" do
    for kind <- ["array", "iterator_items"] do
      state =
        machine("map --wrap row 'label={{id}}' | head --n 0", ~S([{"id":"a"},{"id":"b"}]), kind)

      initial_heap = state["heap"]
      constructed = seek(state, &(&1["stage_index"] == 2))
      [map, _head] = constructed["frames"]
      assert map["name"] == "map"
      assert constructed["streams"][map["output"]]["kind"] == "transform"
      assert constructed["heap"] == initial_heap
      assert input(constructed)["cursor"] == 0
      assert input(constructed)["started"] == false

      {:complete, result, final, []} = boundary(constructed)

      assert result == %{
               "items" => [],
               "rendered" => false,
               "rendered_items" => [],
               "stdout" => ""
             }

      assert final["heap"] == initial_heap
      assert input(final)["cursor"] == 0
      assert input(final)["started"] == false
      assert input(final)["completed"] == false
      assert input(final)["returned"] == false
    end
  end

  test "one demanded object mutates in place and normal head return pulls no extra item" do
    for kind <- ["array", "iterator_items"] do
      state = machine("map 'label={{id}}!' | head --n 1", ~S([{"id":"a"},{"id":"b"}]), kind)
      [first, second] = input(state)["items"]
      {:complete, result, final, []} = boundary(state)
      assert result["items"] == [first]
      assert public(first, final) == %{"id" => "a", "label" => "a!"}
      assert public(second, final) == %{"id" => "b"}
      assert input(final)["cursor"] == 1
      assert input(final)["completed"] == false
      assert input(final)["returned"] == true
      assert Enum.all?(final["frames"], &(&1["status"] == "finished"))
    end
  end

  test "ordinary exhaustion preserves original object roots and completes the source" do
    state = machine("map 'label={{id}}' | json", ~S([{"id":"a"},{"id":"b"}]), "iterator_items")
    roots = input(state)["items"]
    {:complete, result, final, []} = boundary(state)
    assert result["items"] == roots

    assert public_items(result["items"], final) == [
             %{"id" => "a", "label" => "a"},
             %{"id" => "b", "label" => "b"}
           ]

    assert input(final)["cursor"] == 2
    assert input(final)["completed"] == true
    assert input(final)["returned"] == false
  end

  test "shared object aliases observe repeated mutation and earlier assignments" do
    assert {:ok, item, heap} = Value.decode_json(~S({"x":"A"}))
    state = new_machine("map 'x={{x}}!' 'seen={{x}}'", [item, item], heap, "iterator_items")
    {:complete, result, final, []} = boundary(state)
    assert result["items"] == [item, item]

    assert public_items(result["items"], final) == [
             %{"x" => "A!!", "seen" => "A!!"},
             %{"x" => "A!!", "seen" => "A!!"}
           ]

    assert Value.object_keys(item, final["heap"]) == ["x", "seen"]
  end

  test "wrap allocates a fresh object while assignments keep the original object context" do
    state =
      machine(
        "map --wrap row 'id=changed' 'seen={{id}}' 'original={{this}}'",
        ~S([{"id":"a"},{"id":"b"}])
      )

    roots = input(state)["items"]
    {:complete, result, final, []} = boundary(state)
    [first, second] = result["items"]
    refute first == second

    for {wrapper, original} <- Enum.zip(result["items"], roots) do
      refute wrapper == original
      assert Value.object_get(wrapper, "row", final["heap"]) == original
    end

    assert public_items(roots, final) == [%{"id" => "a"}, %{"id" => "b"}]

    assert public_items(result["items"], final) == [
             %{
               "row" => %{"id" => "a"},
               "id" => "changed",
               "seen" => "a",
               "original" => ~S({"id":"a"})
             },
             %{
               "row" => %{"id" => "b"},
               "id" => "changed",
               "seen" => "b",
               "original" => ~S({"id":"b"})
             }
           ]
  end

  test "scalar assignments allocate value wrappers and template dot and this use the scalar" do
    for {json, expected} <- [
          {"[2,3]",
           [
             %{"value" => 2, "dot" => "2", "self" => "2"},
             %{"value" => 3, "dot" => "3", "self" => "3"}
           ]},
          {~S(["a","b"]),
           [
             %{"value" => "a", "dot" => "a", "self" => "a"},
             %{"value" => "b", "dot" => "b", "self" => "b"}
           ]},
          {"[true,false]",
           [
             %{"value" => true, "dot" => "true", "self" => "true"},
             %{"value" => false, "dot" => "false", "self" => "false"}
           ]},
          {"[null,null]",
           [
             %{"value" => nil, "dot" => "", "self" => ""},
             %{"value" => nil, "dot" => "", "self" => ""}
           ]}
        ] do
      {:complete, result, final, []} = boundary(machine("map 'dot={{.}}' 'self={{this}}'", json))
      assert public_items(result["items"], final) == expected
    end
  end

  test "array assignments allocate value wrappers retaining the original arrays" do
    state = machine("map 'size={{length}}' 'first={{0}}' 'self={{.}}'", "[[1,2],[3,4]]")
    roots = input(state)["items"]
    {:complete, result, final, []} = boundary(state)

    assert public_items(result["items"], final) == [
             %{"value" => [1, 2], "size" => "2", "first" => "1", "self" => "[1,2]"},
             %{"value" => [3, 4], "size" => "2", "first" => "3", "self" => "[3,4]"}
           ]

    for {wrapper, original} <- Enum.zip(result["items"], roots) do
      assert Value.object_get(wrapper, "value", final["heap"]) == original
    end
  end

  test "wrap without assignments retains references and wraps scalar values" do
    for {json, expected} <- [
          {"[2,3]", [%{"item" => 2}, %{"item" => 3}]},
          {"[[1],[2]]", [%{"item" => [1]}, %{"item" => [2]}]},
          {~S([{"x":1},{"x":2}]), [%{"item" => %{"x" => 1}}, %{"item" => %{"x" => 2}}]}
        ] do
      state = machine("map --wrap item", json)
      roots = input(state)["items"]
      {:complete, result, final, []} = boundary(state)
      assert public_items(result["items"], final) == expected

      for {wrapper, original} <- Enum.zip(result["items"], roots) do
        assert Value.object_get(wrapper, "item", final["heap"]) == original
      end
    end
  end

  test "unwrap reads a literal own key and ignores assignments" do
    state =
      machine(
        "map --unwrap 'a.b' 'ignored=yes'",
        ~S([{"a.b":{"id":"a"},"a":{"b":"nested"}},{"a.b":{"id":"b"},"a":{"b":"nested"}}])
      )

    roots = input(state)["items"]
    children = Enum.map(roots, &Value.object_get(&1, "a.b", state["heap"]))
    {:complete, result, final, []} = boundary(state)
    assert result["items"] == children
    assert public_items(children, final) == [%{"id" => "a"}, %{"id" => "b"}]

    assert public_items(roots, final) == [
             %{"a.b" => %{"id" => "a"}, "a" => %{"b" => "nested"}},
             %{"a.b" => %{"id" => "b"}, "a" => %{"b" => "nested"}}
           ]
  end

  test "unwrap supports dense array index and length properties" do
    for {pipeline, expected} <- [{"map --unwrap 0", [1, 3]}, {"map --unwrap length", [2, 2]}] do
      {:complete, result, final, []} = boundary(machine(pipeline, "[[1,2],[3,4]]"))
      assert public_items(result["items"], final) == expected
    end
  end

  test "assignments split at the first equals trim only keys and retain duplicate order" do
    pipeline =
      "map ignored '=skip' '  =skip' '\uFEFF key \u00A0=  a=b  ' 'dup=first' 'after={{dup}}' 'dup=last' 'empty='"

    {:complete, result, final, []} = boundary(machine(pipeline, ~S([{"seed":"S"}])))

    assert public_items(result["items"], final) == [
             %{
               "seed" => "S",
               "key" => "  a=b  ",
               "dup" => "last",
               "after" => "first",
               "empty" => ""
             }
           ]

    assert Value.object_keys(hd(result["items"]), final["heap"]) == [
             "seed",
             "key",
             "dup",
             "after",
             "empty"
           ]
  end

  test "templates trim expressions preserve middle path whitespace and render nullish as empty" do
    pipeline =
      "map 'path={{ .nested.. value .name. }}' 'nil=<{{nullable}}>' 'missing=<{{absent}}>' 'text={{ text }}' 'literal={{}}'"

    json = ~S([{"nested":{" value ":{"name":"kept"}},"nullable":null,"text":"  exact  "}])
    {:complete, result, final, []} = boundary(machine(pipeline, json))
    [item] = public_items(result["items"], final)

    assert Map.take(item, ["path", "nil", "missing", "text", "literal"]) == %{
             "path" => "kept",
             "nil" => "<>",
             "missing" => "<>",
             "text" => "  exact  ",
             "literal" => "{{}}"
           }
  end

  test "compact template JSON preserves JavaScript property ordering and sequential mutation" do
    {:complete, result, final, []} =
      boundary(
        machine("map 'a=A' '0=zero' 'snapshot={{this}}'", ~S([{"2":"two","1":"one","z":"Z"}]))
      )

    [item] = result["items"]

    assert Value.object_get(item, "snapshot", final["heap"]) ==
             string(~S({"0":"zero","1":"one","2":"two","z":"Z","a":"A"}))

    assert Value.object_keys(item, final["heap"]) == ["0", "1", "2", "z", "a", "snapshot"]
  end

  test "empty or nonstring flags leave ordinary items unchanged" do
    for pipeline <- ["map", "map --wrap ''", "map --unwrap ''", "map --wrap", "map --unwrap"] do
      state = machine(pipeline, ~S([{"id":"a"},{"id":"b"}]))
      roots = input(state)["items"]
      {:complete, result, final, []} = boundary(state)
      assert result["items"] == roots
      assert public_items(roots, final) == [%{"id" => "a"}, %{"id" => "b"}]
    end
  end

  test "every intermediate map state survives JSON roundtrip with aliases and lazy return" do
    assert {:ok, item, heap} = Value.decode_json(~S({"x":"A"}))

    state =
      new_machine(
        "map 'x={{x}}!' 'seen={{x}}' | map --wrap row 'label={{x}}' | head --n 2",
        [item, item, item],
        heap,
        "iterator_items"
      )

    {saved, {:complete, expected, final, []}} = snapshots(state)
    assert input(final)["cursor"] == 2
    assert input(final)["returned"] == true

    assert public_items(expected["items"], final) == [
             %{"row" => %{"x" => "A!!", "seen" => "A!!"}, "label" => "A!"},
             %{"row" => %{"x" => "A!!", "seen" => "A!!"}, "label" => "A!!"}
           ]

    for original <- saved do
      restored = original |> Jason.encode!() |> Jason.decode!()
      assert restored == original
      assert json_data?(restored)
      assert {:complete, ^expected, ^final, []} = boundary(restored)
    end
  end

  test "actual Schema checkpoint resumes into map using the saved ordinary response" do
    with_session(fn session ->
      state =
        machine(
          "map --wrap row 'label={{id}}' | ask --prompt Review --schema '{\"type\":\"string\"}' --subject-from-stdin | map --wrap answer 'echo={{.}}' | json",
          ~S([{"id":"a"},{"id":"b"}]),
          "iterator_items"
        )

      {:checkpoint, checkpoint, saved, requests} = boundary(state, session)
      assert checkpoint["mode"] == "same_stage"
      assert checkpoint["stage_index"] == 1
      assert input(saved)["completed"] == true

      assert public(checkpoint["request"], saved)["subject"] == %{
               "text" =>
                 "{\"row\":{\"id\":\"a\"},\"label\":\"a\"}\n{\"row\":{\"id\":\"b\"},\"label\":\"b\"}"
             }

      assert requests == [
               %{"kind" => "compile_schema", "boundary" => "ask_constructor"},
               %{"kind" => "compile_schema", "boundary" => "request_metadata"}
             ]

      restored = saved |> Jason.encode!() |> Jason.decode!()
      assert restored == saved
      assert {:ok, resumed} = Machine.resume(restored, string("continue"))
      assert Enum.map(resumed["program"], & &1["name"]) == ["ask", "map", "json"]
      {:complete, result, completed, resumed_requests} = boundary(resumed, session)

      assert public_items(result["items"], completed) == [
               %{"answer" => "continue", "echo" => "continue"}
             ]

      assert Enum.map(completed["frames"], & &1["name"]) == ["ask", "map", "json"]

      assert Enum.map(resumed_requests, & &1["kind"]) == [
               "compile_schema",
               "compile_schema",
               "validate_response",
               "compile_schema",
               "compile_schema",
               "compile_schema",
               "validate_response"
             ]

      assert completed["resume_input"]["consumed"] == true
    end)
  end

  defp machine(pipeline, json, kind \\ "array") do
    assert {:ok, array, heap} = Value.decode_json(json)
    new_machine(pipeline, Value.array_items(array, heap), heap, kind)
  end

  defp new_machine(pipeline, items, heap, kind) do
    assert {:ok, program} = Pipeline.parse(pipeline)
    assert {:ok, state} = Machine.new(program, %{"kind" => kind, "items" => items}, heap)
    state
  end

  defp input(state), do: state["streams"][state["input_stream"]]
  defp string(value), do: %{"type" => "string", "value" => value}

  defp public(value, state) do
    assert {:ok, text} = WorkflowJSON.stringify(value, state["heap"])
    Jason.decode!(text)
  end

  defp public_items(items, state), do: Enum.map(items, &public(&1, state))

  defp seek(state, predicate, remaining \\ 4_000)
  defp seek(_state, _predicate, 0), do: flunk("ordinary transition bound exceeded")

  defp seek(state, predicate, remaining) do
    if predicate.(state) do
      state
    else
      assert {:continue, next} = Machine.advance(state)
      seek(next, predicate, remaining - 1)
    end
  end

  defp boundary(state, session \\ nil, requests \\ [], remaining \\ 4_000)
  defp boundary(_state, _session, _requests, 0), do: flunk("ordinary transition bound exceeded")

  defp boundary(state, session, requests, remaining) do
    case Machine.advance(state) do
      {:continue, next} ->
        boundary(next, session, requests, remaining - 1)

      {:request, request, pending} when not is_nil(session) ->
        assert {:continue, next} = Schema.advance_pending(session, pending, @operation_timeout)

        boundary(
          next,
          session,
          requests ++ [Map.take(request, ["kind", "boundary"])],
          remaining - 1
        )

      {:complete, result, final} ->
        {:complete, result, final, requests}

      {:checkpoint, checkpoint, saved} ->
        {:checkpoint, checkpoint, saved, requests}

      other ->
        flunk("unexpected ordinary map transition: #{inspect(other)}")
    end
  end

  defp snapshots(state, saved \\ [], remaining \\ 4_000)
  defp snapshots(_state, _saved, 0), do: flunk("ordinary transition bound exceeded")

  defp snapshots(state, saved, remaining) do
    case Machine.advance(state) do
      {:continue, next} ->
        snapshots(next, [state | saved], remaining - 1)

      {:complete, result, final} ->
        {Enum.reverse([final, state | saved]), {:complete, result, final, []}}

      other ->
        flunk("unexpected ordinary map transition: #{inspect(other)}")
    end
  end

  defp json_data?(value) when is_map(value),
    do: Enum.all?(value, fn {key, child} -> is_binary(key) and json_data?(child) end)

  defp json_data?(value) when is_list(value), do: Enum.all?(value, &json_data?/1)
  defp json_data?(value), do: is_binary(value) or is_number(value) or value in [nil, true, false]

  defp with_session(run) do
    node = System.find_executable("node")
    assert is_binary(node)

    session =
      start_supervised!(
        {PortSession,
         owner_pid: self(),
         node_executable: node,
         helper_path: Path.join(@root, "packages/tool-host/src/workflow/schema-stdio.mjs")}
      )

    try do
      run.(session)
    after
      assert {:ok, %{phase: :settled, cleanup_confirmed: true, exit_status: 0}} =
               PortSession.close(session)
    end
  end
end
