defmodule Synapsis.Workflow.MachineWhereFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workflow.JSON, as: WorkflowJSON
  alias Synapsis.Workflow.Schema.PortSession
  alias Synapsis.Workflow.{Machine, Pipeline, Schema, Value}

  @root Path.expand("../../../../..", __DIR__)
  @operation_timeout 15_000
  @moduletag timeout: 120_000

  # Independent ordinary literals from Lobster 2026.9.16 stdlib/where.js.
  # Each input domain is homogeneous. No effects or nonfinite probes are used.
  # The parent freezes this file before production implementation begins.

  test "construction and downstream zero demand leave input unopened" do
    for kind <- ["array", "iterator_items"] do
      state =
        machine("where unread=true | head --n 0", ~S([{"unread":false},{"unread":true}]), kind)

      constructed = seek(state, &(&1["stage_index"] == 2))
      [where, _head] = constructed["frames"]
      assert where["name"] == "where"
      assert constructed["streams"][where["output"]]["kind"] == "transform"
      assert constructed["heap"] == state["heap"]
      assert input(constructed)["cursor"] == 0
      assert input(constructed)["started"] == false

      {:complete, result, final, []} = boundary(constructed)
      assert result["items"] == []
      assert final["heap"] == state["heap"]
      assert input(final)["cursor"] == 0
      assert input(final)["started"] == false
      assert input(final)["completed"] == false
      assert input(final)["returned"] == false
    end
  end

  test "skipped objects consume demand without output and head returns after the first match" do
    for kind <- ["array", "iterator_items"] do
      state =
        machine(
          "where unread=true | head --n 1",
          ~S([{"unread":false},{"unread":true},{"unread":true}]),
          kind
        )

      [_, wanted, _] = input(state)["items"]
      skipped = seek(state, &(input(&1)["cursor"] == 1 and where_stream(&1)["acquired"] == true))
      assert where_stream(skipped)["cursor"] == 0
      assert hd(skipped["frames"])["output_started"] == false
      assert skipped["items"] == []

      {:complete, result, final, []} = boundary(skipped)
      assert result["items"] == [wanted]
      assert input(final)["cursor"] == 2
      assert input(final)["completed"] == false
      assert input(final)["returned"] == true
      assert where_stream(final)["cursor"] == 1

      assert Map.take(final["heap"]["nodes"], Map.keys(state["heap"]["nodes"])) ==
               state["heap"]["nodes"]

      if kind == "iterator_items", do: assert(final["heap"] == state["heap"])
      assert Enum.all?(final["frames"], &(&1["status"] == "finished"))
    end
  end

  test "ordinary boolean equality inequality and exhaustion retain original roots" do
    for {expression, indices} <- [
          {"unread=true", [0, 2]},
          {"unread==false", [1]},
          {"unread!=true", [1]}
        ] do
      assert_filter(expression, ~S([{"unread":true},{"unread":false},{"unread":true}]), indices)
    end
  end

  test "all relational operators compare ordinary numbers numerically" do
    for {expression, indices} <- [
          {"minutes<10", [0]},
          {"minutes<=10", [0, 1]},
          {"minutes>10", [2]},
          {"minutes>=10", [1, 2]},
          {"minutes=10", [1]},
          {"minutes!=10", [0, 2]}
        ] do
      assert_filter(expression, ~S([{"minutes":2},{"minutes":10},{"minutes":30}]), indices)
    end
  end

  test "numeric fields and numeric strings use loose equality and Number parsing" do
    for expression <- ["n=16", "n=0x10", "n=0b10000", "n=0o20", "n=+16", "n=1.6e1", "n=16."] do
      assert_filter(expression, ~S([{"n":"16"},{"n":"17"},{"n":"016"}]), [0, 2])
      assert_filter(expression, ~S([{"n":16},{"n":17}]), [0])
    end

    assert_filter("n>=10", ~S([{"n":"2"},{"n":"10"},{"n":"30"}]), [1, 2])
    assert_filter("n=false", ~S([{"n":""},{"n":"0"},{"n":"1"}]), [0, 1])
    assert_filter("n=true", ~S([{"n":0},{"n":1},{"n":2}]), [1])
    assert_filter("n=0", ~S([{"n":false},{"n":true}]), [0])
  end

  test "predicate whitespace is optional around operators while raw strings remain exact" do
    assert_filter("n \t >= \t 10 \u00A0", ~S([{"n":2},{"n":10},{"n":30}]), [1, 2])
    assert_filter("name = ready", ~S([{"name":"ready"},{"name":"ready "}]), [0])
    assert_filter("name=ready ", ~S([{"name":"ready"},{"name":"ready "}]), [1])
    assert_filter("name=true ", ~S([{"name":"true"},{"name":"true "}]), [1])
    assert_filter("name=   ", ~S([{"name":""},{"name":" "},{"name":"   "}]), [1])
    state = machine("where n=2 ignored=3", ~S([{"n":2},{"n":3}]))
    {:complete, result, final, []} = boundary(state)
    assert public_items(result["items"], final) == [%{"n" => 2}]
  end

  test "null and missing paths use loose nullish equality and numeric relational conversion" do
    assert_filter("n=null", ~S([{"n":null},{},{"other":1}]), [0, 1, 2])
    assert_filter("n!=null", ~S([{"n":2},{"n":3}]), [0, 1])
    assert_filter("n=0", ~S([{"n":null},{"n":null}]), [])
    assert_filter("n<=0", ~S([{"n":null},{"n":null}]), [0, 1])
    assert_filter("n>=0", ~S([{},{}]), [])
    assert_filter("n.child=null", ~S([{"n":null},{"n":null}]), [0, 1])
  end

  test "where paths retain empty segments and read only object and dense array properties" do
    assert_filter("a..b=2", ~S([{"a":{"":{"b":2},"b":3}},{"a":{"":{"b":3},"b":2}}]), [0])
    assert_filter(".a.=2", ~S([{"":{"a":{"":2}}},{"":{"a":{"":3}}}]), [0])
    assert_filter("a.0.rank=2", ~S([{"a":[{"rank":2}]},{"a":[{"rank":3}]}]), [0])
    assert_filter("length=2", "[[1,2],[3],[4,5]]", [0, 2])
    assert_filter("0=2", "[[2,8],[1,9],[2,7]]", [0, 2])
    assert_filter("0=null", ~S(["a","b"]), [0, 1])
    assert_filter("length=null", ~S(["ab","c"]), [0, 1])
    assert_filter("name.length=null", ~S([{"name":"ab"},{"name":"c"}]), [0, 1])
  end

  test "ordinary strings use exact equality and UTF16 relational order" do
    assert_filter("name=ready", ~S([{"name":"ready"},{"name":"Ready"}]), [0])
    assert_filter("name<z", ~S([{"name":"a"},{"name":"z"},{"name":"zz"}]), [0])
    assert_filter("name<", ~S([{"name":"😀"},{"name":""},{"name":"𐀀"}]), [0, 2])
    assert_filter("name>=😀", ~S([{"name":"😀"},{"name":""},{"name":"𐀀"}]), [0, 1])
  end

  test "array primitive conversion joins values before numeric or string comparison" do
    assert_filter("k=2", ~S([{"k":[2]},{"k":[3]},{"k":[[2]]}]), [0, 2])
    assert_filter("k=false", ~S([{"k":[]},{"k":[null]},{"k":[0]},{"k":[1]}]), [0, 1, 2])
    assert_filter("k=1,2", ~S([{"k":[1,2]},{"k":[2,1]}]), [0])
    assert_filter("k>=10", ~S([{"k":[2]},{"k":[10]},{"k":[30]}]), [1, 2])
    assert_filter("k=null", ~S([{"k":[]},{"k":[null]}]), [])
  end

  test "ordinary object equality uses default primitive conversion only when required" do
    assert_filter("k=[object Object]", ~S([{"k":{"x":1}},{"k":{"valueOf":2}}]), [0, 1])
    assert_filter("k=0", ~S([{"k":{"x":1}},{"k":{"valueOf":0}}]), [])
    assert_filter("k=null", ~S([{"k":{"x":1}},{"k":{"toString":0}}]), [])
    assert_filter("k>[object A]", ~S([{"k":{"x":1}},{"k":{"valueOf":2}}]), [0, 1])
  end

  test "every intermediate state restores through JSON with shared roots and lazy return" do
    assert {:ok, item, heap} = Value.decode_json(~S({"keep":true,"child":{"id":"a"}}))
    assert {:ok, skipped, heap} = Value.decode_json(~S({"keep":false,"child":{"id":"b"}}), heap)

    state =
      new_machine(
        "where keep=true | head --n 2",
        [skipped, item, item, skipped],
        heap,
        "iterator_items"
      )

    {saved, {:complete, expected, final, []}} = snapshots(state)
    assert expected["items"] == [item, item]
    assert input(final)["cursor"] == 3
    assert input(final)["returned"] == true
    assert final["heap"] == heap

    for original <- saved do
      restored = original |> Jason.encode!() |> Jason.decode!()
      assert restored == original
      assert json_data?(restored)
      assert {:complete, ^expected, ^final, []} = boundary(restored)
    end
  end

  @tag :schema_checkpoint
  test "actual Schema same and next stage checkpoints resume into where" do
    with_session(fn session ->
      for {subject, mode} <- [{" --subject-from-stdin", "same_stage"}, {" --emit", "next_stage"}] do
        state =
          machine(
            "where keep=true | ask --prompt Review --schema '{\"type\":\"object\",\"properties\":{\"keep\":{\"type\":\"boolean\"}},\"required\":[\"keep\"]}'" <>
              subject <> " | where keep=true | json",
            ~S([{"keep":false},{"keep":true}]),
            "iterator_items"
          )

        {:checkpoint, checkpoint, saved, requests} = boundary(state, session)
        assert checkpoint["mode"] == mode
        assert checkpoint["stage_index"] == 1
        assert input(saved)["completed"] == true
        assert Enum.all?(requests, &(&1["kind"] == "compile_schema"))
        restored = saved |> Jason.encode!() |> Jason.decode!()
        assert restored == saved
        assert {:ok, response, heap} = Value.decode_json(~S({"keep":true}), restored["heap"])
        assert {:ok, resumed} = Machine.resume(%{restored | "heap" => heap}, response)
        {:complete, result, final, resumed_requests} = boundary(resumed, session)
        assert public_items(result["items"], final) == [%{"keep" => true}]
        assert Enum.any?(resumed_requests, &(&1["kind"] == "validate_response"))

        if mode == "same_stage" do
          assert final["resume_input"]["consumed"] == true
        else
          assert final["resume_input"] == nil
        end
      end
    end)
  end

  defp assert_filter(expression, json, indices) do
    state = machine("where '" <> expression <> "' | json", json, "iterator_items")
    roots = input(state)["items"]
    {:complete, result, final, []} = boundary(state)
    assert result["items"] == Enum.map(indices, &Enum.at(roots, &1))
    assert final["heap"] == state["heap"]
    assert input(final)["cursor"] == length(roots)
    assert input(final)["completed"] == true
    assert input(final)["returned"] == false
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
  defp where_stream(state), do: state["streams"][hd(state["frames"])["output"]]

  defp public_items(items, state) do
    Enum.map(items, fn item ->
      assert {:ok, text} = WorkflowJSON.stringify(item, state["heap"])
      Jason.decode!(text)
    end)
  end

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
        flunk("unexpected ordinary where transition: #{inspect(other)}")
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
        flunk("unexpected ordinary where transition: #{inspect(other)}")
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
