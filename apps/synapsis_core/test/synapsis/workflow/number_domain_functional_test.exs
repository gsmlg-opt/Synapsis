defmodule Synapsis.Workflow.NumberDomainFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workflow.JSON, as: WorkflowJSON
  alias Synapsis.Workflow.Schema.PortSession
  alias Synapsis.Workflow.{Machine, Pipeline, Schema, Sort, Template, Value}

  @root Path.expand("../../../../..", __DIR__)
  @timeout 15_000
  @moduletag timeout: 120_000

  # Independent literal binary64 expectations, frozen before implementation.
  # Valid JSON is source input; Infinity/NaN tags are trusted internal input.
  # These tests exercise shared pure semantics, not a native/Concord driver.
  @decimal_vectors [
    {"1e400", "7ff0000000000000"},
    {"-1e400", "fff0000000000000"},
    {"1e-4000", "0000000000000000"},
    {"-1e-4000", "8000000000000000"},
    {"-0", "8000000000000000"},
    {"-0.000e400", "8000000000000000"},
    {"1.7976931348623157e308", "7fefffffffffffff"},
    {"1.7976931348623158e308", "7fefffffffffffff"},
    {"1.7976931348623159e308", "7ff0000000000000"},
    {"-1.7976931348623158e308", "ffefffffffffffff"},
    {"-1.7976931348623159e308", "fff0000000000000"},
    {"179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497791",
     "7fefffffffffffff"},
    {"179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497792",
     "7ff0000000000000"},
    {"-179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497792",
     "fff0000000000000"},
    {"2.2250738585072014e-308", "0010000000000000"},
    {"2.225073858507201e-308", "000fffffffffffff"},
    {"5e-324", "0000000000000001"},
    {"2.4703282292062327e-324", "0000000000000000"},
    {"2.4703282292062328e-324", "0000000000000001"},
    {"0.0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000024703282292062327208828439643411068618252990130716238221279284125033775363510437593264991818081799618989828234772285886546332835517796989819938739800539093906315035659515570226392290858392449105184435931802849936536152500319370457678249219365623669863658480757001585769269903706311928279558551332927834338409351978015531246597263579574622766465272827220056374006485499977096599470454020828166226237857393450736339007967761930577506740176324673600968951340535537458516661134223766678604162159680461914467291840300530057530849048765391711386591646239524912623653881879636239373280423891018672348497668235089863388587925628302755995657524455507255189313690836254779186948667994968324049705821028513185451396213837722826145437693412532098591327667236328125",
     "0000000000000000"},
    {"0.00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000247032822920623272088284396434110686182529901307162382212792841250337753635104375932649918180817996189898282347722858865463328355177969898199387398005390939063150356595155702263922908583924491051844359318028499365361525003193704576782492193656236698636584807570015857692699037063119282795585513329278343384093519780155312465972635795746227664652728272200563740064854999770965994704540208281662262378573934507363390079677619305775067401763246736009689513405355374585166611342237666786041621596804619144672918403005300575308490487653917113865916462395249126236538818796362393732804238910186723484976682350898633885879256283027559956575244555072551893136908362547791869486679949683240497058210285131854513962138377228261454376934125320985913276672363281251",
     "0000000000000001"},
    {"-0.0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000024703282292062327208828439643411068618252990130716238221279284125033775363510437593264991818081799618989828234772285886546332835517796989819938739800539093906315035659515570226392290858392449105184435931802849936536152500319370457678249219365623669863658480757001585769269903706311928279558551332927834338409351978015531246597263579574622766465272827220056374006485499977096599470454020828166226237857393450736339007967761930577506740176324673600968951340535537458516661134223766678604162159680461914467291840300530057530849048765391711386591646239524912623653881879636239373280423891018672348497668235089863388587925628302755995657524455507255189313690836254779186948667994968324049705821028513185451396213837722826145437693412532098591327667236328125",
     "8000000000000000"},
    {"-0.00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000247032822920623272088284396434110686182529901307162382212792841250337753635104375932649918180817996189898282347722858865463328355177969898199387398005390939063150356595155702263922908583924491051844359318028499365361525003193704576782492193656236698636584807570015857692699037063119282795585513329278343384093519780155312465972635795746227664652728272200563740064854999770965994704540208281662262378573934507363390079677619305775067401763246736009689513405355374585166611342237666786041621596804619144672918403005300575308490487653917113865916462395249126236538818796362393732804238910186723484976682350898633885879256283027559956575244555072551893136908362547791869486679949683240497058210285131854513962138377228261454376934125320985913276672363281251",
     "8000000000000001"},
    {"9007199254740993", "4340000000000000"},
    {"9007199254740995", "4340000000000002"},
    {"-9007199254740993", "c340000000000000"},
    {"1.00000000000000011102230246251565404236316680908203125", "3ff0000000000000"},
    {"1.0000000000000001110223024625156540423631668090820312500000000000000001",
     "3ff0000000000001"},
    {"1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e-600",
     "3ff0000000000000"},
    {"0.000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001e600",
     "3ff0000000000000"},
    {"1.0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001",
     "3ff0000000000000"},
    {"999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999e-291",
     "7ff0000000000000"},
    {"-0.0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001",
     "8000000000000000"}
  ]

  test "valid JSON decimal import covers overflow, underflow and correctly rounded boundaries" do
    for {literal, bits} <- @decimal_vectors do
      assert {:ok, value, heap} = Value.decode_json(literal)
      assert value == number(bits), literal
      assert heap == Value.new()

      assert roundtrip(%{"root" => value, "heap" => heap}) == %{
               "root" => number(bits),
               "heap" => heap
             }
    end
  end

  test "numeric import retains UTF16 keys, duplicate replacement position and enumeration" do
    assert {:ok, root, heap} =
             Value.decode_json(
               ~S({"z":1e400,"2":-1e400,"\ud800":-1e-4000,"z":1.7976931348623158e308})
             )

    lone = %{"type" => "string", "utf16le" => "ANg="}
    assert Value.object_keys(root, heap) == ["2", "z", lone]
    assert Value.object_get(root, "z", heap) == number("7fefffffffffffff")
    assert Value.object_get(root, "2", heap) == number("fff0000000000000")
    assert Value.object_get(root, lone, heap) == number("8000000000000000")

    assert {:ok, ~S({"2":null,"z":1.7976931348623157e+308,"\ud800":0})} =
             WorkflowJSON.stringify(root, heap)
  end

  test "trusted supplied nonfinite payload bits survive tagged graph storage and normalize only in JSON" do
    values = numeric_roots()
    {array, heap} = Value.array(values, Value.new())
    {root, heap} = Value.object([{"z", array}, {"a", hd(values)}], heap)
    stored = roundtrip(%{"roots" => [root, array, array], "heap" => heap})
    assert stored["roots"] == [root, array, array]
    assert Value.array_items(array, stored["heap"]) == values
    assert Value.object_get(root, "z", stored["heap"]) == array
    assert {:ok, "[null,null,null,null,0]"} = WorkflowJSON.stringify(array, heap)

    assert {:ok, "[\n  null,\n  null,\n  null,\n  null,\n  0\n]"} =
             WorkflowJSON.pretty(array, heap)

    assert {:ok, ~S({"a":null,"z":[null,null,null,null,0]})} =
             WorkflowJSON.stable_stringify(root, heap)

    for value <- Enum.take(values, 4) do
      assert {:ok, "null"} = WorkflowJSON.stringify(value, heap)
      assert {:ok, "null"} = WorkflowJSON.pretty(value, heap)
      assert {:ok, "null"} = WorkflowJSON.stable_stringify(value, heap)
    end

    assert {:ok, null, _} = Value.decode_json("null")
    assert {:ok, "null"} = WorkflowJSON.stringify(null, heap)
  end

  test "numeric sort orders both infinities, keeps zero and Infinity ties, and treats NaN comparison as zero" do
    values =
      Enum.map(
        [
          "7ff0000000000000",
          "4000000000000000",
          "fff0000000000000",
          "8000000000000000",
          "0000000000000000",
          "c014000000000000",
          "7ff0000000000000"
        ],
        &number/1
      )

    for {pipeline, indices} <- [
          {"sort", [2, 5, 3, 4, 1, 0, 6]},
          {"sort --desc", [0, 6, 1, 3, 4, 5, 2]}
        ] do
      {rows, heap} = rows(values)
      {:complete, result, final, []} = drive(new(pipeline <> " --key n", rows, heap))
      assert result["items"] == Enum.map(indices, &Enum.at(rows, &1))
      assert original_fields(rows, final["heap"]) == values
    end

    with_session(fn session ->
      for values <- [
            [number("4008000000000000"), number("7ff8000000000042"), number("3ff0000000000000")],
            [number("7ff8000000000042"), number("7ff0000000000000")],
            [number("fff0000000000000"), number("7ff8000000000042")]
          ] do
        {rows, heap} = rows(values)
        {:complete, result, final, [request]} = drive(new("sort --key n", rows, heap), session)
        assert result["items"] == rows
        assert original_fields(rows, final["heap"]) == values
        assert request["kind"] == "sort_items"
        assert request["desc"] == false
        assert request["stage_index"] == 0
        assert Value.array_items(request["keys"], final["heap"]) == values
      end
    end)
  end

  test "numeric NaN source ordering retains exact original occurrence roots" do
    # Parent source-only diagnostic established this ordinary pinned-V8 result
    # before product edits. A generic stable Enum.sort comparator differs.
    values =
      Enum.map(
        [
          "4008000000000000",
          "3ff0000000000000",
          "0000000000000000",
          "7ff8000000000042",
          "4000000000000000"
        ],
        &number/1
      )

    with_session(fn session ->
      {rows, heap} = rows(values)
      {:complete, result, final, [request]} = drive(new("sort --key n", rows, heap), session)
      assert result["items"] == Enum.map([2, 1, 4, 0, 3], &Enum.at(rows, &1))
      assert original_fields(rows, final["heap"]) == values
      assert request["id"] == "sort:1"
      assert request["kind"] == "sort_items"
      assert Value.array_items(request["keys"], final["heap"]) == values
    end)
  end

  test "where numeric equality and relational consumers support Infinity and NaN without BEAM floats" do
    values =
      Enum.map(
        [
          "fff0000000000000",
          "c000000000000000",
          "8000000000000000",
          "0000000000000000",
          "4000000000000000",
          "7ff0000000000000",
          "7ff8000000000042"
        ],
        &number/1
      )

    for {expression, indices} <- [
          {"n=Infinity", [5]},
          {"n==1e400", [5]},
          {"n=-Infinity", [0]},
          {"n!=Infinity", [0, 1, 2, 3, 4, 6]},
          {"n<Infinity", [0, 1, 2, 3, 4]},
          {"n<=Infinity", [0, 1, 2, 3, 4, 5]},
          {"n>-Infinity", [1, 2, 3, 4, 5]},
          {"n>=-Infinity", [0, 1, 2, 3, 4, 5]},
          {"n=0", [2, 3]}
        ] do
      assert_filter(values, expression, indices)
    end

    # Homogeneous string fields exercise source Number conversion separately.
    strings =
      Enum.map(["Infinity", "1e400", "-Infinity", "-1e400", "0", "  Infinity  "], &string/1)

    for {expression, indices} <- [
          {"n=Infinity", [0, 1, 5]},
          {"n=-Infinity", [2, 3]},
          {"n>0", [0, 1, 5]},
          {"n<=-1e400", [2, 3]}
        ] do
      assert_filter(strings, expression, indices)
    end
  end

  test "dedupe and groupBy use null JSON signatures while preserving first original numeric keys and members" do
    values = Enum.take(numeric_roots(), 4)
    {rows, heap} = rows(values)
    {:complete, result, final, []} = drive(new("dedupe --key n", rows, heap))
    assert result["items"] == [hd(rows)]
    assert original_fields(rows, final["heap"]) == values
    {:complete, grouped, final, []} = drive(new("groupBy --key n", rows, heap))
    assert [group] = grouped["items"]
    assert Value.object_keys(group, final["heap"]) == ["key", "items", "count"]
    assert Value.object_get(group, "key", final["heap"]) == number("7ff0000000000000")

    assert group |> Value.object_get("items", final["heap"]) |> Value.array_items(final["heap"]) ==
             rows

    assert Value.object_get(group, "count", final["heap"]) == number("4010000000000000")
    assert original_fields(rows, final["heap"]) == values

    {:complete, deduped, final, []} = drive(new("dedupe", values, Value.new()))
    assert deduped["items"] == [number("7ff0000000000000")]
    assert {:ok, "null"} = WorkflowJSON.stringify(hd(deduped["items"]), final["heap"])

    # Separate homogeneous null input demonstrates the same JSON signature.
    null = %{"type" => "null"}
    {:complete, nulls, final, []} = drive(new("dedupe", [null, null], Value.new()))
    assert nulls["items"] == [null]
    assert {:ok, "null"} = WorkflowJSON.stringify(hd(nulls["items"]), final["heap"])
  end

  test "table uses String for numeric cells while map assignments use JSON serialization" do
    values = numeric_roots()

    {:complete, result, final, []} =
      drive(new("table", values, Value.new(), %{"render_output" => true}))

    assert result["rendered"] == true
    assert result["items"] == []
    assert result["stdout"] == "Infinity\n-Infinity\nNaN\nNaN\n0\n"
    assert input(final)["items"] == values

    {rows, heap} = rows(values)
    {:complete, result, final, []} = drive(new("map 'shown={{n}}'", rows, heap))
    assert result["items"] == rows
    assert original_fields(rows, final["heap"]) == values

    assert Enum.map(rows, &Value.object_get(&1, "shown", final["heap"])) ==
             Enum.map(["null", "null", "null", "null", "0"], &string/1)

    {rows, heap} = rows(Enum.take(values, 3))
    {:complete, result, _final, []} = drive(new("table", rows, heap, %{"render_output" => true}))
    assert result["stdout"] == "n        \n---------\nInfinity \n-Infinity\nNaN      \n"
  end

  test "head retains successful finite native argument coercion and exact input roots" do
    values = numeric_roots()

    for {args, count} <- [
          {%{"n" => 2.1}, 3},
          {%{"n" => true}, 1},
          {%{"n" => false}, 0},
          {%{"n" => "0x2"}, 2},
          {%{"n" => " 2e0 "}, 2},
          {%{"n" => ""}, 0},
          {%{"n" => 0}, 0},
          {%{"n" => nil}, 0},
          {%{"n" => []}, 0},
          {%{"n" => [2]}, 2},
          {%{"n" => [[2]]}, 2},
          {%{}, 5}
        ] do
      program = [%{"name" => "head", "args" => Map.put(args, "_", [])}]
      {:complete, result, final, []} = drive(new(program, values, Value.new()))
      assert result["items"] == Enum.take(values, count)
      assert input(final)["items"] == values
      assert input(final)["cursor"] == count
    end
  end

  test "real Template helper renders supplied nonfinite tags then safe text crosses both ordinary checkpoint modes" do
    with_session(fn session ->
      values = [
        number("7ff0000000000000"),
        number("fff0000000000000"),
        number("7ff8000000000042"),
        number("8000000000000000")
      ]

      {:complete, rendered, final, requests} =
        drive(new("template --text '{{.}}'", values, Value.new()), session)

      assert rendered["items"] == Enum.map(["Infinity", "-Infinity", "NaN", "0"], &string/1)
      assert Enum.map(requests, & &1["kind"]) == List.duplicate("render_template", 4)
      assert Enum.map(requests, & &1["item"]) == values
      assert input(final)["items"] == values

      {:complete, json_rendered, _final, json_requests} =
        drive(new("template --text '{{. | json}}'", values, Value.new()), session)

      assert json_rendered["items"] == Enum.map(["null", "null", "null", "0"], &string/1)
      assert Enum.map(json_requests, & &1["kind"]) == List.duplicate("render_template", 4)

      for {extra, mode, retained} <- [
            {" --emit", "next_stage", ["template"]},
            {"", "same_stage", ["ask", "template"]}
          ] do
        pipeline =
          "template --text '{{.}}' | ask --prompt Review --schema '{\"type\":\"string\"}' --subject-from-stdin" <>
            extra <> " | template --text '[{{.}}]'"

        {:checkpoint, checkpoint, saved, requests} =
          drive(new(pipeline, values, Value.new()), session)

        assert checkpoint["mode"] == mode
        assert checkpoint["stage_index"] == 1
        assert input(saved)["items"] == values
        assert Enum.count(requests, &(&1["kind"] == "render_template")) == 4
        assert Enum.any?(requests, &(&1["kind"] == "compile_schema"))
        assert {:ok, text} = WorkflowJSON.stringify(checkpoint["request"], saved["heap"])
        envelope = Jason.decode!(text)
        assert envelope["subject"] == %{"text" => "Infinity\n-Infinity\nNaN\n0"}
        assert checkpoint["replay_items"] == []

        assert envelope["items"] ==
                 if(mode == "same_stage", do: [], else: ["Infinity", "-Infinity", "NaN", "0"])

        assert {:ok, resumed} = Machine.resume(roundtrip(saved), string("accepted"))
        assert resumed["segment"] == 1
        assert resumed["frames"] == []
        assert Enum.map(resumed["program"], & &1["name"]) == retained
        {:complete, result, finished, after_requests} = drive(roundtrip(resumed), session)
        assert result["items"] == [string("[accepted]")]
        assert Enum.count(after_requests, &(&1["kind"] == "render_template")) == 1
        assert Enum.any?(after_requests, &(&1["kind"] == "validate_response"))
        if mode == "same_stage", do: assert(finished["resume_input"]["consumed"] == true)
      end
    end)
  end

  test "acknowledged NaN sort and safe projection survive both fresh semantic checkpoint slices" do
    with_session(fn session ->
      values =
        Enum.map(
          [
            "4008000000000000",
            "3ff0000000000000",
            "0000000000000000",
            "7ff8000000000042",
            "4000000000000000"
          ],
          &number/1
        )

      {rows, heap} = rows(values)

      for {flag, mode, suffix} <- [
            {"", "same_stage", ["ask", "template"]},
            {" --emit", "next_stage", ["template"]}
          ] do
        pipeline =
          "sort --key n | template --text '{{n}}' | ask --prompt Review --schema '{\"type\":\"string\"}' --subject-from-stdin" <>
            flag <> " | template --text '[{{.}}]'"

        {:checkpoint, checkpoint, saved, requests} = drive(new(pipeline, rows, heap), session)
        assert checkpoint["mode"] == mode
        assert checkpoint["stage_index"] == 2
        assert original_fields(rows, saved["heap"]) == values
        assert Enum.count(requests, &(&1["kind"] == "sort_items")) == 1
        assert Enum.count(requests, &(&1["kind"] == "render_template")) == 5
        assert {:ok, text} = WorkflowJSON.stringify(checkpoint["request"], saved["heap"])
        envelope = Jason.decode!(text)
        assert envelope["subject"] == %{"text" => "0\n1\n2\n3\nNaN"}

        assert envelope["items"] ==
                 if(mode == "next_stage", do: ["0", "1", "2", "3", "NaN"], else: [])

        assert {:ok, resumed} = Machine.resume(roundtrip(saved), string("accepted"))
        assert Enum.map(resumed["program"], & &1["name"]) == suffix
        {:complete, result, _final, later} = drive(roundtrip(resumed), session)
        assert result["items"] == [string("[accepted]")]
        assert Enum.count(later, &(&1["kind"] == "sort_items")) == 0
        assert Enum.count(later, &(&1["kind"] == "render_template")) == 1
      end
    end)
  end

  defp number(bits), do: %{"type" => "number", "bits" => bits}
  defp string(text), do: %{"type" => "string", "value" => text}

  defp numeric_roots,
    do:
      Enum.map(
        [
          "7ff0000000000000",
          "fff0000000000000",
          "7ff8000000000000",
          "7ff8000000000042",
          "8000000000000000"
        ],
        &number/1
      )

  defp input(state), do: state["streams"][state["input_stream"]]

  defp rows(values) do
    Enum.map_reduce(values, Value.new(), fn value, heap -> Value.object([{"n", value}], heap) end)
  end

  defp original_fields(rows, heap), do: Enum.map(rows, &Value.object_get(&1, "n", heap))

  defp assert_filter(values, expression, indices) do
    {rows, heap} = rows(values)
    {:complete, result, final, []} = drive(new("where '" <> expression <> "'", rows, heap))
    assert result["items"] == Enum.map(indices, &Enum.at(rows, &1))
    assert original_fields(rows, final["heap"]) == values
  end

  defp new(program, items, heap, options \\ %{"render_output" => false}) do
    program =
      if is_binary(program) do
        assert {:ok, parsed} = Pipeline.parse(program)
        parsed
      else
        program
      end

    assert {:ok, state} =
             Machine.new(program, %{"kind" => "iterator_items", "items" => items}, heap, options)

    roundtrip(state)
  end

  defp roundtrip(value) do
    restored = value |> Jason.encode!() |> Jason.decode!()
    assert restored == value
    restored
  end

  defp drive(state, session \\ nil, requests \\ [], remaining \\ 4_000)
  defp drive(_state, _session, _requests, 0), do: flunk("ordinary transition bound exceeded")

  defp drive(state, session, requests, remaining) do
    case Machine.advance(roundtrip(state)) do
      {:continue, next} ->
        drive(roundtrip(next), session, requests, remaining - 1)

      {:request, request, pending} = result ->
        assert Machine.advance(roundtrip(pending)) == result

        transition =
          case request["kind"] do
            "render_template" ->
              Template.advance_pending(session, pending, @timeout)

            "sort_items" ->
              Sort.advance_pending(session, pending, @timeout)

            kind when kind in ["compile_schema", "validate_response"] ->
              Schema.advance_pending(session, pending, @timeout)
          end

        assert {:continue, next} = transition
        assert %{phase: :idle} = PortSession.status(session)
        drive(roundtrip(next), session, requests ++ [request], remaining - 1)

      {:complete, result, final} ->
        {:complete, result, roundtrip(final), requests}

      {:checkpoint, checkpoint, final} ->
        {:checkpoint, checkpoint, roundtrip(final), requests}

      other ->
        flunk("unexpected ordinary transition: #{inspect(other)}")
    end
  end

  defp with_session(run) do
    node = System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
    assert Path.type(node) == :absolute

    session =
      start_supervised!(
        {PortSession,
         owner_pid: self(),
         node_executable: node,
         helper_path: Path.join(@root, "packages/tool-host/src/workflow/schema-stdio.mjs")}
      )

    try do
      run.(session)
      assert {:ok, %{cleanup_confirmed: true, exit_status: 0}} = PortSession.close(session)
    after
      if Process.alive?(session), do: PortSession.close(session)
    end
  end
end
