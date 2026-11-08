defmodule Synapsis.Workflow.UTF16ImportKeyFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workflow.{Machine, Pipeline, Schema, Template, Value}
  alias Synapsis.Workflow.JSON, as: WorkflowJSON
  alias Synapsis.Workflow.Schema.PortSession

  @root Path.expand("../../../../..", __DIR__)
  @high %{"type" => "string", "utf16le" => "Pdg="}
  @low %{"type" => "string", "utf16le" => "AN4="}
  @response ~S({"\ud83d":"\ude00","Pdg=":"ordinary","nested":{"\ude00":"\ud83d"}})
  @projection "{\n  \"\\ud83d\": \"\\ude00\",\n  \"Pdg=\": \"ordinary\",\n  \"nested\": {\n    \"\\ude00\": \"\\ud83d\"\n  }\n}"
  @schema ~S({"type":"object","required":["\ud83d"]})
  @moduletag timeout: 180_000

  # These successful literals precede product changes. No production parser,
  # key sorter or JSON formatter constructs the expected units/order/text.
  @strings [
    {~S("\ud83d"), [55357], ~S("\ud83d")},
    {~S("\ude00"), [56832], ~S("\ude00")},
    {~S("\uD83D\uDE00"), [55357, 56832], ~s("😀")},
    {~s("😀"), [55357, 56832], ~s("😀")},
    {~S("\ud83d\ud83d\ude00\ude00"), [55357, 55357, 56832, 56832], ~S("\ud83d😀\ude00")},
    {~S("\ud800A\udfff"), [55296, 65, 57343], ~S("\ud800A\udfff")},
    {~S("\\ud83d"), [92, 117, 100, 56, 51, 100], ~S("\\ud83d")},
    {~S("\u0000\b\t\n\f\r\"\\\/"), [0, 8, 9, 10, 12, 13, 34, 92, 47],
     ~S("\u0000\b\t\n\f\r\"\\/")},
    {~s("雪😀"), [38634, 55357, 56832], ~s("雪😀")},
    {~S(""), [], ~S("")}
  ]

  for {input, expected_units, expected_json} <- @strings do
    @input input
    @units expected_units
    @json expected_json
    test "raw JSON imports exact root and nested string units: #{inspect(input)}" do
      assert {:ok, root, heap} = Value.decode_json(@input)
      if @input == ~S("\ud83d"), do: assert(root == @high)
      if @input == ~S("\ude00"), do: assert(root == @low)
      if @units == [55357, 56832], do: assert(root == string("😀"))
      assert units(root) == @units
      assert WorkflowJSON.stringify(root, heap) == {:ok, @json}
      assert {:ok, nested, nested_heap} = Value.decode_json("{\"v\":[" <> @input <> "]}")
      array = Value.object_get(nested, "v", nested_heap)
      assert [^root] = Value.array_items(array, nested_heap)
      assert WorkflowJSON.stringify(nested, nested_heap) == {:ok, "{\"v\":[" <> @json <> "]}"}
      assert roundtrip(%{"root" => root, "heap" => heap}) == %{"root" => root, "heap" => heap}
    end
  end

  test "masking keeps positional string and key patches distinct from ordinary NUL and escape-looking data" do
    raw =
      ~S({"\ud83d":"\ude00","\u0000":"\ud83d","\\ud83d":"\u0000","":"\ud800","﷐":"\udfff","\ude00":"\\ude00"})

    assert {:ok, root, heap} = Value.decode_json(raw)
    assert Value.object_keys(root, heap) == [@high, <<0>>, "\\ud83d", "", "﷐", @low]
    assert Value.object_get(root, @high, heap) == @low
    assert Value.object_get(root, <<0>>, heap) == @high
    assert Value.object_get(root, "\\ud83d", heap) == string(<<0>>)
    assert units(Value.object_get(root, "", heap)) == [55296]
    assert units(Value.object_get(root, "﷐", heap)) == [57343]
    assert Value.object_get(root, @low, heap) == string("\\ude00")
    assert WorkflowJSON.stringify(root, heap) == {:ok, raw}
  end

  test "duplicate escape-equivalent names replace values at first positions with numeric enumeration" do
    raw =
      ~S({"z":0,"\uD83D":"first","2":"two","\ud83d":"last","10":"ten","a":1,"\u0061":2,"😀":"raw","\ud83d\ude00":"pair-last","Pdg=":"ordinary"})

    assert {:ok, root, heap} = Value.decode_json(raw)
    assert Value.object_keys(root, heap) == ["2", "10", "z", @high, "a", "😀", "Pdg="]
    assert Value.object_fetch!(root, @high, heap) == string("last")
    assert Value.object_fetch!(root, string("a"), heap) == number("4000000000000000")
    assert Value.object_fetch!(root, string("😀"), heap) == string("pair-last")

    assert WorkflowJSON.stringify(root, heap) ==
             {:ok,
              ~S({"2":"two","10":"ten","z":0,"\ud83d":"last","a":2,"😀":"pair-last","Pdg=":"ordinary"})}

    assert WorkflowJSON.pretty(root, heap) ==
             {:ok,
              "{\n  \"2\": \"two\",\n  \"10\": \"ten\",\n  \"z\": 0,\n  \"\\ud83d\": \"last\",\n  \"a\": 2,\n  \"😀\": \"pair-last\",\n  \"Pdg=\": \"ordinary\"\n}"}
  end

  test "member names retain empty control raw astral and unpaired sequences" do
    assert {:ok, root, heap} =
             Value.decode_json(
               ~S({"":0,"\u0000":1,"a\tb":2,"\ud800A\udfff":3,"\ud83d\ud83d\ude00\ude00":4,"雪😀":5})
             )

    assert Enum.map(Value.object_keys(root, heap), &units(Value.key_string(&1))) == [
             [],
             [0],
             [97, 9, 98],
             [55296, 65, 57343],
             [55357, 55357, 56832, 56832],
             [38634, 55357, 56832]
           ]

    assert WorkflowJSON.stringify(root, heap) ==
             {:ok, ~S({"":0,"\u0000":1,"a\tb":2,"\ud800A\udfff":3,"\ud83d😀\ude00":4,"雪😀":5})}
  end

  test "binary and canonical tagged selectors share equality while encoded and ordinary namespaces stay distinct" do
    {root, heap} =
      Value.object(
        [
          {"Pdg=", string("literal")},
          {@high, @low},
          {string("a"), string("old")},
          {"a", string("new")},
          {"fields_utf16le", string("data")}
        ],
        Value.new()
      )

    assert Value.object_keys(root, heap) == ["Pdg=", @high, "a", "fields_utf16le"]

    assert heap["nodes"][root["id"]] == %{
             "type" => "object",
             "keys" => ["Pdg=", @high, "a", "fields_utf16le"],
             "fields" => %{
               "Pdg=" => string("literal"),
               "a" => string("new"),
               "fields_utf16le" => string("data")
             },
             "fields_utf16le" => %{"Pdg=" => @low}
           }

    changed =
      heap
      |> then(&Value.object_put(root, string("a"), string("updated"), &1))
      |> then(&Value.object_put(root, @high, string("high"), &1))
      |> then(&Value.object_put(root, @low, string("low"), &1))

    assert Value.object_keys(root, changed) == ["Pdg=", @high, "a", "fields_utf16le", @low]
    assert Value.object_get(root, "Pdg=", changed) == string("literal")
    assert Value.object_get(root, @high, changed) == string("high")
    assert Value.object_get(root, string("a"), changed) == string("updated")
    assert Value.object_get(root, @low, changed) == string("low")
    assert Value.key_string("😀") == string("😀")
    assert Value.key_string(@high) == @high

    for {selector, expected} <- [
          {"0", 0},
          {string("2"), 2},
          {"4294967294", 4_294_967_294},
          {"4294967295", nil},
          {"01", nil},
          {@high, nil}
        ],
        do: assert(Value.key_index(selector) == expected)

    {ordinary, ordinary_heap} = Value.object([{string("a"), @high}], Value.new())

    assert ordinary_heap["nodes"][ordinary["id"]] == %{
             "type" => "object",
             "keys" => ["a"],
             "fields" => %{"a" => @high}
           }

    assert roundtrip(changed) == changed
  end

  test "stable UTF16 name sort preserves index enumeration and distinguishes lone-prefix pair low and BMP" do
    assert {:ok, root, heap} =
             Value.decode_json(
               ~S({"":0,"\ude00":1,"😀":2,"\ud83dA":3,"\ud83d":4,"a":5,"10":6,"2":7,"01":8,"4294967295":9,"4294967294":10})
             )

    assert Value.object_keys(root, heap) == [
             "2",
             "10",
             "4294967294",
             "",
             @low,
             "😀",
             %{"type" => "string", "utf16le" => "PdhBAA=="},
             @high,
             "a",
             "01",
             "4294967295"
           ]

    assert WorkflowJSON.stable_stringify(root, heap) ==
             {:ok,
              ~S({"2":7,"10":6,"4294967294":10,"01":8,"4294967295":9,"a":5,"\ud83d":4,"\ud83dA":3,"😀":2,"\ude00":1,"":0})}
  end

  test "strict snapshots retain names and independent alias copies without changing original nodes" do
    assert {:ok, shared, heap} = Value.decode_json(@response)
    {root, heap} = Value.array([shared, shared, number("8000000000000000")], heap)
    original = heap["nodes"]
    assert {:ok, copy, copied} = WorkflowJSON.snapshot(root, heap)
    [left, right, zero] = Value.array_items(copy, copied)
    assert left != right and left != shared and right != shared
    assert zero == number("0000000000000000")
    assert Value.object_keys(left, copied) == [@high, "Pdg=", "nested"]
    assert Value.object_get(left, @high, copied) == @low
    assert Map.take(copied["nodes"], Map.keys(original)) == original
    changed = Value.object_put(left, @high, string("copy"), copied)
    assert Value.object_get(right, @high, changed) == @low
    assert Value.object_get(shared, @high, changed) == @low

    assert roundtrip(%{"roots" => [root, copy], "heap" => changed}) == %{
             "roots" => [root, copy],
             "heap" => changed
           }
  end

  test "finite number and signed zero lexemes survive alongside surrogate patches" do
    assert {:ok, root, heap} =
             Value.decode_json(~S(["\ud83d",-0,-0e2,-0.0,0,9007199254740993,1e23,1e-7,0.1]))

    assert Value.array_items(root, heap) == [
             @high,
             number("8000000000000000"),
             number("8000000000000000"),
             number("8000000000000000"),
             number("0000000000000000"),
             number("4340000000000000"),
             number("44b52d02c7e14af6"),
             number("3e7ad7f29abcaf48"),
             number("3fb999999999999a")
           ]

    assert WorkflowJSON.stringify(root, heap) ==
             {:ok, ~S(["\ud83d",0,0,0,0,9007199254740992,1e+23,1e-7,0.1])}
  end

  test "Machine map mutation and wrapping preserve exact arbitrary siblings and shared references" do
    assert {:ok, item, heap} = Value.decode_json(~S({"\ud83d":"\ude00","v":"A"}))

    {:complete, result, final, []} =
      drive(machine("map 'v={{v}}!' | map --wrap record", [item, item], heap))

    [left, right] = result["items"]
    assert Value.object_get(left, "record", final["heap"]) == item
    assert Value.object_get(right, "record", final["heap"]) == item
    assert Value.object_get(item, "v", final["heap"]) == string("A!!")
    assert Value.object_get(item, @high, final["heap"]) == @low
    assert Value.object_keys(item, final["heap"]) == [@high, "v"]
  end

  test "table exact lone and astral headers replace units only at the stdout sink" do
    assert {:ok, array, heap} = Value.decode_json(~S([{"\ud83d":"\ude00","😀":"X","a\nb":"Y"}]))
    roots = Value.array_items(array, heap)

    {:complete, result, final, []} =
      drive(machine("table", roots, heap, %{"render_output" => true}))

    assert result == %{
             "items" => [],
             "rendered" => true,
             "rendered_items" => [],
             "stdout" => "�    😀   a b\n---  ---  ---\n�    X    Y  \n"
           }

    assert Map.take(final["heap"]["nodes"], Map.keys(heap["nodes"])) == heap["nodes"]
    assert String.valid?(result["stdout"])
  end

  test "actual helper validates required lone keys and resumes same and next checkpoints through JSON text" do
    with_session(fn session ->
      for {mode, flag} <- [{"same_stage", ""}, {"next_stage", " --emit"}] do
        state =
          machine(
            "ask --prompt Review --schema '" <>
              @schema <> "'" <> flag <> " | template --text '{{. | json}}'",
            [],
            Value.new()
          )

        {:checkpoint, checkpoint, saved, requests} = drive(state, session)
        assert checkpoint["mode"] == mode

        if mode == "same_stage" do
          assert checkpoint["command_input"]["pending"]["metadata"]["signature"] ==
                   ~S({"prompt":"Review","responseSchema":{"required":["\ud83d"],"type":"object"}})
        end

        assert Enum.any?(requests, &(&1["kind"] == "compile_schema"))
        assert {:ok, response, heap} = Value.decode_json(@response, saved["heap"])
        assert {:ok, resumed} = Machine.resume(%{saved | "heap" => heap}, response)
        {:complete, result, final, after_requests} = drive(resumed, session)
        assert result["items"] == [string(@projection)]
        assert Enum.any?(after_requests, &(&1["kind"] == "validate_response"))
        assert Enum.any?(after_requests, &(&1["kind"] == "render_template"))
        assert Value.object_keys(response, final["heap"]) == [@high, "Pdg=", "nested"]
        assert Value.object_get(response, @high, final["heap"]) == @low
        if mode == "same_stage", do: assert(final["resume_input"]["consumed"] == true)
      end
    end)
  end

  test "internal invoke imports exact raw argument and reply names without a native-map claim" do
    state =
      machine(
        "openclaw.invoke --tool fixture.echo --action echo --args-json '" <> @response <> "'",
        [],
        Value.new()
      )

    {:request, request, pending, []} = drive(state)

    assert request["body"] ==
             ~S({"tool":"fixture.echo","action":"echo","args":{"\ud83d":"\ude00","Pdg=":"ordinary","nested":{"\ude00":"\ud83d"}}})

    assert {:continue, next} =
             Machine.advance(roundtrip(pending), %{
               "id" => request["id"],
               "response_json" =>
                 ~S({"ok":true,"result":{"\ud83d":"\ude00","nested":{"\ude00":"\ud83d"}}})
             })

    {:complete, result, final, []} = drive(next)
    [item] = result["items"]
    assert Value.object_keys(item, final["heap"]) == [@high, "nested"]

    assert WorkflowJSON.stringify(item, final["heap"]) ==
             {:ok, ~S({"\ud83d":"\ude00","nested":{"\ude00":"\ud83d"}})}
  end

  defp units(value), do: for(<<unit::little-16 <- Value.to_utf16le(value)>>, do: unit)
  defp string(value), do: %{"type" => "string", "value" => value}
  defp number(bits), do: %{"type" => "number", "bits" => bits}

  defp roundtrip(value) do
    restored = Jason.decode!(Jason.encode!(value))
    assert restored === value
    restored
  end

  defp machine(pipeline, items, heap, options \\ %{}) do
    assert {:ok, program} = Pipeline.parse(pipeline)

    assert {:ok, state} =
             Machine.new(
               program,
               %{"kind" => "array", "items" => items},
               heap,
               Map.put_new(options, "render_output", false)
             )

    state
  end

  defp drive(state, session \\ nil, requests \\ [], remaining \\ 4_000)
  defp drive(_state, _session, _requests, 0), do: flunk("ordinary transition bound exceeded")

  defp drive(state, session, requests, remaining) do
    case Machine.advance(roundtrip(state)) do
      {:continue, next} ->
        drive(next, session, requests, remaining - 1)

      {:request, request, pending} when not is_nil(session) ->
        before_status = PortSession.status(session)

        transition =
          if request["kind"] == "render_template",
            do: Template.advance_pending(session, pending, 15_000),
            else: Schema.advance_pending(session, pending, 15_000)

        assert {:continue, next} = transition
        after_status = PortSession.status(session)
        if before_status.os_pid, do: assert(after_status.os_pid == before_status.os_pid)
        assert File.exists?("/proc/#{after_status.os_pid}")

        if request["kind"] == "render_template",
          do: assert(after_status.cache_entries == before_status.cache_entries)

        drive(next, session, requests ++ [request], remaining - 1)

      {:request, request, pending} ->
        {:request, request, roundtrip(pending), requests}

      {:checkpoint, checkpoint, saved} ->
        {:checkpoint, checkpoint, roundtrip(saved), requests}

      {:complete, result, final} ->
        {:complete, result, roundtrip(final), requests}

      other ->
        flunk("unexpected ordinary UTF16-key transition: #{inspect(other)}")
    end
  end

  defp with_session(run) do
    session =
      start_supervised!(
        {PortSession,
         owner_pid: self(),
         node_executable: System.find_executable("node"),
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
