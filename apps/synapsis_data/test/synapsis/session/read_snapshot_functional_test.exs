defmodule Synapsis.Session.ReadSnapshotFunctionalTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Concord.KV.Record
  alias Synapsis.Session.ReadSnapshot, as: Snapshot
  alias Synapsis.Session.Store

  @timeout 5_000
  @observed [{:revision, 1}, {:list, 1}, {:get, 2}]

  setup do
    assert :ok = Store.ensure_started()
    ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]
    on_exit(fn -> Enum.each(ids, fn id -> assert :ok = Store.delete_session(id) end) end)
    [id, other_id] = ids
    %{id: id, other_id: other_id}
  end

  test "metadata-only capture retains the actual public Record and opaque metadata", %{id: id} do
    key = Store.meta_key(id)
    meta = %{"title" => "雪 🌙", :opaque => {:bytes, <<0, 255, 128>>}}
    record_meta = %{source: "ordinary session", bytes: <<0, 254>>}

    assert {:ok, %{revision: created}} =
             put(key, meta, metadata: record_meta, content_type: "application/x-erlang")

    before_capture = System.monotonic_time(:millisecond)
    {{:ok, snapshot}, calls} = observe(fn -> Snapshot.capture(id) end)
    after_capture = System.monotonic_time(:millisecond)

    assert %{__struct__: Snapshot, version: 1, session_id: ^id, meta: ^meta} = snapshot
    assert snapshot.owner == {:concord_turso, Process.whereis(Concord.Turso.DB)}
    assert snapshot.create_revision == created
    assert snapshot.deadline > after_capture
    assert snapshot.deadline >= before_capture + 5_000
    assert snapshot.deadline <= after_capture + 5_000
    assert snapshot.max_bytes == 65_536
    assert :erlang.external_size(snapshot) <= snapshot.max_bytes

    expected_record =
      %Record{
        value: nil,
        create_revision: created,
        mod_revision: created,
        version: 1,
        expires_at: nil,
        lease_id: nil,
        content_type: "application/x-erlang",
        metadata: record_meta
      }
      |> Map.put(:key, key)

    assert snapshot.meta_record == expected_record
    assert Enum.map(calls, & &1.function) == [:revision, :list, :get]
    [revision_call, list_call, get_call] = calls
    assert revision_call.result == {:ok, snapshot.revision}
    assert list_call.result == {:ok, [expected_record], %{has_more: false, last_key: key}}
    assert get_call.result == {:ok, meta}
    assert list_call.args |> hd() |> Keyword.fetch!(:range) == {key, key <> <<0>>}
    assert get_call.args |> hd() == key
    assert_historical_calls([list_call, get_call], snapshot.revision)
    assert_timeouts(calls, 5_000)
  end

  test "sparse head tail overlap and exclusive pages coexist with an empty existing session", %{
    id: id,
    other_id: other_id
  } do
    assert :ok = Store.put_meta(id, %{title: "sparse"})
    assert :ok = Store.put_meta(other_id, %{title: "empty"})

    entries = [
      {0, %{text: "zero"}},
      {7, %{text: "seven"}},
      {91, %{text: "ninety-one"}},
      {999_999_999_999, %{text: "last"}}
    ]

    persist_turns(id, entries)
    deadline = System.monotonic_time(:millisecond) + 4_000
    assert {:ok, snapshot} = Snapshot.capture(id, deadline: deadline)
    assert {:ok, empty} = Snapshot.capture(other_id, deadline: deadline)
    expected = pages(entries)

    assert {:ok, %{turns: head, has_more: true, next_cursor: 0, truncated: false}} =
             Snapshot.read_page(snapshot, limit: 1)

    assert head == Enum.take(expected, 1)

    assert {:ok, %{turns: first, has_more: true, next_cursor: 7, truncated: false}} =
             Snapshot.read_page(snapshot, order: :asc, limit: 2)

    assert first == Enum.take(expected, 2)

    assert {:ok, %{turns: last, has_more: false, next_cursor: nil, truncated: false}} =
             Snapshot.read_page(snapshot, cursor: 7, limit: 2)

    assert last == Enum.drop(expected, 2)

    assert {:ok, %{turns: tail, has_more: true, next_cursor: 7, truncated: false}} =
             Snapshot.read_page(snapshot, order: :desc, limit: 3)

    assert tail == Enum.drop(expected, 1)
    assert Enum.at(first, 1) == hd(tail)

    assert {:ok, %{turns: ^head, has_more: false, next_cursor: nil, truncated: false}} =
             Snapshot.read_page(snapshot, order: :desc, cursor: 7, limit: 3)

    for opts <- [[], [order: :desc], [cursor: 999_999_999_999], [order: :desc, cursor: 0]] do
      assert {:ok, %{turns: [], has_more: false, next_cursor: nil, truncated: false}} =
               Snapshot.read_page(empty, opts)
    end

    assert {:ok, %{turns: [], has_more: false, next_cursor: nil, truncated: false}} =
             Snapshot.read_page(snapshot, order: :desc, cursor: 0)
  end

  test "one captured revision survives ordinary overwrite append and turn deletion when widened",
       %{
         id: id
       } do
    meta = %{title: "original 雪", opaque: %{bytes: <<0, 255>>, tuple: {:kept, 4}}}
    assert :ok = Store.put_meta(id, meta)

    entries =
      for n <- 0..23 do
        {n * 7,
         %{
           "text" => "original #{n} 雪 🌙",
           :opaque => {:bytes, <<0, 255, n>>},
           :nested => [%{at: ~U[2026-11-06 00:00:00Z], index: n}]
         }}
      end

    persist_turns(id, entries)
    deadline = System.monotonic_time(:millisecond) + 4_000
    assert {:ok, snapshot} = Snapshot.capture(id, deadline: deadline)
    original = snapshot
    expected = pages(entries)

    assert {:ok, _} = put(Store.turn_key(id, 0), %{text: "current overwritten head"})
    assert {:ok, _} = put(Store.turn_key(id, 161), %{text: "current overwritten tail"})
    assert {:ok, _} = KV.delete(Store.turn_key(id, 7), engine: :turso, timeout: @timeout)
    assert :ok = Store.commit_turn(id, 168, %{text: "later append"}, %{title: "current"})

    assert {:ok, %{turns: head, has_more: true, next_cursor: 0, truncated: false}} =
             Snapshot.read_page(snapshot, limit: 1)

    assert head == Enum.take(expected, 1)

    assert {:ok, %{turns: tail, has_more: true, next_cursor: 28, truncated: false}} =
             Snapshot.read_page(snapshot, order: :desc)

    assert tail == Enum.drop(expected, 4)

    assert {:ok, %{turns: widened, has_more: false, next_cursor: nil, truncated: false}} =
             Snapshot.read_page(snapshot, order: :desc, limit: 100)

    assert widened == expected

    assert {:ok, %{turns: continuation, has_more: false, next_cursor: nil, truncated: false}} =
             Snapshot.read_page(snapshot, order: :desc, cursor: 28)

    assert continuation == Enum.take(expected, 4)

    assert {:ok, %{turns: ascending, has_more: true, next_cursor: 14, truncated: false}} =
             Snapshot.read_page(snapshot, limit: 3)

    assert ascending == Enum.take(expected, 3)
    assert snapshot == original
    assert snapshot.meta == meta
    assert {:ok, %{title: "current"}} = Store.get_meta(id)
    assert {:ok, current} = Store.list_turns(id)
    assert hd(current) == %{text: "current overwritten head"}
    assert List.last(current) == %{text: "later append"}
    refute Enum.at(expected, 1).turn in current
  end

  test "historical one-key seeks point-read only selected payloads within the complete byte bound",
       %{
         id: id
       } do
    assert :ok = Store.put_meta(id, %{title: "selected values"})
    entries = for n <- 0..5, do: {n * 9, %{text: "turn #{n} 雪", bytes: <<0, 255, n>>}}
    persist_turns(id, entries)
    assert {:ok, snapshot} = Snapshot.capture(id)

    {{:ok, page}, calls} =
      observe(fn -> Snapshot.read_page(snapshot, order: :desc, limit: 3) end)

    assert page == %{
             turns: entries |> pages() |> Enum.drop(3),
             has_more: true,
             next_cursor: 27,
             truncated: false
           }

    lists = Enum.filter(calls, &(&1.function == :list))
    gets = Enum.filter(calls, &(&1.function == :get))
    assert length(lists) == 4
    assert length(lists) <= 512
    assert Enum.map(calls, & &1.function) == [:list, :list, :list, :list, :get, :get, :get]

    prefix = Store.turns_prefix(id)

    assert Enum.map(lists, fn call -> hd(call.args)[:range] end) == [
             {prefix, prefix <> "999999999999" <> <<0>>},
             {prefix, Store.turn_key(id, 45)},
             {prefix, Store.turn_key(id, 36)},
             {prefix, Store.turn_key(id, 27)}
           ]

    assert Enum.all?(lists, fn call -> hd(call.args)[:order] == :desc end)
    assert Enum.map(gets, &hd(&1.args)) == Enum.map([27, 36, 45], &Store.turn_key(id, &1))
    assert Enum.map(gets, & &1.result) == Enum.map(page.turns, &{:ok, &1.turn})
    assert_historical_calls(calls, snapshot.revision)
    assert_timeouts(calls, 5_000)

    record_bytes =
      Enum.reduce(lists, 0, fn call, total ->
        assert {:ok, [record], _page} = call.result
        assert %Record{value: nil} = record
        total + :erlang.external_size(record)
      end)

    exact_bytes = :erlang.external_size(page) + record_bytes
    assert exact_bytes < 65_536

    assert {:ok, ^page} =
             Snapshot.read_page(snapshot, order: :desc, limit: 3, max_bytes: exact_bytes)
  end

  test "validation uses one common revision after ordinary metadata edits appends and unrelated writes",
       %{
         id: id,
         other_id: other_id
       } do
    assert :ok = Store.commit_turn(id, 0, %{text: "first original"}, %{title: "first"})
    assert :ok = Store.commit_turn(other_id, 3, %{text: "second original"}, %{title: "second"})
    deadline = System.monotonic_time(:millisecond) + 4_000
    assert {:ok, first} = Snapshot.capture(id, deadline: deadline)
    assert :ok = Store.put_meta(other_id, %{title: "second captured"})
    assert {:ok, second} = Snapshot.capture(other_id, deadline: deadline)
    originals = [second, first]
    assert first.revision < second.revision

    assert :ok = Store.commit_turn(id, 1, %{text: "first later"}, %{title: "first edited"})

    assert :ok =
             Store.commit_turn(other_id, 4, %{text: "second later"}, %{title: "second edited"})

    assert {:ok, _} = put(Store.value_key(id, "ordinary-unrelated"), %{value: "unrelated"})

    {{:ok, validation}, calls} = observe(fn -> Snapshot.validate_many(originals) end)

    assert validation.targets == [
             %{session_id: other_id, same_lifecycle: true},
             %{session_id: id, same_lifecycle: true}
           ]

    assert validation.revision > second.revision
    assert Enum.map(calls, & &1.function) == [:revision, :list, :list]
    [revision_call | lists] = calls
    assert revision_call.result == {:ok, validation.revision}
    assert_historical_calls(lists, validation.revision)

    for {call, snapshot} <- Enum.zip(lists, originals) do
      key = Store.meta_key(snapshot.session_id)
      assert hd(call.args)[:range] == {key, key <> <<0>>}
      assert {:ok, [record], %{has_more: false, last_key: ^key}} = call.result
      assert %Record{value: nil, expires_at: nil, lease_id: nil} = record
      assert record.key == key
      assert record.create_revision == snapshot.create_revision
      assert record.mod_revision > snapshot.revision
      assert record.version > snapshot.meta_record.version
    end

    assert originals == [second, first]
    assert first.meta == %{title: "first"}
    assert second.meta == %{title: "second captured"}

    assert {:ok, %{turns: [%{index: 0, turn: %{text: "first original"}}]}} =
             Snapshot.read_page(first)

    assert {:ok, %{turns: [%{index: 3, turn: %{text: "second original"}}]}} =
             Snapshot.read_page(second)

    assert_timeouts(calls, 4_000)
  end

  test "one caller allowance remains positive and nonincreasing through capture pages and validation",
       %{
         id: id,
         other_id: other_id
       } do
    assert :ok = Store.commit_turn(id, 0, %{text: "first"}, %{title: "first"})
    assert :ok = Store.commit_turn(other_id, 5, %{text: "second"}, %{title: "second"})
    deadline = System.monotonic_time(:millisecond) + 4_000

    {{first, second}, calls} =
      observe(fn ->
        assert {:ok, first} = Snapshot.capture(id, deadline: deadline)
        assert {:ok, second} = Snapshot.capture(other_id, deadline: deadline)

        assert {:ok, %{turns: [%{index: 0, turn: %{text: "first"}}]}} =
                 Snapshot.read_page(first, limit: 1)

        assert {:ok, %{turns: [%{index: 5, turn: %{text: "second"}}]}} =
                 Snapshot.read_page(second, order: :desc, limit: 100)

        assert {:ok, %{targets: [%{same_lifecycle: true}, %{same_lifecycle: true}]}} =
                 Snapshot.validate_many([first, second])

        {first, second}
      end)

    assert first.deadline == deadline
    assert second.deadline == deadline
    assert first.owner == second.owner
    assert first.owner == {:concord_turso, Process.whereis(Concord.Turso.DB)}
    assert System.monotonic_time(:millisecond) < deadline
    assert_timeouts(calls, 4_000)
  end

  defp put(key, value, opts \\ []) do
    KV.put(key, value, [engine: :turso, compress: false, timeout: @timeout] ++ opts)
  end

  defp persist_turns(id, entries) do
    for {index, value} <- entries do
      assert {:ok, _} = put(Store.turn_key(id, index), value)
    end
  end

  defp pages(entries), do: Enum.map(entries, fn {index, turn} -> %{index: index, turn: turn} end)

  defp assert_historical_calls(calls, revision) do
    for call <- calls do
      opts = List.last(call.args)
      assert opts[:engine] == :turso
      assert opts[:revision] == revision
      refute Keyword.has_key?(opts, :metadata)

      if call.function == :list do
        assert opts[:keys_only] == true
        assert opts[:queue] == true
        assert opts[:limit] == 1
        assert opts[:order] in [:asc, :desc]
      end
    end
  end

  defp assert_timeouts(calls, maximum) do
    timeouts = Enum.map(calls, fn call -> List.last(call.args)[:timeout] end)
    assert timeouts != []
    assert Enum.all?(timeouts, &(&1 in 1..maximum))
    assert timeouts == Enum.sort(timeouts, :desc)
    assert Enum.all?(calls, fn call -> List.last(call.args)[:engine] == :turso end)
  end

  defp observe(fun) do
    Code.ensure_loaded!(KV)
    observer = spawn(fn -> collect([], []) end)
    monitor = Process.monitor(observer)

    for {function, arity} <- @observed do
      :erlang.trace_pattern({KV, function, arity}, [{:_, [], [{:return_trace}]}], [:local])
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

      for {function, arity} <- @observed,
          do: :erlang.trace_pattern({KV, function, arity}, false, [:local])

      send(observer, :stop)
    end
  end

  defp collect(stack, calls) do
    receive do
      {:trace, _, :call, {KV, function, args}} ->
        collect([{function, args} | stack], calls)

      {:trace, _, :return_from, {KV, function, arity}, result} ->
        [{^function, args} | rest] = stack
        ^arity = length(args)
        collect(rest, [%{function: function, args: args, result: result} | calls])

      {:finish, owner} ->
        [] = stack
        send(owner, {:observed_calls, Enum.reverse(calls)})

      :stop ->
        :ok
    end
  end
end
