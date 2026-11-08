defmodule Synapsis.Workboard.CoreLinkFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workboard.Store

  # Independent OpenClaw 488631c ordinary fixtures and batch383's explicit
  # atomic-pair Concord adaptation. No implementation candidate was inspected.
  # Supplied provenance is fixture JSON, never native/model invocation evidence.
  @creator %{
    "runId" => "fixture:383:create",
    "incarnation" => 21,
    "extra" => %{"json" => [nil, true, 1.5, "雪😀"]}
  }
  @linker %{
    "runId" => "fixture:383:link",
    "incarnation" => 22,
    "toolCallId" => "fixture:383:link-call"
  }
  @editor %{
    "runId" => "fixture:383:edit",
    "incarnation" => 23,
    "toolCallId" => "fixture:383:edit-call"
  }

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{context: %{scope: "fixture:383:links/雪/" <> Ecto.UUID.generate(), provenance: @creator}}
  end

  test "first and duplicate ordinary pairs retain distinct reciprocal identity and commit exact immutable events",
       %{context: context} do
    board(context, "research")
    parent = create(context, "Parent café", "todo")
    child = create(context, "Child 雪😀", "todo", %{"idempotencyKey" => "child-key"})
    {parent1, child1} = link(context, parent, child, "todo")

    assert_read(
      context,
      parent1,
      context_text(parent1, "\n\n## Links\n- child: " <> child1["id"])
    )

    assert_read(
      context,
      child1,
      context_text(child1, "\n\n## Links\n- parent: " <> parent1["id"])
    )

    {parent2, child2} = link(context, parent1, child1, "todo", true)
    assert parent2["metadata"]["links"] == parent1["metadata"]["links"]
    assert child2["metadata"]["links"] == child1["metadata"]["links"]
    stable = facts(context)

    assert execute(context, "create", %{
             "title" => "Ignored",
             "boardId" => "research",
             "idempotencyKey" => "child-key",
             "parents" => [parent["id"]]
           }) == {:ok, %{"card" => child2}}

    assert facts(context) == stable
    assert_list(context, [parent2, child2])
  end

  test "all parents are reevaluated only on relink after ordinary parent completion", %{
    context: context
  } do
    board(context, "research")
    first = create(context, "First", "todo")
    second = create(context, "Second", "done")
    child = create(context, "Child", "ready")
    {first1, child1} = link(context, first, child, "todo")
    {second1, child2} = link(context, second, child1, "todo")
    before = snapshot(context)
    first2 = move(context, first1, "done")
    assert get_item(snapshot(context), child["id"]) == get_item(before, child["id"])
    {second2, ready} = link(context, second1, child2, "ready", true)
    assert ready["metadata"]["links"] == child2["metadata"]["links"]

    assert Enum.map(ready["metadata"]["links"], & &1["targetCardId"]) == [
             first2["id"],
             second2["id"]
           ]

    {second3, ready2} = link(context, second2, ready, "ready", true)
    assert ready2["position"] == ready["position"]
    assert_list(context, [first2, second3, ready2])
  end

  test "done parents make backlog triage todo ready ordinary children ready", %{context: context} do
    board(context, "research")
    parent = create(context, "Done parent", "done")

    Enum.reduce(["backlog", "triage", "todo", "ready"], parent, fn status, previous ->
      child = create(context, "Ordinary " <> status, status)
      {next, ready} = link(context, previous, child, "ready")
      assert ready["status"] == "ready"
      next
    end)
  end

  test "create parents normalize string and lists hold running review and preserve original create key",
       %{context: context} do
    board(context, "research")
    first = create(context, "Incomplete", "todo")
    second = create(context, "Done", "done")

    assert {:ok, %{"card" => held}} =
             execute(context, "create", %{
               "title" => "Held",
               "boardId" => "research",
               "status" => "running",
               "parents" => " " <> first["id"] <> " ",
               "idempotencyKey" => "held-key"
             })

    assert held["status"] == "todo"
    refute Map.has_key?(held, "startedAt")

    assert held["metadata"]["automation"] == %{
             "boardId" => "research",
             "idempotencyKey" => "held-key",
             "createdByCardId" => first["id"]
           }

    assert Enum.map(held["events"], & &1["kind"]) == ["created", "link_added"]
    assert hd(held["events"])["toStatus"] == "todo"
    assert Enum.map(held["metadata"]["links"], & &1["targetCardId"]) == [first["id"]]
    stable = facts(context)

    assert execute(context, "create", %{
             "title" => "Ignored",
             "boardId" => "research",
             "parents" => [second["id"]],
             "idempotencyKey" => "held-key"
           }) == {:ok, %{"card" => held}}

    assert facts(context) == stable

    assert {:ok, %{"card" => multiple}} =
             execute(context, "create", %{
               "title" => "Multiple",
               "boardId" => "research",
               "status" => "review",
               "parents" => [" " <> first["id"] <> " ", second["id"], first["id"]]
             })

    assert multiple["status"] == "todo"
    assert multiple["metadata"]["automation"] == %{"boardId" => "research"}

    assert Enum.map(multiple["metadata"]["links"], & &1["targetCardId"]) == [
             first["id"],
             second["id"]
           ]

    assert {:ok, %{"card" => ready}} =
             execute(context, "create", %{
               "title" => "Ready chain",
               "boardId" => "research",
               "status" => "review",
               "parents" => [second["id"]],
               "createdByCardId" => " supplied-origin "
             })

    assert ready["status"] == "ready"
    refute Map.has_key?(ready, "startedAt")

    assert ready["metadata"]["automation"] == %{
             "boardId" => "research",
             "createdByCardId" => "supplied-origin"
           }

    assert Enum.map(ready["events"], & &1["kind"]) == ["created", "link_added", "moved"]
    row = get_item(snapshot(context), ready["id"])
    assert row.record.revision == 3
    [_, metadata_event, moved_event] = ready["events"]

    new_rows =
      Enum.filter(
        events(snapshot(context), ready["id"]),
        &(&1.record.id in [metadata_event["id"], moved_event["id"]])
      )

    assert Enum.all?(new_rows, &(&1.storage_revision == row.storage_revision))
    assert Enum.all?(new_rows, &(&1.record.provenance == @creator))
  end

  test "same and crossboard successful specify and move retain links proof attachments and provenance",
       %{context: context} do
    board(context, "research")
    board(context, "delivery")
    parent = create(context, "Done parent", "done")
    child = create(context, "Child", "todo", %{"idempotencyKey" => "preserved-key"})

    assert {:ok, %{"card" => uploaded}} =
             execute(edit(context), "attachment_add", %{
               "id" => child["id"],
               "fileName" => "receipt.txt",
               "contentBase64" => "6Zuq8J+YgAo="
             })

    [attachment] = uploaded["metadata"]["attachments"]
    assert {:ok, blob} = Store.get_attachment(snapshot(context), attachment["id"], deadline())

    assert {:ok, %{"card" => proofed, "proofId" => _}} =
             execute(edit(context), "proof", %{
               "id" => child["id"],
               "status" => "passed",
               "label" => "Checked",
               "artifactPath" => "/supplied/check.log"
             })

    {parent1, ready} = link(context, parent, proofed, "ready")
    running = move(context, ready, "running")
    returned = move(context, running, "todo")
    clarified = specify(context, returned, "research", "Same board")
    moved = specify(context, clarified, "delivery", "Delivery summary")
    assert moved["metadata"]["links"] == ready["metadata"]["links"]
    assert moved["metadata"]["proof"] == ready["metadata"]["proof"]
    assert moved["metadata"]["artifacts"] == ready["metadata"]["artifacts"]
    assert moved["metadata"]["attachments"] == [attachment]
    assert Store.get_attachment(snapshot(context), attachment["id"], deadline()) == {:ok, blob}
    assert get_item(snapshot(context), moved["id"]).record.provenance == @creator
    {_, re_ready} = link(context, parent1, moved, "ready", true)
    assert re_ready["metadata"] == moved["metadata"]

    text =
      context_text(
        re_ready,
        "\n\n## Recent comments\n- Same board\n- Delivery summary\n\n## Proof\n- passed: Checked\n\n## Artifacts\n- Checked\n\n## Attachments\n- receipt.txt · 8 bytes\n\n## Links\n- parent: " <>
          parent1["id"] <> "\n\n## Parent results\n- #{parent1["id"]} Done parent: done"
      ) <> "\nSummary: Delivery summary"

    assert_read(context, re_ready, text)
  end

  test "completed parent summaries follow link order with last six and source text windows before recent done work",
       %{context: context} do
    board(context, "research")

    parents =
      for index <- 1..7 do
        parent = create(context, "Parent #{index}", "todo")

        clarified =
          specify(
            context,
            parent,
            "research",
            if(index == 7, do: String.duplicate("x", 510), else: "Result #{index}")
          )

        move(context, clarified, "done")
      end

    recent = create(context, "Recent", "done", %{"agentId" => "fixture-agent"})
    child = create(context, "Context child", "todo", %{"agentId" => "fixture-agent"})

    linked =
      Enum.reduce(parents, child, fn parent, previous ->
        elem(link(context, parent, previous, "ready"), 1)
      end)

    links = Enum.map_join(parents, "\n", &"- parent: #{&1["id"]}")

    results =
      Enum.map_join(Enum.drop(parents, 1), "\n", fn p ->
        summary =
          if p["title"] == "Parent 7",
            do: String.duplicate("x", 499) <> "…",
            else: p["metadata"]["automation"]["summary"]

        "- #{p["id"]} #{p["title"]}: #{summary}"
      end)

    extra =
      "\n\n## Links\n" <>
        links <>
        "\n\n## Parent results\n" <>
        results <> "\n\n## Recent done work by fixture-agent\n- #{recent["id"]} Recent: done"

    assert_read(context, linked, context_text(linked, extra))
  end

  test "normal completed creator leaves full reciprocal facts for a distinct fresh reader", %{
    context: context
  } do
    creator =
      Task.async(fn ->
        board(context, "research")
        parent = create(context, "Durable parent", "done")
        child = create(context, "Durable child", "todo")
        {parent1, child1} = link(context, parent, child, "ready")
        %{parent: parent1, child: child1, facts: facts(context)}
      end)

    written = Task.await(creator, 30_000)
    refute Process.alive?(creator.pid)

    reader =
      Task.async(fn ->
        assert facts(context) == written.facts
        assert_list(context, [written.parent, written.child])

        assert_read(
          context,
          written.child,
          context_text(
            written.child,
            "\n\n## Links\n- parent: #{written.parent["id"]}\n\n## Parent results\n- #{written.parent["id"]} Durable parent: done"
          )
        )

        written.child
      end)

    assert Task.await(reader, 30_000) == written.child
    refute Process.alive?(reader.pid)
    assert creator.pid != reader.pid
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

  defp specify(context, previous, slug, summary) do
    assert {:ok, %{"card" => actual}} =
             execute(edit(context), "specify", %{
               "id" => previous["id"],
               "boardId" => slug,
               "summary" => summary
             })

    event = List.last(actual["events"])
    assert event == %{"id" => uuid(event["id"]), "kind" => "specified", "at" => event["at"]}
    assert actual["updatedAt"] > previous["updatedAt"] and actual["updatedAt"] >= event["at"]

    comment = %{
      "id" => uuid(List.last(actual["metadata"]["comments"])["id"]),
      "body" => summary,
      "createdAt" => event["at"]
    }

    metadata =
      previous["metadata"]
      |> Map.put(
        "automation",
        Map.merge(previous["metadata"]["automation"], %{"boardId" => slug, "summary" => summary})
      )
      |> Map.put("comments", Map.get(previous["metadata"], "comments", []) ++ [comment])

    expected = %{
      previous
      | "status" => "todo",
        "updatedAt" => actual["updatedAt"],
        "events" => previous["events"] ++ [event],
        "metadata" => metadata
    }

    assert actual == expected
    expected
  end

  defp board(context, slug) do
    assert {:ok, %{"board" => board}} =
             execute(context, "board_create", %{"id" => slug, "name" => String.capitalize(slug)})

    board
  end

  defp create(context, title, status, extra \\ %{}) do
    before = snapshot(context)

    assert {:ok, %{"card" => actual}} =
             execute(
               context,
               "create",
               Map.merge(%{"title" => title, "status" => status, "boardId" => "research"}, extra)
             )

    at = actual["createdAt"]
    assert is_integer(at) and at > 0
    automation = Map.take(extra, ["idempotencyKey"]) |> Map.put("boardId", "research")

    event = %{
      "id" => uuid(hd(actual["events"])["id"]),
      "kind" => "created",
      "at" => at,
      "toStatus" => status
    }

    expected = %{
      "id" => uuid(actual["id"]),
      "title" => title,
      "status" => status,
      "priority" => "normal",
      "labels" => [],
      "position" =>
        next_position(
          before,
          %{"id" => "new", "metadata" => %{"automation" => automation}},
          status
        ),
      "createdAt" => at,
      "updatedAt" => at,
      "events" => [event],
      "metadata" => %{"automation" => automation}
    }

    expected = if status == "done", do: Map.put(expected, "completedAt", at), else: expected

    expected =
      if extra["agentId"], do: Map.put(expected, "agentId", extra["agentId"]), else: expected

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

    case card["metadata"]["links"] do
      nil ->
        base

      links ->
        base
        |> Map.put("parents", for(l <- links, l["type"] == "parent", do: l["targetCardId"]))
        |> Map.put("children", for(l <- links, l["type"] == "child", do: l["targetCardId"]))
    end
  end

  defp assert_list(context, cards) do
    stable = facts(context)
    assert {:ok, %{"cards" => actual}} = execute(context, "list", %{})
    expected = Enum.map(cards, &Map.drop(projection(&1), ["position", "createdAt"]))
    assert Enum.sort_by(actual, & &1["id"]) == Enum.sort_by(expected, & &1["id"])
    assert facts(context) == stable
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
