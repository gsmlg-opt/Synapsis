defmodule Synapsis.Workflow.MachineStateFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workflow.JSON, as: WorkflowJSON
  alias Synapsis.Workflow.Schema.PortSession
  alias Synapsis.Workflow.{Machine, Pipeline, Schema, Value}

  @root Path.expand("../../../../..", __DIR__)
  @timeout 15_000
  @moduletag timeout: 120_000

  # Independent literal expectations from the unchanged Lobster 2026.9.16
  # state.js, diff_last.js and store.js. State ACKs below are declared semantic
  # fixtures only: they do not establish filesystem, native or durable effects.
  # Schema requests use the actual retained PortSession and Schema helper.

  test "get requests during construction without demanding lazy upstream even before head zero" do
    state =
      new("template --text '{{.}}' | state.get 'Raw Key/A' --key ignored | head --n 0", [
        string("unused")
      ])

    {:request, request, pending} = boundary(state)

    assert request == %{
             "id" => "state:1",
             "kind" => "state_get",
             "key" => "Raw Key/A",
             "stage_index" => 1
           }

    assert pending["stage_index"] == 1
    assert length(pending["frames"]) == 2
    assert input(pending)["cursor"] == 0
    assert input(pending)["started"] == false
    assert Enum.at(pending["frames"], 0)["output_started"] == false

    next =
      acknowledge(pending, %{
        "id" => "state:1",
        "kind" => "state_get",
        "result" => "ok",
        "text" => "{\"loaded\":true}\n"
      })

    {:complete, result, final} = boundary(next)
    assert result["items"] == []
    assert input(final)["cursor"] == 0
    assert input(final)["started"] == false
    assert final["next_request"] == 2
  end

  test "each get imports a fresh graph and expands serialized aliases into independent children" do
    {shared, heap} = Value.object([{"value", number("3ff0000000000000")}], Value.new())
    {original, heap} = Value.object([{"left", shared}, {"right", shared}], heap)

    {:request, first, pending} =
      boundary(new("state.get aliases | state.get aliases", [original], heap))

    assert first == %{
             "id" => "state:1",
             "kind" => "state_get",
             "key" => "aliases",
             "stage_index" => 0
           }

    next =
      acknowledge(pending, %{
        "id" => "state:1",
        "kind" => "state_get",
        "result" => "ok",
        "text" => "{\"left\":{\"value\":1},\"right\":{\"value\":1}}\n"
      })

    {:request, second, pending} = boundary(next)

    assert second == %{
             "id" => "state:2",
             "kind" => "state_get",
             "key" => "aliases",
             "stage_index" => 1
           }

    first_frame = hd(pending["frames"])
    assert [read1] = pending["streams"][first_frame["output"]]["items"]
    assert read1 != original
    left1 = Value.object_get(read1, "left", pending["heap"])
    right1 = Value.object_get(read1, "right", pending["heap"])
    assert left1 != shared
    assert right1 != shared
    assert left1 != right1

    next =
      acknowledge(pending, %{
        "id" => "state:2",
        "kind" => "state_get",
        "result" => "ok",
        "text" => "{\"left\":{\"value\":1},\"right\":{\"value\":1}}\n"
      })

    {:complete, result, final} = boundary(next)
    assert [read2] = result["items"]
    assert read2 not in [original, read1]
    left2 = Value.object_get(read2, "left", final["heap"])
    right2 = Value.object_get(read2, "right", final["heap"])
    assert left2 not in [shared, left1, right1, right2]
    assert right2 not in [shared, left1, right1]
    assert_json(read2, final["heap"], ~S({"left":{"value":1},"right":{"value":1}}))
    assert Value.object_get(original, "left", final["heap"]) == shared
    assert Value.object_get(original, "right", final["heap"]) == shared
    assert input(final)["started"] == false
  end

  test "get uses shared binary64 import while retaining duplicate position and UTF16 own keys" do
    {:request, request, pending} = boundary(new("state.get numbers", []))
    assert request["kind"] == "state_get"

    next =
      acknowledge(pending, %{
        "id" => "state:1",
        "kind" => "state_get",
        "result" => "ok",
        "text" =>
          ~S({"z":1e400,"2":-1e400,"\ud800":-1e-4000,"z":1.7976931348623158e308,"s":"\udfff","tiny":1e-4000,"negativeZero":-0})
      })

    {:complete, result, final} = boundary(next)
    assert [root] = result["items"]
    lone = %{"type" => "string", "utf16le" => "ANg="}
    assert Value.object_keys(root, final["heap"]) == ["2", "z", lone, "s", "tiny", "negativeZero"]
    assert Value.object_get(root, "z", final["heap"]) == number("7fefffffffffffff")
    assert Value.object_get(root, "2", final["heap"]) == number("fff0000000000000")
    assert Value.object_get(root, lone, final["heap"]) == number("8000000000000000")
    assert Value.object_get(root, "tiny", final["heap"]) == number("0000000000000000")
    assert Value.object_get(root, "negativeZero", final["heap"]) == number("8000000000000000")

    assert Value.object_get(root, "s", final["heap"]) == %{
             "type" => "string",
             "utf16le" => "/98="
           }

    assert_json(
      root,
      final["heap"],
      ~S({"2":null,"z":1.7976931348623157e+308,"\ud800":0,"s":"\udfff","tiny":0,"negativeZero":0})
    )
  end

  test "get accepts successful JSON overflow and underflow scalar texts" do
    for {text, bits} <- [
          {"1e400\n", "7ff0000000000000"},
          {"-1e400\n", "fff0000000000000"},
          {"1e-4000\n", "0000000000000000"},
          {"-1e-4000\n", "8000000000000000"}
        ] do
      {:request, _request, pending} = boundary(new("state.get numeric", []))

      next =
        acknowledge(pending, %{
          "id" => "state:1",
          "kind" => "state_get",
          "result" => "ok",
          "text" => text
        })

      {:complete, result, _final} = boundary(next)
      assert result["items"] == [number(bits)]
    end
  end

  test "set zero input allocates one empty array value and returns that exact root once" do
    {:request, request, pending} = boundary(new("state.set empty", []))
    assert_write(request, "state:1", "state_set", "empty", 0, "[]\n")
    assert Value.array_items(request["value"], pending["heap"]) == []
    assert input(pending)["completed"] == true
    next = acknowledge(pending, %{"id" => "state:1", "kind" => "state_set", "result" => "ok"})
    {:complete, result, _final} = boundary(next)
    assert result["items"] == [request["value"]]
  end

  test "set one object retains original aliases own undefined NaN bits and UTF16 through pretty serialization" do
    nan = number("7ff8000000000042")
    lone = %{"type" => "string", "utf16le" => "ANg="}
    {shared, heap} = Value.object([{"n", nan}, {"omitted", Value.undefined()}], Value.new())

    {root, heap} =
      Value.object(
        [
          {"right", shared},
          {"left", shared},
          {lone, %{"type" => "string", "utf16le" => "/98="}},
          {"zero", number("8000000000000000")}
        ],
        heap
      )

    {:request, request, pending} = boundary(new("state.set exact", [root], heap))

    assert_write(
      request,
      "state:1",
      "state_set",
      "exact",
      0,
      "{\n  \"right\": {\n    \"n\": null\n  },\n  \"left\": {\n    \"n\": null\n  },\n  \"\\ud800\": \"\\udfff\",\n  \"zero\": 0\n}\n"
    )

    assert request["value"] == root
    assert pending["heap"]["nodes"][root["id"]] == heap["nodes"][root["id"]]
    assert pending["heap"]["nodes"][shared["id"]] == heap["nodes"][shared["id"]]
    next = acknowledge(pending, %{"id" => "state:1", "kind" => "state_set", "result" => "ok"})
    {:complete, result, final} = boundary(next)
    assert result["items"] == [root]
    assert Value.object_get(root, "left", final["heap"]) == shared
    assert Value.object_get(root, "right", final["heap"]) == shared
    assert Value.object_get(shared, "n", final["heap"]) == nan
    assert Value.object_keys(shared, final["heap"]) == ["n", "omitted"]
    assert Value.object_fetch!(shared, "omitted", final["heap"]) == Value.undefined()
  end

  test "set one undefined writes source literal undefined newline and returns undefined unchanged" do
    {:request, request, pending} = boundary(new("state.set undefined", [Value.undefined()]))
    assert_write(request, "state:1", "state_set", "undefined", 0, "undefined\n")
    assert request["value"] == Value.undefined()
    next = acknowledge(pending, %{"id" => "state:1", "kind" => "state_set", "result" => "ok"})
    {:complete, result, _final} = boundary(next)
    assert result["items"] == [Value.undefined()]
  end

  test "set one array retains its original root rather than wrapping or flattening it" do
    {object, heap} = Value.object([{"x", number("3ff0000000000000")}], Value.new())
    {root, heap} = Value.array([object, object], heap)
    {:request, request, pending} = boundary(new("state.set array", [root], heap))

    assert_write(
      request,
      "state:1",
      "state_set",
      "array",
      0,
      "[\n  {\n    \"x\": 1\n  },\n  {\n    \"x\": 1\n  }\n]\n"
    )

    assert request["value"] == root
    next = acknowledge(pending, %{"id" => "state:1", "kind" => "state_set", "result" => "ok"})
    {:complete, result, final} = boundary(next)
    assert result["items"] == [root]
    assert Value.array_items(root, final["heap"]) == [object, object]
  end

  test "set many input allocates a dense ordered array retaining repeated original roots" do
    {shared, heap} = Value.object([{"x", number("4008000000000000")}], Value.new())
    items = [shared, Value.undefined(), shared, number("8000000000000000")]
    {:request, request, pending} = boundary(new("state.set many", items, heap))

    assert_write(
      request,
      "state:1",
      "state_set",
      "many",
      0,
      "[\n  {\n    \"x\": 3\n  },\n  null,\n  {\n    \"x\": 3\n  },\n  0\n]\n"
    )

    assert request["value"] != shared
    assert Value.array_items(request["value"], pending["heap"]) == items
    assert input(pending)["cursor"] == 4
    assert input(pending)["completed"] == true
    next = acknowledge(pending, %{"id" => "state:1", "kind" => "state_set", "result" => "ok"})
    {:complete, result, final} = boundary(next)
    assert result["items"] == [request["value"]]
    assert Value.array_items(hd(result["items"]), final["heap"]) == items
  end

  test "set drains lazy assignments before downstream head zero is constructed" do
    {one, heap} = Value.object([{"n", number("3ff0000000000000")}], Value.new())
    {two, heap} = Value.object([{"n", number("4000000000000000")}], heap)

    {:request, request, pending} =
      boundary(new("map 'seen={{n}}' | state.set eager | head --n 0", [one, two], heap))

    assert_write(
      request,
      "state:1",
      "state_set",
      "eager",
      1,
      "[\n  {\n    \"n\": 1,\n    \"seen\": \"1\"\n  },\n  {\n    \"n\": 2,\n    \"seen\": \"2\"\n  }\n]\n"
    )

    assert Value.array_items(request["value"], pending["heap"]) == [one, two]
    assert input(pending)["completed"] == true
    assert pending["stage_index"] == 1
    assert Enum.map(pending["frames"], & &1["name"]) == ["map", "state.set"]
    assert Value.object_get(one, "seen", pending["heap"]) == string("1")
    assert Value.object_get(two, "seen", pending["heap"]) == string("2")
    next = acknowledge(pending, %{"id" => "state:1", "kind" => "state_set", "result" => "ok"})
    {:complete, result, _final} = boundary(next)
    assert result["items"] == []
  end

  test "set finite scalars use exact source pretty bytes with one terminal newline" do
    for {value, text} <- [
          {%{"type" => "null"}, "null\n"},
          {number("8000000000000000"), "0\n"},
          {number("444b1ae4d6e2ef50"), "1e+21\n"},
          {number("3e7ad7f29abcaf48"), "1e-7\n"},
          {string("雪😀\n"), "\"雪😀\\n\"\n"}
        ] do
      {:request, request, pending} = boundary(new("state.set scalar", [value]))
      assert_write(request, "state:1", "state_set", "scalar", 0, text)
      assert request["value"] == value
      next = acknowledge(pending, %{"id" => "state:1", "kind" => "state_set", "result" => "ok"})
      {:complete, result, _final} = boundary(next)
      assert result["items"] == [value]
    end
  end

  test "diff drains before downstream head zero even when stable comparison is unchanged" do
    {root, heap} = Value.object([{"n", number("3ff0000000000000")}], Value.new())

    {:request, request, pending} =
      boundary(
        new(
          "map 'seen={{n}}' | diff.last fallback --key 'Selected Key' | head --n 0",
          [root],
          heap
        )
      )

    assert_write(
      request,
      "state:1",
      "state_diff",
      "Selected Key",
      1,
      "{\n  \"n\": 1,\n  \"seen\": \"1\"\n}\n"
    )

    assert request["value"] == root
    assert input(pending)["completed"] == true
    assert Enum.map(pending["frames"], & &1["name"]) == ["map", "diff.last"]

    next =
      acknowledge(pending, %{
        "id" => "state:1",
        "kind" => "state_diff",
        "result" => "ok",
        "before_text" => "{\"seen\":\"1\",\"n\":1}\n",
        "changed" => false
      })

    {:complete, result, _final} = boundary(next)
    assert result["items"] == []
  end

  test "diff unchanged sorts nested UTF16 keys normalizes zero and retains ordered original after" do
    lone = %{"type" => "string", "utf16le" => "ANg="}

    {nested, heap} =
      Value.object(
        [{"b", number("4000000000000000")}, {"a", number("3ff0000000000000")}],
        Value.new()
      )

    {root, heap} =
      Value.object(
        [
          {"z", nested},
          {"\uE000", string("private")},
          {"😀", string("face")},
          {lone, string("lead")},
          {"zero", number("8000000000000000")}
        ],
        heap
      )

    {:request, request, pending} = boundary(new("diff.last snap", [root], heap))

    assert_write(
      request,
      "state:1",
      "state_diff",
      "snap",
      0,
      "{\n  \"z\": {\n    \"b\": 2,\n    \"a\": 1\n  },\n  \"\uE000\": \"private\",\n  \"😀\": \"face\",\n  \"\\ud800\": \"lead\",\n  \"zero\": 0\n}\n"
    )

    assert request["value"] == root

    next =
      acknowledge(pending, %{
        "id" => "state:1",
        "kind" => "state_diff",
        "result" => "ok",
        "before_text" =>
          ~S({"zero":0,"\ud800":"lead","😀":"face","\ue000":"private","z":{"a":1,"b":2}}),
        "changed" => false
      })

    {:complete, result, final} = boundary(next)
    assert [record] = result["items"]
    before = assert_diff(record, final["heap"], "snap", false, root)
    assert before != root

    assert_json(
      before,
      final["heap"],
      ~S({"zero":0,"\ud800":"lead","😀":"face","":"private","z":{"a":1,"b":2}})
    )

    assert Value.object_get(root, "z", final["heap"]) == nested
    assert Value.object_get(root, "zero", final["heap"]) == number("8000000000000000")
    assert Value.object_keys(root, final["heap"]) == ["z", "\uE000", "😀", lone, "zero"]
  end

  test "diff array order changes while before is freshly parsed and after keeps original members" do
    {array, heap} =
      Value.array([number("4000000000000000"), number("3ff0000000000000")], Value.new())

    {root, heap} = Value.object([{"n", number("8000000000000000")}, {"a", array}], heap)
    {:request, request, pending} = boundary(new("diff.last --key one", [root], heap))

    assert_write(
      request,
      "state:1",
      "state_diff",
      "one",
      0,
      "{\n  \"n\": 0,\n  \"a\": [\n    2,\n    1\n  ]\n}\n"
    )

    next =
      acknowledge(pending, %{
        "id" => "state:1",
        "kind" => "state_diff",
        "result" => "ok",
        "before_text" => "{\"a\":[1,2],\"n\":0}\n",
        "changed" => true
      })

    {:complete, result, final} = boundary(next)
    assert [record] = result["items"]
    before = assert_diff(record, final["heap"], "one", true, root)
    assert_json(before, final["heap"], ~S({"a":[1,2],"n":0}))
    assert Value.object_get(before, "a", final["heap"]) != array
    assert Value.object_get(root, "a", final["heap"]) == array
    assert Value.object_get(root, "n", final["heap"]) == number("8000000000000000")
  end

  test "diff zero input creates separate empty before and after arrays with unchanged comparison" do
    {:request, request, pending} = boundary(new("diff.last empty", []))
    assert_write(request, "state:1", "state_diff", "empty", 0, "[]\n")
    assert Value.array_items(request["value"], pending["heap"]) == []

    next =
      acknowledge(pending, %{
        "id" => "state:1",
        "kind" => "state_diff",
        "result" => "ok",
        "before_text" => "[]\n",
        "changed" => false
      })

    {:complete, result, final} = boundary(next)
    assert [record] = result["items"]
    before = assert_diff(record, final["heap"], "empty", false, request["value"])
    assert before != request["value"]
    assert Value.array_items(before, final["heap"]) == []
  end

  test "diff many input allocates ordered after once and retains original nested identity" do
    {object, heap} = Value.object([{"x", number("4008000000000000")}], Value.new())
    items = [number("3ff0000000000000"), object]
    {:request, request, pending} = boundary(new("diff.last many", items, heap))

    assert_write(
      request,
      "state:1",
      "state_diff",
      "many",
      0,
      "[\n  1,\n  {\n    \"x\": 3\n  }\n]\n"
    )

    assert Value.array_items(request["value"], pending["heap"]) == items

    next =
      acknowledge(pending, %{
        "id" => "state:1",
        "kind" => "state_diff",
        "result" => "ok",
        "before_text" => "[1,2]\n",
        "changed" => true
      })

    {:complete, result, final} = boundary(next)
    assert [record] = result["items"]
    before = assert_diff(record, final["heap"], "many", true, request["value"])
    assert_json(before, final["heap"], "[1,2]")
    assert Value.array_items(request["value"], final["heap"]) == items
  end

  test "diff successful overflow before compares as null without losing its imported Infinity" do
    {root, heap} = Value.object([{"number", %{"type" => "null"}}], Value.new())
    {:request, request, pending} = boundary(new("diff.last overflow", [root], heap))
    assert_write(request, "state:1", "state_diff", "overflow", 0, "{\n  \"number\": null\n}\n")

    next =
      acknowledge(pending, %{
        "id" => "state:1",
        "kind" => "state_diff",
        "result" => "ok",
        "before_text" => "{\"number\":1e400}\n",
        "changed" => false
      })

    {:complete, result, final} = boundary(next)
    assert [record] = result["items"]
    before = assert_diff(record, final["heap"], "overflow", false, root)
    assert Value.object_get(before, "number", final["heap"]) == number("7ff0000000000000")
    assert Value.object_get(root, "number", final["heap"]) == %{"type" => "null"}
  end

  test "diff null named key falls back to the original positional key in trusted parsed stages" do
    assert {:ok, [stage]} = Pipeline.parse("diff.last 'Fallback Key/A'")
    # Trusted source-stage input represents args.key === null; this does not
    # introduce a public parser/producer for null-valued command arguments.
    stage = put_in(stage, ["args", "key"], nil)

    assert {:ok, state} =
             Machine.new(
               [stage],
               %{"kind" => "iterator_items", "items" => [string("same")]},
               Value.new(),
               %{"render_output" => false}
             )

    {:request, request, pending} = boundary(roundtrip(state))
    assert_write(request, "state:1", "state_diff", "Fallback Key/A", 0, "\"same\"\n")

    next =
      acknowledge(pending, %{
        "id" => "state:1",
        "kind" => "state_diff",
        "result" => "ok",
        "before_text" => "\"same\"\n",
        "changed" => false
      })

    {:complete, result, final} = boundary(next)
    assert [record] = result["items"]

    assert assert_diff(record, final["heap"], "Fallback Key/A", false, string("same")) ==
             string("same")
  end

  test "get to set keeps raw source keys and fresh get identity without filename normalization" do
    {:request, get, pending} =
      boundary(
        new("state.get 'A B' --key ignored | state.set 'a_b' --key ignored", [string("unused")])
      )

    assert get == %{"id" => "state:1", "kind" => "state_get", "key" => "A B", "stage_index" => 0}

    next =
      acknowledge(pending, %{
        "id" => "state:1",
        "kind" => "state_get",
        "result" => "ok",
        "text" => "{\"b\":2,\"a\":1}\n"
      })

    {:request, set, pending} = boundary(next)
    assert_write(set, "state:2", "state_set", "a_b", 1, "{\n  \"b\": 2,\n  \"a\": 1\n}\n")
    first_frame = hd(pending["frames"])
    assert pending["streams"][first_frame["output"]]["items"] == [set["value"]]
    next = acknowledge(pending, %{"id" => "state:2", "kind" => "state_set", "result" => "ok"})
    {:complete, result, final} = boundary(next)
    assert result["items"] == [set["value"]]
    assert input(final)["started"] == false
  end

  test "successive get set diff set share one counter and consumed state operations are not reissued" do
    {:request, get, pending} =
      boundary(new("state.get start | state.set middle | diff.last end | state.set summary", []))

    assert get == %{
             "id" => "state:1",
             "kind" => "state_get",
             "key" => "start",
             "stage_index" => 0
           }

    next =
      acknowledge(pending, %{
        "id" => "state:1",
        "kind" => "state_get",
        "result" => "ok",
        "text" => "1\n"
      })

    {:request, set, pending} = boundary(next)
    assert_write(set, "state:2", "state_set", "middle", 1, "1\n")
    assert set["value"] == number("3ff0000000000000")
    next = acknowledge(pending, %{"id" => "state:2", "kind" => "state_set", "result" => "ok"})
    {:request, diff, pending} = boundary(next)
    assert_write(diff, "state:3", "state_diff", "end", 2, "1\n")

    next =
      acknowledge(pending, %{
        "id" => "state:3",
        "kind" => "state_diff",
        "result" => "ok",
        "before_text" => "0\n",
        "changed" => true
      })

    {:request, summary, pending} = boundary(next)

    assert_write(
      summary,
      "state:4",
      "state_set",
      "summary",
      3,
      "{\n  \"kind\": \"diff.last\",\n  \"key\": \"end\",\n  \"changed\": true,\n  \"before\": 0,\n  \"after\": 1\n}\n"
    )

    assert assert_diff(summary["value"], pending["heap"], "end", true, number("3ff0000000000000")) ==
             number("0000000000000000")

    next = acknowledge(pending, %{"id" => "state:4", "kind" => "state_set", "result" => "ok"})
    {:complete, result, final} = boundary(next)
    assert result["items"] == [summary["value"]]
    assert final["next_request"] == 5
    assert final["pending_request"] == nil
    assert Machine.advance(roundtrip(final)) == {:complete, result, final}
  end

  test "successful same stage ask resumes a fresh slice without reissuing consumed state commands" do
    assert_checkpoint_resume("", "same_stage", ["ask", "state.set", "diff.last"])
  end

  test "successful next stage ask resumes a fresh slice without reissuing consumed state commands" do
    assert_checkpoint_resume(" --emit", "next_stage", ["state.set", "diff.last"])
  end

  defp assert_checkpoint_resume(flag, mode, suffix) do
    with_session(fn session ->
      pipeline =
        "state.get initial | state.set before | ask --prompt Review --schema '{\"type\":\"string\"}' --subject-from-stdin" <>
          flag <> " | state.set reply | diff.last baseline"

      {:request, get, pending} = boundary(new(pipeline, []))

      assert get == %{
               "id" => "state:1",
               "kind" => "state_get",
               "key" => "initial",
               "stage_index" => 0
             }

      next =
        acknowledge(pending, %{
          "id" => "state:1",
          "kind" => "state_get",
          "result" => "ok",
          "text" => "\"ready\"\n"
        })

      {:request, set, pending} = boundary(next)
      assert_write(set, "state:2", "state_set", "before", 1, "\"ready\"\n")
      next = acknowledge(pending, %{"id" => "state:2", "kind" => "state_set", "result" => "ok"})
      {{:checkpoint, checkpoint, saved}, before_schema} = schema_boundary(next, session)
      assert checkpoint["mode"] == mode
      assert checkpoint["stage_index"] == 2
      assert before_schema != []
      assert Enum.all?(before_schema, &(&1["kind"] == "compile_schema"))
      assert {:ok, text} = WorkflowJSON.stringify(checkpoint["request"], saved["heap"])
      envelope = Jason.decode!(text)
      assert envelope["prompt"] == "Review"
      assert envelope["responseSchema"] == %{"type" => "string"}
      assert envelope["subject"] == %{"text" => "ready"}
      assert envelope["items"] == if(mode == "same_stage", do: [], else: ["ready"])
      assert {:ok, resumed} = Machine.resume(roundtrip(saved), string("accepted"))
      resumed = roundtrip(resumed)
      assert resumed["frames"] == []
      assert resumed["segment"] == 1
      assert resumed["stage_index"] == 0
      assert resumed["next_request"] == saved["next_request"]
      assert Enum.map(resumed["program"], & &1["name"]) == suffix
      {{:request, reply, pending}, after_schema} = schema_boundary(resumed, session)
      assert Enum.any?(after_schema, &(&1["kind"] == "validate_response"))
      reply_index = if mode == "same_stage", do: 1, else: 0

      assert_write(
        reply,
        "state:" <> Integer.to_string(pending["next_request"] - 1),
        "state_set",
        "reply",
        reply_index,
        "\"accepted\"\n"
      )

      # Only this literal semantic fixture ACKs the newly pending state write.
      next = acknowledge(pending, %{"id" => reply["id"], "kind" => "state_set", "result" => "ok"})
      {:request, diff, pending} = boundary(next)

      assert_write(
        diff,
        "state:" <> Integer.to_string(pending["next_request"] - 1),
        "state_diff",
        "baseline",
        reply_index + 1,
        "\"accepted\"\n"
      )

      assert diff["value"] == reply["value"]

      next =
        acknowledge(pending, %{
          "id" => diff["id"],
          "kind" => "state_diff",
          "result" => "ok",
          "before_text" => "\"old\"\n",
          "changed" => true
        })

      {:complete, result, final} = boundary(next)
      assert [record] = result["items"]

      assert assert_diff(record, final["heap"], "baseline", true, string("accepted")) ==
               string("old")

      if mode == "same_stage", do: assert(final["resume_input"]["consumed"] == true)
      all_requests = [get, set] ++ before_schema ++ after_schema ++ [reply, diff]
      assert Enum.map(all_requests, &request_number/1) == Enum.to_list(1..length(all_requests))
      assert final["next_request"] == length(all_requests) + 1
    end)
  end

  defp assert_write(request, id, kind, key, index, text) do
    assert Map.keys(request) |> Enum.sort() == [
             "id",
             "key",
             "kind",
             "stage_index",
             "text",
             "value"
           ]

    assert request["id"] == id
    assert request["kind"] == kind
    assert request["key"] == key
    assert request["stage_index"] == index
    assert request["text"] == text
  end

  defp assert_diff(record, heap, key, changed, after_root) do
    assert record["type"] == "reference"
    assert record != after_root
    assert Value.object_keys(record, heap) == ["kind", "key", "changed", "before", "after"]
    assert Value.object_get(record, "kind", heap) == string("diff.last")
    assert Value.object_get(record, "key", heap) == string(key)
    assert Value.object_get(record, "changed", heap) == %{"type" => "boolean", "value" => changed}
    assert Value.object_get(record, "after", heap) == after_root
    Value.object_fetch!(record, "before", heap)
  end

  defp assert_json(value, heap, literal),
    do: assert(WorkflowJSON.stringify(value, heap) == {:ok, literal})

  defp number(bits), do: %{"type" => "number", "bits" => bits}
  defp string(text), do: %{"type" => "string", "value" => text}
  defp input(state), do: state["streams"][state["input_stream"]]

  defp request_number(request),
    do: request["id"] |> String.split(":") |> List.last() |> String.to_integer()

  defp new(program, items, heap \\ Value.new()) do
    assert {:ok, parsed} = Pipeline.parse(program)

    assert {:ok, state} =
             Machine.new(parsed, %{"kind" => "iterator_items", "items" => items}, heap, %{
               "render_output" => false
             })

    roundtrip(state)
  end

  defp roundtrip(value) do
    restored = value |> Jason.encode!() |> Jason.decode!()
    assert restored == value
    restored
  end

  # Advances pure transitions only. A state request always returns to its test;
  # there is no state backend or generic fabricated effect-fulfillment driver.
  defp boundary(state, remaining \\ 4_000)
  defp boundary(_state, 0), do: flunk("ordinary transition bound exceeded")

  defp boundary(state, remaining) do
    case Machine.advance(roundtrip(state)) do
      {:continue, next} ->
        boundary(roundtrip(next), remaining - 1)

      {:request, request, pending} ->
        pending = roundtrip(pending)
        assert Machine.advance(roundtrip(pending)) == {:request, request, pending}
        {:request, request, pending}

      {:complete, result, final} ->
        {:complete, result, roundtrip(final)}

      {:checkpoint, checkpoint, saved} ->
        {:checkpoint, checkpoint, roundtrip(saved)}

      other ->
        flunk("unexpected ordinary transition: #{inspect(other)}")
    end
  end

  defp acknowledge(pending, literal_fixture) do
    request = pending["pending_request"]
    assert literal_fixture["id"] == request["id"]
    assert literal_fixture["kind"] == request["kind"]
    assert pending["request_phase"] == "construct"
    assert pending["phase"] == "request"
    assert pending["next_request"] == request_number(request) + 1
    assert {:continue, next} = Machine.advance(roundtrip(pending), roundtrip(literal_fixture))
    next = roundtrip(next)
    assert next["pending_request"] == nil
    assert next["phase"] == "construct"
    assert next["next_request"] == pending["next_request"]
    next
  end

  defp schema_boundary(state, session, requests \\ []) do
    case boundary(state) do
      {:request, %{"kind" => kind} = request, pending}
      when kind in ["compile_schema", "validate_response"] ->
        assert {:continue, next} = Schema.advance_pending(session, pending, @timeout)
        assert %{phase: :idle} = PortSession.status(session)
        schema_boundary(roundtrip(next), session, requests ++ [request])

      result ->
        {result, requests}
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
