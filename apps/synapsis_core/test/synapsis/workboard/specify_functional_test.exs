defmodule Synapsis.Workboard.CoreSpecifyFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workboard.Store

  @creator %{
    "sessionId" => "37800000-0000-4000-8000-000000000001",
    "agentId" => "37800000-0000-4000-8000-000000000002",
    "runId" => "fixture:workboard378:create",
    "incarnation" => 8,
    "invocationId" => "fixture:workboard378:invoke-create",
    "toolCallId" => "fixture:workboard378:call-create",
    "extra" => %{"ordinary" => [nil, true, 1.25, "雪😀"]}
  }
  @specifier %{
    "sessionId" => "37800000-0000-4000-8000-000000000011",
    "agentId" => "37800000-0000-4000-8000-000000000012",
    "runId" => "fixture:workboard378:specify",
    "incarnation" => 9,
    "invocationId" => "fixture:workboard378:invoke-specify",
    "toolCallId" => "fixture:workboard378:call-specify"
  }
  @commenter %{
    "sessionId" => "37800000-0000-4000-8000-000000000021",
    "agentId" => "37800000-0000-4000-8000-000000000022",
    "runId" => "fixture:workboard378:comment",
    "incarnation" => 10,
    "invocationId" => "fixture:workboard378:invoke-comment",
    "toolCallId" => "fixture:workboard378:call-comment"
  }
  @body "Prior ordinary comment 雪😀.\nKeep this line."
  @summary "Clarified acceptance 雪😀.\nKeep this summary line."
  @rich_fields %{
    "title" => "Rich rough item café 雪😀",
    "notes" => "Original acceptance 雪😀",
    "priority" => "high",
    "labels" => ["rough", "雪😀"],
    "agentId" => "agent-old"
  }
  @rich_hints %{
    "skills" => ["inspect", "review"],
    "workspace" => %{"kind" => "worktree", "path" => "/supplied/original", "branch" => "main"},
    "maxRuntimeSeconds" => 120,
    "maxRetries" => 2
  }

  # Expectations are independent literals from OpenClaw488631c specify,
  # updateCard, normalizeAutomation/Workspace and the actual SQLite list order.
  # The internal API follows the original factory fields except token; status
  # and position remain move-domain inputs. No batch378 product was inspected.
  # Fixture provenance never claims a native/model invocation.
  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{context: %{scope: "fixture:workboard378/雪/" <> Ecto.UUID.generate(), provenance: @creator}}
  end

  test "full factory fields and partial clarifications retain source clocks and compose with comment move and read",
       %{context: context} do
    create_board(context, "research", "Research")

    original =
      rich_create(context, "triage", "research", "tenant-old", "rich-key")
      |> add_comment(context, @body)

    before = snapshot(context)

    patch = %{
      "id" => " " <> original["id"] <> " ",
      "title" => " Clarified café 雪😀 ",
      "notes" => " New acceptance\nKeep the inner newline. ",
      "agentId" => " agent-new ",
      "priority" => "urgent",
      "labels" => [" ready ", "ready", "雪😀"],
      "boardId" => " RESEARCH ",
      "tenant" => " tenant-new ",
      "skills" => [" implement ", "review", "implement"],
      "workspace" => %{
        "kind" => "worktree",
        "path" => " /supplied/revised ",
        "branch" => " topic "
      },
      "maxRuntimeSeconds" => 3.9,
      "maxRetries" => 0,
      "summary" => " " <> @summary <> " "
    }

    assert {:ok, %{"card" => actual}} = execute(specifier(context), "specify", patch)

    clarified =
      expected_specify(
        original,
        actual,
        %{
          "title" => "Clarified café 雪😀",
          "notes" => "New acceptance\nKeep the inner newline.",
          "agentId" => "agent-new",
          "priority" => "urgent",
          "labels" => ["ready", "雪😀"]
        },
        %{
          "tenant" => "tenant-new",
          "skills" => ["implement", "review"],
          "workspace" => %{
            "kind" => "worktree",
            "path" => "/supplied/revised",
            "branch" => "topic"
          },
          "maxRuntimeSeconds" => 3,
          "maxRetries" => 1
        },
        @summary
      )

    assert actual == clarified

    assert_specify_facts(
      context,
      before,
      snapshot(context),
      original,
      clarified,
      "research",
      "research"
    )

    assert_read(context, clarified)

    # Unchanged todo specification still emits specified. Blank summary retains
    # the previous automation summary and appends no additional comment.
    {repeated, _} =
      Enum.reduce([%{}, %{"summary" => " \t "}], {clarified, nil}, fn supplied, {previous, _} ->
        point = snapshot(context)

        assert {:ok, %{"card" => repeated}} =
                 execute(specifier(context), "specify", Map.put(supplied, "id", original["id"]))

        expected = expected_specify(previous, repeated, %{}, %{}, nil)
        assert repeated == expected

        assert_specify_facts(
          context,
          point,
          snapshot(context),
          previous,
          expected,
          "research",
          "research"
        )

        assert_read(context, expected)
        {expected, point}
      end)

    assert repeated["metadata"]["comments"] == clarified["metadata"]["comments"]

    # Source workspace merges the same path and retains branch, then drops the
    # omitted old branch when the path changes. Numeric0 becomes1, not absence.
    workspace_vectors = [
      {%{"kind" => "worktree"},
       %{"kind" => "worktree", "path" => "/supplied/revised", "branch" => "topic"}},
      {%{"kind" => "worktree", "path" => "/supplied/final"},
       %{"kind" => "worktree", "path" => "/supplied/final"}}
    ]

    merged =
      Enum.reduce(workspace_vectors, repeated, fn {workspace, expected_workspace}, previous ->
        point = snapshot(context)

        assert {:ok, %{"card" => current}} =
                 execute(specifier(context), "specify", %{
                   "id" => original["id"],
                   "workspace" => workspace
                 })

        expected =
          expected_specify(previous, current, %{}, %{"workspace" => expected_workspace}, nil)

        assert current == expected

        assert_specify_facts(
          context,
          point,
          snapshot(context),
          previous,
          expected,
          "research",
          "research"
        )

        expected
      end)

    point = snapshot(context)

    assert {:ok, %{"card" => cleared_actual}} =
             execute(specifier(context), "specify", %{
               "id" => original["id"],
               "notes" => " ",
               "agentId" => "\t",
               "labels" => [],
               "skills" => [],
               "priority" => " ",
               "tenant" => " ",
               "boardId" => " ",
               "maxRuntimeSeconds" => 0
             })

    cleared =
      expected_specify(
        merged,
        cleared_actual,
        %{"notes" => :remove, "agentId" => :remove, "labels" => []},
        %{"skills" => :remove, "maxRuntimeSeconds" => 1},
        nil
      )

    assert cleared_actual == cleared

    assert_specify_facts(
      context,
      point,
      snapshot(context),
      merged,
      cleared,
      "research",
      "research"
    )

    assert_read(context, cleared)
    commented = add_comment(cleared, context, "After specification 雪😀")
    running = move(context, commented, "running", commented["position"])
    returned = move(context, running, "todo", running["position"])
    assert returned["startedAt"] == running["updatedAt"]
    point = snapshot(context)

    assert {:ok, %{"card" => retained_actual}} =
             execute(specifier(context), "specify", %{"id" => original["id"]})

    retained = expected_specify(returned, retained_actual, %{}, %{}, nil)
    assert retained_actual == retained
    assert retained["startedAt"] == running["updatedAt"]

    assert_specify_facts(
      context,
      point,
      snapshot(context),
      returned,
      retained,
      "research",
      "research"
    )

    assert_read(context, retained)
    assert get_item(before, original["id"]).record.payload == original
  end

  test "cross-board and tenant specification atomically moves current membership and releases the former create tuple",
       %{context: context} do
    research = create_board(context, "research", "Research")
    delivery = create_board(context, "delivery", "Delivery")

    original =
      rich_create(context, "backlog", "research", "tenant-old", "ordinary-key")
      |> add_comment(context, @body)

    peer = plain_create(context, "Delivery peer", "delivery", "todo", "tenant-peer", nil)
    before = snapshot(context)
    old_key = {"tenant-old", "research", "ordinary-key"}
    new_key = {"tenant-new", "delivery", "ordinary-key"}
    assert candidate_ids(before, old_key) == [original["id"]]
    assert Store.lookup_create_key_candidates(before, new_key, deadline()) == :not_found

    assert {:ok, %{"card" => actual}} =
             execute(specifier(context), "specify", %{
               "id" => original["id"],
               "boardId" => " DELIVERY ",
               "tenant" => " tenant-new ",
               "summary" => "Clarified for delivery"
             })

    specified =
      expected_specify(
        original,
        actual,
        %{},
        %{"boardId" => "delivery", "tenant" => "tenant-new"},
        "Clarified for delivery"
      )

    assert actual == specified
    assert specified["position"] == original["position"]
    current = snapshot(context)
    assert_specify_facts(context, before, current, original, specified, "research", "delivery")
    assert Store.lookup_create_key_candidates(current, old_key, deadline()) == :not_found
    assert candidate_ids(current, new_key) == [original["id"]]
    assert get_item(current, peer["id"]) == get_item(before, peer["id"])
    assert projections(current, get_board(current, "research").record.id) == []
    assert get_board(current, "research").record.payload == research
    assert get_board(current, "delivery").record.payload == delivery
    assert_read(context, specified)
    assert {:ok, %{"cards" => []}} = execute(context, "list", %{"boardId" => "research"})

    assert {:ok, %{"cards" => listed}} =
             execute(context, "list", %{"boardId" => "delivery", "tenant" => "tenant-new"})

    assert listed == [summary(specified)]
    assert {:ok, %{"boards" => board_summaries}} = execute(context, "boards", %{})

    assert board_summaries == [
             board_summary(delivery, [specified, peer]),
             board_summary(research, [])
           ]

    assert {:ok, %{"card" => ^specified}} =
             execute(
               context,
               "create",
               rich_args("todo", "delivery", "tenant-new", "ordinary-key")
             )

    assert stable_rows(snapshot(context), original["id"], ["research", "delivery"], [
             old_key,
             new_key
           ]) ==
             stable_rows(current, original["id"], ["research", "delivery"], [old_key, new_key])

    assert {:ok, %{"card" => recreated}} =
             execute(
               context,
               "create",
               rich_args("backlog", "research", "tenant-old", "ordinary-key")
             )

    refute recreated["id"] == original["id"]

    assert recreated ==
             expected_created(
               recreated,
               @rich_fields,
               "backlog",
               "research",
               "tenant-old",
               "ordinary-key",
               1000,
               @rich_hints
             )

    final = snapshot(context)
    assert candidate_ids(final, old_key) == [recreated["id"]]
    assert candidate_ids(final, new_key) == [original["id"]]
    assert get_item(final, original["id"]) == get_item(current, original["id"])
    assert candidate_ids(before, old_key) == [original["id"]]
    assert Store.lookup_create_key_candidates(before, new_key, deadline()) == :not_found
    assert get_item(before, original["id"]).record.payload == original
  end

  test "duplicate current tuples retain both cards and source create winner follows live status position time and SQLite UUID ties",
       %{context: context} do
    create_board(context, "research", "Research")
    create_board(context, "delivery", "Delivery")
    # Explicit valid Core-shaped persistence fixtures make exact creation-time
    # ties deterministic. They do not claim these times came from Core create.
    # A is inserted first but has the larger UUID; actual SQLite exact ties
    # prefer B. All specify/move/create operations below use the public Core.
    at = System.system_time(:millisecond)

    a =
      seed_card(
        context,
        "37800000-0000-4000-8000-000000000202",
        "Earlier inserted A",
        "backlog",
        "research",
        "tenant-old",
        "shared-key",
        2000,
        at
      )

    b =
      seed_card(
        context,
        "37800000-0000-4000-8000-000000000201",
        "Later inserted B",
        "todo",
        "delivery",
        "tenant-new",
        "shared-key",
        1000,
        at
      )

    before = snapshot(context)

    assert {:ok, %{"card" => actual}} =
             execute(specifier(context), "specify", %{
               "id" => a["id"],
               "boardId" => "delivery",
               "tenant" => "tenant-new"
             })

    a1 =
      expected_specify(a, actual, %{}, %{"boardId" => "delivery", "tenant" => "tenant-new"}, nil)

    assert actual == a1
    assert_specify_facts(context, before, snapshot(context), a, a1, "research", "delivery")
    key = {"tenant-new", "delivery", "shared-key"}
    collision_point = snapshot(context)
    assert candidate_ids(collision_point, key) == [b["id"], a["id"]]
    assert Store.lookup_create_key(collision_point, key, deadline()) == {:ok, b["id"]}
    assert_create_winner(context, key, b)
    a2 = move(context, a1, "todo", 500)
    assert_create_winner(context, key, a2)
    a3 = move(context, a2, "review", 500)
    assert_create_winner(context, key, b)
    a4 = move(context, a3, "todo", 500)
    assert_create_winner(context, key, a4)
    a5 = move(context, a4, "todo", 1000)
    assert a5["createdAt"] == b["createdAt"]
    assert a5["position"] == b["position"]
    assert a5["id"] > b["id"]
    assert_create_winner(context, key, b)
    # Creation time precedes UUID only after status and position are equal.
    # This ordinary third candidate is older but has the largest UUID.
    c =
      seed_card(
        context,
        "37800000-0000-4000-8000-000000000203",
        "Older timestamp C",
        "backlog",
        "research",
        "tenant-third",
        "shared-key",
        1000,
        at - 1000
      )

    before_c = snapshot(context)

    assert {:ok, %{"card" => c_actual}} =
             execute(specifier(context), "specify", %{
               "id" => c["id"],
               "boardId" => "delivery",
               "tenant" => "tenant-new"
             })

    c1 =
      expected_specify(
        c,
        c_actual,
        %{},
        %{"boardId" => "delivery", "tenant" => "tenant-new"},
        nil
      )

    assert c_actual == c1
    assert_specify_facts(context, before_c, snapshot(context), c, c1, "research", "delivery")
    assert c1["createdAt"] < b["createdAt"]
    assert c1["id"] > a5["id"]
    assert_create_winner(context, key, c1)
    final = snapshot(context)
    assert candidate_ids(final, key) == [b["id"], a["id"], c["id"]]
    assert get_item(final, b["id"]) == get_item(collision_point, b["id"])
    assert get_item(final, a["id"]).record.payload == a5
    assert get_item(collision_point, a["id"]).record.payload == a1
    assert candidate_ids(before, {"tenant-old", "research", "shared-key"}) == [a["id"]]
    assert candidate_ids(before, key) == [b["id"]]
  end

  test "explicit absent namespace is virtual only while occupied then materializes later and survives normal creator exit",
       %{context: context} do
    creator =
      Task.async(fn ->
        research = create_board(context, "research", "Research")

        original =
          rich_create(context, "backlog", "research", "tenant-old", "virtual-key")
          |> add_comment(context, @body)

        before = snapshot(context)
        assert Store.get_board(before, "future", deadline()) == :not_found

        assert {:ok, %{"card" => first_actual}} =
                 execute(specifier(context), "specify", %{
                   "id" => original["id"],
                   "boardId" => "future",
                   "summary" => "Virtual ordinary summary"
                 })

        first =
          expected_specify(
            original,
            first_actual,
            %{},
            %{"boardId" => "future"},
            "Virtual ordinary summary"
          )

        assert first_actual == first
        occupied = snapshot(context)
        assert_specify_facts(context, before, occupied, original, first, "research", "future")
        namespace = get_board(occupied, "future")
        assert namespace.record.payload == %{"id" => "future"}
        assert {:ok, %{"boards" => occupied_boards}} = execute(context, "boards", %{})

        assert occupied_boards == [
                 board_summary(%{"id" => "future"}, [first]),
                 board_summary(research, [])
               ]

        returned = specify_namespace(context, first, "research")
        empty_point = snapshot(context)
        assert get_board(empty_point, "future").record.payload == %{"id" => "future"}
        assert {:ok, %{"boards" => empty_boards}} = execute(context, "boards", %{})
        assert empty_boards == [board_summary(research, [returned])]

        assert {:ok, %{"board" => materialized}} =
                 execute(context, "board_create", %{
                   "id" => "future",
                   "name" => "Future named later"
                 })

        time = materialized["createdAt"]
        assert is_integer(time) and time > 0

        assert materialized == %{
                 "id" => "future",
                 "name" => "Future named later",
                 "createdAt" => time,
                 "updatedAt" => time
               }

        assert get_board(occupied, "future") == namespace
        assert get_board(empty_point, "future").record.payload == %{"id" => "future"}

        archived_card = specify_namespace(context, returned, "archive-future")
        archive_occupied = snapshot(context)

        assert get_board(archive_occupied, "archive-future").record.payload == %{
                 "id" => "archive-future"
               }

        final_card = specify_namespace(context, archived_card, "research")
        archive_empty = snapshot(context)
        assert {:ok, %{"boards" => before_archive_boards}} = execute(context, "boards", %{})

        assert before_archive_boards == [
                 board_summary(materialized, []),
                 board_summary(research, [final_card])
               ]

        assert {:ok, %{"board" => archived_board}} =
                 execute(context, "board_archive", %{"id" => "archive-future"})

        archive_time = archived_board["createdAt"]
        assert is_integer(archive_time) and archive_time > 0

        assert archived_board == %{
                 "id" => "archive-future",
                 "createdAt" => archive_time,
                 "updatedAt" => archive_time,
                 "archivedAt" => archive_time
               }

        assert get_board(archive_empty, "archive-future").record.payload == %{
                 "id" => "archive-future"
               }

        assert {:ok, %{"boards" => final_boards}} = execute(context, "boards", %{})

        assert final_boards == [
                 board_summary(archived_board, []),
                 board_summary(materialized, []),
                 board_summary(research, [final_card])
               ]

        assert_read(context, final_card)

        %{
          card: final_card,
          views:
            read_views(context, final_card["id"], ["archive-future", "future", "research"], [
              {"tenant-old", "research", "virtual-key"},
              {"tenant-old", "future", "virtual-key"},
              {"tenant-old", "archive-future", "virtual-key"}
            ])
        }
      end)

    written = Task.await(creator, 30_000)
    refute Process.alive?(creator.pid)

    reader =
      Task.async(fn ->
        read_views(context, written.card["id"], ["archive-future", "future", "research"], [
          {"tenant-old", "research", "virtual-key"},
          {"tenant-old", "future", "virtual-key"},
          {"tenant-old", "archive-future", "virtual-key"}
        ])
      end)

    read = Task.await(reader, 30_000)
    refute Process.alive?(reader.pid)
    assert creator.pid != reader.pid
    assert read == written.views

    assert {:ok, %{"card" => card}} =
             execute(
               context,
               "create",
               rich_args("backlog", "research", "tenant-old", "virtual-key")
             )

    assert card == written.card

    assert read_views(context, card["id"], ["archive-future", "future", "research"], [
             {"tenant-old", "research", "virtual-key"},
             {"tenant-old", "future", "virtual-key"},
             {"tenant-old", "archive-future", "virtual-key"}
           ]) == read
  end

  defp expected_specify(previous, actual, fields, automation_fields, summary_body) do
    updated = actual["updatedAt"]
    assert is_integer(updated) and updated > previous["updatedAt"]
    event = List.last(actual["events"])
    event_id = uuid(event["id"])
    at = event["at"]
    assert is_integer(at) and at > 0 and at <= updated
    refute event_id in Enum.map(previous["events"], & &1["id"])
    assert event == %{"id" => event_id, "kind" => "specified", "at" => at}
    old_metadata = Map.get(previous, "metadata", %{})
    automation = changed(Map.get(old_metadata, "automation", %{}), automation_fields)
    comments = Map.get(old_metadata, "comments", [])

    {automation, comments} =
      if is_nil(summary_body) do
        {automation, comments}
      else
        comment = List.last(actual["metadata"]["comments"])
        comment_id = uuid(comment["id"])
        refute comment_id in Enum.map(comments, & &1["id"])
        assert comment_id != event_id
        expected_comment = %{"id" => comment_id, "body" => summary_body, "createdAt" => at}
        assert comment == expected_comment
        {Map.put(automation, "summary", summary_body), comments ++ [expected_comment]}
      end

    metadata = Map.put(old_metadata, "automation", automation)

    metadata =
      if comments == [],
        do: Map.delete(metadata, "comments"),
        else: Map.put(metadata, "comments", comments)

    previous
    |> changed(fields)
    |> Map.put("status", "todo")
    |> Map.put("updatedAt", updated)
    |> Map.put("events", previous["events"] ++ [event])
    |> Map.put("metadata", metadata)
    |> Map.delete("completedAt")
  end

  defp assert_specify_facts(
         context,
         before,
         after_point,
         previous,
         card,
         source_slug,
         target_slug
       ) do
    old_item = get_item(before, previous["id"])
    item = get_item(after_point, card["id"])
    source_before = get_board(before, source_slug)
    source_after = get_board(after_point, source_slug)
    target_after = get_board(after_point, target_slug)

    assert item.record == %{
             old_item.record
             | revision: old_item.record.revision + 1,
               board_id: target_after.record.id,
               board_slug: target_slug,
               payload: card
           }

    assert item.record.provenance == @creator
    revision = item.storage_revision
    assert revision > old_item.storage_revision

    assert source_after.record == %{
             source_before.record
             | revision: source_before.record.revision + 1
           }

    assert source_after.storage_revision == revision

    if source_slug != target_slug do
      case Store.get_board(before, target_slug, deadline()) do
        {:ok, target_before} ->
          assert target_after.record == %{
                   target_before.record
                   | revision: target_before.record.revision + 1
                 }

        :not_found ->
          assert target_after.record == %{
                   schema_version: 1,
                   id: uuid(target_after.record.id),
                   scope: context.scope,
                   slug: target_slug,
                   revision: 1,
                   payload: %{"id" => target_slug},
                   provenance: @specifier
                 }
      end

      assert target_after.storage_revision == revision

      assert Enum.reject(
               projections(after_point, source_before.record.id),
               &(&1.record.id == card["id"])
             ) ==
               Enum.reject(
                 projections(before, source_before.record.id),
                 &(&1.record.id == card["id"])
               )

      refute Enum.any?(
               projections(after_point, source_before.record.id),
               &(&1.record.id == card["id"])
             )
    end

    projection = %{
      record: %{
        schema_version: 1,
        id: card["id"],
        scope: context.scope,
        board_id: target_after.record.id,
        board_slug: target_slug,
        payload: Map.merge(summary(card), Map.take(card, ~w(position createdAt)))
      },
      storage_revision: revision
    }

    assert Enum.filter(projections(after_point, nil), &(&1.record.id == card["id"])) == [
             projection
           ]

    assert Enum.filter(
             projections(after_point, target_after.record.id),
             &(&1.record.id == card["id"])
           ) == [projection]

    assert Enum.reject(projections(after_point, nil), &(&1.record.id == card["id"])) ==
             Enum.reject(projections(before, nil), &(&1.record.id == card["id"]))

    public_event = List.last(card["events"])

    new_event = %{
      record: %{
        schema_version: 1,
        id: public_event["id"],
        scope: context.scope,
        item_id: card["id"],
        board_id: target_after.record.id,
        kind: :specified,
        payload: public_event,
        provenance: @specifier
      },
      storage_revision: revision
    }

    assert Enum.filter(events(after_point, card["id"]), &(&1.record.id == public_event["id"])) ==
             [new_event]

    assert Enum.reject(events(after_point, card["id"]), &(&1.record.id == public_event["id"])) ==
             events(before, card["id"])

    old_key = current_key(previous)
    new_key = current_key(card)
    old_ids = ids_or_empty(before, old_key)
    new_ids = ids_or_empty(before, new_key)

    if old_key == new_key do
      assert candidate_ids(after_point, new_key) == old_ids
    else
      remaining = List.delete(old_ids, card["id"])

      if remaining == [] do
        assert Store.lookup_create_key_candidates(after_point, old_key, deadline()) == :not_found
      else
        assert Store.lookup_create_key_candidates(after_point, old_key, deadline()) ==
                 {:ok, %{ids: remaining, storage_revision: revision}}
      end

      assert Store.lookup_create_key_candidates(after_point, new_key, deadline()) ==
               {:ok,
                %{ids: Enum.sort(Enum.uniq(new_ids ++ [card["id"]])), storage_revision: revision}}
    end

    assert get_item(before, card["id"]) == old_item
    assert get_board(before, source_slug) == source_before
  end

  defp specify_namespace(context, previous, slug) do
    point = snapshot(context)
    old_slug = previous["metadata"]["automation"]["boardId"]

    assert {:ok, %{"card" => actual}} =
             execute(specifier(context), "specify", %{"id" => previous["id"], "boardId" => slug})

    expected = expected_specify(previous, actual, %{}, %{"boardId" => slug}, nil)
    assert actual == expected
    assert_specify_facts(context, point, snapshot(context), previous, expected, old_slug, slug)
    expected
  end

  defp move(context, previous, status, position) do
    assert {:ok, %{"card" => actual}} =
             execute(specifier(context), "move", %{
               "id" => previous["id"],
               "status" => status,
               "position" => position
             })

    updated = actual["updatedAt"]
    assert is_integer(updated) and updated > previous["updatedAt"]
    event = List.last(actual["events"])

    expected_event =
      if previous["status"] == status and previous["position"] == position do
        %{"id" => uuid(event["id"]), "kind" => "edited", "at" => updated}
      else
        %{
          "id" => uuid(event["id"]),
          "kind" => "moved",
          "at" => updated,
          "fromStatus" => previous["status"],
          "toStatus" => status
        }
      end

    expected =
      Map.merge(previous, %{
        "status" => status,
        "position" => position,
        "updatedAt" => updated,
        "events" => previous["events"] ++ [expected_event]
      })

    expected =
      if status == "running",
        do: Map.put(expected, "startedAt", previous["startedAt"] || updated),
        else: expected

    assert actual == expected
    expected
  end

  defp assert_create_winner(context, {tenant, board, key}, expected) do
    before = snapshot(context)

    assert {:ok, %{"card" => ^expected}} =
             execute(context, "create", %{
               "title" => "Ignored duplicate request",
               "tenant" => tenant,
               "boardId" => board,
               "idempotencyKey" => key
             })

    assert stable_rows(snapshot(context), expected["id"], ["research", "delivery"], [
             {tenant, board, key}
           ]) ==
             stable_rows(before, expected["id"], ["research", "delivery"], [{tenant, board, key}])
  end

  defp seed_card(context, id, title, status, slug, tenant, key, position, at) do
    point = snapshot(context)
    board = get_board(point, slug).record
    event = %{"id" => Ecto.UUID.generate(), "kind" => "created", "at" => at, "toStatus" => status}

    card = %{
      "id" => id,
      "title" => title,
      "status" => status,
      "priority" => "normal",
      "labels" => [],
      "position" => position,
      "createdAt" => at,
      "updatedAt" => at,
      "events" => [event],
      "metadata" => %{
        "automation" => %{"boardId" => slug, "tenant" => tenant, "idempotencyKey" => key}
      }
    }

    item = %{
      schema_version: 1,
      id: id,
      scope: context.scope,
      board_id: board.id,
      board_slug: slug,
      revision: 1,
      payload: card,
      provenance: @creator
    }

    envelope_event = %{
      schema_version: 1,
      id: event["id"],
      scope: context.scope,
      item_id: id,
      board_id: board.id,
      kind: :created,
      payload: event,
      provenance: @creator
    }

    assert {:ok, ack} =
             Store.commit_item(
               point,
               %{
                 kind: :create,
                 board: %{board | revision: board.revision + 1},
                 item: item,
                 event: envelope_event,
                 projection:
                   Map.merge(summary(card), %{"position" => position, "createdAt" => at}),
                 create_key: {tenant, slug, key}
               },
               deadline()
             )

    assert ack.item == item
    assert ack.event == envelope_event

    assert get_item(snapshot(context), id) == %{
             record: item,
             storage_revision: ack.storage_revision
           }

    card
  end

  defp rich_args(status, slug, tenant, key),
    do:
      Map.merge(Map.merge(@rich_fields, @rich_hints), %{
        "status" => status,
        "boardId" => slug,
        "tenant" => tenant,
        "idempotencyKey" => key
      })

  defp rich_create(context, status, slug, tenant, key) do
    assert {:ok, %{"card" => card}} =
             execute(context, "create", rich_args(status, slug, tenant, key))

    assert card ==
             expected_created(card, @rich_fields, status, slug, tenant, key, 1000, @rich_hints)

    card
  end

  defp plain_create(context, title, slug, status, tenant, key) do
    fields = %{"title" => title, "priority" => "normal", "labels" => []}
    args = Map.merge(fields, %{"boardId" => slug, "status" => status, "tenant" => tenant})
    args = if key, do: Map.put(args, "idempotencyKey", key), else: args
    assert {:ok, %{"card" => card}} = execute(context, "create", args)
    assert card == expected_created(card, fields, status, slug, tenant, key, 1000, %{})
    card
  end

  defp expected_created(card, fields, status, slug, tenant, key, position, hints) do
    [event] = card["events"]
    at = card["createdAt"]
    assert is_integer(at) and at > 0
    automation = Map.merge(hints, %{"boardId" => slug, "tenant" => tenant})
    automation = if key, do: Map.put(automation, "idempotencyKey", key), else: automation

    Map.merge(fields, %{
      "id" => uuid(card["id"]),
      "status" => status,
      "position" => position,
      "createdAt" => at,
      "updatedAt" => at,
      "events" => [
        %{"id" => uuid(event["id"]), "kind" => "created", "at" => at, "toStatus" => status}
      ],
      "metadata" => %{"automation" => automation}
    })
  end

  defp add_comment(previous, context, body) do
    assert {:ok, %{"card" => actual}} =
             execute(%{context | provenance: @commenter}, "comment", %{
               "id" => previous["id"],
               "body" => body
             })

    comment = List.last(actual["metadata"]["comments"])
    event = List.last(actual["events"])

    assert comment == %{
             "id" => uuid(comment["id"]),
             "body" => body,
             "createdAt" => comment["createdAt"]
           }

    assert is_integer(comment["createdAt"]) and comment["createdAt"] > 0
    assert actual["updatedAt"] > previous["updatedAt"]
    assert actual["updatedAt"] >= comment["createdAt"]

    expected_event = %{
      "id" => uuid(event["id"]),
      "kind" => "comment_added",
      "at" => actual["updatedAt"]
    }

    metadata =
      Map.put(
        previous["metadata"],
        "comments",
        Map.get(previous["metadata"], "comments", []) ++ [comment]
      )

    expected = %{
      previous
      | "updatedAt" => actual["updatedAt"],
        "events" => previous["events"] ++ [expected_event],
        "metadata" => metadata
    }

    assert actual == expected
    expected
  end

  defp create_board(context, slug, name) do
    assert {:ok, %{"board" => board}} =
             execute(context, "board_create", %{"id" => slug, "name" => name})

    at = board["createdAt"]
    assert is_integer(at) and at > 0
    assert board == %{"id" => slug, "name" => name, "createdAt" => at, "updatedAt" => at}
    board
  end

  defp assert_read(context, card) do
    assert {:ok, %{"card" => ^card, "workerContext" => text}} =
             execute(context, "read", %{"id" => card["id"]})

    assert text == context_text(card)
  end

  defp context_text(card) do
    automation = card["metadata"]["automation"]

    text =
      "# Workboard card #{card["id"]}\nTitle: #{card["title"]}\nStatus: #{card["status"]}\nPriority: #{card["priority"]}\nBoard: #{automation["boardId"]}\nAgent: #{Map.get(card, "agentId", "(default)")}"

    text = if card["notes"], do: text <> "\n\n## Notes\n" <> card["notes"], else: text
    comments = Map.get(card["metadata"], "comments", [])

    text =
      if comments == [],
        do: text,
        else:
          text <>
            "\n\n## Recent comments\n" <> Enum.map_join(comments, "\n", &("- " <> &1["body"]))

    text =
      text <>
        "\n\n## Automation\nTenant: #{automation["tenant"]}\nBoard: #{automation["boardId"]}"

    text =
      if automation["skills"],
        do: text <> "\nSkills: " <> Enum.join(automation["skills"], ", "),
        else: text

    text =
      if automation["workspace"],
        do:
          text <>
            "\nWorkspace: #{automation["workspace"]["kind"]} #{automation["workspace"]["path"]}",
        else: text

    if automation["summary"], do: text <> "\nSummary: " <> automation["summary"], else: text
  end

  defp summary(card) do
    base = %{
      "id" => card["id"],
      "title" => card["title"],
      "status" => card["status"],
      "priority" => card["priority"],
      "boardId" => card["metadata"]["automation"]["boardId"],
      "updatedAt" => card["updatedAt"]
    }

    base = if card["agentId"], do: Map.put(base, "agentId", card["agentId"]), else: base
    tenant = card["metadata"]["automation"]["tenant"]
    if tenant, do: Map.put(base, "tenant", tenant), else: base
  end

  defp board_summary(board, cards) do
    statuses = Enum.frequencies_by(cards, & &1["status"])
    updated = Enum.reduce(cards, Map.get(board, "updatedAt", 0), &max(&1["updatedAt"], &2))

    Map.merge(Map.delete(board, "createdAt"), %{
      "total" => length(cards),
      "active" => length(cards),
      "archived" => 0,
      "byStatus" => statuses,
      "updatedAt" => updated
    })
  end

  defp changed(value, changes),
    do:
      Enum.reduce(changes, value, fn {key, field}, result ->
        if field == :remove, do: Map.delete(result, key), else: Map.put(result, key, field)
      end)

  defp specifier(context), do: %{context | provenance: @specifier}

  defp execute(context, action, args),
    do: apply(Synapsis.Workboard, :execute, [action, args, context, deadline()])

  defp snapshot(context) do
    assert {:ok, point} = Store.snapshot(context.scope, deadline())
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

  defp projections(point, board_id) do
    opts = if is_nil(board_id), do: [limit: 100], else: [board_id: board_id, limit: 100]
    assert {:ok, %{rows: rows, next_cursor: nil}} = Store.items_page(point, opts, deadline())
    Enum.sort_by(rows, & &1.record.id)
  end

  defp events(point, id) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.events_page(point, id, [limit: 100], deadline())

    Enum.sort_by(rows, & &1.record.id)
  end

  defp candidate_ids(point, tuple) do
    assert {:ok, %{ids: ids, storage_revision: revision}} =
             Store.lookup_create_key_candidates(point, tuple, deadline())

    assert ids == Enum.sort(Enum.uniq(ids))
    assert is_integer(revision) and revision > 0
    Enum.each(ids, &uuid/1)
    ids
  end

  defp ids_or_empty(point, tuple) do
    case Store.lookup_create_key_candidates(point, tuple, deadline()) do
      :not_found -> []
      {:ok, %{ids: ids}} -> ids
    end
  end

  defp current_key(card) do
    automation = card["metadata"]["automation"]
    {automation["tenant"], automation["boardId"], automation["idempotencyKey"]}
  end

  defp stable_rows(point, id, slugs, tuples) do
    %{
      item: get_item(point, id),
      events: events(point, id),
      scope_rows: projections(point, nil),
      boards: Map.new(slugs, &{&1, get_board(point, &1)}),
      board_rows: Map.new(slugs, &{&1, projections(point, get_board(point, &1).record.id)}),
      keys: Map.new(tuples, &{&1, Store.lookup_create_key_candidates(point, &1, deadline())})
    }
  end

  defp read_views(context, id, slugs, tuples) do
    assert {:ok, readback} = execute(context, "read", %{"id" => id})
    assert {:ok, lists} = execute(context, "list", %{})
    assert {:ok, boards} = execute(context, "boards", %{})

    %{
      readback: readback,
      lists: lists,
      boards: boards,
      facts: stable_rows(snapshot(context), id, slugs, tuples)
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
