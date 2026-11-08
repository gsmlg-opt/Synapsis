defmodule Synapsis.Workboard.CoreSchedulePromoteFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workboard.Store

  # Independent ordinary fixtures from unchanged OpenClaw 488631c. No batch384
  # product candidate was inspected. Caller provenance is fixture JSON, never
  # evidence of native/model activation. Stale/diagnostics below are explicit
  # legal Data seeds, not a diagnostic or timeout producer qualification.
  @creator %{
    "runId" => "fixture:384:create",
    "incarnation" => 41,
    "extra" => %{"json" => [nil, true, 1.5, "雪😀"]}
  }
  @linker %{
    "runId" => "fixture:384:link",
    "incarnation" => 42,
    "toolCallId" => "fixture:384:link-call"
  }
  @editor %{
    "runId" => "fixture:384:edit",
    "incarnation" => 43,
    "toolCallId" => "fixture:384:edit-call"
  }

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{context: %{scope: "fixture:384:schedule/雪/" <> Ecto.UUID.generate(), provenance: @creator}}
  end

  test "numeric schedule normalization precedes initial status clock and destination position", %{
    context: context
  } do
    board(context, "research")
    future = System.system_time(:millisecond) + 86_400_000

    first =
      create(context, "Future running", "running", %{"scheduledAt" => future + 0.75}, "scheduled")

    second = create(context, "Future done", "done", %{"scheduledAt" => future}, "scheduled")
    assert first["position"] == 1000
    assert second["position"] == 2000
    assert first["metadata"]["automation"]["scheduledAt"] == future
    refute Map.has_key?(first, "startedAt")
    refute Map.has_key?(second, "completedAt")
    due = create(context, "Due todo", "todo", %{"scheduledAt" => 1.75})
    assert due["metadata"]["automation"]["scheduledAt"] == 1
    zero = create(context, "Zero omitted", "todo", %{"scheduledAt" => 0})
    assert zero["metadata"]["automation"] == %{"boardId" => "research"}
    assert_read(context, first, context_text(first, ""))
    assert_read(context, second, context_text(second, ""))
  end

  test "ordinary link keeps future and undated schedules and promotes a due scheduled child", %{
    context: context
  } do
    board(context, "research")
    parent = create(context, "Done parent", "done")
    future = System.system_time(:millisecond) + 86_400_000

    future_child =
      create(context, "Future child", "todo", %{"scheduledAt" => future}, "scheduled")

    {parent1, future_linked} = link(context, parent, future_child, "scheduled")
    assert future_linked["metadata"]["automation"]["scheduledAt"] == future
    undated = create(context, "Undated child", "scheduled")
    {parent2, undated_linked} = link(context, parent1, undated, "scheduled")
    assert undated_linked["metadata"]["automation"] == %{"boardId" => "research"}
    due = create(context, "Due child", "scheduled", %{"scheduledAt" => 1})
    {_, ready} = link(context, parent2, due, "ready")
    assert ready["metadata"]["automation"]["scheduledAt"] == 1
    assert ready["position"] == due["position"]
    assert Enum.map(ready["events"], & &1["kind"]) == ["created", "link_added", "moved"]
  end

  test "due schedules reevaluate every parent and preserve schedule through normal ready move", %{
    context: context
  } do
    board(context, "research")
    incomplete = create(context, "Pending parent", "todo")
    complete = create(context, "Done parent", "done")
    child = create(context, "Due scheduled child", "scheduled", %{"scheduledAt" => 1})
    {incomplete1, todo} = link(context, incomplete, child, "todo")
    {complete1, todo2} = link(context, complete, todo, "todo")
    _done = move(context, incomplete1, "done")
    {_, ready} = link(context, complete1, todo2, "ready", true)
    assert ready["metadata"]["automation"]["scheduledAt"] == 1
    due = create(context, "Direct due move", "scheduled", %{"scheduledAt" => 1})
    before = snapshot(context)
    moved = move(context, due, "ready")
    assert_transition(context, before, due, moved, @editor)
    assert moved["metadata"] == due["metadata"]
  end

  test "ordinary promote without reason and with blank reason appends exactly one moved event", %{
    context: context
  } do
    board(context, "research")
    initial = create(context, "Promote ordinary", "todo", %{"idempotencyKey" => "plain-key"})
    first = promote(context, initial, %{}, nil)
    assert first["metadata"] == initial["metadata"]
    returned = move(context, first, "todo")
    second = promote(context, returned, %{"reason" => " \uFEFF\u00A0\t "}, nil)
    assert second["metadata"] == returned["metadata"]
    assert Enum.map(second["events"], & &1["kind"]) == ["created", "moved", "moved", "moved"]
    refute Map.has_key?(second["metadata"], "comments")
    refute Map.has_key?(second["metadata"], "stale")
  end

  test "due schedule survives comments proof attachments specify and reasoned promotion", %{
    context: context
  } do
    board(context, "research")

    initial =
      create(context, "Composed due", "todo", %{
        "scheduledAt" => 1,
        "idempotencyKey" => "rich-key"
      })

    assert {:ok, %{"card" => commented}} =
             execute(edit(context), "comment", %{
               "id" => initial["id"],
               "body" => "Earlier comment"
             })

    assert {:ok, %{"card" => proofed, "proofId" => proof_id}} =
             execute(edit(context), "proof", %{
               "id" => initial["id"],
               "status" => "passed",
               "label" => "Checked",
               "artifactPath" => "/supplied/result.log"
             })

    assert List.last(proofed["metadata"]["proof"])["id"] == proof_id

    assert {:ok, %{"card" => uploaded}} =
             execute(edit(context), "attachment_add", %{
               "id" => initial["id"],
               "fileName" => "receipt.txt",
               "contentBase64" => "6Zuq8J+YgAo="
             })

    [attachment] = uploaded["metadata"]["attachments"]
    assert {:ok, blob} = Store.get_attachment(snapshot(context), attachment["id"], deadline())

    assert {:ok, %{"card" => specified}} =
             execute(edit(context), "specify", %{
               "id" => initial["id"],
               "summary" => "Composed summary"
             })

    assert specified["status"] == "todo"

    assert specified["metadata"]["automation"] == %{
             "boardId" => "research",
             "scheduledAt" => 1,
             "idempotencyKey" => "rich-key",
             "summary" => "Composed summary"
           }

    assert specified["metadata"]["proof"] == proofed["metadata"]["proof"]
    assert specified["metadata"]["artifacts"] == proofed["metadata"]["artifacts"]
    assert specified["metadata"]["attachments"] == [attachment]
    assert hd(specified["metadata"]["comments"]) == hd(commented["metadata"]["comments"])

    promoted =
      promote(
        context,
        specified,
        %{"reason" => " \uFEFFReady café 雪😀\nKeep inner line.\u00A0 ", "force" => false},
        "Ready café 雪😀\nKeep inner line."
      )

    assert Store.get_attachment(snapshot(context), attachment["id"], deadline()) == {:ok, blob}
    stable = facts(context)

    assert execute(context, "create", %{
             "title" => "Ignored",
             "boardId" => "research",
             "idempotencyKey" => "rich-key",
             "scheduledAt" => 1
           }) == {:ok, %{"card" => promoted}}

    assert facts(context) == stable

    assert_read(
      context,
      promoted,
      context_text(
        promoted,
        "\n\n## Recent comments\n- Earlier comment\n- Composed summary\n- Ready café 雪😀\nKeep inner line.\n\n## Proof\n- passed: Checked\n\n## Artifacts\n- Checked\n\n## Attachments\n- receipt.txt · 8 bytes"
      ) <> "\nSummary: Composed summary"
    )
  end

  test "promotion clears only selected supplied diagnostics and removes supplied stale metadata",
       %{context: context} do
    board(context, "research")

    initial =
      seed_metadata(
        context,
        ["stranded_ready", "blocked_too_long", "missing_proof"],
        true,
        "seed-mixed"
      )

    expected_diagnostics =
      Enum.filter(initial["metadata"]["diagnostics"], &(&1["kind"] == "missing_proof"))

    promoted =
      promote(
        context,
        initial,
        %{"reason" => "Normal review complete"},
        "Normal review complete",
        fn metadata ->
          metadata |> Map.put("diagnostics", expected_diagnostics) |> Map.delete("stale")
        end
      )

    assert promoted["metadata"]["diagnostics"] == expected_diagnostics
    refute Map.has_key?(promoted["metadata"], "stale")
    only = seed_metadata(context, ["stranded_ready", "blocked_too_long"], false, "seed-only")
    cleared = promote(context, only, %{}, nil, &Map.delete(&1, "diagnostics"))
    refute Map.has_key?(cleared["metadata"], "diagnostics")
  end

  test "all-parent-done promotion persists full state for a distinct reader after ordinary creator completion",
       %{context: context} do
    creator =
      Task.async(fn ->
        board(context, "research")
        first = create(context, "Done one", "done")
        second = create(context, "Done two", "done")

        assert {:ok, %{"card" => linked}} =
                 execute(context, "create", %{
                   "title" => "Parent composed",
                   "boardId" => "research",
                   "status" => "todo",
                   "scheduledAt" => 1,
                   "parents" => [first["id"], second["id"]],
                   "idempotencyKey" => "parent-key"
                 })

        assert linked["status"] == "ready"

        assert linked["metadata"]["automation"] == %{
                 "boardId" => "research",
                 "scheduledAt" => 1,
                 "idempotencyKey" => "parent-key"
               }

        assert Enum.map(linked["metadata"]["links"], & &1["targetCardId"]) == [
                 first["id"],
                 second["id"]
               ]

        returned = move(context, linked, "todo")
        final = promote(context, returned, %{"reason" => "Parents reviewed"}, "Parents reviewed")
        %{card: final, facts: facts(context)}
      end)

    written = Task.await(creator, 30_000)
    refute Process.alive?(creator.pid)

    reader =
      Task.async(fn ->
        assert facts(context) == written.facts

        assert {:ok, %{"card" => final, "workerContext" => text}} =
                 execute(context, "read", %{"id" => written.card["id"]})

        assert final == written.card
        assert String.contains?(text, "## Parent results")

        assert String.contains?(text, "Done one: done") and
                 String.contains?(text, "Done two: done")

        assert final["metadata"]["automation"]["scheduledAt"] == 1
        assert facts(context) == written.facts
        final
      end)

    assert Task.await(reader, 30_000) == written.card
    refute Process.alive?(reader.pid)
    assert creator.pid != reader.pid
  end

  defp promote(context, previous, input, reason, metadata_change \\ &Function.identity/1) do
    before = snapshot(context)
    lower = System.system_time(:millisecond)

    assert {:ok, %{"card" => actual}} =
             execute(
               edit(context),
               "promote",
               Map.put(input, "id", " \uFEFF" <> previous["id"] <> "\u00A0 ")
             )

    upper = System.system_time(:millisecond)
    at = actual["updatedAt"]
    assert at >= lower and at <= max(upper, previous["updatedAt"] + 1)
    assert at > previous["updatedAt"]

    event = %{
      "id" => uuid(List.last(actual["events"])["id"]),
      "kind" => "moved",
      "at" => at,
      "fromStatus" => "todo",
      "toStatus" => "ready"
    }

    metadata = metadata_change.(previous["metadata"])

    metadata =
      if reason do
        comment = List.last(actual["metadata"]["comments"])

        assert comment == %{
                 "id" => uuid(comment["id"]),
                 "body" => reason,
                 "createdAt" => comment["createdAt"]
               }

        assert comment["id"] != event["id"]

        assert comment["createdAt"] >= lower and comment["createdAt"] <= upper and
                 comment["createdAt"] <= at

        Map.put(metadata, "comments", Map.get(metadata, "comments", []) ++ [comment])
      else
        metadata
      end

    expected =
      %{
        previous
        | "status" => "ready",
          "updatedAt" => at,
          "events" => previous["events"] ++ [event],
          "metadata" => metadata
      }
      |> Map.delete("completedAt")

    assert actual == expected
    assert_transition(context, before, previous, expected, @editor)
    expected
  end

  defp assert_transition(context, before, previous, next, provenance) do
    current = snapshot(context)
    old = get_item(before, previous["id"])
    new = get_item(current, next["id"])
    revision = new.storage_revision
    assert revision > old.storage_revision

    assert new == %{
             record: %{old.record | revision: old.record.revision + 1, payload: next},
             storage_revision: revision
           }

    previous_board = get_board(before, old.record.board_slug)

    assert get_board(current, old.record.board_slug) == %{
             record: %{previous_board.record | revision: previous_board.record.revision + 1},
             storage_revision: revision
           }

    public = List.last(next["events"])

    envelope = %{
      schema_version: 1,
      id: public["id"],
      scope: context.scope,
      item_id: next["id"],
      board_id: old.record.board_id,
      kind: :moved,
      payload: public,
      provenance: provenance
    }

    assert events(current, next["id"]) ==
             Enum.sort_by(
               events(before, previous["id"]) ++
                 [%{record: envelope, storage_revision: revision}],
               & &1.record.id
             )

    for board_id <- [nil, old.record.board_id] do
      expected_row = %{
        record: %{
          schema_version: 1,
          id: next["id"],
          scope: context.scope,
          board_id: old.record.board_id,
          board_slug: old.record.board_slug,
          payload: projection(next)
        },
        storage_revision: revision
      }

      assert Enum.filter(projections(current, board_id), &(&1.record.id == next["id"])) == [
               expected_row
             ]

      assert Enum.reject(projections(current, board_id), &(&1.record.id == next["id"])) ==
               Enum.reject(projections(before, board_id), &(&1.record.id == next["id"]))
    end

    for row <- projections(before, nil), row.record.id != next["id"] do
      assert get_item(current, row.record.id) == get_item(before, row.record.id)
      assert events(current, row.record.id) == events(before, row.record.id)
    end

    if key = current_key(next) do
      assert Store.lookup_create_key_candidates(current, key, deadline()) ==
               Store.lookup_create_key_candidates(before, key, deadline())
    end

    assert get_item(before, previous["id"]) == old
    assert new.record.provenance == @creator
  end

  defp create(context, title, status, extra \\ %{}, expected_status \\ nil) do
    before = snapshot(context)
    expected_status = expected_status || status
    lower = System.system_time(:millisecond)

    assert {:ok, %{"card" => actual}} =
             execute(
               context,
               "create",
               Map.merge(%{"title" => title, "status" => status, "boardId" => "research"}, extra)
             )

    upper = System.system_time(:millisecond)
    at = actual["createdAt"]
    assert is_integer(at) and at >= lower and at <= upper
    automation = Map.take(extra, ["idempotencyKey"]) |> Map.put("boardId", "research")

    automation =
      if is_number(extra["scheduledAt"]) and extra["scheduledAt"] >= 1,
        do: Map.put(automation, "scheduledAt", floor(extra["scheduledAt"])),
        else: automation

    event = %{
      "id" => uuid(hd(actual["events"])["id"]),
      "kind" => "created",
      "at" => at,
      "toStatus" => expected_status
    }

    expected = %{
      "id" => uuid(actual["id"]),
      "title" => title,
      "status" => expected_status,
      "priority" => "normal",
      "labels" => [],
      "position" =>
        next_position(
          before,
          %{"id" => "new", "metadata" => %{"automation" => automation}},
          expected_status
        ),
      "createdAt" => at,
      "updatedAt" => at,
      "events" => [event],
      "metadata" => %{"automation" => automation}
    }

    expected =
      if expected_status == "done", do: Map.put(expected, "completedAt", at), else: expected

    expected =
      if expected_status == "running", do: Map.put(expected, "startedAt", at), else: expected

    assert actual == expected
    point = snapshot(context)
    row = get_item(point, actual["id"])
    assert row.record.payload == expected and row.record.provenance == @creator
    expected
  end

  defp seed_metadata(context, kinds, stale?, key) do
    point = snapshot(context)
    board = get_board(point, "research").record
    now = System.system_time(:millisecond)
    id = Ecto.UUID.generate()

    public = %{
      "id" => Ecto.UUID.generate(),
      "kind" => "created",
      "at" => now,
      "toStatus" => "todo"
    }

    diagnostics =
      Enum.map(kinds, fn kind ->
        %{
          "kind" => kind,
          "severity" => "warning",
          "title" => "Supplied " <> kind,
          "detail" => "Explicit canonical fixture",
          "firstSeenAt" => now,
          "lastSeenAt" => now,
          "count" => 1,
          "actions" => []
        }
      end)

    metadata = %{
      "automation" => %{"boardId" => "research", "scheduledAt" => 1, "idempotencyKey" => key},
      "diagnostics" => diagnostics
    }

    metadata =
      if stale?,
        do:
          Map.put(metadata, "stale", %{
            "detectedAt" => now,
            "lastSessionUpdatedAt" => now - 1,
            "reason" => "Supplied persisted marker"
          }),
        else: metadata

    card = %{
      "id" => id,
      "title" => "Supplied metadata " <> key,
      "status" => "todo",
      "priority" => "normal",
      "labels" => [],
      "position" => 1000,
      "createdAt" => now,
      "updatedAt" => now,
      "metadata" => metadata,
      "events" => [public]
    }

    item = %{
      schema_version: 1,
      id: id,
      scope: context.scope,
      board_id: board.id,
      board_slug: "research",
      revision: 1,
      payload: card,
      provenance: @creator
    }

    event = %{
      schema_version: 1,
      id: public["id"],
      scope: context.scope,
      item_id: id,
      board_id: board.id,
      kind: :created,
      payload: public,
      provenance: @creator
    }

    change = %{
      kind: :create,
      board: %{board | revision: board.revision + 1},
      item: item,
      event: event,
      projection: projection(card),
      create_key: current_key(card)
    }

    assert {:ok, ack} = Store.commit_item(point, change, deadline())

    assert ack == %{
             board: change.board,
             item: item,
             event: event,
             storage_revision: ack.storage_revision
           }

    card
  end

  defp current_key(card) do
    a = card["metadata"]["automation"]
    if a["idempotencyKey"], do: {a["tenant"], a["boardId"], a["idempotencyKey"]}
  end

  defp board(context, slug) do
    assert {:ok, %{"board" => board}} =
             execute(context, "board_create", %{"id" => slug, "name" => String.capitalize(slug)})

    board
  end

  defp link(context, parent, child, target, duplicate \\ false) do
    before = snapshot(context)
    lower = System.system_time(:millisecond)

    assert {:ok, result} =
             execute(%{context | provenance: @linker}, "link", %{
               "parentId" => " " <> parent["id"] <> " ",
               "childId" => " " <> child["id"] <> " "
             })

    upper = System.system_time(:millisecond)
    assert Map.keys(result) == ["card"]
    actual_child = result["card"]
    current = snapshot(context)
    actual_parent = get_item(current, parent["id"]).record.payload
    old_parent_links = Map.get(parent["metadata"], "links", [])
    old_child_links = Map.get(child["metadata"], "links", [])

    {parent_links, child_links} =
      if duplicate do
        {old_parent_links, old_child_links}
      else
        p = List.last(actual_parent["metadata"]["links"])
        c = List.last(actual_child["metadata"]["links"])
        assert is_integer(p["createdAt"]) and p["createdAt"] >= lower and p["createdAt"] <= upper

        assert p == %{
                 "id" => uuid(p["id"]),
                 "type" => "child",
                 "targetCardId" => child["id"],
                 "createdAt" => p["createdAt"]
               }

        assert c == %{
                 "id" => uuid(c["id"]),
                 "type" => "parent",
                 "targetCardId" => parent["id"],
                 "createdAt" => p["createdAt"]
               }

        assert p["id"] != c["id"]
        {old_parent_links ++ [p], old_child_links ++ [c]}
      end

    kind = if duplicate, do: "edited", else: "link_added"
    parent1 = expect_metadata(parent, actual_parent, parent_links, kind)
    child_events = Enum.drop(actual_child["events"], length(child["events"]))
    [metadata_event | _] = child_events

    middle = %{
      child
      | "updatedAt" => metadata_event["at"],
        "events" => child["events"] ++ [metadata_event],
        "metadata" => Map.put(child["metadata"], "links", child_links)
    }

    assert middle == expect_metadata(child, middle, child_links, kind)

    child1 =
      if target == child["status"] do
        assert child_events == [metadata_event]
        middle
      else
        [^metadata_event, moved] = child_events

        assert moved == %{
                 "id" => uuid(moved["id"]),
                 "kind" => "moved",
                 "at" => actual_child["updatedAt"],
                 "fromStatus" => child["status"],
                 "toStatus" => target
               }

        assert moved["at"] > metadata_event["at"]

        %{
          middle
          | "status" => target,
            "updatedAt" => moved["at"],
            "events" => middle["events"] ++ [moved]
        }
      end

    assert actual_parent == parent1
    assert actual_child == child1
    assert_pair(context, before, current, parent, child, parent1, child1, child_events)
    {parent1, child1}
  end

  defp expect_metadata(previous, actual, links, kind) do
    event = List.last(actual["events"])
    assert actual["updatedAt"] > previous["updatedAt"]
    assert event == %{"id" => uuid(event["id"]), "kind" => kind, "at" => actual["updatedAt"]}

    %{
      previous
      | "updatedAt" => event["at"],
        "events" => previous["events"] ++ [event],
        "metadata" => Map.put(previous["metadata"], "links", links)
    }
  end

  defp assert_pair(context, before, current, parent, child, next_parent, next_child, child_events) do
    p0 = get_item(before, parent["id"])
    c0 = get_item(before, child["id"])
    p = get_item(current, parent["id"])
    c = get_item(current, child["id"])
    revision = p.storage_revision
    assert revision > p0.storage_revision and revision > c0.storage_revision

    assert p == %{
             record: %{p0.record | revision: p0.record.revision + 1, payload: next_parent},
             storage_revision: revision
           }

    assert c == %{
             record: %{
               c0.record
               | revision: c0.record.revision + length(child_events),
                 payload: next_child
             },
             storage_revision: revision
           }

    for slug <- Enum.uniq([p0.record.board_slug, c0.record.board_slug]) do
      old = get_board(before, slug)

      increment =
        if(p0.record.board_slug == slug, do: 1, else: 0) +
          if c0.record.board_slug == slug, do: length(child_events), else: 0

      assert get_board(current, slug) == %{
               record: %{old.record | revision: old.record.revision + increment},
               storage_revision: revision
             }
    end

    for {old, card, added} <- [
          {p0, next_parent, [List.last(next_parent["events"])]},
          {c0, next_child, child_events}
        ] do
      new =
        Enum.map(added, fn e ->
          %{
            record: %{
              schema_version: 1,
              id: e["id"],
              scope: context.scope,
              item_id: card["id"],
              board_id: old.record.board_id,
              kind: String.to_existing_atom(e["kind"]),
              payload: e,
              provenance: @linker
            },
            storage_revision: revision
          }
        end)

      assert events(current, card["id"]) ==
               Enum.sort_by(events(before, card["id"]) ++ new, & &1.record.id)

      for board_id <- [nil, old.record.board_id] do
        row = %{
          record: %{
            schema_version: 1,
            id: card["id"],
            scope: context.scope,
            board_id: old.record.board_id,
            board_slug: old.record.board_slug,
            payload: projection(card)
          },
          storage_revision: revision
        }

        assert Enum.filter(projections(current, board_id), &(&1.record.id == card["id"])) == [row]
      end

      a = card["metadata"]["automation"]

      if a["idempotencyKey"],
        do:
          assert(
            Store.lookup_create_key_candidates(
              current,
              {a["tenant"], a["boardId"], a["idempotencyKey"]},
              deadline()
            ) ==
              Store.lookup_create_key_candidates(
                before,
                {a["tenant"], a["boardId"], a["idempotencyKey"]},
                deadline()
              )
          )

      assert get_item(before, card["id"]) == old
    end
  end

  defp move(context, previous, status) do
    assert {:ok, %{"card" => actual}} =
             execute(edit(context), "move", %{"id" => previous["id"], "status" => status})

    at = actual["updatedAt"]
    assert at > previous["updatedAt"]

    event = %{
      "id" => uuid(List.last(actual["events"])["id"]),
      "kind" => "moved",
      "at" => at,
      "fromStatus" => previous["status"],
      "toStatus" => status
    }

    expected = %{
      previous
      | "status" => status,
        "updatedAt" => at,
        "events" => previous["events"] ++ [event]
    }

    expected = if status == "done", do: Map.put(expected, "completedAt", at), else: expected

    expected =
      if status == "running",
        do: Map.put(expected, "startedAt", previous["startedAt"] || at),
        else: expected

    assert actual == expected
    expected
  end

  defp next_position(point, card, status) do
    projections(point, nil)
    |> Enum.map(& &1.record.payload)
    |> Enum.filter(
      &(&1["id"] != card["id"] and &1["status"] == status and
          &1["boardId"] == card["metadata"]["automation"]["boardId"])
    )
    |> Enum.map(& &1["position"])
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1000)
  end

  defp projection(card) do
    base =
      Map.take(card, [
        "id",
        "title",
        "status",
        "priority",
        "agentId",
        "updatedAt",
        "position",
        "createdAt"
      ])
      |> Map.put("boardId", card["metadata"]["automation"]["boardId"])

    base =
      if card["metadata"]["diagnostics"],
        do: Map.put(base, "diagnostics", card["metadata"]["diagnostics"]),
        else: base

    case card["metadata"]["links"] do
      nil ->
        base

      links ->
        base
        |> Map.put("parents", for(l <- links, l["type"] == "parent", do: l["targetCardId"]))
        |> Map.put("children", for(l <- links, l["type"] == "child", do: l["targetCardId"]))
    end
  end

  defp context_text(card, extra) do
    a = card["metadata"]["automation"]

    "# Workboard card #{card["id"]}\nTitle: #{card["title"]}\nStatus: #{card["status"]}\nPriority: normal\nBoard: #{a["boardId"]}\nAgent: #{card["agentId"] || "(default)"}" <>
      extra <> "\n\n## Automation\nBoard: #{a["boardId"]}"
  end

  defp assert_read(context, card, text) do
    stable = facts(context)

    assert execute(context, "read", %{"id" => card["id"]}) ==
             {:ok, %{"card" => card, "workerContext" => text}}

    assert facts(context) == stable
  end

  defp facts(context) do
    point = snapshot(context)
    rows = projections(point, nil)
    items = Enum.map(rows, &get_item(point, &1.record.id))

    keys =
      for row <- items,
          a = row.record.payload["metadata"]["automation"],
          a["idempotencyKey"],
          do:
            Store.lookup_create_key_candidates(
              point,
              {a["tenant"], a["boardId"], a["idempotencyKey"]},
              deadline()
            )

    %{
      boards: boards(point),
      items: items,
      projections: rows,
      events: Enum.flat_map(rows, &events(point, &1.record.id)),
      keys: keys
    }
  end

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
    opts = if board_id, do: [limit: 100, board_id: board_id], else: [limit: 100]
    assert {:ok, %{rows: rows, next_cursor: nil}} = Store.items_page(point, opts, deadline())
    Enum.sort_by(rows, & &1.record.id)
  end

  defp events(point, id) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.events_page(point, id, [limit: 100], deadline())

    Enum.sort_by(rows, & &1.record.id)
  end

  defp boards(point) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.boards_page(point, [limit: 100], deadline())

    Enum.sort_by(rows, & &1.record.id)
  end

  defp uuid(id) do
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    id
  end

  defp edit(context), do: %{context | provenance: @editor}

  defp execute(context, action, args),
    do: Synapsis.Workboard.execute(action, args, context, deadline())

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
