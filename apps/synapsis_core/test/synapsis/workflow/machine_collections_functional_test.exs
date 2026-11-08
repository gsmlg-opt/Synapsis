defmodule Synapsis.Workflow.MachineCollectionsFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workflow.JSON, as: WorkflowJSON
  alias Synapsis.Workflow.Schema.PortSession
  alias Synapsis.Workflow.{Machine, Pipeline, Schema, Value}

  @root Path.expand("../../../../..", __DIR__)
  @operation_timeout 15_000
  @moduletag timeout: 120_000

  # Independent source-derived literals, frozen before collection implementation.
  # Only ordinary success in the existing finite, dense, own-property domain.
  # Missing/undefined, mixed comparisons, prototypes and lone UTF-16 stay outside
  # executed qualification. Schema receipts below come from the actual helper.

  test "eager constructors drain before downstream construction while dedupe stays unopened" do
    for {pipeline, json, cursor, started, completed} <- [
          {"sort | head --n 0 | json", "[3,1,2]", 3, true, true},
          {"groupBy --key k | head --n 0 | json", ~S([{"k":"b"},{"k":"a"}]), 2, true, true},
          {"dedupe | head --n 0 | json", "[1,1,2]", 0, false, false}
        ] do
      state = machine(pipeline, json, "iterator_items")
      state = seek(state, &(length(&1["frames"]) == 3))
      assert input(state)["cursor"] == cursor
      assert input(state)["started"] == started
      assert input(state)["completed"] == completed
      assert input(state)["returned"] == false
      assert Enum.all?(state["frames"], &(&1["output_started"] == false))

      {:complete, result, state, []} = boundary(state)
      assert result["items"] == []
      assert input(state)["cursor"] == cursor
      assert input(state)["returned"] == false
    end
  end

  test "dedupe skips duplicate pulls and normal head return reads no extra unique item" do
    state = machine("dedupe | head --n 2 | json", "[2,2,1,3]", "iterator_items")
    {:complete, result, state, []} = boundary(state)
    assert public_items(result["items"], state) == [2, 1]

    assert result["items"] == [
             Enum.at(input(state)["items"], 0),
             Enum.at(input(state)["items"], 2)
           ]

    assert input(state)["cursor"] == 3
    assert input(state)["started"] == true
    assert input(state)["completed"] == false
    assert input(state)["returned"] == true
    assert Enum.all?(state["frames"], &(&1["status"] == "finished"))

    for {pipeline, expected} <- [
          {"head --n 2 | sort | json", [1, 3]},
          {"head --n 2 | groupBy --key length | pick key,count | json",
           [%{"key" => 1, "count" => 2}]}
        ] do
      json = if String.contains?(pipeline, "groupBy"), do: ~S(["b","a","cc"]), else: "[3,1,2]"
      {:complete, result, state, []} = boundary(machine(pipeline, json, "iterator_items"))
      assert public_items(result["items"], state) == expected
      assert input(state)["cursor"] == 2
      assert input(state)["completed"] == false
      assert input(state)["returned"] == true
    end
  end

  test "sort uses numeric or UTF16 lexical comparison with stable ties and exact flags" do
    for {pipeline, json, expected} <- [
          {"sort", "[10,2,1]", [1, 2, 10]},
          {"sort --key", "[10,2,1]", [1, 2, 10]},
          {"sort --key ''", ~S(["2","10","a"]), ["10", "2", "a"]},
          {"sort --desc=''", ~S(["","😀","a","𐀀"]), ["a", "𐀀", "😀", ""]},
          {"sort --desc=false", "[10,2,1]", [10, 2, 1]},
          {"sort --desc", "[10,2,1]", [10, 2, 1]},
          {"sort", "[true,false,true]", [false, true, true]},
          {"sort", "[[2],[10],[1,2]]", [[1, 2], [10], [2]]},
          {"sort", ~S([{"id":"b"},{"id":"a"}]), [%{"id" => "b"}, %{"id" => "a"}]},
          {"sort --key k --desc", ~S([{"k":null,"id":"a"},{"k":null,"id":"b"}]),
           [%{"k" => nil, "id" => "a"}, %{"k" => nil, "id" => "b"}]},
          {"sort --key .meta..rank. --desc=false | pick id",
           ~S([{"id":"a","meta":{"rank":2}},{"id":"b","meta":{"rank":3}},{"id":"c","meta":{"rank":2}}]),
           [%{"id" => "b"}, %{"id" => "a"}, %{"id" => "c"}]},
          {"sort --key ' k ' | pick id", ~S([{"id":"a"," k ":2},{"id":"b"," k ":1}]),
           [%{"id" => "b"}, %{"id" => "a"}]},
          {"sort --key ...", "[10,2,1]", [1, 2, 10]},
          {"sort --key 0", "[[2,8],[1,9]]", [[1, 9], [2, 8]]},
          {"sort --key length", "[[1,2],[3],[4,5]]", [[3], [1, 2], [4, 5]]},
          {"sort --key length", ~S(["bb","a","cc"]), ["a", "bb", "cc"]},
          {"sort --key 0", ~S(["ba","ab","bc"]), ["ab", "ba", "bc"]}
        ] do
      {:complete, result, state, []} = boundary(machine(pipeline <> " | json", json))
      assert public_items(result["items"], state) == expected
    end
  end

  test "dedupe uses ordinary JSON identity, keeps original roots and preserves zero sign" do
    for {pipeline, json, expected, indices} <- [
          {"dedupe", "[2,2,1,2]", [2, 1], [0, 2]},
          {"dedupe --key", "[2,2,1]", [2, 1], [0, 2]},
          {"dedupe --key ''", "[[1,2],[1,2],[2,1]]", [[1, 2], [2, 1]], [0, 2]},
          {"dedupe", ~S([{"a":1,"b":2},{"a":1,"b":2},{"b":2,"a":1}]),
           [%{"a" => 1, "b" => 2}, %{"b" => 2, "a" => 1}], [0, 2]},
          {"dedupe", ~S([{"2":"b","1":"a","z":1},{"1":"a","2":"b","z":1}]),
           [%{"1" => "a", "2" => "b", "z" => 1}], [0]},
          {"dedupe --key ' k '", ~S([{" k ":1,"id":"a"},{" k ":1,"id":"b"},{" k ":2,"id":"c"}]),
           [%{" k " => 1, "id" => "a"}, %{" k " => 2, "id" => "c"}], [0, 2]},
          {"dedupe --key .meta..rank.",
           ~S([{"meta":{"rank":1},"id":"a"},{"meta":{"rank":1},"id":"b"}]),
           [%{"meta" => %{"rank" => 1}, "id" => "a"}], [0]},
          {"dedupe --key ...", "[2,2,1]", [2, 1], [0, 2]},
          {"dedupe --key 0", "[[2,8],[2,9],[1,7]]", [[2, 8], [1, 7]], [0, 2]},
          {"dedupe --key k", ~S([{"k":null,"id":"a"},{"k":null,"id":"b"}]),
           [%{"k" => nil, "id" => "a"}], [0]}
        ] do
      {:complete, result, state, []} = boundary(machine(pipeline <> " | json", json))
      assert public_items(result["items"], state) == expected
      assert result["items"] == Enum.map(indices, &Enum.at(input(state)["items"], &1))
    end

    {:complete, result, state, []} = boundary(machine("dedupe | json", "[-0,0,-0]"))
    assert public_items(result["items"], state) == [0]
    assert result["items"] == [%{"type" => "number", "bits" => "8000000000000000"}]
  end

  test "groupBy drains eagerly but allocates ordered wrappers only on demand and keeps key aliases" do
    state =
      machine(
        "groupBy --key k | json",
        ~S([{"k":{"a":1,"b":2},"id":1},{"k":{"a":1,"b":2},"id":2},{"k":{"b":2,"a":1},"id":3}]),
        "iterator_items"
      )

    roots = input(state)["items"]
    [first, second, third] = roots
    first_key = Value.object_get(first, "k", state["heap"])
    second_key = Value.object_get(second, "k", state["heap"])
    third_key = Value.object_get(third, "k", state["heap"])
    refute first_key == second_key
    state = seek(state, &(&1["stage_index"] == 1))
    assert input(state)["cursor"] == 3
    assert input(state)["completed"] == true
    assert wrapper_count(state) == 0

    assert Enum.any?(state["heap"]["nodes"], fn
             {_id, %{"type" => "array", "items" => items}} -> items == [first, second]
             _ -> false
           end)

    assert Enum.any?(state["heap"]["nodes"], fn
             {_id, %{"type" => "array", "items" => items}} -> items == [third]
             _ -> false
           end)

    assert hd(state["frames"])["output_started"] == false

    state = seek(state, &(hd(&1["frames"])["output_started"] == true))
    assert wrapper_count(state) == 1
    {:complete, result, state, []} = boundary(state)
    assert wrapper_count(state) == 2
    [group_one, group_two] = result["items"]
    assert Value.object_keys(group_one, state["heap"]) == ["key", "items", "count"]
    assert Value.object_keys(group_two, state["heap"]) == ["key", "items", "count"]
    assert Value.object_get(group_one, "key", state["heap"]) == first_key
    assert Value.object_get(group_two, "key", state["heap"]) == third_key
    assert group_members(group_one, state) == [first, second]
    assert group_members(group_two, state) == [third]

    assert public_items(result["items"], state) == [
             %{
               "key" => %{"a" => 1, "b" => 2},
               "items" => [
                 %{"k" => %{"a" => 1, "b" => 2}, "id" => 1},
                 %{"k" => %{"a" => 1, "b" => 2}, "id" => 2}
               ],
               "count" => 2
             },
             %{
               "key" => %{"b" => 2, "a" => 1},
               "items" => [
                 %{"k" => %{"b" => 2, "a" => 1}, "id" => 3}
               ],
               "count" => 1
             }
           ]
  end

  test "groupBy trims its key and preserves first group and member order for ordinary paths" do
    for {pipeline, json, expected} <- [
          {"groupBy --key ' .meta..label. ' | pick key,count",
           ~S([{"meta":{"label":"b"},"id":1},{"meta":{"label":"a"},"id":2},{"meta":{"label":"b"},"id":3}]),
           [%{"key" => "b", "count" => 2}, %{"key" => "a", "count" => 1}]},
          {"groupBy --key ... | pick key,count", "[2,1,2]",
           [%{"key" => 2, "count" => 2}, %{"key" => 1, "count" => 1}]},
          {"groupBy --key 0 | pick key,count", "[[2,8],[1,9],[2,7]]",
           [%{"key" => 2, "count" => 2}, %{"key" => 1, "count" => 1}]},
          {"groupBy --key length | pick key,count", "[[1,2],[3],[4,5]]",
           [%{"key" => 2, "count" => 2}, %{"key" => 1, "count" => 1}]},
          {"groupBy --key length | pick key,count", ~S(["bb","a","cc"]),
           [%{"key" => 2, "count" => 2}, %{"key" => 1, "count" => 1}]},
          {"groupBy --key k", ~S([{"k":null,"id":1},{"k":null,"id":2}]),
           [
             %{
               "key" => nil,
               "items" => [%{"k" => nil, "id" => 1}, %{"k" => nil, "id" => 2}],
               "count" => 2
             }
           ]},
          {"groupBy --key k | pick key,count",
           ~S([{"k":[1,2],"id":1},{"k":[2,1],"id":2},{"k":[1,2],"id":3}]),
           [%{"key" => [1, 2], "count" => 2}, %{"key" => [2, 1], "count" => 1}]},
          {"groupBy --key k", "[]", []}
        ] do
      {:complete, result, state, []} = boundary(machine(pipeline <> " | json", json))
      assert public_items(result["items"], state) == expected
    end
  end

  test "sort dedupe groupBy and pick compose with existing array access and head demand" do
    {:complete, result, state, []} =
      boundary(
        machine(
          "sort --key 0 | dedupe --key 0 | groupBy --key length | pick key,count | head --n 2 | json",
          "[[2,8],[1],[2,9],[3]]"
        )
      )

    assert public_items(result["items"], state) == [
             %{"key" => 1, "count" => 2},
             %{"key" => 2, "count" => 1}
           ]

    assert result["rendered"] == false
    assert result["rendered_items"] == []
    assert result["stdout"] == ""
  end

  test "every intermediate collection state roundtrips through JSON and retains shared roots" do
    assert {:ok, array, heap} =
             Value.decode_json(~S([{"id":"a","rank":2},{"id":"b","rank":1},{"id":"c","rank":3}]))

    [first, second, third] = Value.array_items(array, heap)
    {shared_key, heap} = Value.object([{"label", string("same")}], heap)
    {other_key, heap} = Value.object([{"label", string("other")}], heap)
    heap = Value.object_put(first, "k", shared_key, heap)
    heap = Value.object_put(second, "k", shared_key, heap)
    heap = Value.object_put(third, "k", other_key, heap)

    state =
      new_machine(
        "sort --key rank | dedupe --key id | groupBy --key k | head --n 1 | json",
        [first, first, second, third],
        heap,
        "iterator_items",
        %{}
      )

    {states, {:complete, result, final, []} = expected} = snapshots(state)
    assert Enum.any?(states, &(input(&1)["cursor"] == 1))
    assert Enum.any?(states, &(&1["stage_index"] == 1 and input(&1)["completed"]))
    assert Enum.any?(states, &(&1["stage_index"] == 3 and wrapper_count(&1) == 0))
    assert Enum.any?(states, &(wrapper_count(&1) == 1))

    for saved <- states do
      restored = saved |> Jason.encode!() |> Jason.decode!()
      assert restored == saved
      assert json_data?(saved)
      assert boundary(restored) == expected
    end

    [group] = result["items"]
    assert Value.object_get(group, "key", final["heap"]) == shared_key
    assert group_members(group, final) == [second, first]
    assert Value.object_get(first, "k", final["heap"]) == shared_key
    assert Value.object_get(second, "k", final["heap"]) == shared_key
    assert wrapper_count(final) == 1
    assert input(final)["cursor"] == 4
    assert input(final)["completed"] == true
  end

  test "terminal json renders the composed groups with the existing pretty output contract" do
    {:complete, result, state, []} =
      boundary(
        machine(
          "sort --key rank | dedupe --key k | groupBy --key k | pick key,count | json",
          ~S([{"rank":3,"k":"b"},{"rank":1,"k":"a"},{"rank":2,"k":"a"}]),
          "array",
          %{"render_output" => true}
        )
      )

    assert result["items"] == []
    assert result["rendered"] == true

    assert public_items(result["rendered_items"], state) == [
             %{"key" => "a", "count" => 1},
             %{"key" => "b", "count" => 1}
           ]

    assert result["stdout"] ==
             "[\n  {\n    \"key\": \"a\",\n    \"count\": 1\n  },\n  {\n    \"key\": \"b\",\n    \"count\": 1\n  }\n]\n"
  end

  test "actual Schema helper carries a collection preview through same-stage fresh resume" do
    with_session(fn session ->
      state =
        machine(
          "sort | dedupe | groupBy --key length | pick key,count | ask --prompt Review --schema '{\"type\":\"string\"}' --subject-from-stdin | json",
          ~S(["bb","a","bb"]),
          "iterator_items"
        )

      {:checkpoint, checkpoint, saved, requests} = boundary(state, session)
      assert checkpoint["mode"] == "same_stage"
      assert checkpoint["stage_index"] == 4
      assert checkpoint["replay_items"] == []
      assert input(saved)["cursor"] == 3
      assert input(saved)["completed"] == true
      envelope = public(checkpoint["request"], saved)
      subject = %{"text" => "{\"key\":1,\"count\":1}\n{\"key\":2,\"count\":1}"}
      assert envelope["subject"] == subject

      assert envelope["commandInput"]["pending"]["suspendedState"] == %{
               "type" => "ask",
               "subject" => subject
             }

      assert requests == [
               %{"kind" => "compile_schema", "boundary" => "ask_constructor"},
               %{"kind" => "compile_schema", "boundary" => "request_metadata"}
             ]

      restored = saved |> Jason.encode!() |> Jason.decode!()
      assert restored == saved
      assert {:ok, resumed} = Machine.resume(restored, string("continue"))
      assert resumed["segment"] == 1
      assert resumed["frames"] == []
      assert Enum.map(resumed["program"], & &1["name"]) == ["ask", "json"]
      assert input(resumed)["items"] == []
      {:complete, result, completed, requests} = boundary(resumed, session)
      assert public_items(result["items"], completed) == ["continue"]
      assert Enum.map(completed["frames"], & &1["name"]) == ["ask", "json"]

      assert requests == [
               %{"kind" => "compile_schema", "boundary" => "resume_metadata"},
               %{"kind" => "compile_schema", "boundary" => "saved_response"},
               %{"kind" => "validate_response", "boundary" => "saved_response"},
               %{"kind" => "compile_schema", "boundary" => "ask_constructor"},
               %{"kind" => "compile_schema", "boundary" => "request_metadata"},
               %{"kind" => "compile_schema", "boundary" => "request_response"},
               %{"kind" => "validate_response", "boundary" => "request_response"}
             ]

      [ask, _json] = completed["frames"]
      assert length(ask["request_history"]) == 1

      assert public(ask["request_history"] |> hd() |> Map.fetch!("response"), completed) ==
               "continue"

      assert completed["resume_input"]["consumed"] == true
    end)
  end

  defp machine(pipeline, json, kind \\ "array", options \\ %{}) do
    assert {:ok, array, heap} = Value.decode_json(json)
    new_machine(pipeline, Value.array_items(array, heap), heap, kind, options)
  end

  defp new_machine(pipeline, items, heap, kind, options) do
    assert {:ok, program} = Pipeline.parse(pipeline)
    assert {:ok, state} = Machine.new(program, %{"kind" => kind, "items" => items}, heap, options)
    state
  end

  defp input(state), do: state["streams"][state["input_stream"]]
  defp string(value), do: %{"type" => "string", "value" => value}

  defp public(value, state) do
    assert {:ok, text} = WorkflowJSON.stringify(value, state["heap"])
    Jason.decode!(text)
  end

  defp public_items(items, state), do: Enum.map(items, &public(&1, state))

  defp group_members(group, state) do
    group |> Value.object_get("items", state["heap"]) |> Value.array_items(state["heap"])
  end

  defp wrapper_count(state) do
    Enum.count(state["heap"]["nodes"], fn
      {_id, %{"type" => "object", "keys" => ["key", "items", "count"]}} -> true
      _ -> false
    end)
  end

  defp seek(state, predicate, remaining \\ 2_000)
  defp seek(_state, _predicate, 0), do: flunk("ordinary transition bound exceeded")

  defp seek(state, predicate, remaining) do
    if predicate.(state) do
      state
    else
      assert {:continue, next} = Machine.advance(state)
      seek(next, predicate, remaining - 1)
    end
  end

  defp boundary(state, session \\ nil, requests \\ [], remaining \\ 2_000)
  defp boundary(_state, _session, _requests, 0), do: flunk("ordinary transition bound exceeded")

  defp boundary(state, session, requests, remaining) do
    case Machine.advance(state) do
      {:continue, next} ->
        boundary(next, session, requests, remaining - 1)

      {:request, request, pending} when not is_nil(session) ->
        assert Machine.advance(pending) == {:request, request, pending}
        if request["boundary"] == "saved_response", do: assert(pending["frames"] == [])
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
        flunk("unexpected ordinary transition: #{inspect(other)}")
    end
  end

  defp snapshots(state, saved \\ [], remaining \\ 2_000)
  defp snapshots(_state, _saved, 0), do: flunk("ordinary transition bound exceeded")

  defp snapshots(state, saved, remaining) do
    case Machine.advance(state) do
      {:continue, next} ->
        snapshots(next, [state | saved], remaining - 1)

      {:complete, result, final} ->
        {Enum.reverse([state | saved]), {:complete, result, final, []}}

      other ->
        flunk("unexpected ordinary collection transition: #{inspect(other)}")
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
