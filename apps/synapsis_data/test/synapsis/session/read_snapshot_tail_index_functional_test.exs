defmodule Synapsis.Session.ReadSnapshotTailIndexFunctionalTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Concord.KV.Record
  alias Synapsis.Session.ReadSnapshot, as: Snapshot
  alias Synapsis.Session.Store

  @timeout 5_000
  @observed [
    {KV, :revision, 1},
    {KV, :list, 1},
    {KV, :get, 2},
    {Concord, :revision, 1},
    {Concord, :get, 2},
    {Concord, :get_many, 2},
    {Concord, :get_all, 1},
    {Concord, :prefix_scan, 2}
  ]

  setup do
    assert :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    on_exit(fn -> assert :ok = Store.delete_session(id) end)
    %{id: id}
  end

  test "default tail indexing of an empty existing session reads only historical keys", %{id: id} do
    assert :ok = Store.put_meta(id, %{title: "empty 雪", opaque: {:kept, <<0, 255>>}})
    assert {:ok, snapshot} = Snapshot.capture(id)
    original = snapshot
    started = System.monotonic_time(:millisecond)

    {result, calls} = observe(fn -> Snapshot.tail_index(snapshot) end)

    assert result == {:ok, %{total_turns: 0, entries: [], has_older: false}}
    assert_index_calls(calls, snapshot, started)
    assert length(calls) == 1
    assert hd(calls).result == {:ok, [], %{has_more: false, last_key: nil}}
    assert snapshot == original
  end

  test "sparse physical indices have dense ordinals independent of opaque values and metadata", %{
    id: id
  } do
    meta = %{title: "opaque 雪 🌙", turn_count: 800_000, opaque: {:bytes, <<255, 0>>}}
    assert :ok = Store.put_meta(id, meta)

    persist_turns(id, [
      {0, %{name: "zero", payload: {:opaque, <<0, 255>>}}},
      {7, %{"name" => "seven 雪", :payload => [~U[2026-11-06 00:00:00Z]]}},
      {91, %{name: "ninety-one", payload: %{nested: {:kept, 91}}}},
      {999_999_999_999, %{name: "last 🌙", payload: <<0, 254, 128>>}}
    ])

    assert {:ok, snapshot} = Snapshot.capture(id)
    original = snapshot
    started = System.monotonic_time(:millisecond)

    {{small, large}, calls} =
      observe(fn ->
        {Snapshot.tail_index(snapshot, retain: 2), Snapshot.tail_index(snapshot, retain: 10_000)}
      end)

    assert small ==
             {:ok,
              %{
                total_turns: 4,
                entries: [%{index: 91, ordinal: 3}, %{index: 999_999_999_999, ordinal: 4}],
                has_older: true
              }}

    assert large ==
             {:ok,
              %{
                total_turns: 4,
                entries: [
                  %{index: 0, ordinal: 1},
                  %{index: 7, ordinal: 2},
                  %{index: 91, ordinal: 3},
                  %{index: 999_999_999_999, ordinal: 4}
                ],
                has_older: false
              }}

    assert_index_calls(calls, snapshot, started)

    assert Enum.map(calls, fn call ->
             {:ok, records, _page} = call.result
             Enum.map(records, & &1.key)
           end) ==
             List.duplicate(Enum.map([999_999_999_999, 91, 7, 0], &Store.turn_key(id, &1)), 2)

    assert snapshot == original
    assert snapshot.meta == meta
  end

  test "an exact count spans key pages while the retained tail composes with ordinary value pages",
       %{
         id: id
       } do
    assert :ok = Store.put_meta(id, %{title: "paged history", turn_count: 1})

    entries =
      for n <- 0..1_002 do
        {n * 7, %{name: "turn #{n} 雪", payload: {:opaque, n, <<0, 255>>}}}
      end

    persist_turns(id, entries)
    deadline = System.monotonic_time(:millisecond) + 4_000
    assert {:ok, snapshot} = Snapshot.capture(id, deadline: deadline)
    original = snapshot
    started = System.monotonic_time(:millisecond)

    {result, index_calls} = observe(fn -> Snapshot.tail_index(snapshot, retain: 125) end)

    expected_index = for ordinal <- 879..1_003, do: %{index: (ordinal - 1) * 7, ordinal: ordinal}

    assert result ==
             {:ok, %{total_turns: 1_003, entries: expected_index, has_older: true}}

    assert_index_calls(index_calls, snapshot, started)
    assert length(index_calls) == 11

    record_counts =
      Enum.map(index_calls, fn call ->
        {:ok, records, _page} = call.result
        length(records)
      end)

    assert record_counts == List.duplicate(100, 10) ++ [3]

    scanned_keys =
      Enum.flat_map(index_calls, fn call ->
        {:ok, records, _page} = call.result
        Enum.map(records, & &1.key)
      end)

    assert scanned_keys == Enum.map(1_002..0, &Store.turn_key(id, &1 * 7))

    for {previous, next} <- Enum.zip(index_calls, Enum.drop(index_calls, 1)) do
      {:ok, _records, %{has_more: true, last_key: last_key}} = previous.result
      assert hd(next.args)[:range] == {Store.turns_prefix(id), last_key}
    end

    assert {:ok, [_last, _second_last, _first], %{has_more: false}} =
             List.last(index_calls).result

    scanned_bytes =
      Enum.reduce(index_calls, 0, fn call, bytes ->
        {:ok, records, _page} = call.result
        bytes + Enum.reduce(records, 0, &(:erlang.external_size(&1) + &2))
      end)

    assert scanned_bytes > 65_536

    {{newer, older}, page_calls} =
      observe(fn ->
        assert {:ok, newer} = Snapshot.read_page(snapshot, order: :desc, limit: 100)

        assert {:ok, older} =
                 Snapshot.read_page(snapshot,
                   order: :desc,
                   cursor: newer.next_cursor,
                   limit: 25
                 )

        {newer, older}
      end)

    assert newer.has_more
    assert newer.next_cursor == 903 * 7
    assert older.has_more
    assert older.next_cursor == 878 * 7
    refute newer.truncated
    refute older.truncated
    chronological = older.turns ++ newer.turns

    assert chronological ==
             Enum.map(878..1_002, fn n ->
               %{index: n * 7, turn: %{name: "turn #{n} 雪", payload: {:opaque, n, <<0, 255>>}}}
             end)

    assert Enum.map(chronological, & &1.index) == Enum.map(expected_index, & &1.index)
    assert Enum.count(page_calls, &(&1.function == :get)) == 125
    assert_read_calls(page_calls, snapshot, started)
    assert_timeouts(index_calls ++ page_calls, snapshot.deadline - started)
    assert snapshot == original
    assert snapshot.deadline == deadline
  end

  test "indexing and value pages retain the captured revision after overwrite append and metadata edit",
       %{
         id: id
       } do
    meta = %{title: "captured 雪", turn_count: 900, opaque: {:original, <<0, 255>>}}
    assert :ok = Store.put_meta(id, meta)

    persist_turns(id, [
      {0, %{text: "original zero"}},
      {7, %{text: "original seven"}},
      {91, %{text: "original ninety-one"}},
      {999, %{text: "original last 🌙"}}
    ])

    deadline = System.monotonic_time(:millisecond) + 4_000
    assert {:ok, snapshot} = Snapshot.capture(id, deadline: deadline)
    original = snapshot

    assert {:ok, %{revision: overwritten}} = put(Store.turn_key(id, 999), %{text: "current last"})
    assert overwritten > snapshot.revision
    assert {:ok, _} = put(Store.turn_key(id, 7), %{text: "current seven"})
    assert :ok = Store.commit_turn(id, 1_000, %{text: "later append"}, %{title: "current"})
    assert :ok = Store.put_meta(id, %{title: "edited metadata", turn_count: 1})
    started = System.monotonic_time(:millisecond)

    {result, index_calls} = observe(fn -> Snapshot.tail_index(snapshot, retain: 2) end)

    assert result ==
             {:ok,
              %{
                total_turns: 4,
                entries: [%{index: 91, ordinal: 3}, %{index: 999, ordinal: 4}],
                has_older: true
              }}

    assert_index_calls(index_calls, snapshot, started)

    {page, page_calls} =
      observe(fn -> Snapshot.read_page(snapshot, order: :desc, limit: 100) end)

    assert page ==
             {:ok,
              %{
                turns: [
                  %{index: 0, turn: %{text: "original zero"}},
                  %{index: 7, turn: %{text: "original seven"}},
                  %{index: 91, turn: %{text: "original ninety-one"}},
                  %{index: 999, turn: %{text: "original last 🌙"}}
                ],
                has_more: false,
                next_cursor: nil,
                truncated: false
              }}

    assert_read_calls(page_calls, snapshot, started)
    assert_timeouts(index_calls ++ page_calls, snapshot.deadline - started)
    assert snapshot == original
    assert snapshot.meta == meta
    assert snapshot.deadline == deadline
    assert snapshot.owner == {:concord_turso, Process.whereis(Concord.Turso.DB)}
  end

  defp put(key, value) do
    KV.put(key, value, engine: :turso, compress: false, timeout: @timeout)
  end

  defp persist_turns(id, entries) do
    for chunk <- Enum.chunk_every(entries, 500) do
      puts = Enum.map(chunk, fn {index, value} -> {Store.turn_key(id, index), value} end)
      assert {:ok, _} = Concord.Turso.put_many(puts, timeout: @timeout)
    end
  end

  defp assert_index_calls(calls, snapshot, started) do
    assert calls != []
    assert Enum.all?(calls, &(&1.module == KV and &1.function == :list))
    assert_historical_calls(calls, snapshot.revision)
    assert_timeouts(calls, snapshot.deadline - started)

    for call <- calls do
      opts = hd(call.args)
      assert opts[:limit] == 100
      assert opts[:order] == :desc
      {:ok, records, _page} = call.result
      assert length(records) <= 100
      assert Enum.all?(records, &match?(%Record{value: nil}, &1))
    end

    prefix = Store.turns_prefix(snapshot.session_id)

    assert hd(calls).args |> hd() |> Keyword.fetch!(:range) ==
             {prefix, Store.turn_key(snapshot.session_id, 999_999_999_999) <> <<0>>}
  end

  defp assert_read_calls(calls, snapshot, started) do
    assert calls != []
    assert Enum.all?(calls, &(&1.module == KV and &1.function in [:list, :get]))
    assert_historical_calls(calls, snapshot.revision)
    assert_timeouts(calls, snapshot.deadline - started)
  end

  defp assert_historical_calls(calls, revision) do
    for call <- calls do
      opts = List.last(call.args)
      assert opts[:engine] == :turso
      assert opts[:revision] == revision
      refute Keyword.has_key?(opts, :metadata)

      if call.function == :list do
        assert opts[:keys_only] == true
        assert opts[:queue] == true
      end
    end
  end

  defp assert_timeouts(calls, maximum) do
    timeouts = Enum.map(calls, fn call -> List.last(call.args)[:timeout] end)
    assert timeouts != []
    assert Enum.all?(timeouts, &(is_integer(&1) and &1 > 0 and &1 <= maximum))
    assert timeouts == Enum.sort(timeouts, :desc)
  end

  defp observe(fun) do
    for module <- [KV, Concord], do: Code.ensure_loaded!(module)
    observer = spawn(fn -> collect([], []) end)
    monitor = Process.monitor(observer)

    for mfa <- @observed do
      :erlang.trace_pattern(mfa, [{:_, [], [{:return_trace}]}], [:local])
    end

    :erlang.trace(self(), true, [:call, {:tracer, observer}])

    try do
      result = fun.()
      delivered = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^delivered}, @timeout
      send(observer, {:finish, self()})
      assert_receive {:observed_calls, calls}, @timeout
      assert_receive {:DOWN, ^monitor, :process, ^observer, :normal}, @timeout
      {result, calls}
    after
      :erlang.trace(self(), false, [:call])

      for mfa <- @observed, do: :erlang.trace_pattern(mfa, false, [:local])

      send(observer, :stop)
    end
  end

  defp collect(stack, calls) do
    receive do
      {:trace, _, :call, {module, function, args}} ->
        collect([{module, function, args} | stack], calls)

      {:trace, _, :return_from, {module, function, arity}, result} ->
        [{^module, ^function, args} | rest] = stack
        ^arity = length(args)
        collect(rest, [%{module: module, function: function, args: args, result: result} | calls])

      {:finish, owner} ->
        [] = stack
        send(owner, {:observed_calls, Enum.reverse(calls)})

      :stop ->
        :ok
    end
  end
end
