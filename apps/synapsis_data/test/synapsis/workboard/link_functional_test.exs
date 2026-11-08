defmodule Synapsis.Workboard.DataLinkFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workboard.Store

  # Caller-owned Data envelopes, authored before the batch383 candidate.
  # The tiny payloads are supplied facts, not Core normalization evidence.
  @t 1_800_000_000_000
  @creator %{
    "runId" => "fixture:383:data:create",
    "incarnation" => 31,
    "extra" => %{"json" => [nil, false, 1.25, "雪😀"]}
  }
  @linker %{
    "runId" => "fixture:383:data:link",
    "incarnation" => 32,
    "toolCallId" => "fixture:383:data:link-call"
  }
  @uploader %{"runId" => "fixture:383:data:attachment", "incarnation" => 33}

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{scope: "fixture:383:data:links/雪/" <> Ecto.UUID.generate()}
  end

  test "three sameboard logical stages publish exact final pair ACK and all immutable events at one revision",
       %{scope: scope} do
    state = seed(scope, false)
    change = change(state, true)
    result = commit(state, change)
    assert hd(result.boards).revision == state.parent_board.revision + 3
    assert result.parent.revision == state.parent.revision + 1
    assert result.child.revision == state.child.revision + 2
    assert Enum.map(result.events, & &1.kind) == [:link_added, :link_added, :moved]
    # The child_metadata event remains durable although only the final ready
    # child and final projections are stored at this revision.
    assert result.child.payload["status"] == "ready"
    assert get_item(result.point, state.child.id).record == List.last(change.stages).item
    assert get_item(state.point, state.child.id).record.payload["status"] == "todo"
  end

  test "crossboard pairs preserve full dependency identity and create key rows on ordinary repeated metadata stages",
       %{scope: scope} do
    state = seed(scope, true)
    first = commit(state, change(state, false))

    repeated_state = %{
      state
      | parent: first.parent,
        child: first.child,
        parent_board: Enum.find(first.boards, &(&1.id == state.parent.board_id)),
        child_board: Enum.find(first.boards, &(&1.id == state.child.board_id)),
        point: first.point
    }

    repeated = commit(repeated_state, change(repeated_state, false, true))

    assert repeated.parent.payload["metadata"]["links"] ==
             first.parent.payload["metadata"]["links"]

    assert repeated.child.payload["metadata"]["links"] == first.child.payload["metadata"]["links"]
    assert Enum.map(repeated.events, & &1.kind) == [:edited, :edited]
    assert repeated.parent.payload["updatedAt"] > first.parent.payload["updatedAt"]
    assert repeated.child.payload["updatedAt"] > first.child.payload["updatedAt"]

    assert Enum.all?(repeated.boards, fn b ->
             b.revision == Enum.find(first.boards, &(&1.id == b.id)).revision + 1
           end)
  end

  test "supplied metadata detachment commits with crossboard readiness and survives normal creator completion for a fresh reader",
       %{scope: scope} do
    creator =
      Task.async(fn ->
        state = seed(scope, true)
        state = add_blob(state)
        historical = attachment(state.point, state.blob.id)
        supplied = change(state, true)
        [parent_stage, child_stage, readiness] = supplied.stages

        remove = fn stage ->
          card = %{
            stage.item.payload
            | "metadata" => Map.delete(stage.item.payload["metadata"], "attachments")
          }

          %{stage | item: %{stage.item | payload: card}, projection: projection(card)}
        end

        child_stage = %{remove.(child_stage) | detached: [state.blob]}
        readiness = remove.(readiness)
        supplied = %{supplied | stages: [parent_stage, child_stage, readiness]}
        result = commit(state, supplied)
        assert Store.get_attachment(result.point, state.blob.id, deadline()) == :not_found
        assert attachment(state.point, state.blob.id) == historical
        %{state: state, result: result, historical: historical}
      end)

    written = Task.await(creator, 30_000)
    refute Process.alive?(creator.pid)

    reader =
      Task.async(fn ->
        point = snapshot(scope)

        assert get_item(point, written.result.parent.id) ==
                 stored(written.result.parent, written.result.storage_revision)

        assert get_item(point, written.result.child.id) ==
                 stored(written.result.child, written.result.storage_revision)

        assert Store.get_attachment(point, written.state.blob.id, deadline()) == :not_found
        assert attachment(written.state.point, written.state.blob.id) == written.historical

        assert events(point, written.result.child.id) ==
                 events(written.result.point, written.result.child.id)

        written.result.child
      end)

    assert Task.await(reader, 30_000) == written.result.child
    refute Process.alive?(reader.pid)
    assert creator.pid != reader.pid
  end

  defp seed(scope, crossboard) do
    parent_board = board(scope, "research")
    assert {:ok, _} = Store.commit_board(snapshot(scope), parent_board, deadline())

    child_board =
      if crossboard do
        target = board(scope, "delivery")
        assert {:ok, _} = Store.commit_board(snapshot(scope), target, deadline())
        target
      else
        parent_board
      end

    parent = item(scope, parent_board, "Parent café", "done", "parent-key")
    child = item(scope, child_board, "Child 雪😀", "todo", "child-key")
    extra = item(scope, parent_board, "Additional current parent fact", "done", "extra-key")

    for record <- [parent, child, extra] do
      point = snapshot(scope)
      old_board = get_board(point, record.board_slug).record
      [public] = record.payload["events"]

      supplied = %{
        kind: :create,
        board: %{old_board | revision: old_board.revision + 1},
        item: record,
        event: event(record, :created, public, @creator),
        projection: projection(record.payload),
        create_key: key(record)
      }

      assert {:ok, ack} = Store.commit_item(point, supplied, deadline())

      assert ack == %{
               board: supplied.board,
               item: record,
               event: supplied.event,
               storage_revision: ack.storage_revision
             }
    end

    point = snapshot(scope)

    %{
      scope: scope,
      parent: parent,
      child: child,
      extra: get_item(point, extra.id),
      parent_board: get_board(point, parent_board.slug).record,
      child_board: get_board(point, child_board.slug).record,
      point: point
    }
  end

  defp change(state, readiness, duplicate \\ false) do
    p = state.parent
    c = state.child
    first_at = max(p.payload["updatedAt"], c.payload["updatedAt"]) + 10

    links =
      if duplicate do
        {p.payload["metadata"]["links"], c.payload["metadata"]["links"]}
      else
        {[
           %{
             "id" => Ecto.UUID.generate(),
             "type" => "child",
             "targetCardId" => c.id,
             "createdAt" => first_at
           }
         ],
         [
           %{
             "id" => Ecto.UUID.generate(),
             "type" => "parent",
             "targetCardId" => p.id,
             "createdAt" => first_at
           }
         ]}
      end

    kind = if duplicate, do: :edited, else: :link_added

    p1 =
      metadata_stage(:parent_metadata, state.parent_board, p, elem(links, 0), kind, first_at + 1)

    child_board =
      if state.parent_board.id == state.child_board.id, do: p1.board, else: state.child_board

    c1 = metadata_stage(:child_metadata, child_board, c, elem(links, 1), kind, first_at + 2)

    stages =
      if readiness do
        public = %{
          "id" => Ecto.UUID.generate(),
          "kind" => "moved",
          "at" => first_at + 3,
          "fromStatus" => "todo",
          "toStatus" => "ready"
        }

        payload = %{
          c1.item.payload
          | "status" => "ready",
            "updatedAt" => first_at + 3,
            "events" => c1.item.payload["events"] ++ [public]
        }

        item = %{c1.item | revision: c1.item.revision + 1, payload: payload}

        [
          p1,
          c1,
          %{
            role: :child_readiness,
            board: %{c1.board | revision: c1.board.revision + 1},
            item: item,
            event: event(item, :moved, public, @linker),
            projection: projection(payload),
            detached: []
          }
        ]
      else
        [p1, c1]
      end

    %{
      kind: :link,
      parent_id: p.id,
      child_id: c.id,
      read_item_ids: [state.extra.record.id],
      stages: stages
    }
  end

  defp metadata_stage(role, board, item, links, kind, at) do
    public = %{"id" => Ecto.UUID.generate(), "kind" => Atom.to_string(kind), "at" => at}

    card = %{
      item.payload
      | "updatedAt" => at,
        "events" => item.payload["events"] ++ [public],
        "metadata" => Map.put(item.payload["metadata"], "links", links)
    }

    next = %{item | revision: item.revision + 1, payload: card}

    %{
      role: role,
      board: %{board | revision: board.revision + 1},
      item: next,
      event: event(next, kind, public, @linker),
      projection: projection(card),
      detached: []
    }
  end

  defp commit(state, supplied) do
    assert {:ok, ack} = Store.commit_link(state.point, supplied, deadline())
    revision = ack.storage_revision
    assert is_integer(revision) and revision > 0

    boards =
      supplied.stages
      |> Enum.reduce(%{}, &Map.put(&2, &1.board.id, &1.board))
      |> Map.values()
      |> Enum.sort_by(& &1.id)

    parent = hd(supplied.stages).item
    child = List.last(supplied.stages).item
    added = Enum.map(supplied.stages, & &1.event)

    assert ack == %{
             parent: parent,
             child: child,
             boards: boards,
             events: added,
             storage_revision: revision
           }

    current = snapshot(state.scope)
    for board <- boards, do: assert(get_board(current, board.slug) == stored(board, revision))

    for {old, final} <- [{state.parent, parent}, {state.child, child}] do
      assert revision > get_item(state.point, old.id).storage_revision
      assert get_item(current, final.id) == stored(final, revision)
      assert get_item(state.point, old.id).record == old
      assert final.provenance == @creator

      new_events =
        Enum.filter(added, &(&1.item_id == final.id)) |> Enum.map(&stored(&1, revision))

      assert events(current, final.id) ==
               Enum.sort_by(events(state.point, old.id) ++ new_events, & &1.record.id)

      assert Store.lookup_create_key_candidates(current, key(final), deadline()) ==
               Store.lookup_create_key_candidates(state.point, key(old), deadline())

      row = %{
        record: %{
          schema_version: 1,
          id: final.id,
          scope: final.scope,
          board_id: final.board_id,
          board_slug: final.board_slug,
          payload: projection(final.payload)
        },
        storage_revision: revision
      }

      for board_id <- [nil, final.board_id] do
        assert Enum.filter(projections(current, board_id), &(&1.record.id == final.id)) == [row]
      end
    end

    assert get_item(current, state.extra.record.id) == state.extra

    assert Enum.reject(projections(current, nil), &(&1.record.id in [parent.id, child.id])) ==
             Enum.reject(projections(state.point, nil), &(&1.record.id in [parent.id, child.id]))

    Map.put(ack, :point, current)
  end

  defp add_blob(state) do
    point = snapshot(state.scope)
    current_board = get_board(point, state.child.board_slug).record

    entry = %{
      "id" => Ecto.UUID.generate(),
      "cardId" => state.child.id,
      "fileName" => "supplied.txt",
      "byteSize" => 4,
      "createdAt" => @t + 50
    }

    blob = %{
      schema_version: 1,
      id: entry["id"],
      scope: state.scope,
      item_id: state.child.id,
      payload: %{"version" => 1, "attachment" => entry, "contentBase64" => "AP8BgA=="},
      provenance: @uploader
    }

    public = %{"id" => Ecto.UUID.generate(), "kind" => "attachment_added", "at" => @t + 51}

    card = %{
      state.child.payload
      | "updatedAt" => @t + 51,
        "events" => state.child.payload["events"] ++ [public],
        "metadata" => Map.put(state.child.payload["metadata"], "attachments", [entry])
    }

    child = %{state.child | revision: state.child.revision + 1, payload: card}
    board = %{current_board | revision: current_board.revision + 1}

    supplied = %{
      kind: :attachment_add,
      board: board,
      item: child,
      event: event(child, :attachment_added, public, @uploader),
      projection: projection(card),
      attachment: blob
    }

    assert {:ok, ack} = Store.commit_attachment(point, supplied, deadline())

    assert ack == %{
             board: board,
             item: child,
             event: supplied.event,
             attachment: blob,
             storage_revision: ack.storage_revision
           }

    %{state | child: child, child_board: board, point: snapshot(state.scope)}
    |> Map.put(:blob, blob)
  end

  defp board(scope, slug),
    do: %{
      schema_version: 1,
      id: Ecto.UUID.generate(),
      scope: scope,
      slug: slug,
      revision: 1,
      payload: %{
        "id" => slug,
        "name" => String.capitalize(slug),
        "createdAt" => @t,
        "updatedAt" => @t
      },
      provenance: @creator
    }

  defp item(scope, board, title, status, key) do
    id = Ecto.UUID.generate()

    public = %{
      "id" => Ecto.UUID.generate(),
      "kind" => "created",
      "at" => @t + 10,
      "toStatus" => status
    }

    card = %{
      "id" => id,
      "title" => title,
      "status" => status,
      "priority" => "normal",
      "labels" => [],
      "position" => 1000,
      "createdAt" => @t + 10,
      "updatedAt" => @t + 10,
      "events" => [public],
      "metadata" => %{
        "automation" => %{"boardId" => board.slug, "idempotencyKey" => key},
        "supplied" => %{"retained" => [nil, false, "雪😀"]}
      }
    }

    %{
      schema_version: 1,
      id: id,
      scope: scope,
      board_id: board.id,
      board_slug: board.slug,
      revision: 1,
      payload: card,
      provenance: @creator
    }
  end

  defp event(item, kind, payload, provenance),
    do: %{
      schema_version: 1,
      id: payload["id"],
      scope: item.scope,
      item_id: item.id,
      board_id: item.board_id,
      kind: kind,
      payload: payload,
      provenance: provenance
    }

  defp key(item),
    do: {nil, item.board_slug, item.payload["metadata"]["automation"]["idempotencyKey"]}

  defp projection(card),
    do:
      Map.take(card, [
        "id",
        "title",
        "status",
        "priority",
        "position",
        "createdAt",
        "updatedAt",
        "metadata"
      ])

  defp stored(record, revision), do: %{record: record, storage_revision: revision}
  defp deadline, do: System.monotonic_time(:millisecond) + 5_000

  defp snapshot(scope) do
    assert {:ok, point} = Store.snapshot(scope, deadline())
    point
  end

  defp get_item(point, id) do
    assert {:ok, row} = Store.get_item(point, id, deadline())
    row
  end

  defp get_board(point, slug) do
    assert {:ok, row} = Store.get_board(point, slug, deadline())
    row
  end

  defp attachment(point, id) do
    assert {:ok, row} = Store.get_attachment(point, id, deadline())
    row
  end

  defp projections(point, board_id) do
    opts = if board_id, do: [limit: 100, board_id: board_id], else: [limit: 100]
    assert {:ok, %{rows: rows, next_cursor: nil}} = Store.items_page(point, opts, deadline())
    Enum.sort_by(rows, & &1.record.id)
  end

  defp events(point, id) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.events_page(point, id, [limit: 100], deadline())

    Enum.sort_by(rows, & &1.record.id)
  end
end
