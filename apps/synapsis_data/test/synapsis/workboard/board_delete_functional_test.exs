defmodule Synapsis.Workboard.DataBoardDeleteFunctionalTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Synapsis.Workboard.Store

  # Independent accepted Data transaction contract, before product candidate
  # inspection. Payloads are caller-owned opaque JSON; these fixtures do not
  # assert Core normalization, policy, native/model invocation or race rejection.
  @time 1_800_000_000_000
  @creator %{"runId" => "fixture:388:data", "extra" => [nil, false, 1.5, "雪😀"]}

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{scope: "fixture:388:data/雪/" <> Ecto.UUID.generate()}
  end

  test "one deletion atomically removes exact board name and selected subscriptions while retaining historical facts",
       %{scope: scope} do
    {selected, selected_ack} = board(scope, "alpha", "Selected 雪😀")
    {retained, retained_ack} = board(scope, "beta", "Retained café")
    {one, one_ack} = subscription(scope, "alpha", "First", %{})

    {two, two_ack} =
      subscription(scope, "alpha", "Cross-card selection", %{"cardId" => Ecto.UUID.generate()})

    {other, other_ack} = subscription(scope, "beta", "Retained", %{})
    before = snapshot(scope)
    selected_key = key_for(scope, selected)
    one_key = key_for(scope, one)
    two_key = key_for(scope, two)
    name_key = key_for(scope, selected.id)
    retained_history = history(key_for(scope, retained))
    other_history = history(key_for(scope, other))
    assert Store.notification_sequence(before, deadline()) == {:ok, 0}

    ack = delete(before, selected, [two, one])
    assert ack.storage_revision > other_ack.storage_revision
    current = snapshot(scope)
    assert Store.get_board(current, "alpha", deadline()) == :not_found
    assert Store.get_subscription(current, one.id, deadline()) == :not_found
    assert Store.get_subscription(current, two.id, deadline()) == :not_found

    assert get_board(current, "beta") == %{
             record: retained,
             storage_revision: retained_ack.storage_revision
           }

    assert get_subscription(current, other.id) == %{
             record: other,
             storage_revision: other_ack.storage_revision
           }

    assert boards(current) == [
             %{record: retained, storage_revision: retained_ack.storage_revision}
           ]

    assert subscriptions(current) == [
             %{record: other, storage_revision: other_ack.storage_revision}
           ]

    assert get_board(before, "alpha") == %{
             record: selected,
             storage_revision: selected_ack.storage_revision
           }

    assert get_subscription(before, one.id) == %{
             record: one,
             storage_revision: one_ack.storage_revision
           }

    assert get_subscription(before, two.id) == %{
             record: two,
             storage_revision: two_ack.storage_revision
           }

    assert length(boards(before)) == 2
    assert length(subscriptions(before)) == 3
    assert history(key_for(scope, retained)) == retained_history
    assert history(key_for(scope, other)) == other_history

    for {key, value, revision} <- [
          {selected_key, selected, selected_ack.storage_revision},
          {name_key, selected.id, selected_ack.storage_revision},
          {one_key, one, one_ack.storage_revision},
          {two_key, two, two_ack.storage_revision}
        ] do
      [original, tombstone] = Enum.sort_by(history(key), & &1.mod_revision)
      assert original.value == value
      assert original.mod_revision == revision
      assert tombstone.value == nil and tombstone.version == 0
      assert tombstone.mod_revision == ack.storage_revision
      assert tombstone.create_revision == original.create_revision
    end

    assert marker(scope).mod_revision == ack.storage_revision
    assert Store.notification_sequence(current, deadline()) == {:ok, 0}

    assert Store.items_page(current, [limit: 100], deadline()) ==
             {:ok, %{rows: [], next_cursor: nil}}

    assert snapshot(scope) == current
  end

  test "same slug recreation has a new envelope identity and preserves previous name and board history",
       %{scope: scope} do
    {original, created} = board(scope, "alpha", "Original")
    before = snapshot(scope)
    old_key = key_for(scope, original)
    name_key = key_for(scope, original.id)
    deleted = delete(before, original, [])
    fresh_creator = Map.put(@creator, "runId", "fixture:388:data:new")
    {fresh, recreated} = board(scope, "alpha", "New 雪😀", fresh_creator)
    assert fresh.provenance == fresh_creator and original.provenance == @creator
    assert fresh.id != original.id
    assert fresh.revision == 1
    assert recreated.storage_revision > deleted.storage_revision
    current = snapshot(scope)

    assert get_board(current, "alpha") == %{
             record: fresh,
             storage_revision: recreated.storage_revision
           }

    assert get_board(before, "alpha") == %{
             record: original,
             storage_revision: created.storage_revision
           }

    assert boards(current) == [%{record: fresh, storage_revision: recreated.storage_revision}]

    assert Enum.map(Enum.sort_by(history(name_key), & &1.mod_revision), & &1.value) == [
             original.id,
             nil,
             fresh.id
           ]

    [old, tombstone] = Enum.sort_by(history(old_key), & &1.mod_revision)
    assert old.value == original and tombstone.value == nil
    assert tombstone.mod_revision == deleted.storage_revision
    assert Store.notification_sequence(current, deadline()) == {:ok, 0}
  end

  test "ordinary disjoint board update retains its older snapshot after a successful board deletion",
       %{scope: scope} do
    {selected, _} = board(scope, "alpha", "Selected")
    {retained, retained_ack} = board(scope, "beta", "Before")
    point = snapshot(scope)
    deleted = delete(point, selected, [])
    next = %{retained | revision: 2, payload: Map.put(retained.payload, "name", "After café")}
    assert {:ok, ack} = Store.commit_board(point, next, deadline())
    assert ack == %{board: next, storage_revision: ack.storage_revision}
    assert ack.storage_revision > deleted.storage_revision
    current = snapshot(scope)
    assert get_board(current, "beta") == %{record: next, storage_revision: ack.storage_revision}

    assert get_board(point, "beta") == %{
             record: retained,
             storage_revision: retained_ack.storage_revision
           }

    assert Store.get_board(current, "alpha", deadline()) == :not_found
    assert get_board(point, "alpha").record == selected
    assert marker(scope).mod_revision == ack.storage_revision
    assert Store.notification_sequence(current, deadline()) == {:ok, 0}
  end

  test "normal creator completion leaves acknowledged deletion and historical facts for a distinct reader",
       %{scope: scope} do
    creator =
      Task.async(fn ->
        {selected, created} = board(scope, "alpha", "Handoff 雪😀")
        {sub, subscription_ack} = subscription(scope, "alpha", "Reader", %{})
        before = snapshot(scope)
        ack = delete(before, selected, [sub])

        %{
          selected: selected,
          created: created,
          sub: sub,
          subscription_ack: subscription_ack,
          before: before,
          ack: ack
        }
      end)

    written = Task.await(creator, 5_000)
    refute Process.alive?(creator.pid)

    reader =
      Task.async(fn ->
        current = snapshot(scope)
        assert Store.get_board(current, "alpha", deadline()) == :not_found
        assert Store.get_subscription(current, written.sub.id, deadline()) == :not_found
        assert boards(current) == [] and subscriptions(current) == []

        assert get_board(written.before, "alpha") == %{
                 record: written.selected,
                 storage_revision: written.created.storage_revision
               }

        assert get_subscription(written.before, written.sub.id) == %{
                 record: written.sub,
                 storage_revision: written.subscription_ack.storage_revision
               }

        assert marker(scope).mod_revision == written.ack.storage_revision
        assert Store.notification_sequence(current, deadline()) == {:ok, 0}
        assert snapshot(scope) == current
        current
      end)

    current = Task.await(reader, 5_000)
    refute Process.alive?(reader.pid)
    assert creator.pid != reader.pid
    assert Store.get_board(current, "alpha", deadline()) == :not_found
  end

  defp board(scope, slug, name, provenance \\ @creator) do
    value = %{
      schema_version: 1,
      id: Ecto.UUID.generate(),
      scope: scope,
      slug: slug,
      revision: 1,
      provenance: provenance,
      payload: %{
        "id" => slug,
        "name" => name,
        "createdAt" => @time,
        "updatedAt" => @time,
        "opaque" => %{"kept" => [nil, true, 1.5, "雪😀"]}
      }
    }

    assert {:ok, ack} = Store.commit_board(snapshot(scope), value, deadline())
    assert ack == %{board: value, storage_revision: ack.storage_revision}
    {value, ack}
  end

  defp subscription(scope, slug, target, extra) do
    id = Ecto.UUID.generate()

    value = %{
      schema_version: 1,
      id: id,
      scope: scope,
      revision: 1,
      provenance: @creator,
      payload:
        Map.merge(
          %{
            "id" => id,
            "boardId" => slug,
            "target" => target,
            "createdAt" => @time,
            "updatedAt" => @time,
            "opaque" => [nil, false, "雪😀"]
          },
          extra
        )
    }

    assert {:ok, ack} =
             Store.commit_subscription(
               snapshot(scope),
               %{kind: :create, subscription: value},
               deadline()
             )

    assert ack == %{subscription: value, storage_revision: ack.storage_revision}
    {value, ack}
  end

  defp delete(point, board, selected_subscriptions) do
    assert {:ok, ack} =
             Store.commit_board_delete(
               point,
               %{slug: board.slug, board: board, subscriptions: selected_subscriptions},
               deadline()
             )

    assert ack == %{deleted: true, storage_revision: ack.storage_revision}
    assert is_integer(ack.storage_revision) and ack.storage_revision > 0
    assert marker(board.scope).mod_revision == ack.storage_revision
    ack
  end

  defp get_board(point, slug) do
    assert {:ok, row} = Store.get_board(point, slug, deadline())
    row
  end

  defp get_subscription(point, id) do
    assert {:ok, row} = Store.get_subscription(point, id, deadline())
    row
  end

  defp boards(point) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.boards_page(point, [limit: 100], deadline())

    rows
  end

  defp subscriptions(point) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.subscriptions_page(point, [limit: 100], deadline())

    rows
  end

  defp key_for(scope, value) do
    prefix = "coord/workboard/v1/scopes/" <> Base.url_encode64(scope, padding: false) <> "/"

    assert {:ok, rows, %{has_more: false}} =
             KV.list(
               engine: :turso,
               range: {prefix, prefix <> <<255>>},
               limit: 100,
               timeout: 5_000
             )

    [row] = Enum.filter(rows, &(&1.value == value))
    row.key
  end

  defp history(key) do
    assert {:ok, rows} = KV.history(key, engine: :turso, limit: 100, timeout: 5_000)
    rows
  end

  defp marker(scope) do
    key =
      "coord/workboard/v1/scopes/" <>
        Base.url_encode64(scope, padding: false) <> "/control/mutation_frontier"

    assert {:ok, record} = KV.get(key, engine: :turso, metadata: true, timeout: 5_000)
    record
  end

  defp snapshot(scope) do
    assert {:ok, value} = Store.snapshot(scope, deadline())
    value
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
