defmodule Synapsis.Workboard.DataNotificationFunctionalTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Synapsis.Workboard.Store

  # Independent accepted Data contract fixtures, authored before any product
  # candidate inspection. Payloads are caller-owned opaque JSON storage facts,
  # not evidence of Core subscription/cursor normalization or native invocation.
  @time 1_800_000_000_000
  @creator %{"runId" => "fixture:387:data", "extra" => [nil, true, 1.5, "雪😀"]}

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{scope: "fixture:387:data/雪/" <> Ecto.UUID.generate()}
  end

  test "create publishes exact subscriptions with marker and paginated historical reads", %{
    scope: scope
  } do
    empty = snapshot(scope)
    one = subscription(scope, "alpha", "First 雪😀", @time)
    two = subscription(scope, "beta", "Second café", @time + 2)
    three = subscription(scope, "alpha", "Third", @time + 1)
    first = commit(empty, :create, one)
    assert first == %{subscription: one, storage_revision: first.storage_revision}
    first_point = snapshot(scope)
    second = commit(first_point, :create, two)
    third = commit(snapshot(scope), :create, three)
    assert second.storage_revision > first.storage_revision
    assert third.storage_revision > second.storage_revision
    point = snapshot(scope)
    rows = pages(point, 1)
    assert Enum.map(rows, & &1.record.id) == Enum.sort([one.id, two.id, three.id])

    assert Map.new(rows, &{&1.record.id, &1}) == %{
             one.id => %{record: one, storage_revision: first.storage_revision},
             two.id => %{record: two, storage_revision: second.storage_revision},
             three.id => %{record: three, storage_revision: third.storage_revision}
           }

    assert pages(empty, 2) == []
    assert pages(first_point, 2) == [%{record: one, storage_revision: first.storage_revision}]
    assert Store.notification_sequence(point, deadline()) == {:ok, 0}
    assert snapshot(scope) == point
    assert marker(scope).mod_revision == third.storage_revision
  end

  test "advance retains caller facts and historical sequence-bearing and sequence-free cursors",
       %{scope: scope} do
    original = subscription(scope, "alpha", "Cursor 雪😀", @time)

    original = %{
      original
      | payload: Map.put(original.payload, "deliveredEventIds", ["prior-a", "prior-b"])
    }

    created = commit(snapshot(scope), :create, original)
    before = snapshot(scope)

    payload =
      original.payload
      |> Map.delete("deliveredEventIds")
      |> Map.merge(%{
        "lastEventAt" => @time + 10,
        "lastEventId" => "literal-ordinary-a",
        "lastEventSequence" => (@time + 10) * 1000 + 2,
        "updatedAt" => @time + 20
      })

    advanced = %{original | revision: 2, payload: payload}
    ack = commit(before, :advance, advanced)
    assert ack.storage_revision > created.storage_revision

    assert row(before, original.id) == %{
             record: original,
             storage_revision: created.storage_revision
           }

    sequenced = snapshot(scope)

    assert row(sequenced, original.id) == %{
             record: advanced,
             storage_revision: ack.storage_revision
           }

    payload =
      payload
      |> Map.delete("lastEventSequence")
      |> Map.merge(%{
        "lastEventAt" => @time + 11,
        "lastEventId" => "literal-ordinary-b",
        "updatedAt" => @time + 30
      })

    legacy = %{advanced | revision: 3, payload: payload}
    final = commit(sequenced, :advance, legacy)

    assert row(snapshot(scope), original.id) == %{
             record: legacy,
             storage_revision: final.storage_revision
           }

    assert row(sequenced, original.id).record == advanced
    assert legacy.provenance == @creator
    assert Store.notification_sequence(snapshot(scope), deadline()) == {:ok, 0}
    assert pages(before, 100) == [%{record: original, storage_revision: created.storage_revision}]
  end

  test "successful deletion publishes marker and preserves selected historical subscription", %{
    scope: scope
  } do
    selected = subscription(scope, "alpha", "Selected", @time)
    retained = subscription(scope, "beta", "Retained", @time + 1)
    selected_ack = commit(snapshot(scope), :create, selected)
    retained_ack = commit(snapshot(scope), :create, retained)
    before = snapshot(scope)

    assert {:ok, deleted} =
             Store.commit_subscription(
               before,
               %{kind: :delete, subscription: selected},
               deadline()
             )

    assert deleted == %{deleted: true, storage_revision: deleted.storage_revision}
    assert deleted.storage_revision > retained_ack.storage_revision
    assert marker(scope).mod_revision == deleted.storage_revision
    after_point = snapshot(scope)
    assert Store.get_subscription(after_point, selected.id, deadline()) == :not_found

    assert row(before, selected.id) == %{
             record: selected,
             storage_revision: selected_ack.storage_revision
           }

    assert row(after_point, retained.id) == %{
             record: retained,
             storage_revision: retained_ack.storage_revision
           }

    assert pages(after_point, 1) == [
             %{record: retained, storage_revision: retained_ack.storage_revision}
           ]

    assert Enum.sort_by(pages(before, 1), & &1.record.id) ==
             Enum.sort_by(
               [
                 %{record: selected, storage_revision: selected_ack.storage_revision},
                 %{record: retained, storage_revision: retained_ack.storage_revision}
               ],
               & &1.record.id
             )

    assert Store.notification_sequence(after_point, deadline()) == {:ok, 0}
    assert snapshot(scope) == after_point
  end

  test "disjoint subscription creates from one older snapshot retain independent row semantics",
       %{scope: scope} do
    point = snapshot(scope)
    one = subscription(scope, "alpha", "First old snapshot", @time)
    two = subscription(scope, "beta", "Second old snapshot", @time + 1)
    a = commit(point, :create, one)
    marker_a = marker(scope)
    b = commit(point, :create, two)
    marker_b = marker(scope)
    assert marker_a.value == marker_b.value
    assert marker_a.mod_revision == a.storage_revision
    assert marker_b.mod_revision == b.storage_revision
    assert b.storage_revision > a.storage_revision
    now = snapshot(scope)
    assert row(now, one.id).record == one
    assert row(now, two.id).record == two
    assert Store.notification_sequence(now, deadline()) == {:ok, 0}
  end

  test "normal creator completion leaves full cursor available to distinct fresh reader", %{
    scope: scope
  } do
    creator =
      Task.async(fn ->
        original = subscription(scope, "alpha", "Caller handoff 雪😀", @time)
        created = commit(snapshot(scope), :create, original)
        old = snapshot(scope)

        payload =
          Map.merge(original.payload, %{
            "updatedAt" => @time + 1,
            "lastEventAt" => @time,
            "lastEventId" => "ordinary-handoff",
            "lastEventSequence" => @time * 1000
          })

        next = %{original | revision: 2, payload: payload}
        advanced = commit(old, :advance, next)
        %{original: original, created: created, old: old, advanced: advanced, next: next}
      end)

    written = Task.await(creator, 5_000)
    refute Process.alive?(creator.pid)

    reader =
      Task.async(fn ->
        now = snapshot(scope)

        assert row(now, written.next.id) == %{
                 record: written.next,
                 storage_revision: written.advanced.storage_revision
               }

        assert row(written.old, written.original.id) == %{
                 record: written.original,
                 storage_revision: written.created.storage_revision
               }

        assert pages(now, 1) == [
                 %{record: written.next, storage_revision: written.advanced.storage_revision}
               ]

        assert Store.notification_sequence(now, deadline()) == {:ok, 0}
        assert snapshot(scope) == now
        now
      end)

    point = Task.await(reader, 5_000)
    refute Process.alive?(reader.pid)
    assert creator.pid != reader.pid
    assert row(point, written.next.id).record == written.next
    assert marker(scope).mod_revision == written.advanced.storage_revision
  end

  defp subscription(scope, board, target, created_at) do
    id = Ecto.UUID.generate()

    %{
      schema_version: 1,
      id: id,
      scope: scope,
      revision: 1,
      provenance: @creator,
      payload: %{
        "id" => id,
        "boardId" => board,
        "target" => target,
        "eventKinds" => ["completed", "stale"],
        "sessionKey" => "agent:fixture:topic",
        "runId" => "fixture-ordinary-run",
        "createdAt" => created_at,
        "updatedAt" => created_at,
        "opaque" => %{"preserved" => [nil, false, 1.5, "雪😀"]}
      }
    }
  end

  defp commit(point, kind, value) do
    assert {:ok, ack} =
             Store.commit_subscription(point, %{kind: kind, subscription: value}, deadline())

    assert ack == %{subscription: value, storage_revision: ack.storage_revision}
    now = snapshot(value.scope)
    assert row(now, value.id) == %{record: value, storage_revision: ack.storage_revision}
    assert marker(value.scope).mod_revision == ack.storage_revision
    ack
  end

  defp row(point, id) do
    assert {:ok, value} = Store.get_subscription(point, id, deadline())
    value
  end

  defp pages(point, limit), do: pages(point, limit, nil, [])

  defp pages(point, limit, cursor, acc) do
    assert {:ok, page} =
             Store.subscriptions_page(point, [limit: limit, cursor: cursor], deadline())

    assert Enum.sort(Map.keys(page)) == [:next_cursor, :rows]
    assert length(page.rows) <= limit
    next = acc ++ page.rows
    if page.next_cursor, do: pages(point, limit, page.next_cursor, next), else: next
  end

  defp snapshot(scope) do
    assert {:ok, value} = Store.snapshot(scope, deadline())
    value
  end

  defp marker(scope) do
    key =
      "coord/workboard/v1/scopes/" <>
        Base.url_encode64(scope, padding: false) <> "/control/mutation_frontier"

    assert {:ok, %Concord.KV.Record{} = record} =
             KV.get(key, engine: :turso, metadata: true, timeout: 5_000)

    record
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
