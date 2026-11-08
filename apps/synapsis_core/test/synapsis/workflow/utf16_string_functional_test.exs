defmodule Synapsis.Workflow.UTF16StringFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workflow.Value
  alias Synapsis.Workflow.JSON, as: WorkflowJSON

  @fixture Path.expand("../../../../..", __DIR__)
           |> Path.join("packages/tool-host/test/fixtures/workflow-utf16-string-cases.json")
  @external_resource @fixture
  @cases @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")

  # Independently frozen successful JS string observations. No replacement
  # character normalization or public decoder is used for the lone units.
  for item <- @cases do
    @item item
    test "trusted UTF16 constructor, JSON output and scalar snapshot: #{item["name"]}" do
      raw = for unit <- @item["units"], into: <<>>, do: <<unit::unsigned-little-16>>
      assert Base.encode64(raw) == @item["base64"]
      value = Value.from_utf16le(raw)

      expected =
        if @item["utf8"] == nil,
          do: %{"type" => "string", "utf16le" => @item["base64"]},
          else: %{"type" => "string", "value" => @item["utf8"]}

      assert value == expected
      assert Value.to_utf16le(value) == raw
      assert Jason.decode!(Jason.encode!(value)) == expected

      heap = Value.new()
      assert WorkflowJSON.stringify(value, heap) == {:ok, @item["json"]}
      assert WorkflowJSON.pretty(value, heap) == {:ok, @item["json"]}
      assert WorkflowJSON.stable_stringify(value, heap) == {:ok, @item["json"]}
      assert WorkflowJSON.snapshot(value, heap) == {:ok, expected, heap}
    end
  end

  test "ordinary imported UTF8 strings retain their tags and exact UTF16 units" do
    for item <- @cases, item["utf8"] != nil do
      assert {:ok, value, heap} = Value.decode_json(item["json"])
      assert value == %{"type" => "string", "value" => item["utf8"]}
      assert Value.to_utf16le(value) == Base.decode64!(item["base64"])
      assert WorkflowJSON.stringify(value, heap) == {:ok, item["json"]}
    end
  end

  test "tagged snapshots retain aliases while strict snapshots copy each occurrence and normalize zero" do
    high = Value.from_utf16le(<<0x3D, 0xD8>>)
    low = Value.from_utf16le(<<0x00, 0xDE>>)
    {shared, heap} = Value.object([{"part", high}], Value.new())
    {array, heap} = Value.array([shared, shared, low], heap)
    zero = %{"type" => "number", "bits" => "8000000000000000"}

    {root, heap} = Value.object([{"tail", array}, {"10", zero}, {"2", high}], heap)
    saved = %{"root" => root, "heap" => heap}
    assert saved |> Jason.encode!() |> Jason.decode!() == saved
    assert Value.array_items(array, heap) == [shared, shared, low]
    assert Value.object_keys(root, heap) == ["2", "10", "tail"]

    assert {:ok, copy, copied_heap} = WorkflowJSON.snapshot(root, heap)
    assert copy != root
    assert Value.object_keys(copy, copied_heap) == ["2", "10", "tail"]
    assert copied_heap["nodes"][copy["id"]]["keys"] == ["2", "10", "tail"]

    assert Value.object_get(copy, "10", copied_heap) == %{
             "type" => "number",
             "bits" => "0000000000000000"
           }

    assert Value.object_get(root, "10", copied_heap) == zero

    copied_array = Value.object_get(copy, "tail", copied_heap)
    [left, right, ^low] = Value.array_items(copied_array, copied_heap)
    assert left != right
    assert left != shared
    assert right != shared
    assert Value.object_get(left, "part", copied_heap) == high
    assert Value.object_get(right, "part", copied_heap) == high
    assert Map.take(copied_heap["nodes"], Map.keys(heap["nodes"])) == heap["nodes"]

    changed = Value.object_put(left, "part", low, copied_heap)
    assert Value.object_get(left, "part", changed) == low
    assert Value.object_get(right, "part", changed) == high
    assert Value.object_get(shared, "part", changed) == high

    assert WorkflowJSON.stringify(root, changed) ==
             {:ok,
              ~S({"2":"\ud83d","10":0,"tail":[{"part":"\ud83d"},{"part":"\ud83d"},"\ude00"]})}

    assert WorkflowJSON.stringify(copy, changed) ==
             {:ok,
              ~S({"2":"\ud83d","10":0,"tail":[{"part":"\ude00"},{"part":"\ud83d"},"\ude00"]})}
  end

  test "a strict snapshot preserves canonical scalar and empty container shapes" do
    assert {:ok, root, heap} = Value.decode_json(~S([null,false,true,-0,1.5,[],{},"雪😀"]))
    assert {:ok, copy, copied_heap} = WorkflowJSON.snapshot(root, heap)
    assert copy != root

    assert WorkflowJSON.stringify(copy, copied_heap) ==
             {:ok, ~S([null,false,true,0,1.5,[],{},"雪😀"])}

    assert Value.array_items(root, copied_heap) == Value.array_items(root, heap)
  end
end
