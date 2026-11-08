defmodule Synapsis.Workboard.DataSchedulePromoteFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workboard.Store

  # Direct caller-owned opaque envelopes. These fixtures verify :promote
  # persistence/ACK, not Core scheduling, normalization, native invocation or
  # a threshold-based attachment trim. Authored before any batch384 candidate.
  @t 1_800_000_000_000
  @creator %{
    "runId" => "fixture:384:data:create",
    "incarnation" => 51,
    "extra" => %{"json" => [nil, false, 1.25, "雪😀"]}
  }
  @promoter %{
    "runId" => "fixture:384:data:promote",
    "incarnation" => 52,
    "toolCallId" => "fixture:384:data:promote-call"
  }
  @uploader %{"runId" => "fixture:384:data:attachment", "incarnation" => 53}

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{scope: "fixture:384:data:schedule/雪/" <> Ecto.UUID.generate()}
  end

  test "ordinary promotion returns exact complete ACK and commits board item event and both projections at one revision",
       %{scope: scope} do
    state = seed(scope)
    supplied = change(state)
    result = commit(state, supplied)
    assert result.item.payload["metadata"] == state.item.payload["metadata"]
    assert result.item.payload["metadata"]["automation"]["scheduledAt"] == @t - 100
    assert result.item.payload["position"] == state.item.payload["position"]
    assert result.item.payload["startedAt"] == state.item.payload["startedAt"]
    assert result.event.provenance == @promoter
    assert result.item.provenance == @creator
  end

  test "caller-owned normal detachment and read facts survive ordinary creator completion for a fresh reader",
       %{scope: scope} do
    creator =
      Task.async(fn ->
        state = seed(scope) |> add_blob()
        historical = attachment(state.point, state.blob.id)
        supplied = change(state)

        payload =
          put_in(
            supplied.item.payload,
            ["metadata"],
            Map.delete(supplied.item.payload["metadata"], "attachments")
          )

        supplied = %{
          supplied
          | item: %{supplied.item | payload: payload},
            projection: projection(payload)
        }

        result = commit(state, supplied, [state.blob], [state.sibling.id])
        assert Store.get_attachment(result.point, state.blob.id, deadline()) == :not_found
        assert attachment(state.point, state.blob.id) == historical
        %{state: state, result: result, historical: historical}
      end)

    written = Task.await(creator, 30_000)
    refute Process.alive?(creator.pid)

    reader =
      Task.async(fn ->
        point = snapshot(scope)

        assert get_item(point, written.result.item.id) ==
                 stored(written.result.item, written.result.storage_revision)

        assert get_board(point, written.result.board.slug) ==
                 stored(written.result.board, written.result.storage_revision)

        assert events(point, written.result.item.id) ==
                 events(written.result.point, written.result.item.id)

        assert Store.get_attachment(point, written.state.blob.id, deadline()) == :not_found
        assert attachment(written.state.point, written.state.blob.id) == written.historical

        assert Store.lookup_create_key_candidates(point, key(written.result.item), deadline()) ==
                 Store.lookup_create_key_candidates(
                   written.state.point,
                   key(written.state.item),
                   deadline()
                 )

        written.result.item
      end)

    assert Task.await(reader, 30_000) == written.result.item
    refute Process.alive?(reader.pid)
    assert creator.pid != reader.pid
  end

  defp seed(scope) do
    board = board(scope, "research")
    assert {:ok, _} = Store.commit_board(snapshot(scope), board, deadline())
    item = item(scope, board, "Supplied scheduled item", "todo", "promote-key")

    payload =
      item.payload
      |> put_in(["metadata", "automation", "scheduledAt"], @t - 100)
      |> Map.put("startedAt", @t - 50)

    item = %{item | payload: payload}
    sibling = item(scope, board, "Supplied other fact", "done", "sibling-key")

    for record <- [item, sibling] do
      point = snapshot(scope)
      current_board = get_board(point, board.slug).record
      [public] = record.payload["events"]

      supplied = %{
        kind: :create,
        board: %{current_board | revision: current_board.revision + 1},
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
      point: point,
      board: get_board(point, board.slug).record,
      item: item,
      sibling: sibling
    }
  end

  defp change(state) do
    public = %{
      "id" => Ecto.UUID.generate(),
      "kind" => "moved",
      "at" => @t + 200,
      "fromStatus" => "todo",
      "toStatus" => "ready"
    }

    card = %{
      state.item.payload
      | "status" => "ready",
        "updatedAt" => @t + 200,
        "events" => state.item.payload["events"] ++ [public]
    }

    next = %{state.item | revision: state.item.revision + 1, payload: card}

    %{
      kind: :promote,
      board: %{state.board | revision: state.board.revision + 1},
      item: next,
      event: event(next, :moved, public, @promoter),
      projection: projection(card),
      create_key: nil
    }
  end

  defp commit(state, supplied, detached \\ [], reads \\ []) do
    assert {:ok, ack} = Store.commit_item(state.point, supplied, deadline(), detached, reads)
    revision = ack.storage_revision

    assert is_integer(revision) and
             revision > get_item(state.point, state.item.id).storage_revision

    assert ack == %{
             board: supplied.board,
             item: supplied.item,
             event: supplied.event,
             storage_revision: revision
           }

    current = snapshot(state.scope)
    assert get_board(current, supplied.board.slug) == stored(supplied.board, revision)
    assert get_item(current, supplied.item.id) == stored(supplied.item, revision)
    assert get_item(state.point, state.item.id).record == state.item
    assert get_item(current, state.sibling.id) == get_item(state.point, state.sibling.id)
    assert events(current, state.sibling.id) == events(state.point, state.sibling.id)

    assert events(current, supplied.item.id) ==
             Enum.sort_by(
               events(state.point, state.item.id) ++ [stored(supplied.event, revision)],
               & &1.record.id
             )

    row = %{
      record: %{
        schema_version: 1,
        id: supplied.item.id,
        scope: state.scope,
        board_id: supplied.board.id,
        board_slug: supplied.board.slug,
        payload: supplied.projection
      },
      storage_revision: revision
    }

    for board_id <- [nil, supplied.board.id] do
      assert Enum.filter(projections(current, board_id), &(&1.record.id == supplied.item.id)) == [
               row
             ]

      assert Enum.reject(projections(current, board_id), &(&1.record.id == supplied.item.id)) ==
               Enum.reject(
                 projections(state.point, board_id),
                 &(&1.record.id == supplied.item.id)
               )
    end

    assert Store.lookup_create_key_candidates(current, key(supplied.item), deadline()) ==
             Store.lookup_create_key_candidates(state.point, key(state.item), deadline())

    assert supplied.item.provenance == @creator
    Map.put(ack, :point, current)
  end

  defp add_blob(state) do
    entry = %{
      "id" => Ecto.UUID.generate(),
      "cardId" => state.item.id,
      "fileName" => "supplied.txt",
      "byteSize" => 4,
      "createdAt" => @t + 50
    }

    blob = %{
      schema_version: 1,
      id: entry["id"],
      scope: state.scope,
      item_id: state.item.id,
      payload: %{"version" => 1, "attachment" => entry, "contentBase64" => "AP8BgA=="},
      provenance: @uploader
    }

    public = %{"id" => Ecto.UUID.generate(), "kind" => "attachment_added", "at" => @t + 51}

    card = %{
      state.item.payload
      | "updatedAt" => @t + 51,
        "events" => state.item.payload["events"] ++ [public],
        "metadata" => Map.put(state.item.payload["metadata"], "attachments", [entry])
    }

    item = %{state.item | revision: state.item.revision + 1, payload: card}
    board = %{state.board | revision: state.board.revision + 1}

    supplied = %{
      kind: :attachment_add,
      board: board,
      item: item,
      event: event(item, :attachment_added, public, @uploader),
      projection: projection(card),
      attachment: blob
    }

    assert {:ok, ack} = Store.commit_attachment(state.point, supplied, deadline())

    assert ack == %{
             board: board,
             item: item,
             event: supplied.event,
             attachment: blob,
             storage_revision: ack.storage_revision
           }

    %{state | item: item, board: board, point: snapshot(state.scope)} |> Map.put(:blob, blob)
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
