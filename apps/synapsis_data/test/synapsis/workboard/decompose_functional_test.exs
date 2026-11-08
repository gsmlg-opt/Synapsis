defmodule Synapsis.Workboard.DataDecomposeFunctionalTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Synapsis.Workboard.Store

  # Independent closed Data proposal, before reading any product candidate.
  # These complete caller-owned JSON envelopes prove storage preservation;
  # they do not prove Core child creation, normalization or native execution.
  @time 1_800_000_000_000
  @creator %{"runId" => "fixture:389:data:create", "json" => [nil, true, "雪😀", 2.5]}
  @editor %{"runId" => "fixture:389:data:decompose", "incarnation" => 9}
  @sequence @time * 1000 + 7

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{scope: "fixture:389:data/雪/" <> Ecto.UUID.generate()}
  end

  test "moved and forced decomposed stages publish exact opaque facts while retaining blobs keys and nonzero highwater",
       %{scope: scope} do
    seed = seed(scope, "backlog")
    before = snapshot(scope)
    before_rows = raw_rows(scope)
    old_item = item(before, seed.parent.id)
    old_board = board_at(before, "research")
    children = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    automation =
      old_item.record.payload["metadata"]["automation"]
      |> Map.put("summary", "Kept parent summary 雪😀")
      |> Map.put("createdCardIds", children)

    metadata = Map.put(old_item.record.payload["metadata"], "automation", automation)
    moved_event = public("moved", @time + 100, %{"fromStatus" => "backlog", "toStatus" => "todo"})
    moved = next_item(old_item.record, "todo", metadata, moved_event)
    first = commit_decompose(before, old_board.record, moved, :moved, moved_event)
    first_point = snapshot(scope)
    assert Store.notification_sequence(first_point, deadline()) == {:ok, @sequence}
    assert Store.get_attachment(first_point, seed.blob.id, deadline()) == seed.blob_row

    final_event = public("decomposed", @time + 101)
    final_item = next_item(moved, "todo", metadata, final_event)
    final = commit_decompose(first_point, first.board, final_item, :decomposed, final_event)
    current = snapshot(scope)
    assert final.storage_revision > first.storage_revision
    assert final.item.revision == old_item.record.revision + 2
    assert final.board.revision == old_board.record.revision + 2
    assert final.item.provenance == @creator and final.board.provenance == @creator
    assert final.event.provenance == @editor
    assert final.item.payload["metadata"]["automation"]["createdCardIds"] == children

    assert final.item.payload["metadata"]["comments"] ==
             old_item.record.payload["metadata"]["comments"]

    assert final.item.payload["opaque"] == old_item.record.payload["opaque"]
    assert final.event.payload == final_event
    assert Map.keys(final_event) |> Enum.sort() == ~w(at id kind)

    assert item(before, seed.parent.id) == old_item
    assert board_at(before, "research") == old_board

    assert item(first_point, seed.parent.id) == %{
             record: moved,
             storage_revision: first.storage_revision
           }

    assert item(current, seed.parent.id) == %{
             record: final_item,
             storage_revision: final.storage_revision
           }

    assert Store.get_attachment(current, seed.blob.id, deadline()) == seed.blob_row
    assert Store.notification_sequence(before, deadline()) == {:ok, @sequence}
    assert Store.notification_sequence(current, deadline()) == {:ok, @sequence}

    assert Store.lookup_create_key_candidates(current, key(seed.parent), deadline()) ==
             seed.parent_key

    after_rows = raw_rows(scope)
    touched = mutable_keys(scope, seed.parent)

    new_events = [
      event_key(scope, seed.parent.id, moved_event["id"]),
      event_key(scope, seed.parent.id, final_event["id"])
    ]

    assert Map.drop(after_rows, touched ++ new_events) == Map.drop(before_rows, touched)
    assert MapSet.new(Map.keys(after_rows)) == MapSet.new(Map.keys(before_rows) ++ new_events)

    for {point, ack, expected_event} <- [
          {first_point, first, moved_event},
          {current, final, final_event}
        ] do
      assert_stage(point, ack, expected_event)

      assert history_value(scope_key(scope, "records/" <> seed.parent.id), ack.storage_revision) ==
               ack.item

      assert history_value(
               scope_key(scope, "boards/" <> seed.parent.board_id),
               ack.storage_revision
             ) == ack.board

      assert history_value(
               event_key(scope, seed.parent.id, expected_event["id"]),
               ack.storage_revision
             ) == ack.event
    end

    assert Enum.map(events(current, seed.parent.id), & &1.record.payload["kind"]) ==
             ["created", "attachment_added", "moved", "decomposed"]
  end

  test "edited and forced decomposed commits survive ordinary creator completion and preserve a disjoint old snapshot write",
       %{scope: scope} do
    creator =
      Task.async(fn ->
        seed = seed(scope, "todo")
        before = snapshot(scope)
        parent = item(before, seed.parent.id).record
        board = board_at(before, "research").record
        edited_event = public("edited", @time + 200)
        edited = next_item(parent, "todo", parent.payload["metadata"], edited_event)
        first = commit_decompose(before, board, edited, :edited, edited_event)
        middle = snapshot(scope)
        decomposed_event = public("decomposed", @time + 201)
        decomposed = next_item(edited, "todo", edited.payload["metadata"], decomposed_event)
        last = commit_decompose(middle, first.board, decomposed, :decomposed, decomposed_event)

        %{
          seed: seed,
          before: before,
          middle: middle,
          parent: parent,
          first: first,
          last: last,
          edited_event: edited_event,
          decomposed_event: decomposed_event
        }
      end)

    written = Task.await(creator, 5_000)
    refute Process.alive?(creator.pid)

    reader =
      Task.async(fn ->
        current = snapshot(scope)
        assert_stage(current, written.last, written.decomposed_event)
        assert item(written.before, written.parent.id).record == written.parent
        assert item(written.middle, written.parent.id).record == written.first.item

        assert Enum.map(events(current, written.parent.id), & &1.record.payload["kind"]) ==
                 ["created", "attachment_added", "edited", "decomposed"]

        assert Store.get_attachment(current, written.seed.blob.id, deadline()) ==
                 written.seed.blob_row

        assert Store.lookup_create_key_candidates(current, key(written.parent), deadline()) ==
                 written.seed.parent_key

        assert Store.notification_sequence(current, deadline()) == {:ok, @sequence}

        old_other = board_at(written.before, "delivery").record

        next_other = %{
          old_other
          | revision: old_other.revision + 1,
            payload: Map.put(old_other.payload, "name", "Ordinary disjoint update 雪😀")
        }

        assert {:ok, ack} = Store.commit_board(written.before, next_other, deadline())
        assert ack == %{board: next_other, storage_revision: ack.storage_revision}
        assert ack.storage_revision > written.last.storage_revision
        fresh = snapshot(scope)

        assert board_at(fresh, "delivery") == %{
                 record: next_other,
                 storage_revision: ack.storage_revision
               }

        assert board_at(written.before, "delivery").record == old_other
        assert item(fresh, written.parent.id).record == written.last.item
        assert Store.notification_sequence(fresh, deadline()) == {:ok, @sequence}
        assert marker(scope).mod_revision == ack.storage_revision
        fresh
      end)

    final = Task.await(reader, 5_000)
    refute Process.alive?(reader.pid)
    assert creator.pid != reader.pid
    assert item(final, written.parent.id).record == written.last.item
  end

  defp seed(scope, status) do
    research = create_board(scope, "research")
    delivery = create_board(scope, "delivery")
    parent = create_item(scope, research, status, "Parent 雪😀", "parent-key")
    other = create_item(scope, delivery, "todo", "Unrelated completed card", "other-key")
    point = snapshot(scope)
    public = public("attachment_added", @time + 1)

    metadata = %{
      "id" => Ecto.UUID.generate(),
      "cardId" => parent.id,
      "fileName" => "evidence-雪.bin",
      "byteSize" => 5,
      "createdAt" => @time + 1
    }

    blob = %{
      schema_version: 1,
      id: metadata["id"],
      scope: scope,
      item_id: parent.id,
      payload: %{
        "attachment" => metadata,
        "contentBase64" => Base.encode64(<<0, 1, 2, 128, 255>>)
      },
      provenance: @editor
    }

    attached =
      next_item(
        parent,
        status,
        Map.put(parent.payload["metadata"], "attachments", [metadata]),
        public
      )

    board = board_at(point, "research").record

    change = %{
      kind: :attachment_add,
      board: next_board(board),
      item: attached,
      event: event(attached, :attachment_added, public),
      projection: projection(attached.payload),
      attachment: blob
    }

    assert {:ok, _} = Store.commit_attachment(point, change, deadline())

    point = snapshot(scope)

    notice = %{
      "id" => Ecto.UUID.generate(),
      "kind" => "completed",
      "createdAt" => @time + 2,
      "sequence" => @sequence,
      "message" => "Independent completed record"
    }

    complete_event = public("moved", @time + 2, %{"fromStatus" => "todo", "toStatus" => "done"})

    completed =
      next_item(
        other,
        "done",
        Map.put(other.payload["metadata"], "notifications", [notice]),
        complete_event
      )

    board = board_at(point, "delivery").record

    complete_change = %{
      kind: :complete,
      board: next_board(board),
      item: completed,
      event: event(completed, :moved, complete_event),
      projection: projection(completed.payload),
      detached: [],
      read_item_ids: [],
      notification_sequence: @sequence
    }

    assert {:ok, _} = Store.commit_workflow(point, complete_change, deadline())
    point = snapshot(scope)
    assert {:ok, blob_row} = Store.get_attachment(point, blob.id, deadline())

    %{
      parent: attached,
      other: completed,
      blob: blob,
      blob_row: {:ok, blob_row},
      parent_key: Store.lookup_create_key_candidates(point, key(attached), deadline())
    }
  end

  defp commit_decompose(point, board, item, kind, public) do
    change = %{
      kind: :decompose,
      board: next_board(board),
      item: item,
      event: event(item, kind, public),
      projection: projection(item.payload),
      create_key: nil
    }

    assert {:ok, ack} = Store.commit_item(point, change, deadline())

    assert ack == %{
             board: change.board,
             item: item,
             event: change.event,
             storage_revision: ack.storage_revision
           }

    assert_stage(snapshot(item.scope), ack, public)
    ack
  end

  defp assert_stage(point, ack, public) do
    assert item(point, ack.item.id) == %{record: ack.item, storage_revision: ack.storage_revision}

    assert board_at(point, ack.board.slug) == %{
             record: ack.board,
             storage_revision: ack.storage_revision
           }

    for opts <- [[], [board_id: ack.board.id]] do
      assert {:ok, %{rows: rows, next_cursor: nil}} = Store.items_page(point, opts, deadline())
      row = Enum.find(rows, &(&1.record.id == ack.item.id))
      assert row.storage_revision == ack.storage_revision

      assert row.record == %{
               schema_version: 1,
               id: ack.item.id,
               scope: ack.item.scope,
               board_id: ack.board.id,
               board_slug: ack.board.slug,
               payload: projection(ack.item.payload)
             }
    end

    assert List.last(events(point, ack.item.id)) == %{
             record: ack.event,
             storage_revision: ack.storage_revision
           }

    assert ack.event.payload == public and ack.event.provenance == @editor

    assert history_value(
             scope_key(ack.item.scope, "control/mutation_frontier"),
             ack.storage_revision
           ) == %{schema_version: 1}

    assert ack.item.provenance == @creator and ack.board.provenance == @creator
  end

  defp create_board(scope, slug) do
    board = %{
      schema_version: 1,
      id: Ecto.UUID.generate(),
      scope: scope,
      slug: slug,
      revision: 1,
      payload: %{"id" => slug, "name" => slug, "createdAt" => @time},
      provenance: @creator
    }

    assert {:ok, _} = Store.commit_board(snapshot(scope), board, deadline())
    board
  end

  defp create_item(scope, board, status, title, key_value) do
    id = Ecto.UUID.generate()
    public = public("created", @time)

    payload = %{
      "id" => id,
      "title" => title,
      "status" => status,
      "priority" => "normal",
      "labels" => [],
      "position" => 1000,
      "createdAt" => @time,
      "updatedAt" => @time,
      "events" => [public],
      "opaque" => %{"future" => [nil, false, 1.5, "雪😀"]},
      "metadata" => %{
        "automation" => %{
          "boardId" => board.slug,
          "tenant" => "fixture-tenant",
          "idempotencyKey" => key_value,
          "summary" => "Kept parent summary 雪😀"
        },
        "comments" => [
          %{"id" => Ecto.UUID.generate(), "body" => "Keep this comment", "createdAt" => @time}
        ]
      }
    }

    item = %{
      schema_version: 1,
      id: id,
      scope: scope,
      board_id: board.id,
      board_slug: board.slug,
      revision: 1,
      payload: payload,
      provenance: @creator
    }

    point = snapshot(scope)

    change = %{
      kind: :create,
      board: next_board(board_at(point, board.slug).record),
      item: item,
      event: event(item, :created, public, @creator),
      projection: projection(payload),
      create_key: key(item)
    }

    assert {:ok, _} = Store.commit_item(point, change, deadline())
    item
  end

  defp next_item(item, status, metadata, public) do
    payload =
      item.payload
      |> Map.put("status", status)
      |> Map.put("metadata", metadata)
      |> Map.put("updatedAt", public["at"])
      |> Map.update!("events", &(&1 ++ [public]))

    %{item | revision: item.revision + 1, payload: payload}
  end

  defp public(kind, at, fields \\ %{}),
    do: Map.merge(%{"id" => Ecto.UUID.generate(), "kind" => kind, "at" => at}, fields)

  defp next_board(board), do: %{board | revision: board.revision + 1}

  defp projection(payload),
    do:
      Map.take(
        payload,
        ~w(id title status priority labels position createdAt updatedAt metadata opaque)
      )

  defp key(item),
    do:
      {"fixture-tenant", item.board_slug,
       item.payload["metadata"]["automation"]["idempotencyKey"]}

  defp event(item, kind, public, provenance \\ @editor),
    do: %{
      schema_version: 1,
      id: public["id"],
      scope: item.scope,
      item_id: item.id,
      board_id: item.board_id,
      kind: kind,
      payload: public,
      provenance: provenance
    }

  defp snapshot(scope) do
    assert {:ok, point} = Store.snapshot(scope, deadline())
    point
  end

  defp item(point, id) do
    assert {:ok, row} = Store.get_item(point, id, deadline())
    row
  end

  defp board_at(point, slug) do
    assert {:ok, row} = Store.get_board(point, slug, deadline())
    row
  end

  defp events(point, id) do
    assert {:ok, %{rows: rows, next_cursor: nil}} = Store.events_page(point, id, [], deadline())
    Enum.sort_by(rows, & &1.storage_revision)
  end

  defp raw_rows(scope) do
    prefix = scope_key(scope, "")

    assert {:ok, rows, %{has_more: false}} =
             KV.list(
               engine: :turso,
               range: {prefix, prefix <> <<255>>},
               limit: 100,
               timeout: 5000
             )

    Map.new(rows, &{&1.key, &1})
  end

  defp marker(scope) do
    assert {:ok, row} =
             KV.get(scope_key(scope, "control/mutation_frontier"),
               engine: :turso,
               metadata: true,
               timeout: 5000
             )

    row
  end

  defp history_value(key, revision) do
    assert {:ok, rows} = KV.history(key, engine: :turso, limit: 100, timeout: 5000)
    [record] = Enum.filter(rows, &(&1.mod_revision == revision))
    record.value
  end

  defp scope_key(scope, suffix),
    do: "coord/workboard/v1/scopes/" <> Base.url_encode64(scope, padding: false) <> "/" <> suffix

  defp event_key(scope, id, event_id), do: scope_key(scope, "events/" <> id <> "/" <> event_id)

  defp mutable_keys(scope, parent),
    do:
      Enum.map(
        [
          "names/" <> Base.url_encode64(parent.board_slug, padding: false),
          "boards/" <> parent.board_id,
          "records/" <> parent.id,
          "items/" <> parent.id,
          "board_items/" <> parent.board_id <> "/" <> parent.id,
          "control/mutation_frontier"
        ],
        &scope_key(scope, &1)
      )

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
