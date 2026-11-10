defmodule Synapsis.Session.ReadSnapshotWindowFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Session.{PendingInputStore, ReadSnapshot, Store}

  setup do
    assert :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    assert :ok = Store.put_meta(id, %{id: id, title: "Window 雪 😀", turn_count: 900_000})
    on_exit(fn -> Store.delete_session(id) end)
    %{id: id}
  end

  test "ordinal windows select dense ranks over sparse durable keys", %{id: id} do
    indices = [0, 7, 91, 120, 999]

    for {index, ordinal} <- Enum.with_index(indices, 1) do
      assert :ok = Store.commit_turn(id, index, %{text: "Row #{ordinal} 雪"}, %{id: id})
    end

    assert {:ok, snapshot} = ReadSnapshot.capture(id)

    for {start, count, ranks} <- [{1, 2, [1, 2]}, {3, 2, [3, 4]}, {5, 2, [5]}] do
      assert ReadSnapshot.ordinal_window(snapshot, start: start, limit: count) ==
               {:ok,
                %{
                  total_turns: 5,
                  entries: Enum.map(ranks, &%{index: Enum.at(indices, &1 - 1), ordinal: &1})
                }}
    end
  end

  test "ordinary earlier windows retain original rank and total after an append", %{id: id} do
    rows = for rank <- 1..241, do: {(rank - 1) * 7, %{text: "Original #{rank} 😀"}}
    puts = Enum.map(rows, fn {index, turn} -> {Store.turn_key(id, index), turn} end)
    assert {:ok, _} = Concord.Turso.put_many(puts, timeout: 5_000)
    deadline = System.monotonic_time(:millisecond) + 5_000
    assert {:ok, snapshot} = ReadSnapshot.capture(id, deadline: deadline)
    original = snapshot
    assert :ok = Store.commit_turn(id, 9_999, %{text: "Later append"}, %{id: id})

    assert ReadSnapshot.ordinal_window(snapshot, start: 93, limit: 111, max_bytes: 1_048_576) ==
             {:ok,
              %{
                total_turns: 241,
                entries: Enum.map(93..203, &%{index: (&1 - 1) * 7, ordinal: &1})
              }}

    assert snapshot == original
    assert snapshot.deadline == deadline
    assert snapshot.owner == {:concord_turso, Process.whereis(Concord.Turso.DB)}
    assert {:ok, fresh} = ReadSnapshot.capture(id)

    assert {:ok, %{total_turns: 242, entries: [%{index: 9_999, ordinal: 242}]}} =
             ReadSnapshot.ordinal_window(fresh, start: 242, limit: 1)
  end

  test "an existing empty session has an empty ordinal and pending window", %{id: id} do
    assert {:ok, snapshot} = ReadSnapshot.capture(id)

    assert ReadSnapshot.ordinal_window(snapshot, start: 1, limit: 3) ==
             {:ok, %{total_turns: 0, entries: []}}

    assert ReadSnapshot.read_pending(snapshot) == {:ok, %{entries: []}}
  end

  test "pending reads retain original producer order and revision through adoption and append", %{
    id: id
  } do
    assert {:ok, first} = PendingInputStore.append_prompt(id, "First question 雪", [])
    assert {:ok, steer} = PendingInputStore.append_steer(id, "Keep the ordinary detail 😀")
    assert {:ok, second} = PendingInputStore.append_prompt(id, "Second question", [])
    assert {:ok, {:present, entries, _}} = Store.read_pending_inputs(id)
    assert Enum.map(entries, & &1.id) == [first.id, steer.id, second.id]
    assert {:ok, snapshot} = ReadSnapshot.capture(id)
    original = snapshot

    assert {:ok, taken} = PendingInputStore.take_next_prompt(id)
    assert taken.id == first.id
    assert :ok = PendingInputStore.mark_consumed(id, first.id)
    assert {:ok, last} = PendingInputStore.append_prompt(id, "After capture", [])

    assert ReadSnapshot.read_pending(snapshot, max_bytes: 1_048_576) ==
             {:ok, %{entries: entries}}

    assert snapshot == original

    assert {:ok, fresh} = ReadSnapshot.capture(id)
    assert {:ok, %{entries: current}} = ReadSnapshot.read_pending(fresh)
    assert Enum.map(current, & &1.id) == [first.id, steer.id, second.id, last.id]
    assert Enum.map(current, & &1.status) == ["consumed", "queued", "queued", "queued"]

    assert Enum.map(current, & &1.inserted_at) ==
             Enum.map(entries, & &1.inserted_at) ++ [last.inserted_at]

    assert {:ok, %{targets: [_]}} = ReadSnapshot.validate_many([snapshot])
  end
end
