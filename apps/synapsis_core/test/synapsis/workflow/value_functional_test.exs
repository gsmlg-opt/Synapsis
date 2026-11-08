defmodule Synapsis.Workflow.ValueFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workflow.Value

  # Independently authored ordinary-success expectations for the typed heap.
  # These exercise container representation, not commands or JSON.stringify.
  test "undefined and null stay distinct while own undefined fields remain present" do
    heap = Value.new()
    assert {:ok, present, heap} = Value.decode_json("null", heap)
    undefined = Value.undefined()

    assert undefined == %{"type" => "undefined"}
    assert present == %{"type" => "null"}

    {object, heap} =
      Value.object(
        [{"missing", undefined}, {"present", present}, {"title", string("mail")}],
        heap
      )

    assert Value.object_keys(object, heap) == ["missing", "present", "title"]
    assert Value.object_get(object, "missing", heap) == undefined
    assert Value.object_get(object, "absent", heap) == undefined
    assert Value.object_get(object, "present", heap) == present
    assert Value.object_get(object, "title", heap) == string("mail")
  end

  test "JSON preserves duplicate-property position and ordinary-object key order" do
    input =
      ~S({"z":1,"10":"ten","2":"two","01":"leading","4294967294":"last-index","4294967295":"ordinary","z":2,"a":3})

    assert {:ok, object, heap} = Value.decode_json(input)

    assert Value.object_keys(object, heap) == [
             "2",
             "10",
             "4294967294",
             "z",
             "01",
             "4294967295",
             "a"
           ]

    assert Value.object_get(object, "z", heap) == number("4000000000000000")
    heap = Value.object_put(object, "z", number("4008000000000000"), heap)
    heap = Value.object_put(object, "1", string("one"), heap)
    heap = Value.object_put(object, "b", number("4010000000000000"), heap)

    assert Value.object_keys(object, heap) == [
             "1",
             "2",
             "10",
             "4294967294",
             "z",
             "01",
             "4294967295",
             "a",
             "b"
           ]

    assert Value.object_get(object, "z", heap) == number("4008000000000000")
    assert Value.object_get(object, "b", heap) == number("4010000000000000")
  end

  test "object construction keeps first insertion positions and numeric keys sort canonically" do
    {object, heap} =
      Value.object(
        [
          {"tail", string("old")},
          {"02", string("leading")},
          {"2", string("two")},
          {"0", string("zero")},
          {"tail", string("new")},
          {"end", string("last")}
        ],
        Value.new()
      )

    assert Value.object_keys(object, heap) == ["0", "2", "tail", "02", "end"]
    assert Value.object_get(object, "tail", heap) == string("new")
  end

  test "JSON numeric lexemes become binary64 bits including signed zero and rounding" do
    input = ~S([null,false,true,"雪😀",0,-0,0.1,9007199254740993,1e23,1e-7,-2.5,42])
    assert {:ok, array, heap} = Value.decode_json(input)

    assert Value.array_items(array, heap) == [
             %{"type" => "null"},
             %{"type" => "boolean", "value" => false},
             %{"type" => "boolean", "value" => true},
             string("雪😀"),
             number("0000000000000000"),
             number("8000000000000000"),
             number("3fb999999999999a"),
             number("4340000000000000"),
             number("44b52d02c7e14af6"),
             number("3e7ad7f29abcaf48"),
             number("c004000000000000"),
             number("4045000000000000")
           ]
  end

  test "nested arrays and tag-shaped JSON objects remain ordinary user values" do
    input = ~S([{"type":"undefined","value":null},["雪😀",false],null])
    assert {:ok, root, heap} = Value.decode_json(input)
    [tag_shaped, nested, null] = Value.array_items(root, heap)

    assert tag_shaped["type"] == "reference"
    assert Value.object_keys(tag_shaped, heap) == ["type", "value"]
    assert Value.object_get(tag_shaped, "type", heap) == string("undefined")
    assert Value.object_get(tag_shaped, "value", heap) == %{"type" => "null"}

    assert Value.array_items(nested, heap) == [
             string("雪😀"),
             %{"type" => "boolean", "value" => false}
           ]

    assert null == %{"type" => "null"}
  end

  test "aliases survive JSON snapshot restoration and later allocation remains independent" do
    assert {:ok, shared, heap} = Value.decode_json(~S({"count":1,"label":"old"}))
    {aliases, heap} = Value.array([shared, shared], heap)
    {wrapper, heap} = Value.object([{"item", shared}], heap)

    snapshot = %{"root" => shared, "aliases" => aliases, "wrapper" => wrapper, "heap" => heap}
    restored = snapshot |> Jason.encode!() |> Jason.decode!()
    assert restored == snapshot

    heap = restored["heap"]
    [left, right] = Value.array_items(restored["aliases"], heap)
    wrapped = Value.object_get(restored["wrapper"], "item", heap)
    assert left == restored["root"]
    assert right == left
    assert wrapped == left

    heap = Value.object_put(left, "label", string("updated"), heap)
    heap = Value.object_put(right, "echo", string("1"), heap)

    for reference <- [left, right, wrapped, restored["root"]] do
      assert Value.object_get(reference, "label", heap) == string("updated")
      assert Value.object_get(reference, "echo", heap) == string("1")
      assert Value.object_keys(reference, heap) == ["count", "label", "echo"]
    end

    assert {:ok, fresh, heap} = Value.decode_json(~S({"count":1,"label":"old"}), heap)
    assert fresh != left
    heap = Value.object_put(fresh, "label", string("independent"), heap)
    assert Value.object_get(fresh, "label", heap) == string("independent")
    assert Value.object_get(left, "label", heap) == string("updated")

    {last, heap} = Value.array([fresh, left, Value.undefined()], heap)
    assert last != restored["aliases"]
    assert Value.array_items(last, heap) == [fresh, left, Value.undefined()]

    assert %{"heap" => heap, "last" => last} |> Jason.encode!() |> Jason.decode!() ==
             %{"heap" => heap, "last" => last}
  end

  test "signed zero exponent forms preserve their bits without rewriting string contents" do
    input =
      ~S([-0e0,-0E+2,-0.00,1e-0,10e-0,1e-01,"-0","-0e0","quote: \"-0e0\"","slash: \\-0; quote: \"-0\"","combo: \\\"-0e0\\\""])

    assert {:ok, array, heap} = Value.decode_json(input)

    assert Value.array_items(array, heap) == [
             number("8000000000000000"),
             number("8000000000000000"),
             number("8000000000000000"),
             number("3ff0000000000000"),
             number("4024000000000000"),
             number("3fb999999999999a"),
             string("-0"),
             string("-0e0"),
             string(~S(quote: "-0e0")),
             string(~S(slash: \-0; quote: "-0")),
             string(~S(combo: \"-0e0\"))
           ]
  end

  defp string(value), do: %{"type" => "string", "value" => value}
  defp number(bits), do: %{"type" => "number", "bits" => bits}
end
