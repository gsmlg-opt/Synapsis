defmodule Synapsis.Workboard.StatsFunctionalTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Synapsis.Workboard.Store

  @epoch 1_700_000_000_000
  @creator %{
    "sessionId" => "37900000-0000-4000-8000-000000000001",
    "agentId" => "37900000-0000-4000-8000-000000000002",
    "runId" => "fixture:workboard379:create",
    "incarnation" => 9,
    "invocationId" => "fixture:workboard379:invoke-create",
    "toolCallId" => "fixture:workboard379:call-create",
    "extra" => %{"ordinary" => [nil, true, false, 1.25, "café 雪 😀"]}
  }
  @reader %{
    "sessionId" => "37900000-0000-4000-8000-000000000011",
    "agentId" => "37900000-0000-4000-8000-000000000012",
    "runId" => "fixture:workboard379:read",
    "incarnation" => 10,
    "invocationId" => "fixture:workboard379:invoke-stats",
    "toolCallId" => "fixture:workboard379:call-stats",
    "extra" => %{"supplied" => ["read 雪😀", false, nil]}
  }

  # Independent expectations: OpenClaw 488631c tools-orchestration.ts
  # workboard_stats; store-core.ts stats; store-normalizers.ts normalizeBoardId;
  # sqlite-store-kernel.ts listStatsAggregates and sqlite-store-records.ts
  # stringValue. No stats product candidate was read. Data.commit_item below
  # supplies valid source-domain cards whose archive/clocks/empty assignee cannot
  # currently be produced through Core. These are fixture facts, not a claim
  # that Core implements card archival or native/model execution.
  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()

    %{
      context: %{
        scope: "fixture:workboard379/opaque:雪/" <> Ecto.UUID.generate(),
        provenance: @creator
      }
    }
  end

  test "all-card status and assignee totals retain card archive splits and ignore board metadata clocks",
       %{context: context} do
    board(context, "ops")
    board(context, "delivery")
    seed(context, "ops", "ready", @epoch + 4_000, %{"agentId" => "agent-a"})

    seed(context, "ops", "ready", @epoch + 1_000, %{
      "agentId" => "agent-a",
      "archivedAt" => @epoch + 3_000
    })

    seed(context, "ops", "todo", @epoch + 8_000, %{})
    seed(context, "ops", "review", @epoch + 6_000, %{"agentId" => "", "archivedAt" => 0})
    seed(context, "delivery", "done", @epoch + 7_000, %{"agentId" => "(default)"})

    seed(context, "delivery", "running", @epoch + 9_000, %{
      "agentId" => "agent-b",
      "archivedAt" => @epoch + 10_000
    })

    old = point(context)

    assert {:ok, %{"board" => archived_board}} =
             execute(context, "board_archive", %{"id" => "ops"})

    assert archived_board["archivedAt"] == archived_board["updatedAt"]
    assert archived_board["updatedAt"] > @epoch + 9_000
    current = point(context)
    assert item_rows(current) == item_rows(old)

    all = %{
      "id" => "all",
      "total" => 6,
      "active" => 4,
      "archived" => 2,
      "byStatus" => %{"ready" => 2, "todo" => 1, "review" => 1, "done" => 1, "running" => 1},
      "byAgent" => %{"agent-a" => 2, "(default)" => 3, "agent-b" => 1},
      "updatedAt" => @epoch + 9_000
    }

    assert_stats(context, %{}, all, @epoch + 4_000)

    assert_stats(
      context,
      %{"boardId" => " OPS "},
      %{
        "id" => "ops",
        "total" => 4,
        "active" => 3,
        "archived" => 1,
        "byStatus" => %{"ready" => 2, "todo" => 1, "review" => 1},
        "byAgent" => %{"agent-a" => 2, "(default)" => 2},
        "updatedAt" => @epoch + 8_000
      },
      @epoch + 4_000
    )

    assert_stats(context, %{"boardId" => "delivery"}, %{
      "id" => "delivery",
      "total" => 2,
      "active" => 1,
      "archived" => 1,
      "byStatus" => %{"done" => 1, "running" => 1},
      "byAgent" => %{"(default)" => 1, "agent-b" => 1},
      "updatedAt" => @epoch + 9_000
    })

    assert item_rows(old) == item_rows(current)
  end

  test "empty and missing named boards stay empty while omitted and blank filters mean all boards",
       %{context: context} do
    assert_stats(context, %{}, empty("all"))
    assert_stats(context, %{"boardId" => " ABSENT "}, empty("absent"))
    assert Store.get_board(point(context), "absent", deadline()) == :not_found
    board(context, "empty")
    assert_stats(context, %{"boardId" => " EMPTY "}, empty("empty"))
    assert_stats(context, %{}, empty("all"))
    board(context, "default")

    assert {:ok, %{"card" => card}} =
             execute(context, "create", %{
               "title" => "Default namespace café 雪😀",
               "boardId" => "default"
             })

    expected = %{
      "id" => "all",
      "total" => 1,
      "active" => 1,
      "archived" => 0,
      "byStatus" => %{"todo" => 1},
      "byAgent" => %{"(default)" => 1},
      "updatedAt" => card["updatedAt"]
    }

    assert_stats(context, %{}, expected)
    assert_stats(context, %{"boardId" => " \t\n "}, expected)
    assert_stats(context, %{"boardId" => " DEFAULT "}, %{expected | "id" => "default"})
    assert_stats(context, %{"boardId" => "empty"}, empty("empty"))
    assert_stats(context, %{"boardId" => "absent"}, empty("absent"))
    assert Store.get_board(point(context), "absent", deadline()) == :not_found
  end

  test "stats composes with specify move comments and the current create-key tuple without changing history",
       %{context: context} do
    board(context, "research")
    board(context, "delivery")

    args = %{
      "title" => "Clarify café 雪😀",
      "status" => "backlog",
      "boardId" => "research",
      "tenant" => "tenant-old",
      "idempotencyKey" => "ordinary-key"
    }

    assert {:ok, %{"card" => original}} = execute(context, "create", args)
    historical = point(context)
    historic_revision = elem(historical, 3)
    historic_records = records(historic_revision)

    assert_stats(context, %{"boardId" => "research"}, %{
      "id" => "research",
      "total" => 1,
      "active" => 1,
      "archived" => 0,
      "byStatus" => %{"backlog" => 1},
      "byAgent" => %{"(default)" => 1},
      "updatedAt" => original["updatedAt"]
    })

    assert {:ok, %{"card" => specified}} =
             execute(context, "specify", %{
               "id" => original["id"],
               "boardId" => " DELIVERY ",
               "tenant" => "tenant-new",
               "agentId" => "reviewer",
               "summary" => "Ready to implement 雪😀"
             })

    assert specified["status"] == "todo"
    assert get_in(specified, ["metadata", "automation", "boardId"]) == "delivery"
    assert get_in(specified, ["metadata", "automation", "tenant"]) == "tenant-new"
    new_key = {"tenant-new", "delivery", "ordinary-key"}

    assert Store.lookup_create_key(
             historical,
             {"tenant-old", "research", "ordinary-key"},
             deadline()
           ) ==
             {:ok, original["id"]}

    assert Store.lookup_create_key(
             point(context),
             {"tenant-old", "research", "ordinary-key"},
             deadline()
           ) == :not_found

    assert {:ok, %{ids: [id], storage_revision: key_revision}} =
             Store.lookup_create_key_candidates(point(context), new_key, deadline())

    assert id == specified["id"]
    assert is_integer(key_revision) and key_revision > 0
    assert_stats(context, %{"boardId" => "research"}, empty("research"))

    base = %{
      "id" => "delivery",
      "total" => 1,
      "active" => 1,
      "archived" => 0,
      "byStatus" => %{"todo" => 1},
      "byAgent" => %{"reviewer" => 1},
      "updatedAt" => specified["updatedAt"]
    }

    assert_stats(context, %{"boardId" => "delivery"}, base)

    assert {:ok, %{"card" => ready}} =
             execute(context, "move", %{"id" => id, "status" => "ready"})

    assert ready["status"] == "ready"

    assert_stats(
      context,
      %{"boardId" => "delivery"},
      %{base | "byStatus" => %{"ready" => 1}, "updatedAt" => ready["updatedAt"]},
      ready["updatedAt"]
    )

    assert {:ok, %{"card" => commented}} =
             execute(context, "comment", %{"id" => id, "body" => "Ordinary progress café 雪😀"})

    assert commented["updatedAt"] > ready["updatedAt"]

    assert_stats(
      context,
      %{},
      %{
        base
        | "id" => "all",
          "byStatus" => %{"ready" => 1},
          "updatedAt" => commented["updatedAt"]
      },
      commented["updatedAt"]
    )

    assert {:ok, %{"card" => done}} =
             execute(context, "move", %{"id" => id, "status" => "done"})

    assert done["status"] == "done"

    assert_stats(context, %{}, %{
      base
      | "id" => "all",
        "byStatus" => %{"done" => 1},
        "updatedAt" => done["updatedAt"]
    })

    before_repeat = facts()

    assert {:ok, %{"card" => ^done}} =
             execute(context, "create", %{
               "title" => "Ignored duplicate",
               "tenant" => "tenant-new",
               "boardId" => "delivery",
               "idempotencyKey" => "ordinary-key"
             })

    assert facts() == before_repeat
    assert records(historic_revision) == historic_records
    assert {:ok, %{record: %{payload: ^original}}} = Store.get_item(historical, id, deadline())

    assert {:ok, %{"card" => ^done, "workerContext" => text}} =
             execute(context, "read", %{"id" => id})

    assert is_binary(text) and String.contains?(text, "Ordinary progress café 雪😀")
  end

  test "future and zero ready clocks and archived-only queues survive normal creator completion and a fresh reader",
       %{context: context} do
    creator =
      Task.async(fn ->
        Enum.each(["future", "epoch", "archived", "zero-mixed"], &board(context, &1))
        future_at = System.system_time(:millisecond) + 86_400_000
        seed(context, "future", "ready", future_at, %{"agentId" => "worker"})
        seed(context, "epoch", "ready", 0, %{"agentId" => "", "archivedAt" => 0})
        seed(context, "archived", "ready", @epoch + 2_000, %{"archivedAt" => @epoch + 3_000})
        seed(context, "zero-mixed", "ready", 0, %{})
        seed(context, "zero-mixed", "ready", @epoch + 4_000, %{})

        expected = [
          {%{"boardId" => "future"},
           %{
             "id" => "future",
             "total" => 1,
             "active" => 1,
             "archived" => 0,
             "byStatus" => %{"ready" => 1},
             "byAgent" => %{"worker" => 1},
             "updatedAt" => future_at,
             "oldestReadyAgeMs" => 0
           }},
          {%{"boardId" => "epoch"},
           %{
             "id" => "epoch",
             "total" => 1,
             "active" => 1,
             "archived" => 0,
             "byStatus" => %{"ready" => 1},
             "byAgent" => %{"(default)" => 1}
           }},
          {%{"boardId" => "archived"},
           %{
             "id" => "archived",
             "total" => 1,
             "active" => 0,
             "archived" => 1,
             "byStatus" => %{"ready" => 1},
             "byAgent" => %{"(default)" => 1},
             "updatedAt" => @epoch + 2_000
           }},
          {%{"boardId" => "zero-mixed"},
           %{
             "id" => "zero-mixed",
             "total" => 2,
             "active" => 2,
             "archived" => 0,
             "byStatus" => %{"ready" => 2},
             "byAgent" => %{"(default)" => 2},
             "updatedAt" => @epoch + 4_000
           }}
        ]

        Enum.each(expected, fn {args, result} -> assert_stats(context, args, result) end)
        %{expected: expected, facts: facts()}
      end)

    written = Task.await(creator, 30_000)
    refute Process.alive?(creator.pid)

    reader =
      Task.async(fn ->
        Enum.each(written.expected, fn {args, result} -> assert_stats(context, args, result) end)
        facts()
      end)

    assert Task.await(reader, 30_000) == written.facts
    refute Process.alive?(reader.pid)
    refute creator.pid == reader.pid
  end

  defp assert_stats(context, args, expected, ready_at \\ nil) do
    before = facts()
    earliest = System.system_time(:millisecond)
    assert {:ok, result} = execute(%{context | provenance: @reader}, "stats", args)
    latest = System.system_time(:millisecond)

    if is_nil(ready_at) do
      assert result == expected
    else
      age = result["oldestReadyAgeMs"]
      assert is_integer(age) and age >= 0
      assert age >= max(0, earliest - ready_at)
      assert age <= max(0, latest - ready_at)
      assert result == Map.put(expected, "oldestReadyAgeMs", age)
    end

    # Global revision plus every current Concord fact and its complete ordinary
    # history detects hidden writes to records, projections, names, events and
    # create-key membership, including a write that restores the same value.
    assert facts() == before
    assert records(before.revision) == before.records
    result
  end

  defp empty(id),
    do: %{
      "id" => id,
      "total" => 0,
      "active" => 0,
      "archived" => 0,
      "byStatus" => %{},
      "byAgent" => %{}
    }

  defp board(context, slug) do
    assert {:ok, %{"board" => board}} =
             execute(context, "board_create", %{"id" => slug, "name" => "Board " <> slug})

    board
  end

  defp seed(context, slug, status, at, extra) do
    snapshot = point(context)
    assert {:ok, %{record: board}} = Store.get_board(snapshot, slug, deadline())
    id = Ecto.UUID.generate()

    event = %{
      "id" => Ecto.UUID.generate(),
      "kind" => "created",
      "at" => @epoch - 100_000,
      "toStatus" => status
    }

    metadata = %{"automation" => %{"boardId" => slug}}

    metadata =
      if Map.has_key?(extra, "archivedAt"),
        do: Map.put(metadata, "archivedAt", extra["archivedAt"]),
        else: metadata

    card = %{
      "id" => id,
      "title" => "Supplied ordinary " <> status <> " café 雪😀",
      "status" => status,
      "priority" => "normal",
      "labels" => [],
      "position" => 1000,
      "createdAt" => @epoch - 100_000,
      "updatedAt" => at,
      "events" => [event],
      "metadata" => metadata
    }

    card =
      if Map.has_key?(extra, "agentId"),
        do: Map.put(card, "agentId", extra["agentId"]),
        else: card

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

    stored_event = %{
      schema_version: 1,
      id: event["id"],
      scope: context.scope,
      item_id: id,
      board_id: board.id,
      kind: :created,
      payload: event,
      provenance: @creator
    }

    projection =
      card
      |> Map.take(~w(id title status priority agentId updatedAt position createdAt))
      |> Map.put("boardId", slug)

    projection =
      if Map.has_key?(extra, "archivedAt"),
        do: Map.put(projection, "archivedAt", extra["archivedAt"]),
        else: projection

    assert {:ok, ack} =
             Store.commit_item(
               snapshot,
               %{
                 kind: :create,
                 board: %{board | revision: board.revision + 1},
                 item: item,
                 event: stored_event,
                 projection: projection,
                 create_key: nil
               },
               deadline()
             )

    assert ack.item == item
    assert ack.event == stored_event

    assert {:ok, %{record: ^item, storage_revision: revision}} =
             Store.get_item(point(context), id, deadline())

    assert revision == ack.storage_revision
    card
  end

  defp facts do
    assert {:ok, revision} = KV.revision(engine: :turso, timeout: 5_000)
    rows = records(revision)

    histories =
      Map.new(rows, fn row ->
        assert {:ok, history} = KV.history(row.key, engine: :turso, limit: 10_000, timeout: 5_000)
        {row.key, history}
      end)

    %{revision: revision, records: rows, histories: histories}
  end

  defp records(revision), do: records(revision, "", [])

  defp records(revision, from, accumulated) do
    assert {:ok, rows, page} =
             KV.list(
               engine: :turso,
               range: {from, <<255>>},
               revision: revision,
               limit: 100,
               timeout: 5_000
             )

    all = accumulated ++ rows
    if page.has_more, do: records(revision, page.last_key <> <<0>>, all), else: all
  end

  defp item_rows(point) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.items_page(point, [limit: 100], deadline())

    Enum.sort_by(rows, & &1.record.id)
  end

  defp point(context) do
    assert {:ok, snapshot} = Store.snapshot(context.scope, deadline())
    snapshot
  end

  defp execute(context, action, args),
    do: apply(Synapsis.Workboard, :execute, [action, args, context, deadline()])

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
