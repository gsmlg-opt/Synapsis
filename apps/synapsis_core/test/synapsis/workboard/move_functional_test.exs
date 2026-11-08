defmodule Synapsis.Workboard.MoveFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workboard.Store

  @creator %{
    "sessionId" => "37600000-0000-4000-8000-000000000001",
    "agentId" => "37600000-0000-4000-8000-000000000002",
    "runId" => "fixture:workboard376:create",
    "incarnation" => 6,
    "invocationId" => "fixture:workboard376:invocation-create",
    "toolCallId" => "fixture:workboard376:call-create",
    "extra" => %{"ordinary" => [nil, true, 1.25, "café 雪 😀"]}
  }
  @commenter %{
    "sessionId" => "37600000-0000-4000-8000-000000000011",
    "agentId" => "37600000-0000-4000-8000-000000000012",
    "runId" => "fixture:workboard376:comment",
    "incarnation" => 7,
    "invocationId" => "fixture:workboard376:invocation-comment",
    "toolCallId" => "fixture:workboard376:call-comment"
  }
  @mover %{
    "sessionId" => "37600000-0000-4000-8000-000000000021",
    "agentId" => "37600000-0000-4000-8000-000000000022",
    "runId" => "fixture:workboard376:move",
    "incarnation" => 8,
    "invocationId" => "fixture:workboard376:invocation-move",
    "toolCallId" => "fixture:workboard376:call-move",
    "extra" => %{"supplied" => ["move 雪😀", false, nil]}
  }
  @rich_args %{
    "title" => " Rich moving item café 雪 😀 ",
    "notes" => " Acceptance 雪😀\nKeep this inner newline. ",
    "status" => "running",
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
  @comment_body "Reviewed ordinary evidence 雪😀.\nKeep the supplied body exactly."
  @create_key {"fixture-tenant", "research", "ordinary-repeat"}

  # Independent literals from OpenClaw488631c store-core.ts updateCard,
  # store-card-helpers.ts updateEvent/buildWorkerContext and number-runtime.
  # This tests the explicitly scoped internal source-domain move action.
  # The eventual model factory remains id/status/token, without position.
  # Caller provenance here is a fixture, not evidence of a native invocation.
  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{context: %{scope: "fixture:workboard376/雪/" <> Ecto.UUID.generate(), provenance: @creator}}
  end

  test "same-board status moves preserve rich facts and publish exact atomic history",
       %{context: context} do
    %{card: original, peer: peer, board: board} = rich_fixture(context, "todo")
    initial = facts(context, original["id"], peer["id"], @create_key)
    board_id = uuid(initial.board.record.id)

    assert initial.board.record == %{
             schema_version: 1,
             id: board_id,
             scope: context.scope,
             slug: "research",
             revision: 4,
             payload: board,
             provenance: @creator
           }

    assert initial.item.record == %{
             schema_version: 1,
             id: original["id"],
             scope: context.scope,
             board_id: board_id,
             board_slug: "research",
             revision: 2,
             payload: original,
             provenance: @creator
           }

    assert initial.key == {:ok, original["id"]}

    assert Enum.sort(Enum.map(initial.events, & &1.record.provenance)) ==
             Enum.sort([@creator, @commenter])

    # The destination already has a review card at position1000. Source move
    # retains1000; it does not append2000, reindex or change board membership.
    assert peer["status"] == "review"
    assert peer["position"] == 1000
    assert original["status"] == "todo"
    assert original["position"] == 1000
    refute Map.has_key?(original, "startedAt")

    transitions = [
      {"todo", "running", :moved, :absent, :new},
      {"running", "review", :moved, :absent, :retain},
      {"review", "done", :moved, :new, :retain},
      {"done", "todo", :moved, :absent, :retain},
      {"todo", "running", :moved, :absent, :retain},
      {"running", "done", :moved, :new, :retain},
      {"done", "done", :edited, :retain, :retain}
    ]

    {final, final_facts, completed_times} =
      Enum.reduce(transitions, {original, initial, []}, fn
        {from, status, kind, completion, start}, {previous, before, completed_times} ->
          assert previous["status"] == from
          move_context = %{context | provenance: @mover}

          assert {:ok, %{"card" => moved}} =
                   execute(move_context, "move", %{
                     "id" => " " <> original["id"] <> " ",
                     "status" => status
                   })

          expected = expected_move(previous, moved, from, status, 1000, kind, completion, start)
          assert moved == expected

          if start == :new,
            do: assert(moved["startedAt"] == moved["updatedAt"]),
            else: assert(moved["startedAt"] == previous["startedAt"])

          after_move = facts(context, original["id"], peer["id"], @create_key)
          assert_move_facts(context, before, after_move, expected, rich_summary(expected), kind)
          assert facts_at(before.point, original["id"], peer["id"], @create_key) == before

          assert {:ok, %{"card" => ^expected, "workerContext" => worker_context}} =
                   execute(context, "read", %{"id" => original["id"]})

          assert worker_context == rich_context(original["id"], status)
          assert {:ok, %{"boards" => [summary]}} = execute(context, "boards", %{})

          counts =
            if status == "review", do: %{"review" => 2}, else: %{status => 1, "review" => 1}

          assert summary == %{
                   "id" => "research",
                   "name" => "Research 雪😀",
                   "description" => "Ordinary board",
                   "updatedAt" =>
                     Enum.max([board["updatedAt"], peer["updatedAt"], expected["updatedAt"]]),
                   "total" => 2,
                   "active" => 2,
                   "archived" => 0,
                   "byStatus" => counts
                 }

          times =
            if completion == :new,
              do: completed_times ++ [moved["completedAt"]],
              else: completed_times

          {expected, after_move, times}
      end)

    [first_completed, second_completed] = completed_times
    assert second_completed > first_completed
    assert final["completedAt"] == second_completed
    assert final["startedAt"] == Enum.at(final["events"], 2)["at"]
    assert final_facts.item.record.revision == initial.item.record.revision + 7
    assert final_facts.board.record.revision == initial.board.record.revision + 7
    assert length(final_facts.events) == 9
    assert length(Enum.uniq(Enum.map(final["events"], & &1["id"]))) == 9
    assert facts_at(initial.point, original["id"], peer["id"], @create_key) == initial

    assert {:ok, %{"cards" => listed}} = execute(context, "list", %{"boardId" => "research"})
    assert listed == [peer_summary(peer), rich_summary(final)]

    assert {:ok, %{"cards" => [filtered]}} =
             execute(context, "list", %{
               "boardId" => "research",
               "status" => "done",
               "agentId" => "fixture-agent",
               "tenant" => "fixture-tenant"
             })

    assert filtered == rich_summary(final)

    # The original tuple still resolves the moved CURRENT card. It does not
    # recreate the running input, change provenance or publish any new fact.
    assert {:ok, %{"card" => ^final}} =
             execute(%{context | provenance: @mover}, "create", %{
               @rich_args
               | "title" => "Ignored replacement title"
             })

    assert_same_persisted_facts(
      facts(context, original["id"], peer["id"], @create_key),
      final_facts
    )
  end

  test "position-only domain moves floor clamp and retain source fallback with truthful edited events",
       %{context: context} do
    create_board(context)
    peer = plain_create(context, "First ordinary card", 1000)
    original = plain_create(context, "Second ordinary card", 2000)
    initial = facts(context, original["id"], peer["id"], nil)

    # Omitted status, null and blank status are source fallback, not trimming
    # into a new status. A supplied numeric string is not number coercion.
    vectors = [
      {%{"position" => 750.9}, 750, :moved},
      {%{"status" => nil, "position" => -2.7}, 0, :moved},
      {%{"status" => " \t", "position" => "125"}, 0, :edited},
      {%{"position" => 0.9}, 0, :edited},
      {%{}, 0, :edited}
    ]

    {final, final_facts} =
      Enum.reduce(vectors, {original, initial}, fn {args, position, kind}, {previous, before} ->
        assert {:ok, %{"card" => moved}} =
                 execute(
                   %{context | provenance: @mover},
                   "move",
                   Map.put(args, "id", original["id"])
                 )

        expected = expected_move(previous, moved, "todo", "todo", position, kind, :absent)
        assert moved == expected
        after_move = facts(context, original["id"], peer["id"], nil)
        assert_move_facts(context, before, after_move, expected, plain_summary(expected), kind)
        assert facts_at(before.point, original["id"], peer["id"], nil) == before
        assert {:ok, %{"cards" => listed}} = execute(context, "list", %{"boardId" => "research"})
        assert listed == [plain_summary(expected), plain_summary(peer)]

        assert {:ok, %{"card" => ^expected, "workerContext" => worker_context}} =
                 execute(context, "read", %{"id" => original["id"]})

        assert worker_context ==
                 "# Workboard card #{original["id"]}\nTitle: Second ordinary card\nStatus: todo\nPriority: normal\nBoard: research\nAgent: (default)\n\n## Automation\nBoard: research"

        {expected, after_move}
      end)

    assert final["position"] == 0
    assert final_facts.item.record.revision == 6
    assert length(final_facts.events) == 6
    assert facts_at(initial.point, original["id"], peer["id"], nil) == initial
    assert {:ok, %{"boards" => [board]}} = execute(context, "boards", %{})

    assert board == %{
             "id" => "research",
             "name" => "Research 雪😀",
             "description" => "Ordinary board",
             "updatedAt" => max(final["updatedAt"], peer["updatedAt"]),
             "total" => 2,
             "active" => 2,
             "archived" => 0,
             "byStatus" => %{"todo" => 2}
           }
  end

  test "normal creator exit and fresh reader retain moved payload context and both directories",
       %{context: context} do
    creator =
      Task.async(fn ->
        %{card: original, peer: peer} = rich_fixture(context)
        before = facts(context, original["id"], peer["id"], @create_key)

        assert {:ok, %{"card" => moved}} =
                 execute(%{context | provenance: @mover}, "move", %{
                   "id" => original["id"],
                   "status" => "done"
                 })

        expected = expected_move(original, moved, "running", "done", 1000, :moved, :new)
        assert moved == expected
        written = facts(context, original["id"], peer["id"], @create_key)
        assert_move_facts(context, before, written, expected, rich_summary(expected), :moved)
        %{card: expected, peer: peer, read: read_views(context, original["id"], peer["id"])}
      end)

    written = Task.await(creator, 30_000)
    refute Process.alive?(creator.pid)
    reader = Task.async(fn -> read_views(context, written.card["id"], written.peer["id"]) end)
    read = Task.await(reader, 30_000)
    refute Process.alive?(reader.pid)
    assert reader.pid != creator.pid
    assert read == written.read

    assert read.readback == %{
             "card" => written.card,
             "workerContext" => rich_context(written.card["id"], "done")
           }

    assert read.lists == %{"cards" => [peer_summary(written.peer), rich_summary(written.card)]}
    assert read.facts.item.record.provenance == @creator

    assert Enum.sort(Enum.map(read.facts.events, & &1.record.provenance)) ==
             Enum.sort([@creator, @commenter, @mover])
  end

  defp rich_fixture(context, status \\ "running") do
    board = create_board(context)

    assert {:ok, %{"card" => peer}} =
             execute(context, "create", %{
               "title" => "Destination review card",
               "boardId" => "research",
               "status" => "review"
             })

    assert peer == plain_expected(peer, "Destination review card", "review", 1000)

    assert {:ok, %{"card" => created}} =
             execute(context, "create", Map.put(@rich_args, "status", status))

    [event] = created["events"]
    id = uuid(created["id"])
    at = created["createdAt"]
    assert is_integer(at) and at > 0

    expected_created = %{
      "id" => id,
      "title" => "Rich moving item café 雪 😀",
      "notes" => "Acceptance 雪😀\nKeep this inner newline.",
      "status" => status,
      "priority" => "high",
      "labels" => ["review", "雪😀"],
      "agentId" => "fixture-agent",
      "position" => 1000,
      "createdAt" => at,
      "updatedAt" => at,
      "events" => [
        %{"id" => uuid(event["id"]), "kind" => "created", "at" => at, "toStatus" => status}
      ],
      "metadata" => %{"automation" => @automation}
    }

    expected_created =
      if status == "running",
        do: Map.put(expected_created, "startedAt", at),
        else: expected_created

    assert created == expected_created

    assert {:ok, %{"card" => commented}} =
             execute(%{context | provenance: @commenter}, "comment", %{
               "id" => id,
               "body" => " " <> @comment_body <> " "
             })

    [comment] = commented["metadata"]["comments"]
    comment_event = List.last(commented["events"])

    assert comment == %{
             "id" => uuid(comment["id"]),
             "body" => @comment_body,
             "createdAt" => comment["createdAt"]
           }

    assert is_integer(comment["createdAt"]) and comment["createdAt"] >= at
    assert commented["updatedAt"] > at
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

    %{card: commented, peer: peer, board: board}
  end

  defp expected_move(previous, actual, from, status, position, kind, completion, start \\ :retain) do
    now = actual["updatedAt"]
    assert is_integer(now) and now > previous["updatedAt"]
    event = List.last(actual["events"])
    id = uuid(event["id"])
    refute id in Enum.map(previous["events"], & &1["id"])

    literal =
      case kind do
        :moved ->
          %{
            "id" => id,
            "kind" => "moved",
            "at" => now,
            "fromStatus" => from,
            "toStatus" => status
          }

        :edited ->
          %{"id" => id, "kind" => "edited", "at" => now}
      end

    assert event == literal

    expected =
      Map.merge(previous, %{
        "status" => status,
        "position" => position,
        "updatedAt" => now,
        "events" => previous["events"] ++ [literal]
      })

    expected = if start == :new, do: Map.put(expected, "startedAt", now), else: expected

    case completion do
      :absent -> Map.delete(expected, "completedAt")
      :new -> Map.put(expected, "completedAt", now)
      :retain -> expected
    end
  end

  defp assert_move_facts(context, before, after_move, card, summary, kind) do
    assert after_move.item.record == %{
             before.item.record
             | revision: before.item.record.revision + 1,
               payload: card
           }

    assert after_move.board.record == %{
             before.board.record
             | revision: before.board.record.revision + 1
           }

    assert after_move.item.record.provenance == @creator
    assert after_move.board.record.provenance == @creator
    assert after_move.peer == before.peer
    assert after_move.peer_events == before.peer_events
    assert after_move.key == before.key
    revision = after_move.item.storage_revision
    assert revision > before.item.storage_revision
    assert after_move.board.storage_revision == revision
    new_id = List.last(card["events"])["id"]
    [new_event] = Enum.filter(after_move.events, &(&1.record.id == new_id))
    assert Enum.reject(after_move.events, &(&1.record.id == new_id)) == before.events

    assert new_event == %{
             record: %{
               schema_version: 1,
               id: new_id,
               scope: context.scope,
               item_id: card["id"],
               board_id: before.board.record.id,
               kind: kind,
               payload: List.last(card["events"]),
               provenance: @mover
             },
             storage_revision: revision
           }

    expected_projection = %{
      record: %{
        schema_version: 1,
        id: card["id"],
        scope: context.scope,
        board_id: before.board.record.id,
        board_slug: "research",
        payload:
          Map.merge(summary, %{"position" => card["position"], "createdAt" => card["createdAt"]})
      },
      storage_revision: revision
    }

    for directory <- [:scope_rows, :board_rows] do
      assert Enum.filter(after_move[directory], &(&1.record.id == card["id"])) == [
               expected_projection
             ]

      assert Enum.reject(after_move[directory], &(&1.record.id == card["id"])) ==
               Enum.reject(before[directory], &(&1.record.id == card["id"]))
    end

    assert after_move.board_rows == after_move.scope_rows
    assert after_move.board_page == [after_move.board]
  end

  defp assert_same_persisted_facts(current, previous),
    do: assert(Map.delete(current, :point) == Map.delete(previous, :point))

  defp facts(context, id, peer_id, key), do: facts_at(snapshot(context), id, peer_id, key)

  defp facts_at(point, id, peer_id, key) do
    assert {:ok, item} = Store.get_item(point, id, deadline())
    assert {:ok, peer} = Store.get_item(point, peer_id, deadline())
    assert {:ok, board} = Store.get_board(point, "research", deadline())

    assert {:ok, %{rows: board_page, next_cursor: nil}} =
             Store.boards_page(point, [limit: 100], deadline())

    %{
      point: point,
      item: item,
      peer: peer,
      board: board,
      board_page: board_page,
      scope_rows: projections(point, nil),
      board_rows: projections(point, board.record.id),
      events: events(point, id),
      peer_events: events(point, peer_id),
      key: if(is_nil(key), do: nil, else: Store.lookup_create_key(point, key, deadline()))
    }
  end

  defp read_views(context, id, peer_id) do
    assert {:ok, readback} = execute(context, "read", %{"id" => id})
    assert {:ok, lists} = execute(context, "list", %{"boardId" => "research"})
    assert {:ok, boards} = execute(context, "boards", %{})

    %{
      readback: readback,
      lists: lists,
      boards: boards,
      facts: Map.delete(facts(context, id, peer_id, @create_key), :point)
    }
  end

  defp create_board(context) do
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

    board
  end

  defp plain_create(context, title, position) do
    assert {:ok, %{"card" => card}} =
             execute(context, "create", %{"title" => title, "boardId" => "research"})

    assert card == plain_expected(card, title, "todo", position)
    card
  end

  defp plain_expected(card, title, status, position) do
    [event] = card["events"]
    at = card["createdAt"]
    assert is_integer(at) and at > 0

    %{
      "id" => uuid(card["id"]),
      "title" => title,
      "status" => status,
      "priority" => "normal",
      "labels" => [],
      "position" => position,
      "createdAt" => at,
      "updatedAt" => at,
      "events" => [
        %{"id" => uuid(event["id"]), "kind" => "created", "at" => at, "toStatus" => status}
      ],
      "metadata" => %{"automation" => %{"boardId" => "research"}}
    }
  end

  defp rich_summary(card),
    do: %{
      "id" => card["id"],
      "title" => "Rich moving item café 雪 😀",
      "status" => card["status"],
      "priority" => "high",
      "agentId" => "fixture-agent",
      "tenant" => "fixture-tenant",
      "boardId" => "research",
      "updatedAt" => card["updatedAt"]
    }

  defp peer_summary(card),
    do: %{
      "id" => card["id"],
      "title" => "Destination review card",
      "status" => "review",
      "priority" => "normal",
      "boardId" => "research",
      "updatedAt" => card["updatedAt"]
    }

  defp plain_summary(card),
    do: %{
      "id" => card["id"],
      "title" => card["title"],
      "status" => "todo",
      "priority" => "normal",
      "boardId" => "research",
      "updatedAt" => card["updatedAt"]
    }

  defp rich_context(id, status) do
    "# Workboard card #{id}\nTitle: Rich moving item café 雪 😀\nStatus: #{status}\nPriority: high\nBoard: research\nAgent: fixture-agent\n\n## Notes\nAcceptance 雪😀\nKeep this inner newline." <>
      "\n\n## Recent comments\n- " <>
      @comment_body <>
      "\n\n## Automation\nTenant: fixture-tenant\nBoard: research\nSkills: inspect, review\nWorkspace: dir /supplied/workspace" <>
      if(status == "done",
        do: "\n\n## Active diagnostics\n- warning: Done card has no proof",
        else: ""
      )
  end

  defp execute(context, action, args),
    do: apply(Synapsis.Workboard, :execute, [action, args, context, deadline()])

  defp snapshot(context) do
    assert {:ok, point} = Store.snapshot(context.scope, deadline())
    point
  end

  defp events(point, id) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.events_page(point, id, [limit: 100], deadline())

    Enum.sort_by(rows, & &1.record.id)
  end

  defp projections(point, board_id) do
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
