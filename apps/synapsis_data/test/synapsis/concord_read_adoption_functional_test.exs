defmodule Synapsis.ConcordReadAdoptionFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Concord.KV
  alias Concord.KV.Record
  alias Concord.Turso
  alias Synapsis.Runtime.Store, as: RuntimeStore
  alias Synapsis.Session.Store, as: SessionStore

  @timeout 5_000

  setup do
    assert :ok = SessionStore.ensure_started()
    %{id: Ecto.UUID.generate()}
  end

  test "public point reads preserve values and exact record revisions across an update", %{id: id} do
    key = "adoption/concord-read/" <> id <> "/point"
    cleanup_keys([key])
    first = %{text: "first value", count: 1}
    metadata = %{source: "adoption"}

    assert {:ok, %{revision: created_revision, prev_kv: nil}} =
             KV.put(key, first,
               engine: :turso,
               compress: false,
               content_type: "application/json",
               metadata: metadata,
               timeout: @timeout
             )

    assert is_integer(created_revision) and created_revision > 0
    assert {:ok, ^first} = Turso.get(key, timeout: @timeout)
    assert {:ok, ^first} = KV.get(key, engine: :turso, timeout: @timeout)

    expected = %Record{
      value: first,
      create_revision: created_revision,
      mod_revision: created_revision,
      version: 1,
      content_type: "application/json",
      metadata: metadata
    }

    assert {:ok, ^expected} = KV.get(key, engine: :turso, metadata: true, timeout: @timeout)

    second = %{text: "updated value", count: 2}

    assert {:ok, %{revision: updated_revision, prev_kv: nil}} =
             KV.put(key, second,
               engine: :turso,
               compress: false,
               content_type: "application/json",
               metadata: metadata,
               timeout: @timeout
             )

    assert updated_revision > created_revision
    updated = %{expected | value: second, mod_revision: updated_revision, version: 2}
    assert {:ok, ^second} = Turso.get(key, timeout: @timeout)
    assert {:ok, ^updated} = KV.get(key, engine: :turso, metadata: true, timeout: @timeout)
  end

  test "forced compression is transparent to public value and metadata point reads", %{id: id} do
    key = "adoption/concord-read/" <> id <> "/compressed"
    cleanup_keys([key])
    value = %{text: String.duplicate("compressed 雪 value ", 500), rows: Enum.to_list(1..20)}

    assert {:ok, %{revision: revision, prev_kv: nil}} =
             KV.put(key, value, engine: :turso, compress: true, timeout: @timeout)

    # get_many returns stored values; unlike point getters, it does not decompress.
    assert {:ok, %{^key => {:ok, {:compressed, algorithm, bytes}}} = stored} =
             Turso.get_many([key], timeout: @timeout)

    assert map_size(stored) == 1
    assert algorithm in [:zlib, :gzip, :none]
    assert is_binary(bytes)
    assert {:ok, ^value} = Turso.get(key, timeout: @timeout)
    assert {:ok, ^value} = KV.get(key, engine: :turso, timeout: @timeout)

    expected = %Record{
      value: value,
      create_revision: revision,
      mod_revision: revision,
      version: 1
    }

    assert {:ok, ^expected} = KV.get(key, engine: :turso, metadata: true, timeout: @timeout)
  end

  test "get_many returns the exact success map for every present key", %{id: id} do
    prefix = "adoption/concord-read/" <> id <> "/batch/"
    pairs = [{prefix <> "a", "alpha"}, {prefix <> "b", %{items: [1, 2]}}, {prefix <> "c", 17}]
    keys = Enum.map(pairs, &elem(&1, 0))
    cleanup_keys(keys)

    for {key, value} <- pairs do
      assert :ok = Turso.put(key, value, compress: false, timeout: @timeout)
    end

    expected = Map.new(pairs, fn {key, value} -> {key, {:ok, value}} end)
    assert {:ok, ^expected} = Turso.get_many(keys, timeout: @timeout)
  end

  test "a metadata read fences a successful CAS using the recalculated remaining budget", %{
    id: id
  } do
    key = "adoption/concord-read/" <> id <> "/cas"
    cleanup_keys([key])
    first = %{revision: 1, content: "original"}
    second = %{revision: 2, content: "updated"}

    assert {:ok, %{revision: created_revision, prev_kv: nil}} =
             KV.put(key, first, engine: :turso, compress: false, timeout: @timeout)

    deadline = System.monotonic_time(:millisecond) + @timeout

    assert {:ok, %Record{value: ^first, mod_revision: observed_revision}} =
             KV.get(key,
               engine: :turso,
               metadata: true,
               timeout: remaining_timeout(deadline)
             )

    assert observed_revision == created_revision
    remaining = remaining_timeout(deadline)

    assert {:ok, %{succeeded: true, revision: updated_revision, current_kv: current}} =
             Turso.compare_and_swap(key, second,
               mod_revision: observed_revision,
               compress: false,
               timeout: remaining
             )

    assert updated_revision > observed_revision

    expected = %Record{
      value: second,
      create_revision: created_revision,
      mod_revision: updated_revision,
      version: 2
    }

    assert current == %{expected | value: nil}

    assert {:ok, ^expected} =
             KV.get(key,
               engine: :turso,
               metadata: true,
               timeout: remaining_timeout(deadline)
             )

    assert {:ok, ^second} = Turso.get(key, timeout: remaining_timeout(deadline))
  end

  test "real runtime aggregate creation and update preserve facts and projections", %{id: id} do
    run_id = Ecto.UUID.generate()
    namespace_segment = segment(id)
    run_segment = segment(run_id)

    cleanup_keys([
      "coord/runtime/runs/" <> namespace_segment <> "/" <> run_segment,
      "coord/runtime/facts/" <>
        namespace_segment <> "/" <> segment(:adoption) <> "/" <> run_segment,
      "coord/runtime/projections/" <> namespace_segment
    ])

    fact = %{run_id: run_id, content: "recorded fact"}
    assert :ok = RuntimeStore.put_fact(id, :adoption, run_id, fact)
    assert {:ok, ^fact} = RuntimeStore.get_fact(id, :adoption, run_id)
    assert {:ok, [^fact]} = RuntimeStore.list_facts(id, :adoption)

    first = %{
      revision: 1,
      incarnation: 3,
      run: %{run_id: run_id, state: :running, history: ["first"]},
      effects: [],
      outbox: [%{id: "first-item", value: "initial"}]
    }

    assert :ok = RuntimeStore.commit(id, run_id, 0, 3, first)
    assert {:ok, ^first} = RuntimeStore.load(id, run_id)

    second = %{
      first
      | revision: 2,
        run: %{run_id: run_id, state: :completed, history: ["first", "second"]},
        outbox: [%{id: "second-item", value: "complete"}]
    }

    assert :ok = RuntimeStore.commit(id, run_id, 1, 3, second)
    assert {:ok, ^second} = RuntimeStore.load(id, run_id)

    projection = %{run_id: run_id, revision: 2, state: :completed}
    assert :ok = RuntimeStore.put_projection(id, projection)
    assert {:ok, ^projection} = RuntimeStore.get_projection(id)
    assert {:ok, ^fact} = RuntimeStore.get_fact(id, :adoption, run_id)
  end

  test "session metadata, turns, context pages and recent history roundtrip exactly", %{id: id} do
    on_exit(fn -> assert :ok = SessionStore.delete_session(id) end)
    initial_meta = %{id: id, status: "idle", title: "Concord read adoption"}
    assert :ok = SessionStore.put_meta(id, initial_meta)
    assert {:ok, ^initial_meta} = SessionStore.get_meta(id, timeout: @timeout)

    turns = [
      %{role: "user", content: "First message 雪"},
      %{role: "assistant", content: "First response"},
      %{role: "user", content: "Next message"}
    ]

    for {turn, index} <- Enum.with_index(turns) do
      meta = Map.put(initial_meta, :latest_turn, index)
      assert :ok = SessionStore.commit_turn(id, index, turn, meta)
      assert {:ok, ^turn} = SessionStore.get_turn(id, index)
      assert {:ok, ^meta} = SessionStore.get_meta(id, timeout: @timeout)
    end

    assert {:ok, ^turns} = SessionStore.list_turns(id)
    recent = Enum.take(turns, -2)
    assert {:ok, ^recent} = SessionStore.list_recent_turns(id, 2)

    page = %{
      turns: Enum.with_index(turns, fn turn, index -> %{index: index, turn: turn} end),
      next_cursor: nil,
      has_more: false,
      truncated: false
    }

    assert {:ok, ^page} =
             SessionStore.list_turn_page(id,
               limit: 3,
               deadline: System.monotonic_time(:millisecond) + @timeout,
               max_bytes: 65_536
             )
  end

  defp cleanup_keys(keys) do
    on_exit(fn -> assert {:ok, _} = Turso.delete_many(keys, timeout: @timeout) end)
  end

  defp remaining_timeout(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    assert remaining > 0
    remaining
  end

  defp segment(value), do: value |> to_string() |> Base.url_encode64(padding: false)
end
