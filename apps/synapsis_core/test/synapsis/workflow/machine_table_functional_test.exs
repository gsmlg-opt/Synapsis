defmodule Synapsis.Workflow.MachineTableFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workflow.JSON, as: WorkflowJSON
  alias Synapsis.Workflow.{Machine, Pipeline, Value}

  # Source-derived literals from @clawdbot/lobster 2026.9.16 table.js, frozen
  # before table product/capture edits. Each executed case is homogeneous with
  # present own fields; unsupported general JavaScript domains are source-only.
  @render_cases [
    {
      "true-eager-despite-downstream-zero",
      "table | head --n 0",
      "[{\"x\":\"a\"},{\"x\":\"b\"}]",
      "iterator_items",
      "x  \n---\na  \nb  \n",
      2,
      true,
      false
    },
    {
      "empty-iterator-renders-no-results",
      "table",
      "[]",
      "iterator_items",
      "(no results)\n",
      0,
      true,
      false
    },
    {
      "empty-array-renders-no-results",
      "table",
      "[]",
      "array",
      "(no results)\n",
      0,
      true,
      false
    },
    {
      "sample-twenty-excludes-last-extra-key",
      "table",
      "[{\"x\":\"a\"},{\"x\":\"a\"},{\"x\":\"a\"},{\"x\":\"a\"},{\"x\":\"a\"},{\"x\":\"a\"},{\"x\":\"a\"},{\"x\":\"a\"},{\"x\":\"a\"},{\"x\":\"a\"},{\"x\":\"a\"},{\"x\":\"a\"},{\"x\":\"a\"},{\"x\":\"a\"},{\"x\":\"a\"},{\"x\":\"a\"},{\"x\":\"a\"},{\"x\":\"a\"},{\"x\":\"a\"},{\"x\":\"a\"},{\"x\":\"long\",\"extra\":\"ignored\"}]",
      "array",
      "x   \n----\na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \na   \nlong\n",
      21,
      true,
      false
    },
    {
      "own-numeric-keys-order-before-insertion-keys",
      "table",
      "[{\"10\":\"ten\",\"2\":\"two\",\"z\":\"zee\",\"01\":\"one\"},{\"01\":\"uno\",\"z\":\"zed\",\"2\":\"dos\",\"10\":\"dix\"}]",
      "array",
      "2    10   z    01 \n---  ---  ---  ---\ntwo  ten  zee  one\ndos  dix  zed  uno\n",
      2,
      true,
      false
    },
    {
      "utf16-supplementary-header-and-cell-width",
      "table",
      "[{\"😀😀\":\"𐀀𐀀𐀀\",\"k\":\"x\"}]",
      "array",
      "😀😀    k  \n------  ---\n𐀀𐀀𐀀  x  \n",
      1,
      true,
      false
    },
    {
      "min-three-and-final-column-padding",
      "table",
      "[{\"a\":\"x\",\"b\":\"y\"}]",
      "array",
      "a    b  \n---  ---\nx    y  \n",
      1,
      true,
      false
    },
    {
      "table-header-and-cell-flatten-only-lf",
      "table",
      "[{\"h\\n\\r\":\"a\\nb\\rc\"}]",
      "array",
      "h \r  \n-----\na b\rc\n",
      1,
      true,
      false
    },
    {
      "strings-fallback-keeps-lf-and-cr",
      "table",
      "[\"a\\nb\",\"c\\rd\"]",
      "array",
      "a\nb\nc\rd\n",
      2,
      true,
      false
    },
    {
      "arrays-fallback-compact-json",
      "table",
      "[[1,2],[3]]",
      "array",
      "[1,2]\n[3]\n",
      2,
      true,
      false
    },
    {
      "numbers-fallback",
      "table",
      "[1,1.25,-2]",
      "array",
      "1\n1.25\n-2\n",
      3,
      true,
      false
    },
    {
      "booleans-fallback",
      "table",
      "[true,false]",
      "array",
      "true\nfalse\n",
      2,
      true,
      false
    },
    {
      "null-fallback",
      "table",
      "[null,null]",
      "array",
      "\n\n",
      2,
      true,
      false
    },
    {
      "number-cells",
      "table",
      "[{\"n\":1},{\"n\":1.25},{\"n\":-2}]",
      "array",
      "n   \n----\n1   \n1.25\n-2  \n",
      3,
      true,
      false
    },
    {
      "boolean-cells",
      "table",
      "[{\"b\":true},{\"b\":false}]",
      "array",
      "b    \n-----\ntrue \nfalse\n",
      2,
      true,
      false
    },
    {
      "null-cells",
      "table",
      "[{\"n\":null},{\"n\":null}]",
      "array",
      "n  \n---\n   \n   \n",
      2,
      true,
      false
    },
    {
      "array-valued-cells",
      "table",
      "[{\"v\":[1,2]},{\"v\":[3]}]",
      "array",
      "v    \n-----\n[1,2]\n[3]  \n",
      2,
      true,
      false
    },
    {
      "object-valued-cells",
      "table",
      "[{\"v\":{\"a\":1}},{\"v\":{\"a\":2}}]",
      "array",
      "v      \n-------\n{\"a\":1}\n{\"a\":2}\n",
      2,
      true,
      false
    },
    {
      "zero-columns-empty-own-objects",
      "table",
      "[{},{}]",
      "array",
      "\n\n\n\n",
      2,
      true,
      false
    },
    {
      "upstream-head-normal-return",
      "head --n 2 | table",
      "[\"a\",\"b\",\"c\"]",
      "iterator_items",
      "a\nb\n",
      2,
      false,
      true
    },
    {
      "rendered-empty-generator-feeds-json",
      "table | json",
      "[{\"x\":\"a\"}]",
      "array",
      "x  \n---\na  \n[]\n",
      1,
      true,
      false
    }
  ]

  test "complete table rendering literals survive JSON restoration at every transition" do
    for {id, pipeline, json, kind, stdout, cursor, completed, returned} <- @render_cases do
      state = machine(pipeline, json, kind, true)

      expected = %{
        "items" => [],
        "rendered" => true,
        "rendered_items" => [],
        "stdout" => stdout
      }

      {saved, {:complete, result, final}} = snapshots(state)
      assert result == expected, id
      assert input(final)["cursor"] == cursor, id
      assert input(final)["started"] == true, id
      assert input(final)["completed"] == completed, id
      assert input(final)["returned"] == returned, id
      assert final["pipeline_output_started"] == true, id
      table = Enum.find(final["frames"], &(&1["name"] == "table"))
      assert table["output_started"] == false, id

      for original <- saved do
        restored = original |> Jason.encode!() |> Jason.decode!()
        assert restored == original, id
        assert json_data?(restored), id
        assert {:complete, ^expected, ^final} = boundary(restored)
      end
    end
  end

  test "explicit false preserves original roots through a tracker with no array replay identity" do
    for kind <- ["array", "iterator_items"] do
      state = machine("table | head --n 2", ~S([{"x":"a"},{"x":"b"},{"x":"c"}]), kind, false)
      roots = input(state)["items"]
      constructed = seek(state, &(&1["stage_index"] == 2))
      [table, head] = constructed["frames"]
      assert table["name"] == "table"
      assert constructed["streams"][table["output"]]["kind"] == "transform"
      assert constructed["streams"][head["tracker"]]["known_items"] == nil
      assert input(constructed)["cursor"] == 0
      assert input(constructed)["started"] == false
      assert constructed["stdout"] == ""
      assert constructed["pipeline_output_started"] == false

      expected = %{
        "items" => Enum.take(roots, 2),
        "rendered" => false,
        "rendered_items" => [],
        "stdout" => ""
      }

      {saved, {:complete, result, final}} = snapshots(state)
      assert result == expected
      assert public_items(result["items"], final) == [%{"x" => "a"}, %{"x" => "b"}]
      assert input(final)["cursor"] == 2
      assert input(final)["completed"] == false
      assert input(final)["returned"] == true
      assert final["pipeline_output_started"] == false

      for original <- saved do
        restored = original |> Jason.encode!() |> Jason.decode!()
        assert restored == original
        assert json_data?(restored)
        assert {:complete, ^expected, ^final} = boundary(restored)
      end
    end
  end

  test "explicit false table leaves downstream zero demand unopened" do
    state = machine("table | head --n 0", ~S(["a","b"]), "iterator_items", false)
    expected = %{"items" => [], "rendered" => false, "rendered_items" => [], "stdout" => ""}
    {saved, {:complete, result, final}} = snapshots(state)
    assert result == expected
    assert input(final)["cursor"] == 0
    assert input(final)["started"] == false
    assert input(final)["completed"] == false
    assert input(final)["returned"] == false
    assert final["pipeline_output_started"] == false

    for original <- saved do
      restored = original |> Jason.encode!() |> Jason.decode!()
      assert restored == original
      assert {:complete, ^expected, ^final} = boundary(restored)
    end
  end

  test "true table drains eagerly before downstream zero construction and yields no items" do
    state = machine("table | head --n 0", ~S([{"x":"a"},{"x":"b"}]), "iterator_items", true)
    constructed = seek(state, &(&1["stage_index"] == 2))
    assert input(constructed)["cursor"] == 2
    assert input(constructed)["completed"] == true
    assert input(constructed)["returned"] == false
    assert constructed["rendered"] == true
    assert constructed["rendered_items"] == []
    assert constructed["stdout"] == "x  \n---\na  \nb  \n"
    assert constructed["pipeline_output_started"] == true
    assert Enum.all?(constructed["frames"], &(&1["output_started"] == false))
    {:complete, result, _final} = boundary(constructed)

    assert result == %{
             "items" => [],
             "rendered" => true,
             "rendered_items" => [],
             "stdout" => "x  \n---\na  \nb  \n"
           }
  end

  defp machine(pipeline, json, kind, render) do
    assert {:ok, array, heap} = Value.decode_json(json)
    assert {:ok, program} = Pipeline.parse(pipeline)

    assert {:ok, state} =
             Machine.new(
               program,
               %{"kind" => kind, "items" => Value.array_items(array, heap)},
               heap,
               %{
                 "render_output" => render
               }
             )

    state
  end

  defp input(state), do: state["streams"][state["input_stream"]]

  defp public_items(items, state) do
    Enum.map(items, fn value ->
      assert {:ok, text} = WorkflowJSON.stringify(value, state["heap"])
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

  defp boundary(state, remaining \\ 4_000)
  defp boundary(_state, 0), do: flunk("ordinary transition bound exceeded")

  defp boundary(state, remaining) do
    case Machine.advance(state) do
      {:continue, next} -> boundary(next, remaining - 1)
      {:complete, result, final} -> {:complete, result, final}
      other -> flunk("unexpected ordinary table transition: #{inspect(other)}")
    end
  end

  defp snapshots(state, saved \\ [], remaining \\ 4_000)
  defp snapshots(_state, _saved, 0), do: flunk("ordinary transition bound exceeded")

  defp snapshots(state, saved, remaining) do
    case Machine.advance(state) do
      {:continue, next} ->
        snapshots(next, [state | saved], remaining - 1)

      {:complete, result, final} ->
        {Enum.reverse([final, state | saved]), {:complete, result, final}}

      other ->
        flunk("unexpected ordinary table transition: #{inspect(other)}")
    end
  end

  defp json_data?(value) when is_map(value),
    do: Enum.all?(value, fn {key, child} -> is_binary(key) and json_data?(child) end)

  defp json_data?(value) when is_list(value), do: Enum.all?(value, &json_data?/1)
  defp json_data?(value), do: is_binary(value) or is_number(value) or value in [nil, true, false]
end
