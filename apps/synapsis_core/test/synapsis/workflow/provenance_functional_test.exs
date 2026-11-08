defmodule Synapsis.Workflow.ProvenanceFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workflow.Provenance.Owner
  alias Synapsis.Workflow.Value

  @timeout 5_000
  @text ~S({"model":"fixture","usage":{"inputTokens":2},"answer":"ok"})

  # Internal private-model fixtures, independently frozen from unchanged
  # Lobster source. These are neither public mark producers nor LLM execution.
  setup do
    owner = start_supervised!({Owner, name: nil})
    %{owner: owner}
  end

  test "heap deltas retain stable aliases and carry changed and fresh complete nodes" do
    {root, usage, before} = item()
    changed = Value.object_put(root, "answer", string("updated"), before)
    {array, after_heap} = Value.array([root, root], changed)

    assert Value.heap_delta(before, before) == %{upsert: %{}, next_id: before["next_id"]}

    assert Value.heap_delta(before, after_heap) == %{
             upsert: %{
               root["id"] => after_heap["nodes"][root["id"]],
               array["id"] => after_heap["nodes"][array["id"]]
             },
             next_id: after_heap["next_id"]
           }

    assert Value.array_items(array, after_heap) == [root, root]
    assert after_heap["nodes"][usage["id"]] == before["nodes"][usage["id"]]
  end

  test "item usage and retained aliases share replay without adding metadata to public nodes", %{
    owner: owner
  } do
    {root, usage, heap} = item()
    {aliases, heap} = Value.object([{"left", root}, {"right", root}], heap)
    binding = open(owner, heap)
    binding = publish(binding, heap, heap, [{:mark_item, root, string("call-a"), false}])
    assert_mark(binding, root, "call-a", false)
    assert_mark(binding, usage, "call-a", false)

    binding = publish(binding, heap, heap, [{:mark_replayed, usage}])
    assert_mark(binding, root, "call-a", true)
    assert_mark(binding, Value.object_get(aliases, "right", heap), "call-a", true)
    assert_mark(binding, usage, "call-a", true)

    # Narrow shape evidence: the owner's public node copy remains exactly v1.
    assert only_graph(owner).nodes == heap["nodes"]
    assert Owner.release(binding, @timeout) == :ok
  end

  test "array-valued usage receives the same private call as its item", %{owner: owner} do
    {usage, heap} = Value.array([string("ordinary")], Value.new())
    {root, heap} = Value.object([{"usage", usage}], heap)
    cache_key = Value.from_utf16le(<<0x00, 0xD8>>)
    assert cache_key == %{"type" => "string", "utf16le" => "ANg="}
    binding = open(owner, heap)
    binding = publish(binding, heap, heap, [{:mark_item, root, cache_key, false}])
    binding = publish(binding, heap, heap, [{:mark_replayed, usage}])
    assert_mark(binding, root, cache_key, true)
    assert_mark(binding, usage, cache_key, true)
    assert Owner.release(binding, @timeout) == :ok
  end

  test "shallow spread shares a call while a fresh projection retains only its marked child", %{
    owner: owner
  } do
    {root, usage, heap} = item()
    {spread, heap} = Value.object([{"model", string("fixture")}, {"usage", usage}], heap)
    {projection, heap} = Value.object([{"usage", usage}], heap)
    binding = open(owner, heap)

    binding =
      publish(binding, heap, heap, [
        {:mark_item, root, string("spread-call"), false},
        {:copy_mark, root, spread},
        {:mark_replayed, spread}
      ])

    assert_mark(binding, root, "spread-call", true)
    assert_mark(binding, spread, "spread-call", true)
    assert_mark(binding, usage, "spread-call", true)
    assert Owner.provenance_of(binding, projection, @timeout) == {:ok, nil}
    assert Value.object_get(projection, "usage", heap) == usage
    assert Owner.release(binding, @timeout) == :ok
  end

  test "remembered roots follow replaced nested edges and subsequent in-place re-marks", %{
    owner: owner
  } do
    {first, _first_usage, heap} = item()
    {root, heap} = Value.object([{"nested", first}], heap)
    binding = open(owner, heap)
    text = ~S({"nested":{"model":"fixture","usage":{"inputTokens":2},"answer":"ok"}})

    binding =
      publish(binding, heap, heap, [
        {:mark_item, first, string("before"), false},
        {:remember, "/ordinary/live.json", text, root}
      ])

    {replacement, _usage, next_heap} = item(heap)
    next_heap = Value.object_put(root, "nested", replacement, next_heap)
    {:ok, target, next_heap} = Value.decode_json(text, next_heap)

    binding =
      publish(binding, heap, next_heap, [
        {:mark_item, replacement, string("replacement"), false},
        {:carry_remembered, "/ordinary/live.json", text, target}
      ])

    target_child = Value.object_get(target, "nested", next_heap)
    assert_mark(binding, target_child, "replacement", true)

    {:ok, later, last_heap} = Value.decode_json(text, next_heap)

    binding =
      publish(binding, next_heap, last_heap, [
        {:mark_item, replacement, string("remarked"), false},
        {:carry_remembered, "/ordinary/live.json", text, later}
      ])

    assert_mark(binding, Value.object_get(later, "nested", last_heap), "remarked", true)
    assert_mark(binding, replacement, "remarked", false)
    assert Owner.release(binding, @timeout) == :ok
  end

  test "remembering an unmarked live root allows a later trusted mark to carry", %{owner: owner} do
    {root, usage, heap} = item()
    binding = open(owner, heap)
    binding = publish(binding, heap, heap, [{:remember, "/ordinary/later.json", @text, root}])
    {:ok, read, next_heap} = Value.decode_json(@text, heap)

    binding =
      publish(binding, heap, next_heap, [
        {:mark_item, root, string("later-call"), false},
        {:carry_remembered, "/ordinary/later.json", @text, read}
      ])

    assert_mark(binding, read, "later-call", true)
    assert_mark(binding, Value.object_get(read, "usage", next_heap), "later-call", true)
    assert_mark(binding, root, "later-call", false)
    assert_mark(binding, usage, "later-call", false)
    assert Owner.release(binding, @timeout) == :ok
  end

  test "alternate valid text leaves the remembered entry available for exact-text restoration", %{
    owner: owner
  } do
    {root, _usage, heap} = item()
    binding = open(owner, heap)

    binding =
      publish(binding, heap, heap, [
        {:mark_item, root, string("text-call"), false},
        {:remember, "/ordinary/text.json", @text, root}
      ])

    alternate = @text <> "\n"
    {:ok, other, next_heap} = Value.decode_json(alternate, heap)

    binding =
      publish(binding, heap, next_heap, [
        {:carry_remembered, "/ordinary/text.json", alternate, other}
      ])

    assert Owner.provenance_of(binding, other, @timeout) == {:ok, nil}

    {:ok, restored, last_heap} = Value.decode_json(@text, next_heap)

    binding =
      publish(binding, next_heap, last_heap, [
        {:carry_remembered, "/ordinary/text.json", @text, restored}
      ])

    assert_mark(binding, restored, "text-call", true)
    assert_mark(binding, root, "text-call", false)
    assert Owner.release(binding, @timeout) == :ok
  end

  test "fresh reads split aliases and give each marked object its own new replay identity", %{
    owner: owner
  } do
    {shared, _usage, heap} = item()
    {root, heap} = Value.object([{"left", shared}, {"right", shared}], heap)

    text =
      ~S({"left":{"model":"fixture","usage":{"inputTokens":2},"answer":"ok"},"right":{"model":"fixture","usage":{"inputTokens":2},"answer":"ok"}})

    binding = open(owner, heap)

    binding =
      publish(binding, heap, heap, [
        {:mark_item, shared, string("fresh-call"), false},
        {:remember, "/ordinary/fresh.json", text, root}
      ])

    {:ok, first, next_heap} = Value.decode_json(text, heap)
    {:ok, second, next_heap} = Value.decode_json(text, next_heap)

    binding =
      publish(binding, heap, next_heap, [
        {:carry_remembered, "/ordinary/fresh.json", text, first},
        {:carry_remembered, "/ordinary/fresh.json", text, second}
      ])

    children =
      for read <- [first, second],
          key <- ["left", "right"],
          do: Value.object_get(read, key, next_heap)

    objects =
      Enum.flat_map(children, fn child -> [child, Value.object_get(child, "usage", next_heap)] end)

    assert length(Enum.uniq(children)) == 4
    Enum.each(objects, &assert_mark(binding, &1, "fresh-call", true))
    assert_mark(binding, shared, "fresh-call", false)

    # Already-replayed objects cannot reveal distinct calls through another
    # replay. Inspect only their call IDs; no binding struct fields are read.
    marks = only_graph(owner).marks
    calls = Enum.map(objects, &Map.fetch!(marks, &1["id"]))
    assert length(Enum.uniq(calls)) == 8
    refute Map.fetch!(marks, shared["id"]) in calls
    assert Owner.release(binding, @timeout) == :ok
  end

  test "equal local IDs and equal cache keys in separate graphs never share a private call", %{
    owner: owner
  } do
    {left, _usage, heap_a} = item()
    {right, _usage, heap_b} = item()
    assert left == right
    a = open(owner, heap_a)
    b = open(owner, heap_b)
    a = publish(a, heap_a, heap_a, [{:mark_item, left, string("same-key"), false}])
    assert Owner.provenance_of(b, right, @timeout) == {:ok, nil}
    b = publish(b, heap_b, heap_b, [{:mark_item, right, string("same-key"), false}])
    a = publish(a, heap_a, heap_a, [{:mark_replayed, left}])
    assert_mark(a, left, "same-key", true)
    assert_mark(b, right, "same-key", false)
    assert Owner.release(a, @timeout) == :ok
    assert Owner.release(b, @timeout) == :ok
  end

  test "normal release retains cached roots while collecting unrelated nodes and calls", %{
    owner: owner
  } do
    {root, _usage, heap} = item()
    {unrelated, _usage, heap} = item(heap)
    binding = open(owner, heap)

    binding =
      publish(binding, heap, heap, [
        {:mark_item, root, string("kept"), false},
        {:mark_item, unrelated, string("collected"), false},
        {:remember, "/ordinary/kept.json", @text, root}
      ])

    assert Owner.release(binding, @timeout) == :ok
    state = :sys.get_state(owner)
    assert state.leases == %{}
    assert map_size(state.graphs) == 1
    assert map_size(only_graph(owner).nodes) == 2
    refute Map.has_key?(only_graph(owner).nodes, unrelated["id"])
    assert map_size(state.calls) == 1

    {:ok, read, fresh_heap} = Value.decode_json(@text)
    next = open(owner, fresh_heap)

    next =
      publish(next, fresh_heap, fresh_heap, [
        {:carry_remembered, "/ordinary/kept.json", @text, read}
      ])

    assert_mark(next, read, "kept", true)
    assert Owner.release(next, @timeout) == :ok
    assert map_size(:sys.get_state(owner).graphs) == 1
    assert map_size(:sys.get_state(owner).calls) == 1
  end

  test "normal replacement and final unremembered release sweep obsolete graphs and calls", %{
    owner: owner
  } do
    {first, _usage, heap} = item()
    a = open(owner, heap)

    a =
      publish(a, heap, heap, [
        {:mark_item, first, string("old-call"), false},
        {:remember, "/ordinary/replaced.json", @text, first}
      ])

    assert Owner.release(a, @timeout) == :ok

    {second, _usage, next_heap} = item()
    b = open(owner, next_heap)

    b =
      publish(b, next_heap, next_heap, [
        {:mark_item, second, string("new-call"), false},
        {:remember, "/ordinary/replaced.json", @text, second}
      ])

    assert Owner.release(b, @timeout) == :ok
    state = :sys.get_state(owner)
    assert state.leases == %{}
    assert map_size(state.graphs) == 1
    assert Enum.map(Map.values(state.calls), & &1.cache_key) == [string("new-call")]

    # A separate unremembered graph retires normally without enlarging cache GC.
    c = open(owner, heap)
    c = publish(c, heap, heap, [{:mark_item, first, string("temporary"), false}])
    assert Owner.release(c, @timeout) == :ok
    assert :sys.get_state(owner).graphs == state.graphs
    assert :sys.get_state(owner).calls == state.calls
  end

  test "same-shape array carry follows only matching positions and leaves source calls live", %{
    owner: owner
  } do
    {first, _usage, heap} = item()
    {second, _usage, heap} = item(heap)
    {source, heap} = Value.array([first, second], heap)
    binding = open(owner, heap)
    text = "[" <> @text <> "," <> @text <> "]"

    binding =
      publish(binding, heap, heap, [
        {:mark_item, source, string("array-root"), false},
        {:mark_item, first, string("first"), false},
        {:mark_item, second, string("second"), false},
        {:remember, "/ordinary/array.json", text, source}
      ])

    # Mutate the live source array to one child while the captured text remains
    # the ordinary two-item JSON. The fresh target still has two positions.
    next_heap = put_in(heap, ["nodes", source["id"], "items"], [first])
    {:ok, read, next_heap} = Value.decode_json(text, next_heap)

    binding =
      publish(binding, heap, next_heap, [{:carry_remembered, "/ordinary/array.json", text, read}])

    [read_first, read_second] = Value.array_items(read, next_heap)
    assert_mark(binding, read, "array-root", true)
    assert_mark(binding, read_first, "first", true)
    assert Owner.provenance_of(binding, read_second, @timeout) == {:ok, nil}
    assert_mark(binding, first, "first", false)
    assert_mark(binding, second, "second", false)
    assert Owner.release(binding, @timeout) == :ok
  end

  defp item(heap \\ Value.new()) do
    {:ok, root, heap} = Value.decode_json(@text, heap)
    {root, Value.object_get(root, "usage", heap), heap}
  end

  defp open(owner, heap) do
    assert {:ok, binding} = Owner.open(owner, self(), heap, @timeout)
    binding
  end

  defp publish(binding, before_heap, after_heap, actions) do
    assert {:ok, next} =
             Owner.publish(binding, Value.heap_delta(before_heap, after_heap), actions, @timeout)

    next
  end

  defp assert_mark(binding, root, key, replayed) do
    assert Owner.provenance_of(binding, root, @timeout) ==
             {:ok, %{cache_key: string(key), replayed: replayed}}
  end

  defp only_graph(owner) do
    assert [graph] = owner |> :sys.get_state() |> Map.fetch!(:graphs) |> Map.values()
    graph
  end

  defp string(value), do: Value.key_string(value)
end
