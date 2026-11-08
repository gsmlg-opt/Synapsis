defmodule Synapsis.Session.SnapshotPublicationFunctionalTest do
  use ExUnit.Case, async: false

  alias Concord.{KV, Turso}
  alias Concord.KV.Record
  alias Synapsis.Message
  alias Synapsis.Session.{Snapshot, Store}

  @timeout 5_000
  @observed [
    {:replace_prefix, 3},
    {:put, 2},
    {:put, 3},
    {:delete, 1},
    {:delete, 2},
    {:put_many, 1},
    {:put_many, 2},
    {:delete_many, 1},
    {:delete_many, 2},
    {:txn, 1},
    {:txn, 2}
  ]

  setup do
    assert :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    on_exit(fn -> assert :ok = Store.delete_session(id) end)
    %{id: id}
  end

  test "snapshot publishes all five hundred turns and raw metadata in one replacement", %{id: id} do
    meta = raw_meta(id, 71)
    assert :ok = Store.put_meta(id, meta)

    messages =
      Enum.map(0..499, fn n ->
        %Message{
          id: Ecto.UUID.generate(),
          session_id: id,
          role: "assistant",
          token_count: n + 1,
          inserted_at: ~U[2026-11-06 01:02:03.000000Z],
          input_provenance: %{"source" => "ordinary", "index" => n},
          internal_turn_source: "ordinary",
          reply_presentation: %{"phase" => "final"},
          parts: [%Synapsis.Part.Text{content: "snapshot #{n} 雪"}]
        }
      end)

    assert :ok = Message.persist_list(id, messages)

    expected_turns =
      Enum.with_index(messages)
      |> Enum.map(fn {message, n} ->
        %{
          id: message.id,
          role: "assistant",
          token_count: n + 1,
          inserted_at: ~U[2026-11-06 01:02:03.000000Z],
          input_provenance: %{"source" => "ordinary", "index" => n},
          internal_turn_source: "ordinary",
          reply_presentation: %{"phase" => "final"},
          parts: [%{type: "text", text: "snapshot #{n} 雪"}]
        }
      end)

    original_meta = record(Store.meta_key(id))
    original_turns = records(id)
    unrelated_key = "sessions/" <> id <> "/opaque/side-value"

    assert {:ok, _} =
             KV.put(unrelated_key, {:retained, <<0, 255>>}, engine: :turso, timeout: @timeout)

    original_unrelated = record(unrelated_key)
    before = revision()
    expected_meta = Map.put(meta, :turn_count, 500)
    puts = turn_pairs(id, expected_turns) ++ [{Store.meta_key(id), expected_meta}]

    {result, calls} = observe(fn -> Snapshot.snapshot_session(id) end)

    assert result == :ok
    assert calls == [{:replace_prefix, [Store.turns_prefix(id), puts, [timeout: 5_000]]}]
    published = revision()
    assert published == before + 1
    assert record(Store.meta_key(id), before) == original_meta
    assert records(id, before) == original_turns
    assert Enum.map(original_turns, &{&1.key, &1.value}) == turn_pairs(id, expected_turns)
    assert_snapshot(id, expected_meta, expected_turns, published)
    current_meta = record(Store.meta_key(id), published)
    assert current_meta.create_revision == original_meta.create_revision
    assert current_meta.version == original_meta.version + 1

    for {current, original} <- Enum.zip(records(id, published), original_turns) do
      assert current.create_revision == original.create_revision
      assert current.version == original.version + 1
    end

    assert record(unrelated_key, before) == original_unrelated
    assert record(unrelated_key, published) == original_unrelated
    assert Message.list_by_session(id) == messages
  end

  test "empty snapshot uses the same coupled replacement and preserves opaque raw fields", %{
    id: id
  } do
    meta = raw_meta(id, 12)
    assert :ok = Store.put_meta(id, meta)
    original_meta = record(Store.meta_key(id))
    before = revision()
    expected_meta = Map.put(meta, :turn_count, 0)

    {result, calls} = observe(fn -> Snapshot.snapshot_session(id) end)

    assert result == :ok

    assert calls == [
             {:replace_prefix,
              [Store.turns_prefix(id), [{Store.meta_key(id), expected_meta}], [timeout: 5_000]]}
           ]

    published = revision()
    assert published == before + 1
    assert record(Store.meta_key(id), before) == original_meta
    assert records(id, before) == []
    assert_snapshot(id, expected_meta, [], published)
    current = record(Store.meta_key(id), published)
    assert current.create_revision == original_meta.create_revision
    assert current.version == original_meta.version + 1
  end

  defp raw_meta(id, count) do
    %{
      :id => id,
      :title => "opaque snapshot 雪",
      :status => "idle",
      :turn_count => count,
      "title" => "parallel string key retained",
      "turn_count" => "opaque string count",
      "extension" => %{nested: [{:bytes, <<0, 255, 128>>}, ~U[2026-11-06 00:00:00Z]]},
      :snapshotted_at => "existing timestamp stays",
      :opaque => {:tuple, <<0, 254>>}
    }
  end

  defp assert_snapshot(id, meta, turns, published) do
    assert {:ok, ^meta} = Store.get_meta(id)
    assert {:ok, ^turns} = Store.list_turns(id)
    assert {:ok, %{meta: ^meta, turns: ^turns}} = Snapshot.rehydrate(id)
    assert %Record{value: ^meta, mod_revision: ^published} = record(Store.meta_key(id), published)
    rows = records(id, published)
    assert Enum.map(rows, &{&1.key, &1.value}) == turn_pairs(id, turns)
    assert Enum.all?(rows, &(&1.mod_revision == published))
  end

  defp turn_pairs(id, turns) do
    turns |> Enum.with_index() |> Enum.map(fn {turn, n} -> {Store.turn_key(id, n), turn} end)
  end

  defp revision do
    assert {:ok, revision} = Turso.revision(timeout: @timeout)
    revision
  end

  defp record(key, revision \\ nil) do
    opts = [engine: :turso, range: {key, key <> <<0>>}, limit: 1, timeout: @timeout]
    opts = if revision, do: Keyword.put(opts, :revision, revision), else: opts
    assert {:ok, [record], %{has_more: false}} = KV.list(opts)
    record
  end

  defp records(id, revision \\ nil) do
    opts = [engine: :turso, prefix: Store.turns_prefix(id), limit: 500, timeout: @timeout]
    opts = if revision, do: Keyword.put(opts, :revision, revision), else: opts
    assert {:ok, rows, %{has_more: false}} = KV.list(opts)
    rows
  end

  defp observe(fun) do
    Code.ensure_loaded!(Turso)
    observer = spawn(fn -> collect([]) end)
    monitor = Process.monitor(observer)

    for {function, arity} <- @observed,
        do: :erlang.trace_pattern({Turso, function, arity}, true, [:local])

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
          do: :erlang.trace_pattern({Turso, function, arity}, false, [:local])

      send(observer, :stop)
    end
  end

  defp collect(calls) do
    receive do
      {:trace, _, :call, {Turso, function, args}} -> collect([{function, args} | calls])
      {:finish, owner} -> send(owner, {:observed_calls, Enum.reverse(calls)})
      :stop -> :ok
    end
  end
end
