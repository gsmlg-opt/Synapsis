defmodule Synapsis.Session.StoreValueCASTest do
  use ExUnit.Case, async: false

  @moduletag upstream_blocker: "gsmlg-dev/concord#107"

  alias Concord.Turso, as: KV
  alias Synapsis.Session.Store

  setup do
    assert :ok = Store.ensure_started()
    ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    on_exit(fn ->
      for id <- ids,
          suffix <- ["permission", "permission-extra", "todos"],
          do: KV.delete(Store.value_key(id, suffix), timeout: 5_000)
    end)

    [id: hd(ids), other_id: List.last(ids)]
  end

  test "missing snapshots remain absent even when a longer key exists", %{id: id} do
    assert :ok = Store.put_value(id, "permission-extra", %{private: "neighbor"})
    assert :not_found = Store.value_snapshot(id, "permission")
  end

  test "snapshots preserve raw atom keys, unknown metadata, timestamps and number types", %{
    id: id
  } do
    raw = %{
      session_id: id,
      mode: :approve,
      inserted_at: ~U[2026-10-25 01:02:03.123456Z],
      updated_at: ~U[2026-10-25 02:03:04.654321Z],
      future_metadata: %{mixed: [1, 1.0, nil, :unknown], nested: %{"keep" => true}}
    }

    assert :ok = Store.put_value(id, "permission", raw)
    assert {:ok, %{value: value, revision: revision}} = Store.value_snapshot(id, "permission")
    assert value === raw
    assert is_integer(revision) and revision > 0
  end

  test "revision zero creates only when absent", %{id: id} do
    raw = %{mode: :approve, future_field: :keep}
    assert :ok = Store.put_value_if_revision(id, "permission", raw, 0)
    assert {:ok, %{value: ^raw, revision: revision}} = Store.value_snapshot(id, "permission")
    assert revision > 0

    assert {:error, :conflict} =
             Store.put_value_if_revision(id, "permission", %{mode: :auto}, 0)

    assert Store.get_value(id, "permission") === raw
  end

  test "the exact current revision permits replacement and advances the revision", %{id: id} do
    assert :ok = Store.put_value(id, "permission", %{mode: :approve})
    assert {:ok, %{revision: revision}} = Store.value_snapshot(id, "permission")
    replacement = %{mode: :auto, updated_at: ~U[2026-10-25 03:04:05Z], unknown: :preserved}

    assert :ok = Store.put_value_if_revision(id, "permission", replacement, revision)

    assert {:ok, %{value: value, revision: next_revision}} =
             Store.value_snapshot(id, "permission")

    assert value === replacement
    assert next_revision > revision
  end

  test "an intervening writer causes conflict and its raw value survives", %{id: id} do
    assert :ok = Store.put_value(id, "permission", %{mode: :approve})
    assert {:ok, %{revision: revision}} = Store.value_snapshot(id, "permission")
    writer_value = %{mode: :deny, unknown: %{numeric: 1.0}, updated_at: ~U[2026-10-25 04:05:06Z]}
    assert :ok = Store.put_value(id, "permission", writer_value)

    assert {:error, :conflict} =
             Store.put_value_if_revision(id, "permission", %{mode: :auto}, revision)

    assert Store.get_value(id, "permission") === writer_value
  end

  test "a deleted snapshot cannot be recreated using its old positive revision", %{id: id} do
    assert :ok = Store.put_value(id, "permission", %{mode: :approve})
    assert {:ok, %{revision: revision}} = Store.value_snapshot(id, "permission")
    assert :ok = KV.delete(Store.value_key(id, "permission"), timeout: 5_000)

    assert {:error, :conflict} =
             Store.put_value_if_revision(id, "permission", %{mode: :auto}, revision)

    assert :not_found = Store.value_snapshot(id, "permission")
  end

  test "a same-value write invalidates an earlier snapshot", %{id: id} do
    raw = %{mode: :approve, future_field: :keep}
    assert :ok = Store.put_value(id, "permission", raw)
    assert {:ok, %{revision: revision}} = Store.value_snapshot(id, "permission")
    assert :ok = Store.put_value(id, "permission", raw)

    assert {:error, :conflict} =
             Store.put_value_if_revision(id, "permission", %{mode: :auto}, revision)

    assert Store.get_value(id, "permission") === raw
  end

  test "ABA replacement invalidates an earlier snapshot", %{id: id} do
    raw = %{mode: :approve}
    assert :ok = Store.put_value(id, "permission", raw)
    assert {:ok, %{revision: revision}} = Store.value_snapshot(id, "permission")
    assert :ok = Store.put_value(id, "permission", %{mode: :deny})
    assert :ok = Store.put_value(id, "permission", raw)

    assert {:error, :conflict} =
             Store.put_value_if_revision(id, "permission", %{mode: :auto}, revision)

    assert Store.get_value(id, "permission") === raw
  end

  test "changing integer one to float one invalidates an earlier snapshot", %{id: id} do
    assert :ok = Store.put_value(id, "permission", %{version: 1})
    assert {:ok, %{revision: revision}} = Store.value_snapshot(id, "permission")
    assert :ok = Store.put_value(id, "permission", %{version: 1.0})

    assert {:error, :conflict} =
             Store.put_value_if_revision(id, "permission", %{version: 2}, revision)

    assert Store.get_value(id, "permission") === %{version: 1.0}
  end

  test "session IDs and suffixes remain isolated", %{id: id, other_id: other_id} do
    assert :ok = Store.put_value_if_revision(id, "permission", :first, 0)
    assert :ok = Store.put_value_if_revision(other_id, "permission", :second, 0)
    assert :ok = Store.put_value_if_revision(id, "todos", :third, 0)
    assert {:ok, %{value: :first, revision: revision}} = Store.value_snapshot(id, "permission")

    assert :ok = Store.put_value_if_revision(id, "permission", :replacement, revision)
    assert {:ok, %{value: :replacement}} = Store.value_snapshot(id, "permission")
    assert {:ok, %{value: :second}} = Store.value_snapshot(other_id, "permission")
    assert {:ok, %{value: :third}} = Store.value_snapshot(id, "todos")
  end

  test "invalid IDs, suffixes and revisions return bounded input errors", %{id: id} do
    for {bad_id, bad_suffix} <- [
          {nil, "permission"},
          {1, "permission"},
          {"", "permission"},
          {"../other", "permission"},
          {"bad\0id", "permission"},
          {String.duplicate("x", 4_097), "permission"},
          {id, nil},
          {id, ""},
          {id, "../permission"},
          {id, "bad\0suffix"},
          {id, String.duplicate("x", 4_097)}
        ] do
      assert {:error, :invalid_input} = Store.value_snapshot(bad_id, bad_suffix)

      assert {:error, :invalid_input} =
               Store.put_value_if_revision(bad_id, bad_suffix, :value, 0)
    end

    for revision <- [-1, 1.0, nil, :latest, "1"] do
      assert {:error, :invalid_input} =
               Store.put_value_if_revision(id, "permission", :value, revision)
    end

    assert :not_found = Store.value_snapshot(id, "permission")
  end

  test "options are closed, finite and bounded", %{id: id} do
    for opts <- [
          nil,
          %{},
          [:timeout],
          [{"timeout", 20}],
          [timeout: :infinity],
          [timeout: nil],
          [timeout: 0],
          [timeout: -1],
          [timeout: 1.0],
          [timeout: 5_001],
          [timeout: 20, timeout: 30],
          [engine: :local],
          [unknown: "private option"]
        ] do
      assert {:error, :invalid_input} = Store.value_snapshot(id, "permission", opts)

      assert {:error, :invalid_input} =
               Store.put_value_if_revision(id, "permission", :value, 0, opts)
    end

    assert :ok = Store.put_value_if_revision(id, "permission", :value, 0, timeout: 5_000)
    assert {:ok, %{value: :value}} = Store.value_snapshot(id, "permission", timeout: 5_000)
  end

  test "a busy real Turso connection returns finite timeouts without changing values", %{id: id} do
    assert :ok = Store.put_value(id, "permission", :original)
    owner = self()
    supervisor = start_supervised!(Task.Supervisor)

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        DBConnection.run(Concord.Turso.DB, fn _conn ->
          send(owner, {:checked_out, self()})

          receive do
            :release -> :ok
          after
            2_000 -> :holder_timeout
          end
        end)
      end)

    try do
      assert_receive {:checked_out, pid}, 1_000
      assert pid == holder.pid
      started = System.monotonic_time(:millisecond)
      assert {:error, :timeout} = Store.value_snapshot(id, "permission", timeout: 20)

      assert {:error, :timeout} =
               Store.put_value_if_revision(id, "permission", :replacement, 0, timeout: 20)

      assert System.monotonic_time(:millisecond) - started < 1_000
    after
      send(holder.pid, :release)
      assert :ok = Task.await(holder, 1_000)
    end

    assert Store.get_value(id, "permission") === :original
  end
end
