defmodule Synapsis.Workboard.DataAttachmentFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workboard.Store

  # Independent, fully caller-owned Data fixtures; no Core normalization, model,
  # SQLite reference execution, or implementation candidate inspection involved.
  @board "38110000-0000-4000-8000-000000000001"
  @target "38110000-0000-4000-8000-000000000002"
  @item "38110000-0000-4000-8000-000000000011"
  @created "38110000-0000-4000-8000-000000000021"
  @added_one "38110000-0000-4000-8000-000000000022"
  @added_two "38110000-0000-4000-8000-000000000023"
  @deleted_one "38110000-0000-4000-8000-000000000024"
  @deleted_two "38110000-0000-4000-8000-000000000025"
  @specified "38110000-0000-4000-8000-000000000026"
  @one "38110000-0000-4000-8000-000000000031"
  @two "38110000-0000-4000-8000-000000000032"
  @t 1_800_000_000_000
  @encoded "AP8BgA=="
  @key {"tenant-old", "research", "attachment-key"}
  @creator %{
    "sessionId" => "38110000-0000-4000-8000-000000000041",
    "agentId" => "38110000-0000-4000-8000-000000000042",
    "runId" => "fixture:381:data-create",
    "incarnation" => 17,
    "invocationId" => "fixture:381:data-create-invoke",
    "toolCallId" => "fixture:381:data-create-call",
    "extra" => %{"json" => [nil, false, 1.5, "雪😀"]}
  }
  @uploader %{
    "sessionId" => "38110000-0000-4000-8000-000000000051",
    "agentId" => "38110000-0000-4000-8000-000000000052",
    "runId" => "fixture:381:data-upload",
    "incarnation" => 18,
    "invocationId" => "fixture:381:data-upload-invoke",
    "toolCallId" => "fixture:381:data-upload-call",
    "extra" => %{"retained" => [true, nil, "café"]}
  }
  @editor %{
    "sessionId" => "38110000-0000-4000-8000-000000000061",
    "agentId" => "38110000-0000-4000-8000-000000000062",
    "runId" => "fixture:381:data-delete",
    "incarnation" => 19,
    "invocationId" => "fixture:381:data-delete-invoke",
    "toolCallId" => "fixture:381:data-delete-call",
    "extra" => %{"json" => %{"ordinary" => [7, "雪😀"]}}
  }
  @automation %{
    "boardId" => "research",
    "tenant" => "tenant-old",
    "idempotencyKey" => "attachment-key",
    "skills" => ["inspect"],
    "workspace" => %{"kind" => "dir", "path" => "/supplied/data-workspace"}
  }

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{scope: "fixture:381:data/opaque:雪/" <> Ecto.UUID.generate()}
  end

  test "ordinary distinct blobs with identical binary content atomically publish exact closed ACK and row facts",
       %{scope: scope} do
    initial = seed(scope)
    one = blob(scope, @one, "first 雪😀.bin", @t + 100)
    first = add(initial, one, @added_one, @t + 101)
    first_point = first.point
    first_row = attachment(first.point, @one)
    assert first_row == stored(one, first.revision)

    assert first_row.record.payload == %{
             "version" => 1,
             "attachment" => %{
               "id" => @one,
               "cardId" => @item,
               "fileName" => "first 雪😀.bin",
               "byteSize" => 4,
               "createdAt" => @t + 100,
               "mimeType" => "application/octet-stream",
               "note" => "Supplied Data fixture\n雪😀"
             },
             "contentBase64" => @encoded
           }

    assert Base.decode64!(first_row.record.payload["contentBase64"]) == <<0, 255, 1, 128>>
    two = blob(scope, @two, "second.bin", @t + 110)
    second = add(first, two, @added_two, @t + 111)

    assert second.item.payload["metadata"]["attachments"] == [
             one.payload["attachment"],
             two.payload["attachment"]
           ]

    assert @one != @two
    assert one.payload["contentBase64"] == two.payload["contentBase64"]
    assert attachment(second.point, @one) == first_row
    assert attachment(second.point, @two) == stored(two, second.revision)
    assert attachment(first_point, @one) == first_row
    assert get_item(first_point).record.payload == first.item.payload
    assert create_key(second.point, @key) == create_key(initial.point, @key)

    assert create_key(second.point, @key) ==
             {:ok, %{ids: [@item], storage_revision: initial.revision}}
  end

  test "ordinary deletion removes exactly one blob then the last attachment while historical snapshots retain complete payloads",
       %{scope: scope} do
    initial = seed(scope)
    one = blob(scope, @one, "first.bin", @t + 100)
    two = blob(scope, @two, "second.bin", @t + 110)
    first = add(initial, one, @added_one, @t + 101)
    second = add(first, two, @added_two, @t + 111)
    historical = second.point
    old_one = attachment(historical, @one)
    old_two = attachment(historical, @two)
    deleted_first = delete(second, one, @deleted_one, @t + 120)
    assert deleted_first.item.payload["metadata"]["attachments"] == [two.payload["attachment"]]
    assert Store.get_attachment(deleted_first.point, @one, deadline()) == :not_found
    assert attachment(deleted_first.point, @two) == old_two
    deleted_last = delete(deleted_first, two, @deleted_two, @t + 130)
    assert deleted_last.item.payload["metadata"] == %{"automation" => @automation}
    assert Store.get_attachment(deleted_last.point, @two, deadline()) == :not_found
    assert attachment(historical, @one) == old_one
    assert attachment(historical, @two) == old_two
    assert get_item(historical) == stored(second.item, second.revision)
    assert create_key(deleted_last.point, @key) == create_key(initial.point, @key)
    assert old_one.record.provenance == @uploader
    assert old_two.record.provenance == @uploader
  end

  test "caller-owned Data specify detaches one envelope atomically while crossboard retained blobs keep original creator provenance",
       %{scope: scope} do
    initial = seed(scope)
    one = blob(scope, @one, "detached.bin", @t + 100)
    two = blob(scope, @two, "retained.bin", @t + 110)
    first = add(initial, one, @added_one, @t + 101)
    second = add(first, two, @added_two, @t + 111)
    historical = second.point
    original_one = attachment(historical, @one)
    original_two = attachment(historical, @two)
    destination = board_record(scope, @target, "delivery", "Delivery")
    assert {:ok, ack_board} = Store.commit_board(snapshot(scope), destination, deadline())
    assert ack_board == %{board: destination, storage_revision: ack_board.storage_revision}
    point = snapshot(scope)
    source_before = get_board(point, "research")
    target_before = get_board(point, "delivery")
    source = %{source_before.record | revision: source_before.record.revision + 1}
    target = %{target_before.record | revision: target_before.record.revision + 1}
    public = %{"id" => @specified, "kind" => "specified", "at" => @t + 200}

    card = %{
      second.item.payload
      | "title" => "Moved caller Data fixture",
        "updatedAt" => @t + 201,
        "events" => second.item.payload["events"] ++ [public],
        "metadata" => %{
          "automation" =>
            Map.merge(@automation, %{"boardId" => "delivery", "tenant" => "tenant-new"}),
          "attachments" => [two.payload["attachment"]]
        }
    }

    item = %{
      second.item
      | revision: second.item.revision + 1,
        board_id: @target,
        board_slug: "delivery",
        payload: card
    }

    event = event_record(scope, @target, :specified, public, @editor)
    new_key = {"tenant-new", "delivery", "attachment-key"}

    change = %{
      kind: :specify,
      source_board: source,
      board: target,
      item: item,
      event: event,
      projection: projection(card),
      previous_create_key: @key,
      create_key: new_key
    }

    # Explicit caller-owned detachment adaptation, not a Core trim/threshold fixture.
    assert {:ok, ack} = Store.commit_specify(point, change, deadline(), [one])
    revision = ack.storage_revision

    assert is_integer(revision) and revision > second.revision and
             revision > ack_board.storage_revision

    assert ack == %{
             source_board: source,
             board: target,
             item: item,
             event: event,
             storage_revision: revision
           }

    current = snapshot(scope)
    assert get_board(current, "research") == stored(source, revision)
    assert get_board(current, "delivery") == stored(target, revision)
    assert get_item(current) == stored(item, revision)
    assert projections(current, nil) == [projected(item, projection(card), revision)]
    assert projections(current, @target) == [projected(item, projection(card), revision)]
    assert projections(current, @board) == []
    assert_new_event(point, current, event, revision)
    assert Store.get_attachment(current, @one, deadline()) == :not_found
    assert attachment(current, @two) == original_two
    assert original_two.record == two

    assert Map.keys(two) |> Enum.sort() == [
             :id,
             :item_id,
             :payload,
             :provenance,
             :schema_version,
             :scope
           ]

    assert two.provenance == @uploader
    assert two.item_id == item.id
    assert create_key(current, @key) == :not_found
    assert create_key(current, new_key) == {:ok, %{ids: [@item], storage_revision: revision}}
    assert create_key(point, @key) == {:ok, %{ids: [@item], storage_revision: initial.revision}}
    assert get_board(point, "research") == source_before
    assert get_board(point, "delivery") == target_before
    assert attachment(point, @one) == original_one
    assert attachment(point, @two) == original_two
    assert attachment(historical, @one) == original_one

    moved = %{
      scope: scope,
      board: target,
      item: item,
      event: event,
      revision: revision,
      point: current
    }

    deleted = delete(moved, two, @deleted_two, @t + 210)
    assert deleted.item.payload["metadata"] == %{"automation" => card["metadata"]["automation"]}
    assert Store.get_attachment(deleted.point, @two, deadline()) == :not_found
    assert attachment(current, @two) == original_two
    assert attachment(historical, @one) == original_one
    assert attachment(historical, @two) == original_two
  end

  defp seed(scope) do
    board = board_record(scope, @board, "research", "Research")
    assert {:ok, b_ack} = Store.commit_board(snapshot(scope), board, deadline())
    assert b_ack == %{board: board, storage_revision: b_ack.storage_revision}
    public = %{"id" => @created, "kind" => "created", "at" => @t + 10, "toStatus" => "todo"}

    card = %{
      "id" => @item,
      "title" => "Caller Data card café 雪😀",
      "notes" => "Full fixture\nKeep newline.",
      "status" => "todo",
      "priority" => "high",
      "labels" => ["review", "雪😀"],
      "agentId" => "fixture-agent",
      "position" => 1000,
      "createdAt" => @t + 10,
      "updatedAt" => @t + 10,
      "startedAt" => @t + 1,
      "events" => [public],
      "metadata" => %{"automation" => @automation}
    }

    item = %{
      schema_version: 1,
      id: @item,
      scope: scope,
      board_id: @board,
      board_slug: "research",
      revision: 1,
      payload: card,
      provenance: @creator
    }

    next_board = %{board | revision: 2}
    event = event_record(scope, @board, :created, public, @creator)

    assert {:ok, ack} =
             Store.commit_item(
               snapshot(scope),
               %{
                 kind: :create,
                 board: next_board,
                 item: item,
                 event: event,
                 projection: projection(card),
                 create_key: @key
               },
               deadline()
             )

    revision = ack.storage_revision
    assert is_integer(revision) and revision > b_ack.storage_revision
    assert ack == %{board: next_board, item: item, event: event, storage_revision: revision}
    point = snapshot(scope)
    assert get_board(point, "research") == stored(next_board, revision)
    assert get_item(point) == stored(item, revision)
    assert events(point) == [stored(event, revision)]
    assert projections(point, nil) == [projected(item, projection(card), revision)]
    assert projections(point, @board) == [projected(item, projection(card), revision)]
    assert create_key(point, @key) == {:ok, %{ids: [@item], storage_revision: revision}}
    %{scope: scope, board: next_board, item: item, event: event, revision: revision, point: point}
  end

  defp board_record(scope, id, slug, name),
    do: %{
      schema_version: 1,
      id: id,
      scope: scope,
      slug: slug,
      revision: 1,
      payload: %{
        "id" => slug,
        "name" => name,
        "description" => "Supplied Data board 雪😀",
        "createdAt" => @t,
        "updatedAt" => @t
      },
      provenance: @creator
    }

  defp blob(scope, id, file_name, created_at) do
    %{
      schema_version: 1,
      id: id,
      scope: scope,
      item_id: @item,
      provenance: @uploader,
      payload: %{
        "version" => 1,
        "attachment" => %{
          "id" => id,
          "cardId" => @item,
          "fileName" => file_name,
          "byteSize" => 4,
          "createdAt" => created_at,
          "mimeType" => "application/octet-stream",
          "note" => "Supplied Data fixture\n雪😀"
        },
        "contentBase64" => @encoded
      }
    }
  end

  defp add(previous, blob, event_id, now) do
    public = %{"id" => event_id, "kind" => "attachment_added", "at" => now}
    old_card = previous.item.payload

    metadata =
      Map.put(
        old_card["metadata"],
        "attachments",
        Map.get(old_card["metadata"], "attachments", []) ++ [blob.payload["attachment"]]
      )

    card = %{
      old_card
      | "updatedAt" => now,
        "metadata" => metadata,
        "events" => old_card["events"] ++ [public]
    }

    item = %{previous.item | revision: previous.item.revision + 1, payload: card}
    board = %{previous.board | revision: previous.board.revision + 1}
    event = event_record(previous.scope, board.id, :attachment_added, public, @uploader)

    change = %{
      kind: :attachment_add,
      board: board,
      item: item,
      event: event,
      projection: projection(card),
      attachment: blob
    }

    point = snapshot(previous.scope)
    assert {:ok, ack} = Store.commit_attachment(point, change, deadline())
    assert_ack_rows(previous, point, change, ack)
  end

  defp delete(previous, blob, event_id, now) do
    public = %{"id" => event_id, "kind" => "edited", "at" => now}
    old_card = previous.item.payload
    remaining = Enum.reject(old_card["metadata"]["attachments"], &(&1["id"] == blob.id))

    metadata =
      if remaining == [],
        do: Map.delete(old_card["metadata"], "attachments"),
        else: Map.put(old_card["metadata"], "attachments", remaining)

    card = %{
      old_card
      | "updatedAt" => now,
        "metadata" => metadata,
        "events" => old_card["events"] ++ [public]
    }

    item = %{previous.item | revision: previous.item.revision + 1, payload: card}
    board = %{previous.board | revision: previous.board.revision + 1}
    event = event_record(previous.scope, board.id, :edited, public, @editor)

    change = %{
      kind: :attachment_delete,
      board: board,
      item: item,
      event: event,
      projection: projection(card),
      attachment: blob
    }

    point = snapshot(previous.scope)
    assert attachment(point, blob.id).record == blob
    assert blob.provenance == @uploader
    assert {:ok, ack} = Store.commit_attachment(point, change, deadline())
    assert_ack_rows(previous, point, change, ack)
  end

  defp assert_ack_rows(previous, before, change, ack) do
    revision = ack.storage_revision
    assert is_integer(revision) and revision > previous.revision

    assert ack == %{
             board: change.board,
             item: change.item,
             event: change.event,
             attachment: change.attachment,
             storage_revision: revision
           }

    current = snapshot(previous.scope)
    assert get_board(current, change.board.slug) == stored(change.board, revision)
    assert get_item(current) == stored(change.item, revision)
    assert change.item.provenance == @creator
    assert change.item.id == previous.item.id
    assert change.item.scope == previous.item.scope
    assert change.item.board_id == previous.item.board_id
    assert change.item.board_slug == previous.item.board_slug
    assert change.item.revision == previous.item.revision + 1
    assert change.item.payload["createdAt"] == @t + 10
    assert change.item.payload["startedAt"] == @t + 1
    assert change.board == %{previous.board | revision: previous.board.revision + 1}
    assert_new_event(before, current, change.event, revision)
    expected_projection = projected(change.item, change.projection, revision)
    assert projections(current, nil) == [expected_projection]
    assert projections(current, change.board.id) == [expected_projection]
    key = current_key(change.item.payload)
    assert create_key(current, key) == create_key(before, key)
    assert get_item(before) == stored(previous.item, previous.revision)
    assert get_board(before, previous.board.slug) == stored(previous.board, previous.revision)

    if change.kind == :attachment_add do
      assert attachment(current, change.attachment.id) == stored(change.attachment, revision)
      assert change.event.kind == :attachment_added
      assert change.event.provenance == @uploader
    else
      assert Store.get_attachment(current, change.attachment.id, deadline()) == :not_found
      assert attachment(before, change.attachment.id).record == change.attachment
      assert change.event.kind == :edited
      assert change.event.provenance == @editor
    end

    for old <- Map.get(change.item.payload["metadata"], "attachments", []),
        old["id"] != change.attachment.id do
      assert attachment(current, old["id"]) == attachment(before, old["id"])
    end

    %{
      scope: previous.scope,
      board: change.board,
      item: change.item,
      event: change.event,
      revision: revision,
      point: current
    }
  end

  defp assert_new_event(before, current, event, revision) do
    assert Enum.filter(events(current), &(&1.record.id == event.id)) == [stored(event, revision)]
    assert Enum.reject(events(current), &(&1.record.id == event.id)) == events(before)
  end

  defp event_record(scope, board, kind, payload, provenance),
    do: %{
      schema_version: 1,
      id: payload["id"],
      scope: scope,
      item_id: @item,
      board_id: board,
      kind: kind,
      payload: payload,
      provenance: provenance
    }

  defp projection(card) do
    a = card["metadata"]["automation"]

    %{
      "id" => card["id"],
      "title" => card["title"],
      "status" => card["status"],
      "priority" => card["priority"],
      "agentId" => card["agentId"],
      "boardId" => a["boardId"],
      "tenant" => a["tenant"],
      "updatedAt" => card["updatedAt"],
      "position" => card["position"],
      "createdAt" => card["createdAt"]
    }
  end

  defp projected(item, projection, revision),
    do:
      stored(
        %{
          schema_version: 1,
          id: item.id,
          scope: item.scope,
          board_id: item.board_id,
          board_slug: item.board_slug,
          payload: projection
        },
        revision
      )

  defp current_key(card) do
    a = card["metadata"]["automation"]
    {a["tenant"], a["boardId"], a["idempotencyKey"]}
  end

  defp stored(record, revision), do: %{record: record, storage_revision: revision}
  defp create_key(point, key), do: Store.lookup_create_key_candidates(point, key, deadline())
  defp deadline, do: System.monotonic_time(:millisecond) + 5_000

  defp snapshot(scope) do
    assert {:ok, point} = Store.snapshot(scope, deadline())
    point
  end

  defp get_board(point, slug) do
    assert {:ok, row} = Store.get_board(point, slug, deadline())
    row
  end

  defp get_item(point) do
    assert {:ok, row} = Store.get_item(point, @item, deadline())
    row
  end

  defp attachment(point, id) do
    assert {:ok, row} = Store.get_attachment(point, id, deadline())
    row
  end

  defp events(point) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.events_page(point, @item, [limit: 100], deadline())

    Enum.sort_by(rows, & &1.record.id)
  end

  defp projections(point, board_id) do
    opts = if board_id, do: [board_id: board_id, limit: 100], else: [limit: 100]
    assert {:ok, %{rows: rows, next_cursor: nil}} = Store.items_page(point, opts, deadline())
    Enum.sort_by(rows, & &1.record.id)
  end
end
