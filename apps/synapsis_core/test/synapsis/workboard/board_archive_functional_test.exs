defmodule Synapsis.Workboard.BoardArchiveFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workboard.Store

  @creator %{
    "sessionId" => "37700000-0000-4000-8000-000000000001",
    "agentId" => "37700000-0000-4000-8000-000000000002",
    "runId" => "fixture:workboard377:create",
    "incarnation" => 7,
    "invocationId" => "fixture:workboard377:invocation-create",
    "toolCallId" => "fixture:workboard377:call-create",
    "extra" => %{"ordinary" => [nil, true, 1.25, "café 雪 😀"]}
  }
  @commenter %{
    "sessionId" => "37700000-0000-4000-8000-000000000011",
    "agentId" => "37700000-0000-4000-8000-000000000012",
    "runId" => "fixture:workboard377:comment",
    "incarnation" => 8,
    "invocationId" => "fixture:workboard377:invocation-comment",
    "toolCallId" => "fixture:workboard377:call-comment"
  }
  @archiver %{
    "sessionId" => "37700000-0000-4000-8000-000000000021",
    "agentId" => "37700000-0000-4000-8000-000000000022",
    "runId" => "fixture:workboard377:archive",
    "incarnation" => 9,
    "invocationId" => "fixture:workboard377:invocation-archive",
    "toolCallId" => "fixture:workboard377:call-archive",
    "extra" => %{"supplied" => ["archive 雪😀", false, nil]}
  }
  @rich_args %{
    "title" => " Rich retained item café 雪 😀 ",
    "notes" => " Acceptance 雪😀\nKeep this inner newline. ",
    "priority" => "high",
    "labels" => [" review ", "review", "雪😀"],
    "agentId" => " fixture-agent ",
    "tenant" => " fixture-tenant ",
    "boardId" => " RESEARCH ",
    "idempotencyKey" => " ordinary-repeat ",
    "skills" => [" inspect ", "review", "inspect"],
    "workspace" => %{"kind" => "dir", "path" => "/supplied/workspace"},
    "maxRuntimeSeconds" => 120,
    "maxRetries" => 2
  }
  @automation %{
    "tenant" => "fixture-tenant",
    "boardId" => "research",
    "idempotencyKey" => "ordinary-repeat",
    "skills" => ["inspect", "review"],
    "workspace" => %{"kind" => "dir", "path" => "/supplied/workspace"},
    "maxRuntimeSeconds" => 120,
    "maxRetries" => 2
  }
  @body "Retained ordinary comment 雪😀.\nKeep the supplied body exactly."
  @create_key {"fixture-tenant", "research", "ordinary-repeat"}

  # Independent source expectations: OpenClaw488631c tools-orchestration.ts
  # workboard_board_archive -> store-boards.ts archiveBoard/upsertBoard ->
  # store-board-normalizers.ts normalizeBoardMetadata. These are board metadata
  # transitions, not card archival. No batch377 product candidate was read.
  # Provenance is an explicit fixture, not a native/model invocation claim.
  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{context: %{scope: "fixture:workboard377/雪/" <> Ecto.UUID.generate(), provenance: @creator}}
  end

  test "board archive repeat restore and ordinary upsert preserve complete card facts and historical snapshots",
       %{context: context} do
    %{board: original, card: card} = rich_fixture(context)
    initial = facts(context, card["id"])
    board_id = uuid(initial.board.record.id)

    assert initial.board.record == %{
             schema_version: 1,
             id: board_id,
             scope: context.scope,
             slug: "research",
             revision: 3,
             payload: original,
             provenance: @creator
           }

    assert initial.item.record == %{
             schema_version: 1,
             id: card["id"],
             scope: context.scope,
             board_id: board_id,
             board_slug: "research",
             revision: 2,
             payload: card,
             provenance: @creator
           }

    assert length(initial.events) == 2

    assert Enum.sort(Enum.map(initial.events, & &1.record.provenance)) ==
             Enum.sort([@creator, @commenter])

    assert initial.key == {:ok, card["id"]}

    expected_projection = %{
      record: %{
        schema_version: 1,
        id: card["id"],
        scope: context.scope,
        board_id: board_id,
        board_slug: "research",
        payload:
          Map.merge(rich_summary(card), %{"position" => 1000, "createdAt" => card["createdAt"]})
      },
      storage_revision: initial.item.storage_revision
    }

    assert initial.scope_rows == [expected_projection]
    assert initial.board_rows == [expected_projection]

    Enum.each(card["events"], fn public_event ->
      [row] = Enum.filter(initial.events, &(&1.record.id == public_event["id"]))

      {kind, provenance} =
        case public_event["kind"] do
          "created" -> {:created, @creator}
          "comment_added" -> {:commented, @commenter}
        end

      assert is_integer(row.storage_revision) and row.storage_revision > 0

      assert row.record == %{
               schema_version: 1,
               id: public_event["id"],
               scope: context.scope,
               item_id: card["id"],
               board_id: board_id,
               kind: kind,
               payload: public_event,
               provenance: provenance
             }

      if kind == :commented, do: assert(row.storage_revision == initial.item.storage_revision)
    end)

    assert initial.board_page == [initial.board]

    # Source always writes, including repeated true and false. Wall-clock
    # milliseconds can be equal; envelope/storage revisions prove each write.
    # Omitting archived archives; upsert without archived retains its value.
    operations = [
      {"board_archive", %{"id" => " RESEARCH "}, :archive},
      {"board_archive", %{"id" => "research", "archived" => true}, :archive},
      {"board_create", %{"id" => "research", "name" => " Research renamed 雪😀 "}, :rename},
      {"board_archive", %{"id" => "research", "archived" => false}, :restore},
      {"board_archive", %{"id" => "research", "archived" => false}, :restore},
      {"board_archive", %{"id" => "research", "archived" => true}, :archive}
    ]

    {final, final_facts} =
      Enum.reduce(operations, {original, initial}, fn {action, args, operation},
                                                      {previous, before} ->
        assert {:ok, %{"board" => current}} =
                 execute(%{context | provenance: @archiver}, action, args)

        expected = expected_board_change(previous, current, operation)
        assert current == expected
        assert current["createdAt"] == original["createdAt"]
        after_change = facts(context, card["id"])
        assert_board_change(before, after_change, expected)
        assert facts_at(before.point, card["id"]) == before
        assert_card_views(context, card, expected)
        {expected, after_change}
      end)

    assert final["name"] == "Research renamed 雪😀"
    assert final["archivedAt"] == final["updatedAt"]
    assert final_facts.board.record.revision == 9
    assert facts_at(initial.point, card["id"]) == initial
    assert final_facts.item == initial.item
    assert final_facts.events == initial.events
    assert final_facts.scope_rows == initial.scope_rows
    assert final_facts.board_rows == initial.board_rows
    assert final_facts.key == initial.key

    assert {:ok, %{"card" => ^card}} =
             execute(%{context | provenance: @archiver}, "create", %{
               @rich_args
               | "title" => "Ignored replacement title"
             })

    assert persisted(facts(context, card["id"])) == persisted(final_facts)
  end

  test "archive and restore of previously absent explicit names create source metadata without cards",
       %{context: context} do
    before = snapshot(context)
    assert Store.get_board(before, "future", deadline()) == :not_found
    assert Store.get_board(before, "restored", deadline()) == :not_found
    assert board_rows(before) == []
    assert projection_rows(before, nil) == []

    archive_context = %{context | provenance: @archiver}

    assert {:ok, %{"board" => archived}} =
             execute(archive_context, "board_archive", %{"id" => " FUTURE "})

    at = archived["createdAt"]
    assert is_integer(at) and at > 0

    assert archived == %{
             "id" => "future",
             "createdAt" => at,
             "updatedAt" => at,
             "archivedAt" => at
           }

    archive_point = snapshot(context)
    assert {:ok, archive_row} = Store.get_board(archive_point, "future", deadline())

    assert archive_row.record == %{
             schema_version: 1,
             id: uuid(archive_row.record.id),
             scope: context.scope,
             slug: "future",
             revision: 1,
             payload: archived,
             provenance: @archiver
           }

    assert board_rows(archive_point) == [archive_row]

    # Restoring an absent explicit name is also an upsert, not a silent no-op.
    assert {:ok, %{"board" => restored}} =
             execute(archive_context, "board_archive", %{"id" => "restored", "archived" => false})

    restored_at = restored["createdAt"]
    assert is_integer(restored_at) and restored_at > 0

    assert restored == %{
             "id" => "restored",
             "createdAt" => restored_at,
             "updatedAt" => restored_at
           }

    restore_point = snapshot(context)
    assert {:ok, restore_row} = Store.get_board(restore_point, "restored", deadline())

    assert restore_row.record == %{
             schema_version: 1,
             id: uuid(restore_row.record.id),
             scope: context.scope,
             slug: "restored",
             revision: 1,
             payload: restored,
             provenance: @archiver
           }

    refute restore_row.record.id == archive_row.record.id
    assert restore_row.storage_revision > archive_row.storage_revision
    assert board_rows(restore_point) == [archive_row, restore_row]

    # The existing archived board restores while retaining identity/creator.
    assert {:ok, %{"board" => future_restored}} =
             execute(context, "board_archive", %{"id" => "future", "archived" => false})

    assert future_restored == %{
             "id" => "future",
             "createdAt" => at,
             "updatedAt" => future_restored["updatedAt"]
           }

    assert is_integer(future_restored["updatedAt"]) and future_restored["updatedAt"] > 0
    final_point = snapshot(context)
    assert {:ok, final_row} = Store.get_board(final_point, "future", deadline())
    assert final_row.record == %{archive_row.record | revision: 2, payload: future_restored}
    assert final_row.storage_revision > restore_row.storage_revision
    assert Store.get_board(final_point, "restored", deadline()) == {:ok, restore_row}
    assert board_rows(final_point) == [final_row, restore_row]
    assert projection_rows(final_point, nil) == []
    assert projection_rows(final_point, archive_row.record.id) == []
    assert projection_rows(final_point, restore_row.record.id) == []
    assert Store.get_board(before, "future", deadline()) == :not_found
    assert Store.get_board(before, "restored", deadline()) == :not_found
    assert board_rows(before) == []
    assert Store.get_board(archive_point, "future", deadline()) == {:ok, archive_row}
    assert board_rows(archive_point) == [archive_row]
    assert {:ok, %{"cards" => []}} = execute(context, "list", %{})
    assert {:ok, %{"boards" => boards}} = execute(context, "boards", %{})

    assert boards == [
             %{
               "id" => "future",
               "updatedAt" => future_restored["updatedAt"],
               "total" => 0,
               "active" => 0,
               "archived" => 0,
               "byStatus" => %{}
             },
             %{
               "id" => "restored",
               "updatedAt" => restored_at,
               "total" => 0,
               "active" => 0,
               "archived" => 0,
               "byStatus" => %{}
             }
           ]
  end

  test "normal creator exit and fresh reader preserve archived metadata and keyed current card",
       %{context: context} do
    creator =
      Task.async(fn ->
        %{board: original, card: card} = rich_fixture(context)
        before = facts(context, card["id"])

        assert {:ok, %{"board" => board}} =
                 execute(%{context | provenance: @archiver}, "board_archive", %{
                   "id" => "research"
                 })

        expected = expected_board_change(original, board, :archive)
        assert board == expected
        assert_board_change(before, facts(context, card["id"]), expected)
        assert_card_views(context, card, expected)
        %{card: card, board: expected, views: read_views(context, card["id"])}
      end)

    written = Task.await(creator, 30_000)
    refute Process.alive?(creator.pid)
    reader = Task.async(fn -> read_views(context, written.card["id"]) end)
    read = Task.await(reader, 30_000)
    refute Process.alive?(reader.pid)
    assert creator.pid != reader.pid
    assert read == written.views

    assert read.readback == %{
             "card" => written.card,
             "workerContext" => rich_context(written.card["id"])
           }

    assert read.lists == %{"cards" => [rich_summary(written.card)]}
    assert read.facts.board.record.payload == written.board
    assert read.facts.board.record.provenance == @creator
    assert read.facts.item.record.provenance == @creator

    assert Enum.sort(Enum.map(read.facts.events, & &1.record.provenance)) ==
             Enum.sort([@creator, @commenter])

    assert {:ok, %{"card" => card}} =
             execute(%{context | provenance: @archiver}, "create", %{
               @rich_args
               | "title" => "Ignored after creator exit"
             })

    assert card == written.card
    assert read_views(context, written.card["id"]) == read
  end

  defp expected_board_change(previous, actual, operation) do
    now = actual["updatedAt"]
    assert is_integer(now) and now > 0
    expected = Map.put(previous, "updatedAt", now)

    case operation do
      :archive -> Map.put(expected, "archivedAt", now)
      :restore -> Map.delete(expected, "archivedAt")
      :rename -> Map.put(expected, "name", "Research renamed 雪😀")
    end
  end

  defp assert_board_change(before, after_change, board) do
    assert after_change.board.record == %{
             before.board.record
             | revision: before.board.record.revision + 1,
               payload: board
           }

    assert after_change.board.storage_revision > before.board.storage_revision
    # get_board resolves the actual slug mapping; boards_page independently
    # reads the committed board. Both expose this same acknowledged row.
    assert after_change.board_page == [after_change.board]
    assert after_change.item == before.item
    assert after_change.events == before.events
    assert after_change.scope_rows == before.scope_rows
    assert after_change.board_rows == before.board_rows
    assert after_change.key == before.key
  end

  defp assert_card_views(context, card, board) do
    assert {:ok, %{"card" => ^card, "workerContext" => text}} =
             execute(context, "read", %{"id" => card["id"]})

    assert text == rich_context(card["id"])
    assert {:ok, %{"cards" => [summary]}} = execute(context, "list", %{"boardId" => "research"})
    assert summary == rich_summary(card)
    assert {:ok, %{"boards" => boards}} = execute(context, "boards", %{})

    assert boards == [
             Map.merge(Map.delete(board, "createdAt"), %{
               "updatedAt" => max(board["updatedAt"], card["updatedAt"]),
               "total" => 1,
               "active" => 1,
               "archived" => 0,
               "byStatus" => %{"todo" => 1}
             })
           ]
  end

  defp rich_fixture(context) do
    assert {:ok, %{"board" => board}} =
             execute(context, "board_create", %{
               "id" => "research",
               "name" => "Research 雪😀",
               "description" => "Ordinary board"
             })

    at = board["createdAt"]
    assert is_integer(at) and at > 0

    assert board == %{
             "id" => "research",
             "name" => "Research 雪😀",
             "description" => "Ordinary board",
             "createdAt" => at,
             "updatedAt" => at
           }

    assert {:ok, %{"card" => created}} = execute(context, "create", @rich_args)
    [event] = created["events"]
    id = uuid(created["id"])
    created_at = created["createdAt"]
    assert is_integer(created_at) and created_at > 0

    assert created == %{
             "id" => id,
             "title" => "Rich retained item café 雪 😀",
             "notes" => "Acceptance 雪😀\nKeep this inner newline.",
             "status" => "todo",
             "priority" => "high",
             "labels" => ["review", "雪😀"],
             "agentId" => "fixture-agent",
             "position" => 1000,
             "createdAt" => created_at,
             "updatedAt" => created_at,
             "events" => [
               %{
                 "id" => uuid(event["id"]),
                 "kind" => "created",
                 "at" => created_at,
                 "toStatus" => "todo"
               }
             ],
             "metadata" => %{"automation" => @automation}
           }

    assert {:ok, %{"card" => commented}} =
             execute(%{context | provenance: @commenter}, "comment", %{
               "id" => id,
               "body" => " " <> @body <> " "
             })

    [comment] = commented["metadata"]["comments"]
    comment_event = List.last(commented["events"])

    assert comment == %{
             "id" => uuid(comment["id"]),
             "body" => @body,
             "createdAt" => comment["createdAt"]
           }

    assert is_integer(comment["createdAt"]) and comment["createdAt"] >= created_at
    assert commented["updatedAt"] > created_at
    assert commented["updatedAt"] >= comment["createdAt"]

    assert comment_event == %{
             "id" => uuid(comment_event["id"]),
             "kind" => "comment_added",
             "at" => commented["updatedAt"]
           }

    assert commented == %{
             created
             | "updatedAt" => commented["updatedAt"],
               "events" => [event, comment_event],
               "metadata" => %{"automation" => @automation, "comments" => [comment]}
           }

    %{board: board, card: commented}
  end

  defp facts(context, id), do: facts_at(snapshot(context), id)

  defp facts_at(point, id) do
    assert {:ok, board} = Store.get_board(point, "research", deadline())
    assert {:ok, item} = Store.get_item(point, id, deadline())

    %{
      point: point,
      board: board,
      item: item,
      board_page: board_rows(point),
      events: event_rows(point, id),
      scope_rows: projection_rows(point, nil),
      board_rows: projection_rows(point, board.record.id),
      key: Store.lookup_create_key(point, @create_key, deadline())
    }
  end

  defp persisted(facts), do: Map.delete(facts, :point)

  defp read_views(context, id) do
    assert {:ok, readback} = execute(context, "read", %{"id" => id})
    assert {:ok, lists} = execute(context, "list", %{"boardId" => "research"})
    assert {:ok, boards} = execute(context, "boards", %{})
    %{readback: readback, lists: lists, boards: boards, facts: persisted(facts(context, id))}
  end

  defp rich_summary(card),
    do: %{
      "id" => card["id"],
      "title" => "Rich retained item café 雪 😀",
      "status" => "todo",
      "priority" => "high",
      "agentId" => "fixture-agent",
      "tenant" => "fixture-tenant",
      "boardId" => "research",
      "updatedAt" => card["updatedAt"]
    }

  defp rich_context(id) do
    "# Workboard card #{id}\nTitle: Rich retained item café 雪 😀\nStatus: todo\nPriority: high\nBoard: research\nAgent: fixture-agent\n\n## Notes\nAcceptance 雪😀\nKeep this inner newline." <>
      "\n\n## Recent comments\n- " <>
      @body <>
      "\n\n## Automation\nTenant: fixture-tenant\nBoard: research\nSkills: inspect, review\nWorkspace: dir /supplied/workspace"
  end

  defp execute(context, action, args),
    do: apply(Synapsis.Workboard, :execute, [action, args, context, deadline()])

  defp snapshot(context) do
    assert {:ok, point} = Store.snapshot(context.scope, deadline())
    point
  end

  defp board_rows(point) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.boards_page(point, [limit: 100], deadline())

    Enum.sort_by(rows, & &1.record.slug)
  end

  defp event_rows(point, id) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.events_page(point, id, [limit: 100], deadline())

    Enum.sort_by(rows, & &1.record.id)
  end

  defp projection_rows(point, board_id) do
    opts = if is_nil(board_id), do: [limit: 100], else: [board_id: board_id, limit: 100]
    assert {:ok, %{rows: rows, next_cursor: nil}} = Store.items_page(point, opts, deadline())
    Enum.sort_by(rows, & &1.record.id)
  end

  defp uuid(value) do
    assert is_binary(value)
    assert {:ok, ^value} = Ecto.UUID.cast(value)

    assert String.match?(
             value,
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
           )

    value
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
