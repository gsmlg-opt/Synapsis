defmodule Synapsis.Workboard.DataWorkerLifecycleFunctionalTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Synapsis.Workboard.Store

  # Caller-owned opaque envelopes from the accepted Data/Core architecture.
  # These are storage facts, not Core normalization or native invocation evidence.
  # Authored before inspecting the batch386 implementation candidate.
  @time 1_800_000_000_000
  @creator %{"runId" => "fixture:386:data:create", "extra" => [nil, true, 1.5, "雪😀"]}
  @worker %{"runId" => "fixture:386:data:worker", "incarnation" => 7}

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{scope: "fixture:386:data/雪/" <> Ecto.UUID.generate()}
  end

  test "complete worker cycle publishes exact opaque facts and sequence with historical reads", %{
    scope: scope
  } do
    board = create_board(scope, "research")
    original = create_item(scope, board, "Ordinary worker", "work-key")
    point0 = snapshot(scope)
    assert Store.notification_sequence(point0, deadline()) == {:ok, 0}

    claim = %{
      "ownerId" => "worker-a",
      "token" => "fixture-token",
      "claimedAt" => @time,
      "lastHeartbeatAt" => @time,
      "expiresAt" => @time + 1_800_000
    }

    claimed =
      workflow(
        scope,
        original,
        :claim,
        "running",
        "moved",
        Map.put(original.payload["metadata"], "claim", claim),
        nil
      )

    heartbeat_claim = %{claim | "lastHeartbeatAt" => @time + 10, "expiresAt" => @time + 1_800_010}

    heartbeat =
      workflow(
        scope,
        claimed.item,
        :heartbeat,
        "running",
        "heartbeat",
        Map.put(claimed.item.payload["metadata"], "claim", heartbeat_claim),
        nil
      )

    released =
      workflow(
        scope,
        heartbeat.item,
        :release,
        "todo",
        "moved",
        Map.delete(heartbeat.item.payload["metadata"], "claim"),
        nil
      )

    reclaimed =
      workflow(
        scope,
        released.item,
        :claim,
        "running",
        "moved",
        Map.put(released.item.payload["metadata"], "claim", claim),
        nil
      )

    before_complete = snapshot(scope)
    sequence = @time * 1000

    note = %{
      "id" => Ecto.UUID.generate(),
      "kind" => "completed",
      "createdAt" => @time,
      "sequence" => sequence,
      "message" => "Completed 雪😀"
    }

    metadata =
      reclaimed.item.payload["metadata"]
      |> Map.delete("claim")
      |> Map.put("failureCount", 0)
      |> Map.put("notifications", [note])

    completed = workflow(scope, reclaimed.item, :complete, "done", "moved", metadata, sequence)
    assert Store.notification_sequence(snapshot(scope), deadline()) == {:ok, sequence}
    assert Store.notification_sequence(before_complete, deadline()) == {:ok, 0}
    assert Store.notification_sequence(point0, deadline()) == {:ok, 0}
    assert item(point0, original.id) == original
    assert item(before_complete, original.id) == reclaimed.item
    assert completed.item.payload["metadata"]["notifications"] == [note]
    assert completed.item.provenance == @creator
    assert completed.event.provenance == @worker

    assert Enum.map(events(snapshot(scope), original.id), & &1.record.payload["kind"]) ==
             ["created", "moved", "heartbeat", "moved", "moved", "moved"]

    assert Store.lookup_create_key_candidates(snapshot(scope), key(original), deadline()) ==
             Store.lookup_create_key_candidates(point0, key(original), deadline())

    assert_control(scope, "notification_sequence", sequence, completed.storage_revision)
  end

  test "ordinary disjoint writes keep an older snapshot valid while each marker advances", %{
    scope: scope
  } do
    empty = snapshot(scope)
    first_board = board(scope, "research")
    second_board = board(scope, "delivery")
    assert {:ok, a} = Store.commit_board(empty, first_board, deadline())
    first_marker = marker(scope, a.storage_revision)
    assert {:ok, b} = Store.commit_board(empty, second_board, deadline())
    second_marker = marker(scope, b.storage_revision)
    assert first_marker.value == second_marker.value
    assert second_marker.mod_revision > first_marker.mod_revision
    shared = snapshot(scope)
    one = new_item(scope, first_board, "First independent", "one")
    two = new_item(scope, second_board, "Second independent", "two")
    x = commit_create(shared, first_board, one)
    y = commit_create(shared, second_board, two)
    assert y.storage_revision > x.storage_revision
    assert item(snapshot(scope), one.id) == one
    assert item(snapshot(scope), two.id) == two
    assert marker(scope, y.storage_revision).value == first_marker.value
    assert Store.notification_sequence(shared, deadline()) == {:ok, 0}
    assert Store.notification_sequence(snapshot(scope), deadline()) == {:ok, 0}
  end

  test "existing attachment specify and linked stages publish the collection marker together", %{
    scope: scope
  } do
    board = create_board(scope, "research")
    parent = create_item(scope, board, "Parent", "parent")
    child = create_item(scope, board, "Child", "child")
    point = snapshot(scope)
    current_board = board_at(point, "research")
    blob_id = Ecto.UUID.generate()

    blob = %{
      schema_version: 1,
      id: blob_id,
      scope: scope,
      item_id: child.id,
      payload: %{
        "attachment" => %{"id" => blob_id, "fileName" => "雪.txt"},
        "contentBase64" => "6Zuq8J+YgAo="
      },
      provenance: @worker
    }

    public = public_event("attachment_added")

    attached =
      update_item(
        child,
        child.payload["status"],
        "attachment_added",
        Map.put(child.payload["metadata"], "attachments", [blob.payload["attachment"]]),
        public
      )

    attachment_change = %{
      kind: :attachment_add,
      board: next_board(current_board),
      item: attached,
      event: envelope(attached, :attachment_added, public),
      projection: projection(attached.payload),
      attachment: blob
    }

    assert {:ok, attachment_ack} = Store.commit_attachment(point, attachment_change, deadline())
    marker(scope, attachment_ack.storage_revision)
    blob_before = attachment(snapshot(scope), blob.id)
    point = snapshot(scope)
    current_board = board_at(point, "research")
    public = public_event("specified")

    specified =
      update_item(
        attached,
        attached.payload["status"],
        "specified",
        attached.payload["metadata"],
        public
      )

    next = next_board(current_board)

    specify = %{
      kind: :specify,
      source_board: next,
      board: next,
      item: specified,
      event: envelope(specified, :specified, public),
      projection: projection(specified.payload),
      previous_create_key: key(specified),
      create_key: key(specified)
    }

    assert {:ok, specified_ack} = Store.commit_specify(point, specify, deadline())
    marker(scope, specified_ack.storage_revision)
    point = snapshot(scope)
    current_board = board_at(point, "research")
    p_event = public_event("link_added")
    c_event = public_event("link_added")
    parent_next = update_item(parent, "todo", "link_added", parent.payload["metadata"], p_event)

    child_next =
      update_item(specified, "todo", "link_added", specified.payload["metadata"], c_event)

    stages = [
      stage(:parent_metadata, next_board(current_board), parent_next, p_event),
      stage(
        :child_metadata,
        %{current_board | revision: current_board.revision + 2},
        child_next,
        c_event
      )
    ]

    linked = %{
      kind: :link,
      parent_id: parent.id,
      child_id: child.id,
      read_item_ids: [parent.id, child.id],
      stages: stages
    }

    assert {:ok, link_ack} = Store.commit_link(point, linked, deadline())
    marker(scope, link_ack.storage_revision)
    assert attachment(snapshot(scope), blob.id) == blob_before
    before_complete = snapshot(scope)

    metadata =
      child_next.payload["metadata"]
      |> Map.delete("attachments")
      |> Map.put("notifications", [
        %{
          "id" => Ecto.UUID.generate(),
          "sequence" => @time * 1000,
          "kind" => "completed",
          "createdAt" => @time,
          "message" => "Supplied completion"
        }
      ])

    completed =
      workflow(scope, child_next, :complete, "done", "moved", metadata, @time * 1000, [blob], [
        parent.id
      ])

    assert Store.get_attachment(snapshot(scope), blob.id, deadline()) == :not_found
    assert attachment(before_complete, blob.id) == blob_before
    assert item(snapshot(scope), parent.id) == parent_next
    assert_control(scope, "notification_sequence", @time * 1000, completed.storage_revision)
  end

  test "normally completed creator and fresh callers preserve crossboard notification ordering",
       %{scope: scope} do
    creator =
      Task.async(fn ->
        a = create_board(scope, "research")
        b = create_board(scope, "delivery")
        one = create_item(scope, a, "First completed", "first")
        two = create_item(scope, b, "Second completed", "second")
        old = snapshot(scope)
        first = complete(scope, one, @time * 1000)
        assert Store.notification_sequence(snapshot(scope), deadline()) == {:ok, @time * 1000}
        second = complete(scope, two, @time * 1000 + 1)
        %{first: first, second: second, old: old}
      end)

    written = Task.await(creator, 30_000)
    refute Process.alive?(creator.pid)

    reader =
      Task.async(fn ->
        point = snapshot(scope)
        assert Store.notification_sequence(point, deadline()) == {:ok, @time * 1000 + 1}
        assert Store.notification_sequence(written.old, deadline()) == {:ok, 0}
        assert item(point, written.first.item.id) == written.first.item
        assert item(point, written.second.item.id) == written.second.item
        third = complete(scope, written.first.item, @time * 1000 + 2)
        assert Store.notification_sequence(snapshot(scope), deadline()) == {:ok, @time * 1000 + 2}
        assert Store.notification_sequence(point, deadline()) == {:ok, @time * 1000 + 1}
        third
      end)

    final = Task.await(reader, 30_000)
    refute Process.alive?(reader.pid)
    assert creator.pid != reader.pid
    assert item(snapshot(scope), final.item.id) == final.item
    other = "fixture:386:other/" <> Ecto.UUID.generate()
    assert Store.notification_sequence(snapshot(other), deadline()) == {:ok, 0}
  end

  defp complete(scope, previous, sequence) do
    notification = %{
      "id" => Ecto.UUID.generate(),
      "kind" => "completed",
      "sequence" => sequence,
      "createdAt" => @time,
      "message" => "Caller-owned completed metadata 雪😀"
    }

    metadata =
      Map.update(
        previous.payload["metadata"],
        "notifications",
        [notification],
        &(&1 ++ [notification])
      )

    event = if previous.payload["status"] == "done", do: "notification", else: "moved"
    workflow(scope, previous, :complete, "done", event, metadata, sequence)
  end

  defp workflow(
         scope,
         previous,
         kind,
         status,
         public_kind,
         metadata,
         sequence,
         detached \\ [],
         read_ids \\ []
       ) do
    point = snapshot(scope)
    old_board = board_at(point, previous.board_slug)
    public = public_event(public_kind)

    public =
      if public_kind == "moved",
        do:
          Map.merge(public, %{"fromStatus" => previous.payload["status"], "toStatus" => status}),
        else: public

    next = update_item(previous, status, public_kind, metadata, public)

    data_kind =
      Map.fetch!(
        %{
          "moved" => :moved,
          "claimed" => :claimed,
          "heartbeat" => :heartbeat,
          "notification" => :notification
        },
        public_kind
      )

    change = %{
      kind: kind,
      board: next_board(old_board),
      item: next,
      event: envelope(next, data_kind, public),
      projection: projection(next.payload),
      detached: detached,
      read_item_ids: read_ids,
      notification_sequence: sequence
    }

    assert {:ok, ack} = Store.commit_workflow(point, change, deadline())

    assert ack == %{
             board: change.board,
             item: next,
             event: change.event,
             storage_revision: ack.storage_revision
           }

    now = snapshot(scope)
    assert item(now, next.id) == next
    assert board_at(now, previous.board_slug) == change.board

    for opts <- [[], [board_id: next.board_id]] do
      assert {:ok, page} = Store.items_page(now, opts, deadline())
      row = Enum.find(page.rows, &(&1.record.id == next.id))
      assert row.storage_revision == ack.storage_revision
      assert row.record.payload == change.projection
    end

    assert List.last(events(now, next.id)).record == change.event
    assert List.last(events(now, next.id)).storage_revision == ack.storage_revision
    marker(scope, ack.storage_revision)
    ack
  end

  defp stage(role, board, item, public),
    do: %{
      role: role,
      board: board,
      item: item,
      event: envelope(item, :link_added, public),
      projection: projection(item.payload),
      detached: []
    }

  defp create_board(scope, slug) do
    value = board(scope, slug)
    assert {:ok, ack} = Store.commit_board(snapshot(scope), value, deadline())
    marker(scope, ack.storage_revision)
    value
  end

  defp create_item(scope, board, title, key_value) do
    value = new_item(scope, board, title, key_value)
    point = snapshot(scope)
    commit_create(point, board_at(point, board.slug), value)
    value
  end

  defp commit_create(point, board, item) do
    [public] = item.payload["events"]

    change = %{
      kind: :create,
      board: next_board(board),
      item: item,
      event: envelope(item, :created, public, @creator),
      projection: projection(item.payload),
      create_key: key(item)
    }

    assert {:ok, ack} = Store.commit_item(point, change, deadline())
    marker(item.scope, ack.storage_revision)
    ack
  end

  defp board(scope, slug),
    do: %{
      schema_version: 1,
      id: Ecto.UUID.generate(),
      scope: scope,
      slug: slug,
      revision: 1,
      payload: %{"id" => slug, "name" => "Board 雪😀", "createdAt" => @time},
      provenance: @creator
    }

  defp new_item(scope, board, title, key_value) do
    id = Ecto.UUID.generate()

    payload = %{
      "id" => id,
      "title" => title,
      "status" => "todo",
      "priority" => "normal",
      "labels" => [],
      "position" => 1000,
      "createdAt" => @time,
      "updatedAt" => @time,
      "events" => [public_event("created")],
      "metadata" => %{
        "automation" => %{
          "boardId" => board.slug,
          "tenant" => "fixture-tenant",
          "idempotencyKey" => key_value
        }
      }
    }

    %{
      schema_version: 1,
      id: id,
      scope: scope,
      board_id: board.id,
      board_slug: board.slug,
      revision: 1,
      payload: payload,
      provenance: @creator
    }
  end

  defp update_item(item, status, _kind, metadata, public) do
    payload =
      item.payload
      |> Map.put("status", status)
      |> Map.put("metadata", metadata)
      |> Map.put("updatedAt", item.payload["updatedAt"] + 1)
      |> Map.update!("events", &(&1 ++ [public]))

    %{item | revision: item.revision + 1, payload: payload}
  end

  defp envelope(item, kind, public, provenance \\ @worker),
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

  defp public_event(kind), do: %{"id" => Ecto.UUID.generate(), "kind" => kind, "at" => @time + 1}
  defp next_board(board), do: %{board | revision: board.revision + 1}

  defp projection(payload),
    do:
      Map.take(payload, ~w(id title status priority labels position createdAt updatedAt metadata))

  defp key(item),
    do:
      {"fixture-tenant", item.board_slug,
       item.payload["metadata"]["automation"]["idempotencyKey"]}

  defp snapshot(scope) do
    assert {:ok, point} = Store.snapshot(scope, deadline())
    point
  end

  defp item(point, id) do
    assert {:ok, row} = Store.get_item(point, id, deadline())
    row.record
  end

  defp board_at(point, slug) do
    assert {:ok, row} = Store.get_board(point, slug, deadline())
    row.record
  end

  defp events(point, id) do
    assert {:ok, %{rows: rows, next_cursor: nil}} = Store.events_page(point, id, [], deadline())
    Enum.sort_by(rows, & &1.storage_revision)
  end

  defp attachment(point, id) do
    assert {:ok, row} = Store.get_attachment(point, id, deadline())
    row
  end

  defp marker(scope, revision) do
    key = control_key(scope, "mutation_frontier")

    assert {:ok, %Concord.KV.Record{} = record} =
             KV.get(key, engine: :turso, metadata: true, timeout: 5000)

    assert record.mod_revision == revision
    record
  end

  defp assert_control(scope, name, value, revision) do
    assert {:ok, %Concord.KV.Record{} = record} =
             KV.get(control_key(scope, name), engine: :turso, metadata: true, timeout: 5000)

    assert record.value == value
    assert record.mod_revision == revision
  end

  defp control_key(scope, name),
    do:
      "coord/workboard/v1/scopes/" <>
        Base.url_encode64(scope, padding: false) <> "/control/" <> name

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
