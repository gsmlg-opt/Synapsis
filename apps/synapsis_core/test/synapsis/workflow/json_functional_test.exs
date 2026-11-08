defmodule Synapsis.Workflow.JSONFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workflow.JSON, as: WorkflowJSON
  alias Synapsis.Workflow.Value

  # Independent ordinary-success expectations, authored before JSON/capture code.
  # These are public JSON boundaries, not internal heap snapshots or native resume.
  @numbers [
    {"0", "0"},
    {"-0", "0"},
    {"42", "42"},
    {"-2.5", "-2.5"},
    {"0.1", "0.1"},
    {"0.30000000000000004", "0.30000000000000004"},
    {"1.25", "1.25"},
    {"1e-6", "0.000001"},
    {"9e-7", "9e-7"},
    {"1e-7", "1e-7"},
    {"1.234e-6", "0.000001234"},
    {"1.2e-7", "1.2e-7"},
    {"1e20", "100000000000000000000"},
    {"1e21", "1e+21"},
    {"1.234e21", "1.234e+21"},
    {"1e23", "1e+23"},
    {"1000000000000000128", "1000000000000000100"},
    {"9007199254740993", "9007199254740992"},
    {"1.2345678901234567", "1.2345678901234567"},
    {"-1e-6", "-0.000001"},
    {"-1e21", "-1e+21"},
    {"10e-0", "10"},
    {"1424953923781206.25", "1424953923781206.2"}
  ]

  @nested_input ~S({"title":"mail","items":[1,{"b":true,"empty":[]}],"nothing":{}})
  @nested_pretty """
                 {
                   "title": "mail",
                   "items": [
                     1,
                     {
                       "b": true,
                       "empty": []
                     }
                   ],
                   "nothing": {}
                 }
                 """
                 |> String.trim_trailing("\n")

  test "finite numbers choose exact shortest spelling and JavaScript decimal placement" do
    for {input, expected} <- @numbers do
      assert {:ok, value, heap} = Value.decode_json(input)
      assert WorkflowJSON.stringify(value, heap) == {:ok, expected}, input
      assert WorkflowJSON.pretty(value, heap) == {:ok, expected}, input
      assert WorkflowJSON.stable_stringify(value, heap) == {:ok, expected}, input
    end
  end

  test "strings preserve UTF-8 and literal escape-looking text with lowercase control escapes" do
    input = <<0, 8, 9, 10, 11, 12, 13, 14, 31>> <> " \"\\ /雪😀\u2028\u2029 literal \\u000B"

    expected =
      ~S("\u0000\b\t\n\u000b\f\r\u000e\u001f \"\\ /雪😀) <>
        "\u2028\u2029" <> ~S( literal \\u000B")

    value = string(input)
    heap = Value.new()
    assert WorkflowJSON.stringify(value, heap) == {:ok, expected}
    assert WorkflowJSON.pretty(value, heap) == {:ok, expected}
    assert WorkflowJSON.stable_stringify(value, heap) == {:ok, expected}
  end

  test "pretty output uses two spaces without a renderer newline and keeps empty shapes compact" do
    assert {:ok, value, heap} = Value.decode_json(@nested_input)
    assert WorkflowJSON.stringify(value, heap) == {:ok, @nested_input}
    assert WorkflowJSON.pretty(value, heap) == {:ok, @nested_pretty}

    for input <- ["{}", "[]", "null", "true", "false", ~S("mail")] do
      assert {:ok, value, heap} = Value.decode_json(input)
      assert WorkflowJSON.stringify(value, heap) == {:ok, input}
      assert WorkflowJSON.pretty(value, heap) == {:ok, input}
    end

    assert {:ok, value, heap} = Value.decode_json(~S([null,true,false,"mail",0,-0]))
    assert WorkflowJSON.stringify(value, heap) == {:ok, ~S([null,true,false,"mail",0,0])}
  end

  test "public undefined is omitted from objects and rendered as null in dense arrays" do
    heap = Value.new()
    undefined = Value.undefined()
    null = %{"type" => "null"}
    assert WorkflowJSON.stringify(undefined, heap) == {:ok, :undefined}
    assert WorkflowJSON.pretty(undefined, heap) == {:ok, :undefined}
    assert WorkflowJSON.stable_stringify(undefined, heap) == {:ok, :undefined}

    {object, heap} =
      Value.object([{"keep", null}, {"omit", undefined}, {"title", string("mail")}], heap)

    assert WorkflowJSON.stringify(object, heap) == {:ok, ~S({"keep":null,"title":"mail"})}

    assert WorkflowJSON.pretty(object, heap) ==
             {:ok, "{\n  \"keep\": null,\n  \"title\": \"mail\"\n}"}

    assert Value.object_keys(object, heap) == ["keep", "omit", "title"]

    {nested, heap} =
      Value.object([{"omit", undefined}, {"ok", %{"type" => "boolean", "value" => true}}], heap)

    {array, heap} = Value.array([undefined, null, nested], heap)
    assert WorkflowJSON.stringify(array, heap) == {:ok, ~S([null,null,{"ok":true}])}

    assert WorkflowJSON.pretty(array, heap) ==
             {:ok, "[\n  null,\n  null,\n  {\n    \"ok\": true\n  }\n]"}

    assert Value.array_items(array, heap) == [undefined, null, nested]
  end

  test "stable output sorts UTF-16 keys while index keys keep numeric enumeration" do
    # U+E000 precedes U+10000 in UTF-8 byte order, but follows it in UTF-16 order.
    input = ~S({"z":1,"10":"ten","2":"two","":"bmp","𐀀":"astral","a":2})
    compact = ~S({"2":"two","10":"ten","z":1,"":"bmp","𐀀":"astral","a":2})
    stable = ~S({"2":"two","10":"ten","a":2,"z":1,"𐀀":"astral","":"bmp"})
    assert {:ok, value, heap} = Value.decode_json(input)
    assert WorkflowJSON.stringify(value, heap) == {:ok, compact}
    assert WorkflowJSON.stable_stringify(value, heap) == {:ok, stable}
    assert Value.object_keys(value, heap) == ["2", "10", "z", "", "𐀀", "a"]
  end

  test "stable ordering recurses through objects while preserving array order" do
    input = ~S({"b":[{"z":1,"a":2},[{"y":3,"x":4}]],"a":{"d":4,"c":3}})
    expected = ~S({"a":{"c":3,"d":4},"b":[{"a":2,"z":1},[{"x":4,"y":3}]]})
    assert {:ok, value, heap} = Value.decode_json(input)
    assert WorkflowJSON.stringify(value, heap) == {:ok, input}
    assert WorkflowJSON.stable_stringify(value, heap) == {:ok, expected}
  end

  test "successful strict snapshots copy shared objects independently and normalize signed zero" do
    assert {:ok, shared, heap} = Value.decode_json(~S({"value":-0,"label":"mail"}))
    {source, heap} = Value.object([{"left", shared}, {"right", shared}], heap)
    original_heap = heap
    expected = ~S({"left":{"value":0,"label":"mail"},"right":{"value":0,"label":"mail"}})
    assert WorkflowJSON.stringify(source, heap) == {:ok, expected}

    assert {:ok, copy, copied_heap} = WorkflowJSON.snapshot(source, heap)
    assert heap == original_heap
    assert copy != source
    left = Value.object_get(copy, "left", copied_heap)
    right = Value.object_get(copy, "right", copied_heap)
    assert left != right
    assert left != shared
    assert right != shared
    assert Value.object_get(left, "value", copied_heap) == number("0000000000000000")
    assert Value.object_get(right, "value", copied_heap) == number("0000000000000000")
    assert Value.object_get(shared, "value", copied_heap) == number("8000000000000000")
    assert Value.object_get(source, "left", copied_heap) == shared
    assert Value.object_get(source, "right", copied_heap) == shared

    changed = Value.object_put(left, "label", string("edited"), copied_heap)
    edited = ~S({"left":{"value":0,"label":"edited"},"right":{"value":0,"label":"mail"}})
    assert WorkflowJSON.stringify(copy, changed) == {:ok, edited}
    assert WorkflowJSON.stringify(source, changed) == {:ok, expected}
    assert Value.object_get(right, "label", changed) == string("mail")
    assert Value.object_get(shared, "label", changed) == string("mail")

    {fresh, changed} = Value.array([copy, source], changed)
    assert fresh not in [source, copy, shared, left, right]
    assert Value.array_items(fresh, changed) == [copy, source]
  end

  defp string(value), do: %{"type" => "string", "value" => value}
  defp number(bits), do: %{"type" => "number", "bits" => bits}
end
