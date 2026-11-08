defmodule Synapsis.Workboard.SpecifyFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workboard.Store

  @source_id "37800000-0000-4000-8000-000000000001"
  @destination_id "37800000-0000-4000-8000-000000000002"
  @namespace_id "37800000-0000-4000-8000-000000000003"
  @first_id "37800000-0000-4000-8000-000000000011"
  @peer_id "37800000-0000-4000-8000-000000000012"
  @created_id "37800000-0000-4000-8000-000000000021"
  @peer_event_id "37800000-0000-4000-8000-000000000022"
  @specified_id "37800000-0000-4000-8000-000000000023"
  @repeated_id "37800000-0000-4000-8000-000000000024"
  @old_key {"tenant:source-雪", "source", "shared:ordinary/378"}
  @destination_key {"tenant:destination-😀", "destination", "shared:ordinary/378"}
  @retenant_key {"tenant:destination-😀", "source", "shared:ordinary/378"}
  @creator %{
    "sessionId" => "37800000-0000-4000-8000-000000000031",
    "agentId" => "37800000-0000-4000-8000-000000000032",
    "runId" => "fixture:workboard378:create",
    "incarnation" => 3,
    "invocationId" => "fixture:workboard378:create-invocation",
    "toolCallId" => "fixture:workboard378:create-call",
    "extra" => %{"preserved" => [nil, true, false, 1.25, "café 雪 😀"]}
  }
  @specifier %{
    "sessionId" => "37800000-0000-4000-8000-000000000041",
    "agentId" => "37800000-0000-4000-8000-000000000042",
    "runId" => "fixture:workboard378:specify",
    "incarnation" => 4,
    "invocationId" => "fixture:workboard378:specify-invocation",
    "toolCallId" => "fixture:workboard378:specify-call",
    "extra" => %{"supplied" => ["new caller 雪😀", nil, false]}
  }
  @source_metadata %{
    "id" => "source",
    "name" => "Source café 雪😀",
    "description" => "Retain source metadata.\nNo card-derived rewrite.",
    "createdAt" => 1_800_000_000_000,
    "updatedAt" => 1_800_000_000_000,
    "opaque" => %{"ordered" => [1, nil, false, "source"]}
  }
  @destination_metadata %{
    "id" => "destination",
    "name" => "Destination 雪😀",
    "description" => "Retain the archived destination exactly.",
    "createdAt" => 1_800_000_000_100,
    "updatedAt" => 1_800_000_000_200,
    "archivedAt" => 1_800_000_000_200,
    "opaque" => %{"ordered" => [true, "destination", nil]}
  }
  # Data stores caller-supplied JSON. These deliberately opaque records and
  # independently declared tuples do not require Core's metadata.automation.
  # Identity/provenance are explicit fixtures, not native/model invocations.
  @first_payload %{
    "title" => "Complete first record café 雪😀",
    "status" => "backlog",
    "notes" => "Keep all supplied text.\nSecond line.",
    "automation" => %{
      "boardId" => "source",
      "tenant" => "tenant:source-雪",
      "idempotencyKey" => "shared:ordinary/378"
    },
    "comments" => [
      %{"id" => "ordinary-comment", "body" => "Preserved 雪😀.", "createdAt" => 1_800_000_000_900}
    ],
    "createdAt" => 1_800_000_001_000,
    "updatedAt" => 1_800_000_001_000,
    "position" => 1234,
    "arbitrary" => %{"exact" => [nil, 1.25, true, "é"]}
  }
  @peer_payload %{
    "title" => "Existing identity peer 雪😀",
    "status" => "todo",
    "automation" => %{"callerOwned" => "Data must not infer the declared tuple from this object"},
    "createdAt" => 1_800_000_002_000,
    "updatedAt" => 1_800_000_002_000,
    "position" => 500,
    "arbitrary" => [false, nil, %{"body" => "Unchanged peer."}]
  }
  @specified_payload %{
    "title" => "Specified first record café 雪😀",
    "status" => "todo",
    "notes" => "Keep all supplied text.\nSecond line.",
    "automation" => %{
      "boardId" => "destination",
      "tenant" => "tenant:destination-😀",
      "idempotencyKey" => "shared:ordinary/378",
      "summary" => "Ordinary source specification."
    },
    "comments" => [
      %{"id" => "ordinary-comment", "body" => "Preserved 雪😀.", "createdAt" => 1_800_000_000_900}
    ],
    "createdAt" => 1_800_000_001_000,
    "updatedAt" => 1_800_000_003_001,
    "position" => 1234,
    "arbitrary" => %{"exact" => [nil, 1.25, true, "é"]}
  }
  @returned_payload %{
    "title" => "Specified first record café 雪😀",
    "status" => "todo",
    "notes" => "Keep all supplied text.\nSecond line.",
    "automation" => %{
      "boardId" => "source",
      "tenant" => "tenant:source-雪",
      "idempotencyKey" => "shared:ordinary/378",
      "summary" => "Returned without losing either identity peer."
    },
    "comments" => [
      %{"id" => "ordinary-comment", "body" => "Preserved 雪😀.", "createdAt" => 1_800_000_000_900}
    ],
    "createdAt" => 1_800_000_001_000,
    "updatedAt" => 1_800_000_004_001,
    "position" => 1234,
    "arbitrary" => %{"exact" => [nil, 1.25, true, "é"]}
  }
  @first_projection %{
    "title" => "Complete first record café 雪😀",
    "status" => "backlog",
    "position" => 1234,
    "createdAt" => 1_800_000_001_000,
    "updatedAt" => 1_800_000_001_000,
    "commentCount" => 1,
    "optional" => nil
  }
  @peer_projection %{
    "title" => "Existing identity peer 雪😀",
    "status" => "todo",
    "position" => 500,
    "createdAt" => 1_800_000_002_000,
    "updatedAt" => 1_800_000_002_000,
    "commentCount" => 0,
    "optional" => nil
  }
  @specified_projection %{
    "title" => "Specified first record café 雪😀",
    "status" => "todo",
    "position" => 1234,
    "createdAt" => 1_800_000_001_000,
    "updatedAt" => 1_800_000_003_001,
    "commentCount" => 1,
    "optional" => nil
  }
  @returned_projection %{
    "title" => "Specified first record café 雪😀",
    "status" => "todo",
    "position" => 1234,
    "createdAt" => 1_800_000_001_000,
    "updatedAt" => 1_800_000_004_001,
    "commentCount" => 1,
    "optional" => nil
  }
  @created_event %{
    "kind" => "created",
    "at" => 1_800_000_001_000,
    "toStatus" => "backlog",
    "extra" => [nil, "created"]
  }
  @peer_event %{
    "kind" => "created",
    "at" => 1_800_000_002_000,
    "toStatus" => "todo",
    "extra" => [false, "peer"]
  }
  # Source specified event time need not equal the updatedAt in its full card.
  @specified_event %{
    "kind" => "specified",
    "at" => 1_800_000_003_000,
    "fromStatus" => "backlog",
    "toStatus" => "todo",
    "body" => "Ordinary source specification."
  }
  @returned_event %{
    "kind" => "specified",
    "at" => 1_800_000_004_000,
    "fromStatus" => "todo",
    "toStatus" => "todo",
    "body" => "Returned without losing either identity peer."
  }

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{scope: "fixture:workboard378:data/雪/" <> Ecto.UUID.generate()}
  end

  test "cross-board specify atomically joins duplicate identity members and preserves earlier complete facts",
       %{scope: scope} do
    source = board(scope, @source_id, "source", 1, @source_metadata)
    destination = board(scope, @destination_id, "destination", 1, @destination_metadata)
    commit_board(snapshot(scope), source)
    commit_board(snapshot(scope), destination)
    first = item(scope, @first_id, source, 1, @first_payload)
    peer = item(scope, @peer_id, destination, 1, @peer_payload)
    first_event = event(scope, @created_id, first, :created, @created_event, @creator)
    peer_event = event(scope, @peer_event_id, peer, :created, @peer_event, @creator)
    source2 = %{source | revision: 2}
    destination2 = %{destination | revision: 2}

    first_revision =
      commit_create(snapshot(scope), source2, first, first_event, @first_projection, @old_key)

    peer_revision =
      commit_create(
        snapshot(scope),
        destination2,
        peer,
        peer_event,
        @peer_projection,
        @destination_key
      )

    historical = snapshot(scope)

    original =
      view(
        historical,
        ["source", "destination"],
        [@first_id, @peer_id],
        [@source_id, @destination_id],
        [@old_key, @destination_key]
      )

    assert_members(historical, @old_key, [@first_id], first_revision)
    assert_members(historical, @destination_key, [@peer_id], peer_revision)

    source3 = %{source2 | revision: 3}
    destination3 = %{destination2 | revision: 3}
    specified = item(scope, @first_id, destination3, 2, @specified_payload)

    specified_event =
      event(scope, @specified_id, specified, :specified, @specified_event, @specifier)

    change = %{
      kind: :specify,
      source_board: source3,
      board: destination3,
      item: specified,
      event: specified_event,
      projection: @specified_projection,
      previous_create_key: @old_key,
      create_key: @destination_key
    }

    revision = commit_specify(historical, change)
    assert revision > peer_revision
    current = snapshot(scope)
    assert_boards(current, [stored(source3, revision), stored(destination3, revision)])
    assert_item(current, specified, revision)
    assert_item(current, peer, peer_revision)

    assert_projections(current, nil, [
      stored(projection(specified, @specified_projection), revision),
      stored(projection(peer, @peer_projection), peer_revision)
    ])

    assert_projections(current, @source_id, [])

    assert_projections(current, @destination_id, [
      stored(projection(specified, @specified_projection), revision),
      stored(projection(peer, @peer_projection), peer_revision)
    ])

    assert_events(current, @first_id, [
      stored(first_event, first_revision),
      stored(specified_event, revision)
    ])

    assert_events(current, @peer_id, [stored(peer_event, peer_revision)])
    assert candidates(current, @old_key) == :not_found
    assert Store.lookup_create_key(current, @old_key, deadline()) == :not_found
    assert_members(current, @destination_key, [@first_id, @peer_id], revision)
    assert Store.lookup_create_key(current, @destination_key, deadline()) == {:ok, @first_id}

    assert view(
             historical,
             ["source", "destination"],
             [@first_id, @peer_id],
             [@source_id, @destination_id],
             [@old_key, @destination_key]
           ) == original

    # Leaving a duplicate group removes this member only. Both singleton
    # groups now share the return ACK, while the untouched peer row does not.
    source4 = %{source3 | revision: 4}
    destination4 = %{destination3 | revision: 4}
    returned = item(scope, @first_id, source4, 3, @returned_payload)
    returned_event = event(scope, @repeated_id, returned, :specified, @returned_event, @specifier)

    return_revision =
      commit_specify(current, %{
        kind: :specify,
        source_board: destination4,
        board: source4,
        item: returned,
        event: returned_event,
        projection: @returned_projection,
        previous_create_key: @destination_key,
        create_key: @old_key
      })

    assert return_revision > revision
    final = snapshot(scope)

    assert_boards(final, [stored(source4, return_revision), stored(destination4, return_revision)])

    assert_item(final, returned, return_revision)
    assert_item(final, peer, peer_revision)

    assert_projections(final, nil, [
      stored(projection(returned, @returned_projection), return_revision),
      stored(projection(peer, @peer_projection), peer_revision)
    ])

    assert_projections(final, @source_id, [
      stored(projection(returned, @returned_projection), return_revision)
    ])

    assert_projections(final, @destination_id, [
      stored(projection(peer, @peer_projection), peer_revision)
    ])

    assert_events(final, @first_id, [
      stored(first_event, first_revision),
      stored(specified_event, revision),
      stored(returned_event, return_revision)
    ])

    assert_events(final, @peer_id, [stored(peer_event, peer_revision)])
    assert_members(final, @old_key, [@first_id], return_revision)
    assert_members(final, @destination_key, [@peer_id], return_revision)
    assert Store.lookup_create_key(final, @destination_key, deadline()) == {:ok, @peer_id}
    assert_boards(current, [stored(source3, revision), stored(destination3, revision)])
    assert_members(current, @destination_key, [@first_id, @peer_id], revision)
    assert_projections(current, @source_id, [])

    assert view(
             historical,
             ["source", "destination"],
             [@first_id, @peer_id],
             [@source_id, @destination_id],
             [@old_key, @destination_key]
           ) == original
  end

  test "same-board retenant and repeat advance one board while unchanged identity membership keeps its revision",
       %{scope: scope} do
    source = board(scope, @source_id, "source", 1, @source_metadata)
    commit_board(snapshot(scope), source)
    first = item(scope, @first_id, source, 1, @first_payload)
    peer = item(scope, @peer_id, source, 1, @peer_payload)
    first_event = event(scope, @created_id, first, :created, @created_event, @creator)
    peer_event = event(scope, @peer_event_id, peer, :created, @peer_event, @creator)
    source2 = %{source | revision: 2}
    source3 = %{source | revision: 3}

    first_revision =
      commit_create(snapshot(scope), source2, first, first_event, @first_projection, @old_key)

    peer_revision =
      commit_create(snapshot(scope), source3, peer, peer_event, @peer_projection, @retenant_key)

    historical = snapshot(scope)

    original =
      view(historical, ["source"], [@first_id, @peer_id], [@source_id], [@old_key, @retenant_key])

    source4 = %{source3 | revision: 4}

    retenant_payload = %{
      @specified_payload
      | "automation" => %{
          "boardId" => "source",
          "tenant" => "tenant:destination-😀",
          "idempotencyKey" => "shared:ordinary/378",
          "summary" => "Ordinary source specification."
        }
    }

    specified = item(scope, @first_id, source4, 2, retenant_payload)

    specified_event =
      event(scope, @specified_id, specified, :specified, @specified_event, @specifier)

    revision =
      commit_specify(historical, %{
        kind: :specify,
        source_board: source4,
        board: source4,
        item: specified,
        event: specified_event,
        projection: @specified_projection,
        previous_create_key: @old_key,
        create_key: @retenant_key
      })

    assert revision > peer_revision
    current = snapshot(scope)
    assert_boards(current, [stored(source4, revision)])
    assert_item(current, specified, revision)
    assert_item(current, peer, peer_revision)

    assert_projections(current, nil, [
      stored(projection(specified, @specified_projection), revision),
      stored(projection(peer, @peer_projection), peer_revision)
    ])

    assert_projections(current, @source_id, [
      stored(projection(specified, @specified_projection), revision),
      stored(projection(peer, @peer_projection), peer_revision)
    ])

    assert_events(current, @first_id, [
      stored(first_event, first_revision),
      stored(specified_event, revision)
    ])

    assert_events(current, @peer_id, [stored(peer_event, peer_revision)])
    assert candidates(current, @old_key) == :not_found
    assert_members(current, @retenant_key, [@first_id, @peer_id], revision)

    source5 = %{source4 | revision: 5}
    repeated_payload = %{retenant_payload | "updatedAt" => 1_800_000_004_001}
    repeated = item(scope, @first_id, source5, 3, repeated_payload)

    repeated_event =
      event(
        scope,
        @repeated_id,
        repeated,
        :specified,
        %{
          "kind" => "specified",
          "at" => 1_800_000_004_000,
          "fromStatus" => "todo",
          "toStatus" => "todo"
        },
        @specifier
      )

    repeated_revision =
      commit_specify(current, %{
        kind: :specify,
        source_board: source5,
        board: source5,
        item: repeated,
        event: repeated_event,
        projection: @returned_projection,
        previous_create_key: @retenant_key,
        create_key: @retenant_key
      })

    assert repeated_revision > revision
    final = snapshot(scope)
    assert_boards(final, [stored(source5, repeated_revision)])
    assert_item(final, repeated, repeated_revision)
    assert_item(final, peer, peer_revision)

    expected_rows = [
      stored(projection(repeated, @returned_projection), repeated_revision),
      stored(projection(peer, @peer_projection), peer_revision)
    ]

    assert_projections(final, nil, expected_rows)
    assert_projections(final, @source_id, expected_rows)

    assert_events(final, @first_id, [
      stored(first_event, first_revision),
      stored(specified_event, revision),
      stored(repeated_event, repeated_revision)
    ])

    assert_events(final, @peer_id, [stored(peer_event, peer_revision)])
    assert_members(final, @retenant_key, [@first_id, @peer_id], revision)
    assert candidates(final, @old_key) == :not_found
    assert Store.lookup_create_key(final, @retenant_key, deadline()) == {:ok, @first_id}
    assert_boards(current, [stored(source4, revision)])
    assert_item(current, specified, revision)
    assert_members(current, @retenant_key, [@first_id, @peer_id], revision)

    assert view(historical, ["source"], [@first_id, @peer_id], [@source_id], [
             @old_key,
             @retenant_key
           ]) == original
  end

  test "new namespace and no-key specify survive normal creator exit for a distinct fresh reader",
       %{scope: scope} do
    {creator_pid, written} =
      in_normal_task(fn ->
        source = board(scope, @source_id, "source", 1, @source_metadata)
        commit_board(snapshot(scope), source)

        no_key_payload = %{
          "title" => "No identity tuple 雪😀",
          "status" => "triage",
          "createdAt" => 1_800_000_001_000,
          "updatedAt" => 1_800_000_001_000,
          "opaque" => [nil, %{"all" => "Caller-owned text."}]
        }

        first = item(scope, @first_id, source, 1, no_key_payload)

        first_event =
          event(
            scope,
            @created_id,
            first,
            :created,
            %{"kind" => "created", "at" => 1_800_000_001_000, "toStatus" => "triage"},
            @creator
          )

        before_projection = %{
          "title" => "No identity tuple 雪😀",
          "status" => "triage",
          "position" => 1000,
          "optional" => nil
        }

        source2 = %{source | revision: 2}

        first_revision =
          commit_create(snapshot(scope), source2, first, first_event, before_projection, nil)

        before = snapshot(scope)
        assert Store.get_board(before, "future", deadline()) == :not_found
        source3 = %{source2 | revision: 3}
        namespace = board(scope, @namespace_id, "future", 1, %{"id" => "future"}, @specifier)

        next_payload = %{
          "title" => "Specified no-key item 雪😀",
          "status" => "todo",
          "createdAt" => 1_800_000_001_000,
          "updatedAt" => 1_800_000_003_001,
          "opaque" => [nil, %{"all" => "Caller-owned text."}],
          "automation" => %{
            "boardId" => "future",
            "summary" => "Materialize no public board metadata."
          }
        }

        specified = item(scope, @first_id, namespace, 2, next_payload)

        specified_event =
          event(
            scope,
            @specified_id,
            specified,
            :specified,
            %{
              "kind" => "specified",
              "at" => 1_800_000_003_000,
              "fromStatus" => "triage",
              "toStatus" => "todo",
              "body" => "Materialize no public board metadata."
            },
            @specifier
          )

        next_projection = %{
          "title" => "Specified no-key item 雪😀",
          "status" => "todo",
          "position" => 1000,
          "optional" => nil
        }

        revision =
          commit_specify(before, %{
            kind: :specify,
            source_board: source3,
            board: namespace,
            item: specified,
            event: specified_event,
            projection: next_projection,
            previous_create_key: nil,
            create_key: nil
          })

        assert revision > first_revision
        current = snapshot(scope)
        assert_boards(current, [stored(source3, revision), stored(namespace, revision)])
        assert_item(current, specified, revision)

        assert_projections(current, nil, [
          stored(projection(specified, next_projection), revision)
        ])

        assert_projections(current, @source_id, [])

        assert_projections(current, @namespace_id, [
          stored(projection(specified, next_projection), revision)
        ])

        assert_events(current, @first_id, [
          stored(first_event, first_revision),
          stored(specified_event, revision)
        ])

        assert Store.get_board(before, "future", deadline()) == :not_found
        assert_boards(before, [stored(source2, first_revision)])
        assert_item(before, first, first_revision)

        assert_projections(before, @source_id, [
          stored(projection(first, before_projection), first_revision)
        ])

        assert_projections(before, @namespace_id, [])
        assert_events(before, @first_id, [stored(first_event, first_revision)])

        %{
          expected:
            view(current, ["source", "future"], [@first_id], [@source_id, @namespace_id], []),
          namespace: namespace,
          item: specified,
          revision: revision
        }
      end)

    refute Process.alive?(creator_pid)

    {reader_pid, readback} =
      in_normal_task(fn ->
        view(snapshot(scope), ["source", "future"], [@first_id], [@source_id, @namespace_id], [])
      end)

    assert creator_pid != reader_pid
    refute Process.alive?(reader_pid)
    assert readback == written.expected
    assert readback.boards["future"] == {:ok, stored(written.namespace, written.revision)}
    assert written.namespace.payload == %{"id" => "future"}
    assert readback.items[@first_id] == {:ok, stored(written.item, written.revision)}
  end

  defp board(scope, id, slug, revision, payload, provenance \\ @creator),
    do: %{
      schema_version: 1,
      id: id,
      scope: scope,
      slug: slug,
      revision: revision,
      payload: payload,
      provenance: provenance
    }

  defp item(scope, id, board, revision, payload),
    do: %{
      schema_version: 1,
      id: id,
      scope: scope,
      board_id: board.id,
      board_slug: board.slug,
      revision: revision,
      payload: payload,
      provenance: @creator
    }

  defp event(scope, id, item, kind, payload, provenance),
    do: %{
      schema_version: 1,
      id: id,
      scope: scope,
      item_id: item.id,
      board_id: item.board_id,
      kind: kind,
      payload: payload,
      provenance: provenance
    }

  defp projection(item, payload),
    do: %{
      schema_version: 1,
      id: item.id,
      scope: item.scope,
      board_id: item.board_id,
      board_slug: item.board_slug,
      payload: payload
    }

  defp commit_board(point, proposed) do
    assert {:ok, %{board: board, storage_revision: revision}} =
             Store.commit_board(point, proposed, deadline())

    assert board == proposed
    assert is_integer(revision) and revision > 0
    revision
  end

  defp commit_create(point, board, item, event, projection, key) do
    change = %{
      kind: :create,
      board: board,
      item: item,
      event: event,
      projection: projection,
      create_key: key
    }

    assert {:ok, %{storage_revision: revision} = ack} =
             Store.commit_item(point, change, deadline())

    assert ack == %{board: board, item: item, event: event, storage_revision: revision}
    assert is_integer(revision) and revision > 0
    revision
  end

  defp commit_specify(point, change) do
    assert {:ok, %{storage_revision: revision} = ack} =
             apply(Store, :commit_specify, [point, change, deadline()])

    assert is_integer(revision) and revision > 0

    assert ack == %{
             source_board: change.source_board,
             board: change.board,
             item: change.item,
             event: change.event,
             storage_revision: revision
           }

    revision
  end

  defp assert_boards(point, rows) do
    assert boards_page(point) == sort_rows(rows)

    Enum.each(rows, fn row ->
      assert Store.get_board(point, row.record.slug, deadline()) == {:ok, row}
    end)
  end

  defp assert_item(point, item, revision),
    do: assert(Store.get_item(point, item.id, deadline()) == {:ok, stored(item, revision)})

  defp assert_projections(point, board_id, rows),
    do: assert(projections(point, board_id) == sort_rows(rows))

  defp assert_events(point, id, rows),
    do: assert(events(point, id) == sort_rows(rows))

  defp assert_members(point, key, ids, revision) do
    assert candidates(point, key) == {:ok, %{ids: ids, storage_revision: revision}}
  end

  defp candidates(point, key),
    do: apply(Store, :lookup_create_key_candidates, [point, key, deadline()])

  defp boards_page(point) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.boards_page(point, [limit: 100], deadline())

    sort_rows(rows)
  end

  defp projections(point, board_id) do
    opts = if is_nil(board_id), do: [limit: 100], else: [limit: 100, board_id: board_id]
    assert {:ok, %{rows: rows, next_cursor: nil}} = Store.items_page(point, opts, deadline())
    sort_rows(rows)
  end

  defp events(point, id) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.events_page(point, id, [limit: 100], deadline())

    sort_rows(rows)
  end

  defp view(point, slugs, ids, board_ids, keys) do
    %{
      boards: Map.new(slugs, &{&1, Store.get_board(point, &1, deadline())}),
      board_page: boards_page(point),
      items: Map.new(ids, &{&1, Store.get_item(point, &1, deadline())}),
      scope_projection: projections(point, nil),
      board_projections: Map.new(board_ids, &{&1, projections(point, &1)}),
      events: Map.new(ids, &{&1, events(point, &1)}),
      keys: Map.new(keys, &{&1, candidates(point, &1)})
    }
  end

  defp snapshot(scope) do
    assert {:ok, point} = Store.snapshot(scope, deadline())
    point
  end

  defp stored(record, revision), do: %{record: record, storage_revision: revision}
  defp sort_rows(rows), do: Enum.sort_by(rows, & &1.record.id)

  defp in_normal_task(operation) do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, {:ordinary_specify_task, self()})

        receive do
          :start -> operation.()
        after
          5_000 -> flunk("ordinary specify task was not started")
        end
      end)

    assert_receive {:ordinary_specify_task, pid}, 5_000
    monitor = Process.monitor(pid)
    send(pid, :start)
    value = Task.await(task, 20_000)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    {pid, value}
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
