defmodule Synapsis.Workboard.StoreFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workboard.Store

  @board_id "35500000-0000-4000-8000-000000000001"
  @first_id "35500000-0000-4000-8000-000000000011"
  @second_id "35500000-0000-4000-8000-000000000012"
  @first_event_id "35500000-0000-4000-8000-000000000021"
  @second_event_id "35500000-0000-4000-8000-000000000022"
  @comment_event_id "35500000-0000-4000-8000-000000000023"
  @comment_id "35500000-0000-4000-8000-000000000031"
  @slug "release-雪"
  @key {"tenant:ordinary-雪", @slug, "prepare:release/355"}

  # These caller-owned literals precede the Store implementation. They are not
  # produced by a normalization function or by reading implementation output.
  # The identities describe fixture provenance, not actual native execution.
  @provenance %{
    "sessionId" => "35500000-0000-4000-8000-000000000041",
    "agentId" => "35500000-0000-4000-8000-000000000042",
    "runId" => "fixture:workboard355:run",
    "incarnation" => 3,
    "invocationId" => "fixture:workboard355:create",
    "toolCallId" => "fixture:workboard355:call-1",
    "extra" => %{"retained" => [nil, true, false, 1.25, "café 雪 😀"]}
  }
  @comment_provenance %{
    "sessionId" => "35500000-0000-4000-8000-000000000041",
    "agentId" => "35500000-0000-4000-8000-000000000042",
    "runId" => "fixture:workboard355:later-run",
    "incarnation" => 4,
    "invocationId" => "fixture:workboard355:comment",
    "toolCallId" => "fixture:workboard355:call-2"
  }
  @board_created %{
    "name" => "Release 雪",
    "description" => "Caller-supplied metadata: café 😀.",
    "kind" => "cards",
    "createdAt" => 1_800_000_000_000,
    "updatedAt" => 1_800_000_000_000,
    "counts" => %{"total" => 0, "byStatus" => %{}},
    "optional" => nil
  }
  @board_updated %{
    "name" => "Release reviewed 雪",
    "description" => "Caller-supplied metadata: café 😀.\nReady for planning.",
    "kind" => "cards",
    "createdAt" => 1_800_000_000_000,
    "updatedAt" => 1_800_000_000_100,
    "counts" => %{"total" => 0, "byStatus" => %{}},
    "optional" => nil
  }
  @board_first %{
    "name" => "Release reviewed 雪",
    "description" => "Caller-supplied metadata: café 😀.\nReady for planning.",
    "kind" => "cards",
    "createdAt" => 1_800_000_000_000,
    "updatedAt" => 1_800_000_001_000,
    "counts" => %{"total" => 1, "byStatus" => %{"todo" => 1}},
    "optional" => nil
  }
  @board_second %{
    "name" => "Release reviewed 雪",
    "description" => "Caller-supplied metadata: café 😀.\nReady for planning.",
    "kind" => "cards",
    "createdAt" => 1_800_000_000_000,
    "updatedAt" => 1_800_000_002_000,
    "counts" => %{"total" => 2, "byStatus" => %{"todo" => 1, "backlog" => 1}},
    "optional" => nil
  }
  @board_commented %{
    "name" => "Release reviewed 雪",
    "description" => "Caller-supplied metadata: café 😀.\nReady for planning.",
    "kind" => "cards",
    "createdAt" => 1_800_000_000_000,
    "updatedAt" => 1_800_000_003_000,
    "counts" => %{"total" => 2, "byStatus" => %{"todo" => 1, "backlog" => 1}},
    "optional" => nil
  }
  @first_payload %{
    "title" => "Prepare release café 雪 😀",
    "notes" => "Check the source-shaped payload.\nPreserve this newline.",
    "status" => "todo",
    "priority" => "high",
    "labels" => ["release", "雪"],
    "position" => 1000,
    "createdAt" => 1_800_000_001_000,
    "updatedAt" => 1_800_000_001_000,
    "comments" => [],
    "automation" => %{
      "tenant" => "tenant:ordinary-雪",
      "boardId" => @slug,
      "idempotencyKey" => "prepare:release/355"
    },
    "optional" => nil
  }
  @second_payload %{
    "title" => "Review the release notes",
    "notes" => "Explicit second position and status, supplied by the caller.",
    "status" => "backlog",
    "priority" => "normal",
    "labels" => ["review"],
    "position" => 2500,
    "createdAt" => 1_800_000_002_000,
    "updatedAt" => 1_800_000_002_000,
    "comments" => [],
    "automation" => %{"boardId" => @slug},
    "optional" => nil
  }
  @comment %{
    "id" => @comment_id,
    "body" => "Reviewed café 雪 😀.\nKeep the supplied body exactly.",
    "createdAt" => 1_800_000_003_000
  }
  @commented_payload %{
    "title" => "Prepare release café 雪 😀",
    "notes" => "Check the source-shaped payload.\nPreserve this newline.",
    "status" => "todo",
    "priority" => "high",
    "labels" => ["release", "雪"],
    "position" => 1000,
    "createdAt" => 1_800_000_001_000,
    "updatedAt" => 1_800_000_003_000,
    "comments" => [@comment],
    "automation" => %{
      "tenant" => "tenant:ordinary-雪",
      "boardId" => @slug,
      "idempotencyKey" => "prepare:release/355"
    },
    "optional" => nil
  }
  @first_projection %{
    "title" => "Prepare release café 雪 😀",
    "status" => "todo",
    "priority" => "high",
    "position" => 1000,
    "labels" => ["release", "雪"],
    "updatedAt" => 1_800_000_001_000,
    "commentCount" => 0
  }
  @second_projection %{
    "title" => "Review the release notes",
    "status" => "backlog",
    "priority" => "normal",
    "position" => 2500,
    "labels" => ["review"],
    "updatedAt" => 1_800_000_002_000,
    "commentCount" => 0
  }
  @commented_projection %{
    "title" => "Prepare release café 雪 😀",
    "status" => "todo",
    "priority" => "high",
    "position" => 1000,
    "labels" => ["release", "雪"],
    "updatedAt" => 1_800_000_003_000,
    "commentCount" => 1
  }

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{scope: "fixture:workboard355/opaque:雪/" <> Ecto.UUID.generate()}
  end

  test "explicit board upsert preserves full provenance and the earlier snapshot", %{scope: scope} do
    records = fixtures(scope)
    assert {:ok, initial} = Store.snapshot(scope, deadline())
    first_revision = commit_board(initial, records.board_created)
    assert {:ok, historical} = Store.snapshot(scope, deadline())
    assert_board(historical, records.board_created, first_revision)

    updated_revision = commit_board(historical, records.board_updated)
    assert updated_revision > first_revision
    assert {:ok, current} = Store.snapshot(scope, deadline())
    assert_board(current, records.board_updated, updated_revision)
    assert_board(historical, records.board_created, first_revision)

    assert records.board_updated.id == records.board_created.id
    assert records.board_updated.provenance == @provenance
    assert records.board_updated.payload["createdAt"] == 1_800_000_000_000
    assert records.board_updated.revision == 2
  end

  test "sequential cards and comment share acknowledged revisions across all public row readers",
       %{scope: scope} do
    records = fixtures(scope)
    committed = create_records(scope, records)
    assert_complete(committed.current, records, committed.revisions)

    # One snapshot and its cursor remain tied to the earlier committed revision,
    # even after the second create and the comment transaction have completed.
    assert_board(committed.after_first, records.board_first, committed.revisions.first)
    assert_item(committed.after_first, records.first, committed.revisions.first)

    assert_projection_pages(committed.after_first, [
      stored(projection(records.first, @first_projection), committed.revisions.first)
    ])

    assert Store.events_page(committed.after_first, @first_id, [], deadline()) ==
             {:ok,
              %{
                rows: [stored(records.first_event, committed.revisions.first)],
                next_cursor: nil
              }}

    assert Store.lookup_create_key(committed.after_first, @key, deadline()) == {:ok, @first_id}

    assert {:ok, %{rows: [remaining_item], next_cursor: nil}} =
             Store.items_page(
               committed.after_second,
               [limit: 1, cursor: committed.item_cursor],
               deadline()
             )

    assert sort_rows([committed.first_item_row, remaining_item]) ==
             sort_rows([
               stored(projection(records.first, @first_projection), committed.revisions.first),
               stored(projection(records.second, @second_projection), committed.revisions.second)
             ])

    assert committed.first_item_row.record.id != remaining_item.record.id
    assert_item(committed.after_second, records.first, committed.revisions.first)
    assert_board(committed.after_second, records.board_second, committed.revisions.second)

    assert Store.events_page(
             committed.current,
             @first_id,
             [limit: 1],
             deadline()
           ) == committed.first_event_page

    %{rows: [first_event_row], next_cursor: event_cursor} = elem(committed.first_event_page, 1)

    assert {:ok, %{rows: [remaining_event], next_cursor: nil}} =
             Store.events_page(
               committed.current,
               @first_id,
               [limit: 1, cursor: event_cursor],
               deadline()
             )

    assert sort_rows([first_event_row, remaining_event]) ==
             sort_rows([
               stored(records.first_event, committed.revisions.first),
               stored(records.comment_event, committed.revisions.comment)
             ])

    assert first_event_row.record.id != remaining_event.record.id
  end

  test "a normally exited creator Task leaves complete records for a fresh public Store reader",
       %{scope: scope} do
    records = fixtures(scope)
    {creator_pid, committed} = in_normal_task(fn -> create_records(scope, records) end)
    refute Process.alive?(creator_pid)

    {reader_pid, readback} =
      in_normal_task(fn ->
        assert {:ok, snapshot} = Store.snapshot(scope, deadline())
        assert_complete(snapshot, records, committed.revisions)

        %{
          board: Store.get_board(snapshot, @slug, deadline()),
          first: Store.get_item(snapshot, @first_id, deadline()),
          second: Store.get_item(snapshot, @second_id, deadline()),
          key: Store.lookup_create_key(snapshot, @key, deadline()),
          events: sort_page(Store.events_page(snapshot, @first_id, [], deadline()))
        }
      end)

    assert reader_pid != creator_pid
    refute Process.alive?(reader_pid)

    assert readback == %{
             board: {:ok, stored(records.board_commented, committed.revisions.comment)},
             first: {:ok, stored(records.commented, committed.revisions.comment)},
             second: {:ok, stored(records.second, committed.revisions.second)},
             key: {:ok, @first_id},
             events:
               {:ok,
                %{
                  rows: [
                    stored(records.first_event, committed.revisions.first),
                    stored(records.comment_event, committed.revisions.comment)
                  ],
                  next_cursor: nil
                }}
           }
  end

  defp create_records(scope, records) do
    assert {:ok, initial} = Store.snapshot(scope, deadline())
    created_revision = commit_board(initial, records.board_created)
    assert {:ok, created} = Store.snapshot(scope, deadline())
    assert_board(created, records.board_created, created_revision)
    updated_revision = commit_board(created, records.board_updated)
    assert updated_revision > created_revision
    assert {:ok, updated} = Store.snapshot(scope, deadline())
    assert_board(updated, records.board_updated, updated_revision)

    first_revision = commit_item(updated, records.first_change)
    assert first_revision > updated_revision
    assert {:ok, after_first} = Store.snapshot(scope, deadline())
    assert_board(after_first, records.board_first, first_revision)
    assert_item(after_first, records.first, first_revision)

    assert_projection_pages(after_first, [
      stored(projection(records.first, @first_projection), first_revision)
    ])

    assert Store.events_page(after_first, @first_id, [], deadline()) ==
             {:ok, %{rows: [stored(records.first_event, first_revision)], next_cursor: nil}}

    assert Store.lookup_create_key(after_first, @key, deadline()) == {:ok, @first_id}

    second_revision = commit_item(after_first, records.second_change)
    assert second_revision > first_revision
    assert {:ok, after_second} = Store.snapshot(scope, deadline())
    assert_board(after_second, records.board_second, second_revision)
    assert_item(after_second, records.second, second_revision)

    assert_projection_pages(after_second, [
      stored(projection(records.first, @first_projection), first_revision),
      stored(projection(records.second, @second_projection), second_revision)
    ])

    assert Store.events_page(after_second, @second_id, [], deadline()) ==
             {:ok, %{rows: [stored(records.second_event, second_revision)], next_cursor: nil}}

    assert {:ok, %{rows: [first_row], next_cursor: item_cursor}} =
             Store.items_page(after_second, [limit: 1], deadline())

    assert first_row in [
             stored(projection(records.first, @first_projection), first_revision),
             stored(projection(records.second, @second_projection), second_revision)
           ]

    refute is_nil(item_cursor)

    comment_revision = commit_item(after_second, records.comment_change)
    assert comment_revision > second_revision
    assert {:ok, current} = Store.snapshot(scope, deadline())

    assert {:ok, %{rows: [first_event], next_cursor: event_cursor}} =
             first_event_page =
             Store.events_page(current, @first_id, [limit: 1], deadline())

    assert first_event in [
             stored(records.first_event, first_revision),
             stored(records.comment_event, comment_revision)
           ]

    refute is_nil(event_cursor)

    %{
      after_first: after_first,
      after_second: after_second,
      current: current,
      first_item_row: first_row,
      item_cursor: item_cursor,
      first_event_page: first_event_page,
      revisions: %{first: first_revision, second: second_revision, comment: comment_revision}
    }
  end

  defp assert_complete(snapshot, records, revisions) do
    assert_board(snapshot, records.board_commented, revisions.comment)
    assert_item(snapshot, records.commented, revisions.comment)
    assert_item(snapshot, records.second, revisions.second)

    assert_projection_pages(snapshot, [
      stored(projection(records.commented, @commented_projection), revisions.comment),
      stored(projection(records.second, @second_projection), revisions.second)
    ])

    assert Store.lookup_create_key(snapshot, @key, deadline()) == {:ok, @first_id}

    assert sort_page(Store.events_page(snapshot, @first_id, [], deadline())) ==
             {:ok,
              %{
                rows: [
                  stored(records.first_event, revisions.first),
                  stored(records.comment_event, revisions.comment)
                ],
                next_cursor: nil
              }}

    assert Store.events_page(snapshot, @second_id, [], deadline()) ==
             {:ok, %{rows: [stored(records.second_event, revisions.second)], next_cursor: nil}}
  end

  defp assert_board(snapshot, record, revision) do
    expected = stored(record, revision)
    assert Store.get_board(snapshot, @slug, deadline()) == {:ok, expected}

    assert Store.boards_page(snapshot, [], deadline()) ==
             {:ok, %{rows: [expected], next_cursor: nil}}
  end

  defp assert_item(snapshot, record, revision) do
    assert Store.get_item(snapshot, record.id, deadline()) == {:ok, stored(record, revision)}
  end

  defp assert_projection_pages(snapshot, rows) do
    expected = {:ok, %{rows: sort_rows(rows), next_cursor: nil}}
    assert sort_page(Store.items_page(snapshot, [], deadline())) == expected
    assert sort_page(Store.items_page(snapshot, [board_id: @board_id], deadline())) == expected
  end

  # Public pages promise KV-key order, not UUID order. Compare every supplied
  # row and storage revision by identity, while cursor checks prove coverage.
  defp sort_rows(rows), do: Enum.sort_by(rows, & &1.record.id)
  defp sort_page({:ok, %{rows: rows} = page}), do: {:ok, %{page | rows: sort_rows(rows)}}

  defp commit_board(snapshot, proposed) do
    assert {:ok, %{board: board, storage_revision: revision}} =
             Store.commit_board(snapshot, proposed, deadline())

    assert board == proposed
    assert is_integer(revision) and revision > 0
    revision
  end

  defp commit_item(snapshot, change) do
    assert {:ok, %{board: board, item: item, event: event, storage_revision: revision}} =
             Store.commit_item(snapshot, change, deadline())

    assert board == change.board
    assert item == change.item
    assert event == change.event
    assert is_integer(revision) and revision > 0
    revision
  end

  defp stored(record, revision), do: %{record: record, storage_revision: revision}

  defp projection(item, payload) do
    %{
      schema_version: 1,
      id: item.id,
      scope: item.scope,
      board_id: item.board_id,
      board_slug: item.board_slug,
      payload: payload
    }
  end

  defp fixtures(scope) do
    board_created = board(scope, 1, @board_created)
    board_updated = board(scope, 2, @board_updated)
    board_first = board(scope, 3, @board_first)
    board_second = board(scope, 4, @board_second)
    board_commented = board(scope, 5, @board_commented)
    first = item(scope, @first_id, 1, @first_payload)
    second = item(scope, @second_id, 1, @second_payload)
    commented = item(scope, @first_id, 2, @commented_payload)

    first_event =
      event(
        scope,
        @first_event_id,
        @first_id,
        :created,
        %{
          "at" => 1_800_000_001_000,
          "toStatus" => "todo",
          "position" => 1000
        },
        @provenance
      )

    second_event =
      event(
        scope,
        @second_event_id,
        @second_id,
        :created,
        %{
          "at" => 1_800_000_002_000,
          "toStatus" => "backlog",
          "position" => 2500
        },
        @provenance
      )

    comment_event =
      event(
        scope,
        @comment_event_id,
        @first_id,
        :commented,
        %{
          "at" => 1_800_000_003_000,
          "comment" => @comment
        },
        @comment_provenance
      )

    %{
      board_created: board_created,
      board_updated: board_updated,
      board_first: board_first,
      board_second: board_second,
      board_commented: board_commented,
      first: first,
      second: second,
      commented: commented,
      first_event: first_event,
      second_event: second_event,
      comment_event: comment_event,
      first_change: %{
        kind: :create,
        board: board_first,
        item: first,
        event: first_event,
        projection: @first_projection,
        create_key: @key
      },
      second_change: %{
        kind: :create,
        board: board_second,
        item: second,
        event: second_event,
        projection: @second_projection,
        create_key: nil
      },
      comment_change: %{
        kind: :comment,
        board: board_commented,
        item: commented,
        event: comment_event,
        projection: @commented_projection,
        create_key: nil
      }
    }
  end

  defp board(scope, revision, payload) do
    %{
      schema_version: 1,
      id: @board_id,
      scope: scope,
      slug: @slug,
      revision: revision,
      payload: payload,
      provenance: @provenance
    }
  end

  defp item(scope, id, revision, payload) do
    %{
      schema_version: 1,
      id: id,
      scope: scope,
      board_id: @board_id,
      board_slug: @slug,
      revision: revision,
      payload: payload,
      provenance: @provenance
    }
  end

  defp event(scope, id, item_id, kind, payload, provenance) do
    %{
      schema_version: 1,
      id: id,
      scope: scope,
      item_id: item_id,
      board_id: @board_id,
      kind: kind,
      payload: payload,
      provenance: provenance
    }
  end

  defp in_normal_task(operation) do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, {:ordinary_workboard_task, self()})

        receive do
          :start -> operation.()
        after
          5_000 -> flunk("ordinary Workboard task was not started")
        end
      end)

    assert_receive {:ordinary_workboard_task, pid}, 5_000
    monitor = Process.monitor(pid)
    send(pid, :start)
    result = Task.await(task, 20_000)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    {pid, result}
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
