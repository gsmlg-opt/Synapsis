defmodule Synapsis.Workboard.CoreDecomposeFunctionalTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Synapsis.Workboard.Store

  # Independent ordinary expectations from pinned OpenClaw 488631c whole factory,
  # domain and original SQLite paths, plus the accepted batch389 host contract.
  # Source: /tmp/synapsis-workboard389-source-i359n74x/source-report.json.
  # No batch389 product candidate or Data candidate was inspected. Explicit scope,
  # creator/event provenance and durable notification highwater are host contracts.
  # Status-only running/review reuse retains its status in the actual source.
  @creator %{
    "runId" => "fixture:389:create",
    "incarnation" => 91,
    "extra" => %{"json" => [nil, true, 1.5, "café 雪😀"]}
  }
  @writer %{
    "runId" => "fixture:389:decompose",
    "incarnation" => 92,
    "toolCallId" => "fixture:389:ordinary-call",
    "extra" => [false, "雪😀"]
  }
  @hints %{
    "skills" => ["parent-skill"],
    "workspace" => %{"kind" => "dir", "path" => "/parent"},
    "maxRuntimeSeconds" => 80,
    "maxRetries" => 3
  }

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{context: %{scope: "fixture:389:decompose/雪/" <> Ecto.UUID.generate(), provenance: @creator}}
  end

  test "default completion returns ordered precompletion children with exact inheritance and own overrides",
       %{context: context} do
    board(context, "alpha")
    board(context, "beta")

    parent =
      create(
        context,
        "alpha",
        "Parent 雪😀",
        "backlog",
        Map.merge(@hints, %{
          "tenant" => "parent-tenant",
          "idempotencyKey" => "parent-key",
          "agentId" => "parent-agent",
          "labels" => ["parent"],
          "notes" => "Retained parent body"
        })
      )

    parent = attach(context, parent)
    before = snapshot(context)

    own = %{
      "notes" => " own note ",
      "agentId" => "child-agent",
      "priority" => "high",
      "labels" => ["own"],
      "boardId" => "beta",
      "tenant" => "child-tenant",
      "idempotencyKey" => "explicit-child",
      "skills" => ["own-skill"],
      "workspace" => %{"kind" => "dir", "path" => "/child"},
      "maxRuntimeSeconds" => 31,
      "maxRetries" => 1
    }

    {done, [first, second]} =
      decompose(
        context,
        parent,
        %{
          "summary" => "  Fan out 雪😀  ",
          "children" => [
            %{"title" => " First ", "boardId" => nil, "tenant" => nil, "idempotencyKey" => nil},
            Map.put(own, "title", "Second")
          ]
        },
        "Fan out 雪😀",
        2
      )

    assert_new_child(
      first,
      parent,
      "First",
      "alpha",
      "parent-tenant",
      "parent-key:child:1",
      1000,
      %{},
      %{}
    )

    assert_new_child(
      second,
      parent,
      "Second",
      "beta",
      "child-tenant",
      "explicit-child",
      1000,
      %{
        "notes" => "own note",
        "agentId" => "child-agent",
        "priority" => "high",
        "labels" => ["own"]
      },
      Map.take(own, ~w(skills workspace maxRuntimeSeconds maxRetries))
    )

    assert first["status"] == "todo" and second["status"] == "todo"

    assert done["metadata"]["automation"] ==
             Map.merge(
               parent["metadata"]["automation"],
               %{"summary" => "Fan out 雪😀", "createdCardIds" => [first["id"], second["id"]]}
             )

    assert_rows(context, before, parent, done, [first, second])

    assert_keys(context, [
      {"parent-tenant", "alpha", "parent-key:child:1", first},
      {"child-tenant", "beta", "explicit-child", second}
    ])

    assert Enum.map(done["events"], & &1["kind"]) ==
             ["created", "attachment_added", "link_added", "link_added", "moved", "decomposed"]
  end

  test "literal false opens backlog then retained todo keeps summary and appends edited plus forced events",
       %{context: context} do
    board(context, "alpha")

    parent =
      create(context, "alpha", "Open parent", "backlog", %{
        "tenant" => "open",
        "idempotencyKey" => "open-key"
      })

    parent = attach(context, parent)
    before = snapshot(context)

    {opened, [child]} =
      decompose(
        context,
        parent,
        %{
          "completeParent" => false,
          "summary" => " Retained summary ",
          "children" => [%{"title" => "Open child"}]
        },
        "Retained summary",
        1
      )

    assert_new_child(
      child,
      parent,
      "Open child",
      "alpha",
      "open",
      "open-key:child:1",
      1000,
      %{},
      %{}
    )

    assert_rows(context, before, parent, opened, [child])
    assert Enum.take(Enum.map(opened["events"], & &1["kind"]), -2) == ["moved", "decomposed"]
    before = snapshot(context)

    {retained, [same]} =
      decompose(
        context,
        opened,
        %{
          "completeParent" => false,
          "summary" => " \uFEFF ",
          "children" => [%{"title" => "Ignored"}]
        },
        nil,
        0
      )

    assert same == child
    assert_rows(context, before, opened, retained, [])
    assert Enum.take(Enum.map(retained["events"], & &1["kind"]), -2) == ["edited", "decomposed"]
    before = snapshot(context)

    {again, [same]} =
      decompose(
        context,
        retained,
        %{"completeParent" => false, "children" => [%{"title" => "Ignored again"}]},
        nil,
        0
      )

    assert same == child
    assert_rows(context, before, retained, again, [])
    assert again["metadata"]["automation"]["summary"] == "Retained summary"
    assert get_in(again, ["metadata", "comments"]) == nil
    assert get_in(again, ["metadata", "notifications"]) == nil
    assert Store.notification_sequence(snapshot(context), deadline()) == {:ok, 0}
  end

  test "repeated keys return current child content without duplicate links and still complete and decompose",
       %{context: context} do
    board(context, "alpha")

    parent =
      create(context, "alpha", "Repeated parent", "todo", %{
        "tenant" => "same",
        "idempotencyKey" => "repeat"
      })

    {done, [child]} =
      decompose(context, parent, %{"children" => [%{"title" => "Keep child"}]}, nil, 1)

    assert_new_child(
      child,
      parent,
      "Keep child",
      "alpha",
      "same",
      "repeat:child:1",
      2000,
      %{},
      %{}
    )

    assert {:ok, %{"card" => current}} =
             execute(writer(context), "comment", %{
               "id" => child["id"],
               "body" => "Current child content 雪😀"
             })

    before = snapshot(context)
    child_row = item(before, child["id"])
    key = {"same", "alpha", "repeat:child:1"}
    key_before = Store.lookup_create_key_candidates(before, key, deadline())

    {again, [returned]} =
      decompose(
        context,
        done,
        %{
          "summary" => " Second completion ",
          "children" => [
            %{"title" => "Ignored requested replacement", "notes" => "Ignored replacement notes"}
          ]
        },
        "Second completion",
        0
      )

    assert returned == current
    assert again["metadata"]["links"] == done["metadata"]["links"]
    assert length(again["metadata"]["notifications"]) == 2

    assert Enum.take(Enum.map(again["events"], & &1["kind"]), -2) == [
             "comment_added",
             "decomposed"
           ]

    assert_rows(context, before, done, again, [])
    assert item(snapshot(context), child["id"]) == child_row
    assert Store.lookup_create_key_candidates(snapshot(context), key, deadline()) == key_before
    before_omitted = snapshot(context)

    {third, [same]} =
      decompose(
        context,
        again,
        %{"children" => [%{"title" => "Ignored omitted-summary replacement"}]},
        nil,
        0
      )

    assert same == current
    assert third["metadata"]["links"] == again["metadata"]["links"]
    assert third["metadata"]["automation"]["summary"] == "Second completion"
    assert third["metadata"]["comments"] == again["metadata"]["comments"]
    assert length(third["metadata"]["notifications"]) == 3

    assert Enum.take(Enum.map(third["events"], & &1["kind"]), -2) == [
             "notification",
             "decomposed"
           ]

    assert_rows(context, before_omitted, again, third, [])
    assert item(snapshot(context), child["id"]) == child_row
    assert Store.lookup_create_key_candidates(snapshot(context), key, deadline()) == key_before
  end

  test "unrelated running and review key winners gain reciprocal links while preserving their own content",
       %{context: context} do
    board(context, "alpha")

    for status <- ["running", "review"] do
      existing =
        create(context, "alpha", "Keep " <> status, status, %{
          "tenant" => "reuse",
          "idempotencyKey" => "reuse-" <> status,
          "notes" => "Original content",
          "skills" => ["existing-skill"],
          "labels" => ["existing"]
        })

      parent = create(context, "alpha", "Parent " <> status, "todo", %{"tenant" => "reuse"})
      before = snapshot(context)

      {opened, [child]} =
        decompose(
          context,
          parent,
          %{
            "completeParent" => false,
            "children" => [
              %{"title" => "Ignored requested content", "idempotencyKey" => "reuse-" <> status}
            ]
          },
          nil,
          1
        )

      [link] = child["metadata"]["links"]
      assert_link(link, "parent", parent["id"])
      event = public_event(List.last(child["events"]), "link_added", existing["updatedAt"])

      expected =
        existing
        |> Map.put("updatedAt", event["at"])
        |> Map.put("events", existing["events"] ++ [event])
        |> Map.put("metadata", Map.put(existing["metadata"], "links", [link]))

      assert child == expected
      assert child["status"] == status
      assert get_in(child, ["metadata", "automation", "createdByCardId"]) == nil
      assert_rows(context, before, parent, opened, [child])
      assert item(snapshot(context), child["id"]).record.provenance == @creator

      assert Enum.map(events(snapshot(context), child["id"]), & &1.record.provenance) == [
               @creator,
               @writer
             ]

      before_repeat = snapshot(context)

      {again, [same]} =
        decompose(
          context,
          opened,
          %{
            "completeParent" => false,
            "children" => [%{"title" => "Ignored again", "idempotencyKey" => "reuse-" <> status}]
          },
          nil,
          0
        )

      assert same == child
      assert_rows(context, before_repeat, opened, again, [])
    end
  end

  test "normal completed caller hands exact durable views to a distinct reader and unkeyed calls create fresh children",
       %{context: context} do
    caller =
      Task.async(fn ->
        board(context, "alpha")
        parent = create(context, "alpha", "Caller parent", "triage", %{"tenant" => "ordinary"})
        parent = attach(context, parent)

        {first, [one]} =
          decompose(
            context,
            parent,
            %{"completeParent" => false, "children" => [%{"title" => "Fresh child"}]},
            nil,
            1
          )

        before = snapshot(context)

        {done, [two]} =
          decompose(context, first, %{"children" => [%{"title" => "Fresh child"}]}, nil, 1)

        refute one["id"] == two["id"]
        assert_new_child(one, parent, "Fresh child", "alpha", "ordinary", nil, 1000, %{}, %{})
        assert_new_child(two, parent, "Fresh child", "alpha", "ordinary", nil, 2000, %{}, %{})

        assert one["metadata"]["automation"] == %{
                 "boardId" => "alpha",
                 "tenant" => "ordinary",
                 "createdByCardId" => parent["id"]
               }

        assert two["metadata"]["automation"] == one["metadata"]["automation"]
        assert_rows(context, before, first, done, [two])
        assert done["metadata"]["automation"]["createdCardIds"] == [two["id"]]
        assert Enum.map(done["metadata"]["links"], & &1["targetCardId"]) == [one["id"], two["id"]]
        %{parent: done, children: [one, two], views: views(context, [done, one, two])}
      end)

    written = Task.await(caller, 30_000)
    refute Process.alive?(caller.pid)
    reader = Task.async(fn -> views(context, [written.parent | written.children]) end)
    assert Task.await(reader, 30_000) == written.views
    refute Process.alive?(reader.pid)
    assert caller.pid != reader.pid
  end

  defp decompose(context, previous, args, summary, new_links) do
    before = snapshot(context)
    assert {:ok, sequence} = Store.notification_sequence(before, deadline())
    lower = System.system_time(:millisecond)

    assert {:ok, result} =
             execute(writer(context), "decompose", Map.put(args, "id", previous["id"]))

    upper = System.system_time(:millisecond)
    assert Enum.sort(Map.keys(result)) == ["children", "parent"]
    actual = result["parent"]
    children = result["children"]
    assert length(children) == length(args["children"])
    ids = Enum.map(children, &uuid(&1["id"]))
    old_links = Map.get(previous["metadata"], "links", [])
    links = actual["metadata"]["links"]
    assert Enum.take(links, length(old_links)) == old_links
    added_links = Enum.drop(links, length(old_links))
    assert length(added_links) == new_links

    Enum.each(added_links, fn link ->
      assert_link(link, "child", link["targetCardId"])
      assert link["targetCardId"] in ids
      assert link["createdAt"] >= lower and link["createdAt"] <= upper
    end)

    for child <- children do
      assert Enum.count(links, &(&1["type"] == "child" and &1["targetCardId"] == child["id"])) ==
               1

      assert Enum.count(
               child["metadata"]["links"],
               &(&1["type"] == "parent" and &1["targetCardId"] == previous["id"])
             ) == 1

      assert item(snapshot(context), child["id"]).record.payload == child
    end

    complete = args["completeParent"] != false

    status =
      if complete,
        do: "done",
        else:
          if(previous["status"] in ["triage", "backlog"], do: "todo", else: previous["status"])

    intermediate_kind =
      cond do
        status != previous["status"] -> "moved"
        complete and summary != nil -> "comment_added"
        complete -> "notification"
        true -> "edited"
      end

    suffix = Enum.drop(actual["events"], length(previous["events"]))
    assert length(suffix) == new_links + 2

    {expected_events, _} =
      Enum.map_reduce(Enum.with_index(suffix), previous["updatedAt"], fn {public, index}, prior ->
        kind =
          cond do
            index < new_links -> "link_added"
            index == new_links -> intermediate_kind
            true -> "decomposed"
          end

        event = public_event(public, kind, prior)

        event =
          if kind == "moved",
            do: Map.merge(event, %{"fromStatus" => previous["status"], "toStatus" => status}),
            else: event

        assert public == event
        {event, event["at"]}
      end)

    middle = Enum.at(expected_events, new_links)
    final = List.last(expected_events)
    assert final["at"] == actual["updatedAt"]
    metadata = Map.put(previous["metadata"], "links", links)
    automation = Map.put(metadata["automation"], "createdCardIds", ids)
    automation = if summary, do: Map.put(automation, "summary", summary), else: automation
    metadata = Map.put(metadata, "automation", automation)

    metadata =
      if complete do
        notification = List.last(actual["metadata"]["notifications"])
        raw = notification["createdAt"]
        assert is_integer(raw) and raw >= lower and raw <= upper

        assert notification == %{
                 "id" => uuid(notification["id"]),
                 "kind" => "completed",
                 "createdAt" => raw,
                 "sequence" => max(sequence + 1, raw * 1000),
                 "message" => summary || "Workboard card completed."
               }

        assert Store.notification_sequence(snapshot(context), deadline()) ==
                 {:ok, notification["sequence"]}

        metadata =
          Map.put(
            metadata,
            "notifications",
            Map.get(metadata, "notifications", []) ++ [notification]
          )

        if summary do
          comment = List.last(actual["metadata"]["comments"])
          assert comment == %{"id" => uuid(comment["id"]), "body" => summary, "createdAt" => raw}
          Map.put(metadata, "comments", Map.get(metadata, "comments", []) ++ [comment])
        else
          metadata
        end
      else
        assert Store.notification_sequence(snapshot(context), deadline()) == {:ok, sequence}
        metadata
      end

    expected =
      previous
      |> Map.put("status", status)
      |> Map.put("updatedAt", final["at"])
      |> Map.put("events", previous["events"] ++ expected_events)
      |> Map.put("metadata", metadata)

    expected =
      if complete,
        do: Map.put(expected, "completedAt", previous["completedAt"] || middle["at"]),
        else: Map.delete(expected, "completedAt")

    assert actual == expected
    assert Store.notification_sequence(before, deadline()) == {:ok, sequence}
    {expected, children}
  end

  defp assert_new_child(child, parent, title, slug, tenant, key, position, fields, hints) do
    [created, linked] = child["events"]
    at = child["createdAt"]
    assert is_integer(at) and at > 0

    assert created == %{
             "id" => uuid(created["id"]),
             "kind" => "created",
             "at" => at,
             "toStatus" => "todo"
           }

    assert linked == public_event(linked, "link_added", at)
    [link] = child["metadata"]["links"]
    assert_link(link, "parent", parent["id"])
    assert link["createdAt"] == at

    automation =
      Map.merge(
        %{"boardId" => slug, "tenant" => tenant, "createdByCardId" => parent["id"]},
        hints
      )

    automation = if key, do: Map.put(automation, "idempotencyKey", key), else: automation

    expected =
      Map.merge(
        %{
          "id" => uuid(child["id"]),
          "title" => title,
          "status" => "todo",
          "priority" => "normal",
          "labels" => [],
          "position" => position,
          "createdAt" => at,
          "updatedAt" => linked["at"],
          "events" => [created, linked],
          "metadata" => %{"links" => [link], "automation" => automation}
        },
        fields
      )

    assert child == expected
  end

  defp assert_rows(context, before, previous, parent, children) do
    current = snapshot(context)
    old = item(before, previous["id"])
    fresh = item(current, parent["id"])
    added = Enum.drop(parent["events"], length(previous["events"]))
    revision = fresh.storage_revision

    assert fresh == %{
             record: %{
               old.record
               | revision: old.record.revision + length(added),
                 payload: parent
             },
             storage_revision: revision
           }

    assert fresh.record.provenance == @creator
    assert item(before, previous["id"]) == old
    old_events = events(before, previous["id"])
    new_events = events(current, parent["id"])
    assert Enum.take(new_events, length(old_events)) == old_events

    for event <- added do
      stored = Enum.find(new_events, &(&1.record.id == event["id"]))

      assert stored.record == %{
               schema_version: 1,
               id: event["id"],
               scope: context.scope,
               item_id: parent["id"],
               board_id: old.record.board_id,
               kind: storage_kind(event["kind"]),
               payload: event,
               provenance: @writer
             }
    end

    assert List.last(new_events).storage_revision == revision
    # Every parent stage is independently acknowledged. Full retained history is
    # readable at its own revision; the final forced patch changes only event/time.
    old_history = history(context, parent["id"])

    assert Enum.take(old_history, length(old_history) - length(added))
           |> List.last()
           |> Map.fetch!(:value) == old.record

    assert length(old_history) == length(parent["events"])

    Enum.each(old_history, fn row ->
      assert {:ok, value} =
               KV.get(record_key(context, parent["id"]),
                 engine: :turso,
                 revision: row.mod_revision,
                 timeout: 5000
               )

      assert value == row.value
    end)

    penultimate = Enum.at(old_history, -2)

    assert penultimate.value == %{
             fresh.record
             | revision: fresh.record.revision - 1,
               payload: %{
                 parent
                 | "events" => Enum.drop(parent["events"], -1),
                   "updatedAt" => Enum.at(parent["events"], -2)["at"]
               }
           }

    assert List.last(old_history).value == fresh.record
    assert List.last(old_history).mod_revision == revision
    assert marker(context).mod_revision == revision

    for card <- [parent | children] do
      row = item(current, card["id"])
      assert row.record.payload == card
      assert row.record.provenance in [@creator, @writer]

      unless card["id"] == parent["id"] do
        {prior_revision, prior_events, creator} =
          case Store.get_item(before, card["id"], deadline()) do
            :not_found ->
              {0, [], @writer}

            {:ok, prior} ->
              {prior.record.revision, prior.record.payload["events"], prior.record.provenance}
          end

        assert row.record == %{
                 schema_version: 1,
                 id: card["id"],
                 scope: context.scope,
                 board_id: row.record.board_id,
                 board_slug: card["metadata"]["automation"]["boardId"],
                 revision: prior_revision + length(card["events"]) - length(prior_events),
                 payload: card,
                 provenance: creator
               }

        for public <- Enum.drop(card["events"], length(prior_events)) do
          stored = Enum.find(events(current, card["id"]), &(&1.record.id == public["id"]))

          assert stored.record == %{
                   schema_version: 1,
                   id: public["id"],
                   scope: context.scope,
                   item_id: card["id"],
                   board_id: row.record.board_id,
                   kind: storage_kind(public["kind"]),
                   payload: public,
                   provenance: @writer
                 }
        end
      end

      for board_id <- [nil, row.record.board_id] do
        assert Enum.find(projections(current, board_id), &(&1.record.id == card["id"])) ==
                 %{
                   record: %{
                     schema_version: 1,
                     id: card["id"],
                     scope: context.scope,
                     board_id: row.record.board_id,
                     board_slug: row.record.board_slug,
                     payload: projection(card)
                   },
                   storage_revision: row.storage_revision
                 }
      end
    end

    slugs = Enum.uniq(Enum.map([parent | children], & &1["metadata"]["automation"]["boardId"]))

    for slug <- slugs do
      old_board = board_row(before, slug)
      fresh_board = board_row(current, slug)
      old_count = Enum.count(previous["events"])

      parent_delta =
        if slug == old.record.board_slug, do: length(parent["events"]) - old_count, else: 0

      child_delta =
        Enum.reduce(children, 0, fn child, count ->
          if child["metadata"]["automation"]["boardId"] == slug do
            prior_count =
              case Store.get_item(before, child["id"], deadline()) do
                :not_found -> 0
                {:ok, prior} -> length(prior.record.payload["events"])
              end

            count + length(child["events"]) - prior_count
          else
            count
          end
        end)

      assert fresh_board.record == %{
               old_board.record
               | revision: old_board.record.revision + parent_delta + child_delta
             }

      assert board_row(before, slug) == old_board
    end

    for entry <- Map.get(previous["metadata"], "attachments", []) do
      assert Store.get_attachment(current, entry["id"], deadline()) ==
               Store.get_attachment(before, entry["id"], deadline())
    end

    if key = current_key(previous) do
      assert Store.lookup_create_key_candidates(current, key, deadline()) ==
               Store.lookup_create_key_candidates(before, key, deadline())
    end
  end

  defp assert_keys(context, values) do
    for {tenant, slug, key, child} <- values do
      assert {:ok, %{ids: ids, storage_revision: revision}} =
               Store.lookup_create_key_candidates(
                 snapshot(context),
                 {tenant, slug, key},
                 deadline()
               )

      assert ids == [child["id"]]
      assert revision < item(snapshot(context), child["id"]).storage_revision
    end
  end

  defp attach(context, parent) do
    assert {:ok, %{"card" => card}} =
             execute(context, "attachment_add", %{
               "id" => parent["id"],
               "fileName" => "Retained 雪.txt",
               "mimeType" => "text/plain",
               "contentBase64" => "6Zuq8J+YgAo="
             })

    [entry] = card["metadata"]["attachments"]

    assert {:ok, %{record: blob}} =
             Store.get_attachment(snapshot(context), entry["id"], deadline())

    assert blob.payload == %{
             "version" => 1,
             "attachment" => entry,
             "contentBase64" => "6Zuq8J+YgAo="
           }

    assert blob.provenance == @creator
    card
  end

  defp views(context, cards) do
    point = snapshot(context)

    reads =
      Map.new(cards, fn card ->
        assert {:ok, %{"card" => actual} = result} =
                 execute(context, "read", %{"id" => card["id"]})

        assert actual == card
        {card["id"], result}
      end)

    assert {:ok, listed} = execute(context, "list", %{"boardId" => "alpha"})
    assert {:ok, boards} = execute(context, "boards", %{})

    %{
      reads: reads,
      listed: listed,
      boards: boards,
      projections: projections(point, nil),
      items: Map.new(cards, &{&1["id"], item(point, &1["id"])}),
      events: Map.new(cards, &{&1["id"], events(point, &1["id"])}),
      histories: Map.new(cards, &{&1["id"], history(context, &1["id"])}),
      sequence: Store.notification_sequence(point, deadline()),
      marker: marker(context),
      attachments:
        for(
          card <- cards,
          entry <- Map.get(card["metadata"], "attachments", []),
          do: Store.get_attachment(point, entry["id"], deadline())
        )
    }
  end

  defp public_event(event, kind, prior) do
    at = event["at"]
    assert is_integer(at) and at > prior
    %{"id" => uuid(event["id"]), "kind" => kind, "at" => at}
  end

  defp assert_link(link, type, id) do
    assert is_integer(link["createdAt"]) and link["createdAt"] > 0

    assert link == %{
             "id" => uuid(link["id"]),
             "type" => type,
             "targetCardId" => id,
             "createdAt" => link["createdAt"]
           }
  end

  defp projection(card) do
    base =
      Map.take(card, ~w(id title status priority agentId updatedAt position createdAt))
      |> Map.put("boardId", card["metadata"]["automation"]["boardId"])

    base =
      if tenant = card["metadata"]["automation"]["tenant"],
        do: Map.put(base, "tenant", tenant),
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

  defp create(context, slug, title, status, extra) do
    assert {:ok, %{"card" => card}} =
             execute(
               context,
               "create",
               Map.merge(%{"title" => title, "boardId" => slug, "status" => status}, extra)
             )

    card
  end

  defp board(context, slug) do
    assert {:ok, %{"board" => board}} =
             execute(context, "board_create", %{"id" => slug, "name" => String.capitalize(slug)})

    board
  end

  defp snapshot(context) do
    assert {:ok, point} = Store.snapshot(context.scope, deadline())
    point
  end

  defp item(point, id) do
    assert {:ok, row} = Store.get_item(point, id, deadline())
    row
  end

  defp board_row(point, slug) do
    assert {:ok, row} = Store.get_board(point, slug, deadline())
    row
  end

  defp events(point, id) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.events_page(point, id, [limit: 100], deadline())

    Enum.sort_by(rows, &{&1.storage_revision, &1.record.payload["at"]})
  end

  defp projections(point, board_id) do
    opts = if board_id, do: [board_id: board_id, limit: 100], else: [limit: 100]
    assert {:ok, %{rows: rows, next_cursor: nil}} = Store.items_page(point, opts, deadline())
    Enum.sort_by(rows, & &1.record.id)
  end

  defp history(context, id) do
    assert {:ok, rows} =
             KV.history(record_key(context, id), engine: :turso, limit: 100, timeout: 5000)

    Enum.sort_by(rows, & &1.mod_revision)
  end

  defp marker(context) do
    assert {:ok, record} =
             KV.get(prefix(context) <> "control/mutation_frontier",
               engine: :turso,
               metadata: true,
               timeout: 5000
             )

    record
  end

  defp prefix(context),
    do: "coord/workboard/v1/scopes/" <> Base.url_encode64(context.scope, padding: false) <> "/"

  defp record_key(context, id), do: prefix(context) <> "records/" <> id

  defp current_key(card) do
    a = card["metadata"]["automation"]
    if a["idempotencyKey"], do: {a["tenant"], a["boardId"], a["idempotencyKey"]}
  end

  defp uuid(value) do
    assert {:ok, ^value} = Ecto.UUID.cast(value)

    assert String.match?(
             value,
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
           )

    value
  end

  defp storage_kind("comment_added"), do: :commented
  defp storage_kind(kind), do: String.to_existing_atom(kind)
  defp writer(context), do: %{context | provenance: @writer}

  defp execute(context, action, args),
    do: apply(Synapsis.Workboard, :execute, [action, args, context, deadline()])

  defp deadline, do: System.monotonic_time(:millisecond) + 5000
end
