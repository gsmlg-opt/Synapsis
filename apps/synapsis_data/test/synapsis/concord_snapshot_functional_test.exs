defmodule Synapsis.ConcordSnapshotFunctionalTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Concord.KV.Record
  alias Concord.Turso
  alias Synapsis.Session.Store

  @timeout 5_000

  setup do
    assert :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    prefix = "adoption/concord-snapshot/" <> id <> "/"

    on_exit(fn ->
      assert {:ok, pairs} = Turso.prefix_scan(prefix, timeout: @timeout)
      assert {:ok, _} = Turso.delete_many(Enum.map(pairs, &elem(&1, 0)), timeout: @timeout)
    end)

    %{prefix: prefix}
  end

  test "historical prefix and range pages continue in both directions after ordinary mutations",
       %{
         prefix: prefix
       } do
    assert {:ok, _} = put(prefix <> "a", %{text: "original alpha"})
    assert {:ok, _} = put(prefix <> "c", %{text: "original charlie"})
    assert {:ok, _} = put(prefix <> "e", %{text: "original echo"})
    assert {:ok, _} = put(prefix <> "g", %{text: "original golf"})
    assert {:ok, revision} = Turso.revision(timeout: @timeout)

    assert {:ok, _} = put(prefix <> "a", %{text: "current alpha"})
    assert {:ok, _} = KV.delete(prefix <> "c", engine: :turso, timeout: @timeout)
    assert {:ok, _} = put(prefix <> "b", %{text: "later bravo"})

    assert {:ok, ascending, %{has_more: true, last_key: asc_cursor}} =
             list(prefix: prefix, revision: revision, order: :asc, limit: 2)

    assert values(ascending) == [
             {prefix <> "a", %{text: "original alpha"}},
             {prefix <> "c", %{text: "original charlie"}}
           ]

    assert asc_cursor == prefix <> "c"

    assert {:ok, ascending_tail, %{has_more: false, last_key: asc_end}} =
             list(
               range: {asc_cursor <> <<0>>, prefix <> "\u{10FFFF}"},
               revision: revision,
               order: :asc,
               limit: 2
             )

    assert values(ascending_tail) == [
             {prefix <> "e", %{text: "original echo"}},
             {prefix <> "g", %{text: "original golf"}}
           ]

    assert asc_end == prefix <> "g"

    assert {:ok, descending, %{has_more: true, last_key: desc_cursor}} =
             list(prefix: prefix, revision: revision, order: :desc, limit: 2)

    assert values(descending) == [
             {prefix <> "g", %{text: "original golf"}},
             {prefix <> "e", %{text: "original echo"}}
           ]

    assert desc_cursor == prefix <> "e"

    assert {:ok, descending_tail, %{has_more: false, last_key: desc_end}} =
             list(range: {prefix, desc_cursor}, revision: revision, order: :desc, limit: 2)

    assert values(descending_tail) == [
             {prefix <> "c", %{text: "original charlie"}},
             {prefix <> "a", %{text: "original alpha"}}
           ]

    assert desc_end == prefix <> "a"
    assert {:ok, current, %{has_more: false}} = list(prefix: prefix, limit: 10)

    assert values(current) == [
             {prefix <> "a", %{text: "current alpha"}},
             {prefix <> "b", %{text: "later bravo"}},
             {prefix <> "e", %{text: "original echo"}},
             {prefix <> "g", %{text: "original golf"}}
           ]
  end

  test "key-only metadata and head tail meta point values share the captured revision", %{
    prefix: prefix
  } do
    turns_prefix = prefix <> "turns/"
    head_key = turns_prefix <> "000000000000"
    tail_key = turns_prefix <> "000000000002"
    meta_key = prefix <> "meta"

    assert {:ok, %{revision: head_created}} =
             put(head_key, %{text: "original head"},
               metadata: %{owner: "head", opaque: <<0, 255>>},
               content_type: "application/x-erlang"
             )

    assert {:ok, _} = put(turns_prefix <> "000000000001", %{text: "original middle"})

    assert {:ok, %{revision: tail_created}} =
             put(tail_key, %{text: "original tail 雪"},
               metadata: %{owner: "tail"},
               content_type: "application/x-erlang"
             )

    assert {:ok, %{revision: meta_created}} = put(meta_key, %{title: "original", count: 3})
    assert {:ok, revision} = Turso.revision(timeout: @timeout)

    assert {:ok, _} = put(head_key, %{text: "current head"})
    assert {:ok, _} = put(tail_key, %{text: "current tail"})

    assert {:ok, _} =
             KV.delete(turns_prefix <> "000000000001", engine: :turso, timeout: @timeout)

    assert {:ok, _} = put(turns_prefix <> "000000000003", %{text: "later appended turn"})
    assert {:ok, _} = put(meta_key, %{title: "current", count: 3})

    head = %Record{
      value: %{text: "original head"},
      create_revision: head_created,
      mod_revision: head_created,
      version: 1,
      metadata: %{owner: "head", opaque: <<0, 255>>},
      content_type: "application/x-erlang"
    }

    tail = %Record{
      value: %{text: "original tail 雪"},
      create_revision: tail_created,
      mod_revision: tail_created,
      version: 1,
      metadata: %{owner: "tail"},
      content_type: "application/x-erlang"
    }

    meta = %Record{
      value: %{title: "original", count: 3},
      create_revision: meta_created,
      mod_revision: meta_created,
      version: 1
    }

    assert {:ok, [observed_head], %{has_more: true, last_key: ^head_key}} =
             list(
               prefix: turns_prefix,
               revision: revision,
               keys_only: true,
               order: :asc,
               limit: 1
             )

    assert observed_head == head |> Map.put(:value, nil) |> Map.put(:key, head_key)

    assert {:ok, [observed_tail], %{has_more: true, last_key: ^tail_key}} =
             list(
               prefix: turns_prefix,
               revision: revision,
               keys_only: true,
               order: :desc,
               limit: 1
             )

    assert observed_tail == tail |> Map.put(:value, nil) |> Map.put(:key, tail_key)

    for {key, expected_record} <- [{head_key, head}, {tail_key, tail}, {meta_key, meta}] do
      for keys_only <- [false, true] do
        assert {:ok, [historical_record], %{has_more: false, last_key: ^key}} =
                 list(
                   range: {key, key <> <<0>>},
                   revision: revision,
                   keys_only: keys_only,
                   limit: 1
                 )

        expected = Map.put(expected_record, :key, key)
        expected = if keys_only, do: Map.put(expected, :value, nil), else: expected
        assert historical_record == expected
      end
    end

    assert {:ok, %{text: "original head"}} = point_value(head_key, revision)
    assert {:ok, %{text: "original tail 雪"}} = point_value(tail_key, revision)
    assert {:ok, %{title: "original", count: 3}} = point_value(meta_key, revision)
    assert {:ok, current_revision} = Turso.revision(timeout: @timeout)
    assert current_revision > revision
    assert {:ok, current, %{has_more: false}} = list(prefix: prefix, revision: current_revision)

    assert values(current) == [
             {meta_key, %{title: "current", count: 3}},
             {head_key, %{text: "current head"}},
             {tail_key, %{text: "current tail"}},
             {turns_prefix <> "000000000003", %{text: "later appended turn"}}
           ]
  end

  test "public prefix publication can couple related metadata at one before and after revision",
       %{
         prefix: prefix
       } do
    turns_prefix = prefix <> "turns/"
    head_key = turns_prefix <> "000000000000"
    meta_key = prefix <> "meta"
    assert {:ok, %{revision: head_created}} = put(head_key, %{text: "old head"})
    assert {:ok, _} = put(turns_prefix <> "000000000001", %{text: "old stale tail"})
    assert {:ok, %{revision: meta_created}} = put(meta_key, %{generation: 1, count: 2})
    assert {:ok, before} = Turso.revision(timeout: @timeout)

    assert {:ok, %{succeeded: true, revision: published, deleted: 1, written: 3}} =
             Turso.replace_prefix(
               turns_prefix,
               [
                 {head_key, %{text: "new head"}},
                 {turns_prefix <> "000000000002", %{text: "new tail"}},
                 {meta_key, %{generation: 2, count: 2}}
               ],
               timeout: @timeout
             )

    assert published == before + 1
    assert {:ok, ^published} = Turso.revision(timeout: @timeout)
    assert {:ok, old, %{has_more: false}} = list(prefix: prefix, revision: before)

    assert values(old) == [
             {meta_key, %{generation: 1, count: 2}},
             {head_key, %{text: "old head"}},
             {turns_prefix <> "000000000001", %{text: "old stale tail"}}
           ]

    assert {:ok, current, %{has_more: false}} = list(prefix: prefix, revision: published)

    assert values(current) == [
             {meta_key, %{generation: 2, count: 2}},
             {head_key, %{text: "new head"}},
             {turns_prefix <> "000000000002", %{text: "new tail"}}
           ]

    assert Enum.all?(current, &(&1.mod_revision == published))

    assert [published_meta, published_head, _published_tail] = current

    assert published_head ==
             Map.put(
               %Record{
                 value: %{text: "new head"},
                 create_revision: head_created,
                 mod_revision: published,
                 version: 2
               },
               :key,
               head_key
             )

    assert published_meta ==
             Map.put(
               %Record{
                 value: %{generation: 2, count: 2},
                 create_revision: meta_created,
                 mod_revision: published,
                 version: 2
               },
               :key,
               meta_key
             )

    assert {:ok, %{text: "old head"}} = point_value(head_key, before)
    assert {:ok, %{generation: 1, count: 2}} = point_value(meta_key, before)
    assert {:ok, %{text: "new head"}} = point_value(head_key, published)
    assert {:ok, %{generation: 2, count: 2}} = point_value(meta_key, published)
  end

  defp put(key, value, opts \\ []),
    do: KV.put(key, value, [engine: :turso, compress: false, timeout: @timeout] ++ opts)

  defp list(opts), do: KV.list([engine: :turso, timeout: @timeout] ++ opts)

  defp point_value(key, revision),
    do: KV.get(key, engine: :turso, revision: revision, timeout: @timeout)

  defp values(records), do: Enum.map(records, &{&1.key, &1.value})
end
