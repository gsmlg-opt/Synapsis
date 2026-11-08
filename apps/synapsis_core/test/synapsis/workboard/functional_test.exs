defmodule Synapsis.Workboard.FunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workboard.Store

  @creator %{
    "sessionId" => "37400000-0000-4000-8000-000000000001",
    "agentId" => "37400000-0000-4000-8000-000000000002",
    "runId" => "fixture:workboard374:create",
    "incarnation" => 4,
    "invocationId" => "fixture:workboard374:invocation-create",
    "toolCallId" => "fixture:workboard374:call-create",
    "extra" => %{"ordinary" => [nil, true, 1.25, "café 雪 😀"]}
  }
  @commenter %{
    "sessionId" => "37400000-0000-4000-8000-000000000011",
    "agentId" => "37400000-0000-4000-8000-000000000012",
    "runId" => "fixture:workboard374:comment",
    "incarnation" => 5,
    "invocationId" => "fixture:workboard374:invocation-comment",
    "toolCallId" => "fixture:workboard374:call-comment"
  }
  @rich_args %{
    "title" => " Rich supplied item café 雪 😀 ",
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
  @rich_automation %{
    "tenant" => "fixture-tenant",
    "boardId" => "research",
    "idempotencyKey" => "ordinary-repeat",
    "skills" => ["inspect", "review"],
    "workspace" => %{"kind" => "dir", "path" => "/supplied/workspace"},
    "maxRuntimeSeconds" => 120,
    "maxRetries" => 2
  }
  @comment_body "Reviewed ordinary evidence 雪😀.\nKeep the supplied body exactly."

  # These expectations come from unchanged OpenClaw488631c records/context
  # algorithms and batch374's explicit-existing-board component contract.
  # Provenance above is a caller fixture, never claimed as a native invocation.
  # No candidate/production Workboard implementation was read by this author.
  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{context: %{scope: "fixture:workboard374/雪/" <> Ecto.UUID.generate(), provenance: @creator}}
  end

  test "source-shaped rich records and comments persist as complete atomic facts with historical reads",
       %{context: context} do
    first = create_board(context, " research ", " Research 雪😀 ", " Ordinary board ")
    assert first["id"] == "research"
    first_time = first["createdAt"]
    assert is_integer(first_time) and first_time > 0

    assert first == %{
             "id" => "research",
             "name" => "Research 雪😀",
             "description" => "Ordinary board",
             "createdAt" => first_time,
             "updatedAt" => first_time
           }

    initial_snapshot = snapshot(context)
    assert {:ok, first_board_row} = Store.get_board(initial_snapshot, "research", deadline())
    board_id = uuid(first_board_row.record.id)

    assert first_board_row.record == %{
             schema_version: 1,
             id: board_id,
             scope: context.scope,
             slug: "research",
             revision: 1,
             payload: first,
             provenance: @creator
           }

    assert {:ok, %{"board" => updated}} =
             execute(context, "board_create", %{
               "id" => "RESEARCH",
               "name" => " Research reviewed "
             })

    assert updated == %{
             "id" => "research",
             "name" => "Research reviewed",
             "description" => "Ordinary board",
             "createdAt" => first_time,
             "updatedAt" => updated["updatedAt"]
           }

    assert updated["updatedAt"] >= first_time
    updated_snapshot = snapshot(context)
    assert {:ok, updated_board_row} = Store.get_board(updated_snapshot, "research", deadline())
    assert updated_board_row.record.id == first_board_row.record.id
    assert updated_board_row.record.provenance == @creator
    assert updated_board_row.record.revision == first_board_row.record.revision + 1
    assert updated_board_row.record == %{first_board_row.record | revision: 2, payload: updated}
    assert Store.get_board(initial_snapshot, "research", deadline()) == {:ok, first_board_row}

    assert {:ok, %{"card" => card}} = execute(context, "create", @rich_args)
    assert @rich_args["labels"] == [" review ", "review", "雪😀"]
    [created_event] = card["events"]
    card_id = uuid(card["id"])
    created_event_id = uuid(created_event["id"])
    assert card_id != created_event_id
    created_at = card["createdAt"]
    assert is_integer(created_at) and created_at > 0

    expected_card = %{
      "id" => card_id,
      "title" => "Rich supplied item café 雪 😀",
      "notes" => "Acceptance 雪😀\nKeep this inner newline.",
      "status" => "todo",
      "priority" => "high",
      "labels" => ["review", "雪😀"],
      "agentId" => "fixture-agent",
      "position" => 1000,
      "createdAt" => created_at,
      "updatedAt" => created_at,
      "events" => [
        %{"id" => created_event_id, "kind" => "created", "at" => created_at, "toStatus" => "todo"}
      ],
      "metadata" => %{"automation" => @rich_automation}
    }

    assert card == expected_card
    before_comment = snapshot(context)
    assert {:ok, item_before} = Store.get_item(before_comment, card_id, deadline())
    assert {:ok, board_before} = Store.get_board(before_comment, "research", deadline())
    before_events = events(before_comment, card_id)
    assert length(before_events) == 1
    assert item_before.record.id == card_id
    assert item_before.record.scope == context.scope
    assert item_before.record.board_id == board_before.record.id
    assert item_before.record.board_slug == "research"
    assert item_before.record.provenance == @creator
    assert item_before.record.revision == 1
    assert item_before.record.schema_version == 1

    assert item_before.record == %{
             schema_version: 1,
             id: card_id,
             scope: context.scope,
             board_id: board_id,
             board_slug: "research",
             revision: 1,
             payload: expected_card,
             provenance: @creator
           }

    assert hd(before_events).record == %{
             schema_version: 1,
             id: created_event_id,
             scope: context.scope,
             item_id: card_id,
             board_id: board_id,
             kind: :created,
             payload: created_event,
             provenance: @creator
           }

    assert board_before.record.provenance == @creator
    assert board_before.record.revision == updated_board_row.record.revision + 1
    assert board_before.record == %{updated_board_row.record | revision: 3}

    assert_atomic(
      before_comment,
      board_before,
      item_before,
      hd(before_events),
      expected_card,
      rich_summary(card)
    )

    assert {:ok, %{"card" => ^expected_card, "workerContext" => text_before}} =
             execute(context, "read", %{"id" => " " <> card_id <> " "})

    assert text_before == rich_context(card_id, nil, [])

    comment_context = %{context | provenance: @commenter}

    assert {:ok, %{"card" => commented}} =
             execute(comment_context, "comment", %{
               "id" => card_id,
               "body" => " " <> @comment_body <> " "
             })

    [comment] = commented["metadata"]["comments"]
    comment_id = uuid(comment["id"])
    [^created_event, comment_event] = commented["events"]
    comment_event_id = uuid(comment_event["id"])
    assert length(Enum.uniq([card_id, created_event_id, comment_id, comment_event_id])) == 4

    assert comment == %{
             "id" => comment_id,
             "body" => @comment_body,
             "createdAt" => comment["createdAt"]
           }

    assert is_integer(comment["createdAt"]) and comment["createdAt"] >= created_at
    assert commented["updatedAt"] > created_at
    assert commented["updatedAt"] >= comment["createdAt"]

    assert comment_event == %{
             "id" => comment_event_id,
             "kind" => "comment_added",
             "at" => commented["updatedAt"]
           }

    expected_commented = %{
      expected_card
      | "updatedAt" => commented["updatedAt"],
        "events" => [created_event, comment_event],
        "metadata" => %{"automation" => @rich_automation, "comments" => [comment]}
    }

    assert commented == expected_commented
    current_snapshot = snapshot(context)
    assert {:ok, item_after} = Store.get_item(current_snapshot, card_id, deadline())
    assert {:ok, board_after} = Store.get_board(current_snapshot, "research", deadline())
    after_events = events(current_snapshot, card_id)
    new_event = Enum.find(after_events, &(&1.record.kind == :commented))
    assert length(after_events) == 2
    assert item_after.record.revision == 2
    assert item_after.record.id == item_before.record.id
    assert item_after.record.board_id == item_before.record.board_id
    assert item_after.record.board_slug == item_before.record.board_slug
    assert item_after.record.provenance == @creator
    assert new_event.record.provenance == @commenter
    assert item_after.record == %{item_before.record | revision: 2, payload: expected_commented}

    assert new_event.record == %{
             schema_version: 1,
             id: comment_event_id,
             scope: context.scope,
             item_id: card_id,
             board_id: board_id,
             kind: :commented,
             payload: comment_event,
             provenance: @commenter
           }

    assert board_after.record.revision == board_before.record.revision + 1
    assert board_after.record.provenance == @creator
    assert board_after.record == %{board_before.record | revision: 4}

    assert_atomic(
      current_snapshot,
      board_after,
      item_after,
      new_event,
      expected_commented,
      rich_summary(commented)
    )

    assert Store.get_item(before_comment, card_id, deadline()) == {:ok, item_before}
    assert Store.get_board(before_comment, "research", deadline()) == {:ok, board_before}
    assert events(before_comment, card_id) == before_events

    assert {:ok, %{"card" => ^expected_commented, "workerContext" => text_after}} =
             execute(context, "read", %{"id" => card_id})

    assert text_after == rich_context(card_id, nil, [@comment_body])
    assert {:ok, %{"cards" => [summary]}} = execute(context, "list", %{"boardId" => " research "})
    assert summary == rich_summary(commented)

    assert {:ok, %{"boards" => [board_summary]}} = execute(context, "boards", %{})

    assert board_summary == %{
             "id" => "research",
             "name" => "Research reviewed",
             "description" => "Ordinary board",
             "updatedAt" => max(updated["updatedAt"], commented["updatedAt"]),
             "total" => 1,
             "active" => 1,
             "archived" => 0,
             "byStatus" => %{"todo" => 1}
           }

    assert Store.lookup_create_key(
             current_snapshot,
             {"fixture-tenant", "research", "ordinary-repeat"},
             deadline()
           ) ==
             {:ok, card_id}

    # The repeat returns the current persisted card, including its later comment.
    # All relevant records, directory rows and event inventory remain identical.
    assert {:ok, %{"card" => ^expected_commented}} =
             execute(comment_context, "create", %{
               @rich_args
               | "title" => "Ignored replacement title"
             })

    after_repeat = snapshot(context)
    assert Store.get_item(after_repeat, card_id, deadline()) == {:ok, item_after}
    assert Store.get_board(after_repeat, "research", deadline()) == {:ok, board_after}
    assert events(after_repeat, card_id) == after_events
    assert projections(after_repeat, nil) == projections(current_snapshot, nil)

    assert projections(after_repeat, board_after.record.id) ==
             projections(current_snapshot, board_after.record.id)
  end

  test "ordinary source status ordering compact filters board counts and precise recent-done context",
       %{context: context} do
    research = create_board(context, "research", "Research", "Ordinary board")
    other_board = create_board(context, "other", "Other", "Second explicit board")
    minimal = create(context, %{"title" => " Minimal 雪😀 ", "boardId" => "research"})
    rich = create(context, @rich_args)

    done =
      create(context, %{
        "title" => "Done ordinary item",
        "boardId" => "research",
        "status" => "done",
        "agentId" => "fixture-agent"
      })

    other =
      create(context, %{
        "title" => "Other done item",
        "boardId" => "other",
        "status" => "done",
        "agentId" => "fixture-agent"
      })

    assert minimal == minimal_card(minimal)
    assert rich["position"] == 2000
    assert done["position"] == 1000
    assert other["position"] == 1000
    assert done["completedAt"] == done["createdAt"]
    assert done["updatedAt"] == done["createdAt"]
    [done_event] = done["events"]
    uuid(done_event["id"])

    assert done == %{
             "id" => done["id"],
             "title" => "Done ordinary item",
             "status" => "done",
             "priority" => "normal",
             "labels" => [],
             "position" => 1000,
             "createdAt" => done["createdAt"],
             "updatedAt" => done["createdAt"],
             "completedAt" => done["createdAt"],
             "agentId" => "fixture-agent",
             "events" => [
               %{
                 "id" => done_event["id"],
                 "kind" => "created",
                 "at" => done["createdAt"],
                 "toStatus" => "done"
               }
             ],
             "metadata" => %{"automation" => %{"boardId" => "research"}}
           }

    assert {:ok, %{"cards" => listed}} = execute(context, "list", %{"boardId" => "RESEARCH"})
    assert listed == [plain_summary(minimal), rich_summary(rich), assigned_summary(done)]

    assert {:ok, %{"cards" => [filtered]}} =
             execute(context, "list", %{
               "boardId" => "research",
               "status" => "todo",
               "agentId" => "fixture-agent",
               "tenant" => "fixture-tenant"
             })

    assert filtered == rich_summary(rich)

    assert {:ok, %{"cards" => [limited]}} =
             execute(context, "list", %{"boardId" => "research", "limit" => 1})

    assert limited == plain_summary(minimal)

    assert {:ok, %{"card" => ^rich, "workerContext" => rich_text}} =
             execute(context, "read", %{"id" => rich["id"]})

    assert rich_text == rich_context(rich["id"], done, [])

    assert {:ok, %{"card" => ^done, "workerContext" => done_text}} =
             execute(context, "read", %{"id" => done["id"]})

    assert done_text ==
             "# Workboard card #{done["id"]}\n" <>
               "Title: Done ordinary item\nStatus: done\nPriority: normal\nBoard: research\nAgent: fixture-agent\n" <>
               "\n## Automation\nBoard: research\n" <>
               "\n## Active diagnostics\n- warning: Done card has no proof"

    assert {:ok, %{"boards" => summaries}} = execute(context, "boards", %{})

    assert summaries == [
             %{
               "id" => "other",
               "name" => "Other",
               "description" => "Second explicit board",
               "updatedAt" => max(other_board["updatedAt"], other["updatedAt"]),
               "total" => 1,
               "active" => 1,
               "archived" => 0,
               "byStatus" => %{"done" => 1}
             },
             %{
               "id" => "research",
               "name" => "Research",
               "description" => "Ordinary board",
               "updatedAt" =>
                 Enum.max([
                   research["updatedAt"],
                   minimal["updatedAt"],
                   rich["updatedAt"],
                   done["updatedAt"]
                 ]),
               "total" => 3,
               "active" => 3,
               "archived" => 0,
               "byStatus" => %{"todo" => 2, "done" => 1}
             }
           ]

    # Exact tuple identity: same successful key in another tenant or explicit
    # board is another card, while normalization retains ordinary repeat meaning.
    second_tenant = create(context, %{@rich_args | "tenant" => "second-tenant"})
    second_board = create(context, %{@rich_args | "boardId" => "other"})
    assert length(Enum.uniq([rich["id"], second_tenant["id"], second_board["id"]])) == 3
    assert second_tenant["metadata"]["automation"]["tenant"] == "second-tenant"
    assert second_board["metadata"]["automation"]["boardId"] == "other"
    assert second_tenant["position"] == 3000
    assert second_board["position"] == 1000
  end

  test "normal creator Task exit leaves exact complete source facts for a fresh Core reader",
       %{context: context} do
    creator =
      Task.async(fn ->
        board = create_board(context, "research", "Research", "Ordinary board")
        card = create(context, @rich_args)

        assert {:ok, %{"card" => commented}} =
                 execute(%{context | provenance: @commenter}, "comment", %{
                   "id" => card["id"],
                   "body" => @comment_body
                 })

        assert {:ok, readback} = execute(context, "read", %{"id" => card["id"]})
        assert {:ok, lists} = execute(context, "list", %{"boardId" => "research"})
        assert {:ok, boards} = execute(context, "boards", %{})
        point = snapshot(context)
        assert {:ok, item} = Store.get_item(point, card["id"], deadline())

        %{
          board: board,
          card: commented,
          readback: readback,
          lists: lists,
          boards: boards,
          item: item,
          events: events(point, card["id"]),
          rows: projections(point, nil)
        }
      end)

    written = Task.await(creator, 30_000)
    refute Process.alive?(creator.pid)

    reader =
      Task.async(fn ->
        assert {:ok, readback} = execute(context, "read", %{"id" => written.card["id"]})
        assert {:ok, lists} = execute(context, "list", %{"boardId" => "research"})
        assert {:ok, boards} = execute(context, "boards", %{})
        point = snapshot(context)
        assert {:ok, item} = Store.get_item(point, written.card["id"], deadline())

        %{
          readback: readback,
          lists: lists,
          boards: boards,
          item: item,
          events: events(point, written.card["id"]),
          rows: projections(point, nil)
        }
      end)

    read = Task.await(reader, 30_000)
    refute Process.alive?(reader.pid)
    assert reader.pid != creator.pid
    assert read == Map.drop(written, [:board, :card])

    assert read.readback == %{
             "card" => written.card,
             "workerContext" => rich_context(written.card["id"], nil, [@comment_body])
           }

    assert read.lists == %{"cards" => [rich_summary(written.card)]}
    assert read.item.record.provenance == @creator

    assert Enum.sort(Enum.map(read.events, & &1.record.provenance)) ==
             Enum.sort([@creator, @commenter])
  end

  test "explicit board slugs preserve original locale ordering across punctuation and digits",
       %{context: context} do
    # Literal order observed through unchanged OpenClaw488631c factories in
    # source-board-order.json. This component lists only persisted explicit
    # boards; the reference's virtual default remains outside this contract.
    supplied = [
      "a2",
      "a.b",
      "a1",
      "a_0",
      "aa",
      "a-0",
      "a00",
      "a",
      "a10",
      "a_b",
      "a0",
      "a.0",
      "a01",
      "a-b"
    ]

    created =
      Map.new(supplied, fn id ->
        assert {:ok, %{"board" => board}} = execute(context, "board_create", %{"id" => id})

        assert board == %{
                 "id" => id,
                 "createdAt" => board["createdAt"],
                 "updatedAt" => board["createdAt"]
               }

        assert is_integer(board["createdAt"]) and board["createdAt"] > 0
        {id, board}
      end)

    assert {:ok, %{"boards" => boards}} = execute(context, "boards", %{})

    assert Enum.map(boards, & &1["id"]) == [
             "a",
             "a_0",
             "a_b",
             "a-0",
             "a-b",
             "a.0",
             "a.b",
             "a0",
             "a00",
             "a01",
             "a1",
             "a10",
             "a2",
             "aa"
           ]

    Enum.each(boards, fn board ->
      id = board["id"]

      assert board == %{
               "id" => id,
               "updatedAt" => created[id]["updatedAt"],
               "total" => 0,
               "active" => 0,
               "archived" => 0,
               "byStatus" => %{}
             }
    end)
  end

  defp execute(context, action, args) do
    apply(Synapsis.Workboard, :execute, [action, args, context, deadline()])
  end

  defp create_board(context, id, name, description) do
    assert {:ok, %{"board" => board}} =
             execute(context, "board_create", %{
               "id" => id,
               "name" => name,
               "description" => description
             })

    board
  end

  defp create(context, args) do
    assert {:ok, %{"card" => card}} = execute(context, "create", args)
    uuid(card["id"])
    card
  end

  defp minimal_card(card) do
    [event] = card["events"]
    uuid(event["id"])

    %{
      "id" => card["id"],
      "title" => "Minimal 雪😀",
      "status" => "todo",
      "priority" => "normal",
      "labels" => [],
      "position" => 1000,
      "createdAt" => card["createdAt"],
      "updatedAt" => card["createdAt"],
      "events" => [
        %{
          "id" => event["id"],
          "kind" => "created",
          "at" => card["createdAt"],
          "toStatus" => "todo"
        }
      ],
      "metadata" => %{"automation" => %{"boardId" => "research"}}
    }
  end

  defp plain_summary(card) do
    %{
      "id" => card["id"],
      "title" => "Minimal 雪😀",
      "status" => "todo",
      "priority" => "normal",
      "boardId" => "research",
      "updatedAt" => card["updatedAt"]
    }
  end

  defp rich_summary(card) do
    %{
      "id" => card["id"],
      "title" => "Rich supplied item café 雪 😀",
      "status" => "todo",
      "priority" => "high",
      "agentId" => "fixture-agent",
      "tenant" => "fixture-tenant",
      "boardId" => "research",
      "updatedAt" => card["updatedAt"]
    }
  end

  defp assigned_summary(card) do
    %{
      "id" => card["id"],
      "title" => "Done ordinary item",
      "status" => "done",
      "priority" => "normal",
      "agentId" => "fixture-agent",
      "boardId" => "research",
      "updatedAt" => card["updatedAt"]
    }
  end

  defp rich_context(id, done, comments) do
    header =
      "# Workboard card #{id}\nTitle: Rich supplied item café 雪 😀\nStatus: todo\nPriority: high\nBoard: research\nAgent: fixture-agent\n\n## Notes\nAcceptance 雪😀\nKeep this inner newline."

    recent_comments =
      if comments == [],
        do: "",
        else: "\n\n## Recent comments\n" <> Enum.map_join(comments, "\n", &("- " <> &1))

    recent_done =
      if is_nil(done),
        do: "",
        else: "\n\n## Recent done work by fixture-agent\n- #{done["id"]} Done ordinary item: done"

    header <>
      recent_comments <>
      recent_done <>
      "\n\n## Automation\nTenant: fixture-tenant\nBoard: research\nSkills: inspect, review\nWorkspace: dir /supplied/workspace"
  end

  defp snapshot(context) do
    assert {:ok, point} = Store.snapshot(context.scope, deadline())
    point
  end

  defp events(point, id) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.events_page(point, id, [limit: 100], deadline())

    Enum.sort_by(rows, & &1.record.id)
  end

  defp projections(point, nil) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.items_page(point, [limit: 100], deadline())

    Enum.sort_by(rows, & &1.record.id)
  end

  defp projections(point, board_id) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.items_page(point, [board_id: board_id, limit: 100], deadline())

    Enum.sort_by(rows, & &1.record.id)
  end

  defp assert_atomic(point, board, item, event, card, public_summary) do
    revision = item.storage_revision
    assert board.storage_revision == revision
    assert event.storage_revision == revision
    assert event.record.item_id == item.record.id
    assert event.record.board_id == board.record.id
    [scope_projection] = Enum.filter(projections(point, nil), &(&1.record.id == item.record.id))

    [board_projection] =
      Enum.filter(projections(point, board.record.id), &(&1.record.id == item.record.id))

    assert scope_projection == board_projection
    assert scope_projection.storage_revision == revision
    assert scope_projection.record.board_id == board.record.id
    assert scope_projection.record.board_slug == "research"
    assert scope_projection.record.schema_version == 1

    assert scope_projection == %{
             record: %{
               schema_version: 1,
               id: card["id"],
               scope: item.record.scope,
               board_id: board.record.id,
               board_slug: "research",
               payload:
                 Map.merge(public_summary, %{
                   "position" => card["position"],
                   "createdAt" => card["createdAt"]
                 })
             },
             storage_revision: revision
           }
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
