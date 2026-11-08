defmodule Synapsis.Workboard.CoreNotificationFunctionalTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Synapsis.Workboard.Store

  # Independent positive vectors from original OpenClaw 488631c factory/domain
  # and original SQLite card/subscription stores. Source report:
  # /tmp/synapsis-workboard387-source-vm5jiwfp/source-report.json.
  # No product candidate or new Data tests were read. Explicit subscribe board
  # and immutable creator provenance are approved host adaptations. Session/run
  # metadata and mixed historical notifications below are Data fixtures, not
  # claims that Core produces session/run or stale/failure notifications.
  # Only qualified ASCII legacy event IDs exercise source locale ordering.
  @epoch 1_700_000_000_000
  @creator %{
    "runId" => "fixture:387:create",
    "incarnation" => 71,
    "extra" => %{"ordinary" => [nil, true, 1.25, "café 雪😀"]}
  }
  @writer %{
    "runId" => "fixture:387:notify",
    "incarnation" => 72,
    "toolCallId" => "fixture:387:ordinary-call",
    "extra" => %{"supplied" => [false, 2, %{"text" => "雪😀"}]}
  }
  @owner "fixture:387:ordinary-owner"

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()

    %{
      context: %{
        scope: "fixture:387:notifications/雪/" <> Ecto.UUID.generate(),
        provenance: @creator
      }
    }
  end

  test "natural completions feed pure repeated readers, paged advance, a fresh reader and unsubscribe",
       %{context: context} do
    board(context, "alpha")
    first = completed(context, "alpha", "First completed", " First accepted 雪😀 ")
    second = completed(context, "alpha", "Second completed", nil)
    one = List.last(first["metadata"]["notifications"])
    two = List.last(second["metadata"]["notifications"])
    assert one["message"] == "First accepted 雪😀"
    assert two["message"] == "Workboard card completed."
    assert two["sequence"] > one["sequence"]

    {subscription, initial_point} =
      subscribe(context, %{
        "boardId" => " ALPHA ",
        "target" => " Reviewer 雪😀 ",
        "eventKinds" => ["completed", " stale ", "completed"]
      })

    assert subscription["boardId"] == "alpha"
    assert subscription["target"] == "Reviewer 雪😀"
    assert subscription["eventKinds"] == ["completed", "stale"]
    initial_row = subscription_row(initial_point, subscription["id"])
    initial_key = subscription_key(initial_row.record)
    initial_history = history(initial_key)
    assert length(initial_history) == 1
    assert hd(initial_history).value == initial_row.record
    assert hd(initial_history).mod_revision == initial_row.storage_revision

    expected = %{"subscription" => subscription, "events" => [one, two]}

    assert pure(context, "notify_events", %{"subscriptionId" => " " <> subscription["id"] <> " "}) ==
             expected

    assert pure(context, "notify_events", %{"subscriptionId" => subscription["id"]}) == expected
    assert history(initial_key) == initial_history

    {page_one, point_one} = advance(context, subscription, [one], 1)
    assert subscription_row(initial_point, subscription["id"]) == initial_row

    assert pure(context, "notify_events", %{"subscriptionId" => subscription["id"]}) ==
             %{"subscription" => page_one, "events" => [two]}

    {page_two, point_two} = advance(context, page_one, [two], 1)
    assert subscription_row(point_one, subscription["id"]).record.payload == page_one
    assert subscription_row(point_two, subscription["id"]).record.revision == 3

    assert pure(context, "notify_advance", %{"subscriptionId" => subscription["id"]}) ==
             %{"subscription" => page_two, "events" => []}

    third = completed(context, "alpha", "Third after cursor", nil)
    three = List.last(third["metadata"]["notifications"])
    assert three["sequence"] > two["sequence"]

    assert pure(context, "notify_events", %{"subscriptionId" => subscription["id"]}) ==
             %{"subscription" => page_two, "events" => [three]}

    {page_three, current_point} = advance(context, page_two, [three], 50)

    task =
      Task.async(fn ->
        point = snapshot(context)
        row = subscription_row(point, subscription["id"])
        result = pure(context, "notify_events", %{"boardId" => " ALPHA "})
        {row, result}
      end)

    assert {fresh_row, %{"events" => [^one, ^two, ^three]}} = Task.await(task, 5_000)
    refute Process.alive?(task.pid)
    assert fresh_row == subscription_row(current_point, subscription["id"])
    assert fresh_row.record.payload == page_three
    assert fresh_row.record.provenance == @creator

    versions = history(initial_key) |> Enum.sort_by(& &1.mod_revision)

    assert Enum.map(versions, & &1.value.payload) == [
             subscription,
             page_one,
             page_two,
             page_three
           ]

    assert Enum.map(versions, & &1.value.revision) == [1, 2, 3, 4]
    assert Enum.all?(versions, &(&1.value.provenance == @creator))
    assert Enum.all?(versions, &(&1.create_revision == initial_row.storage_revision))

    before_delete = card_facts(context)

    assert {:ok, %{"deleted" => true}} =
             execute(writer(context), "notify_unsubscribe", %{
               "id" => " " <> subscription["id"] <> " "
             })

    deleted_point = snapshot(context)
    assert Store.get_subscription(deleted_point, subscription["id"], deadline()) == :not_found
    assert card_facts(context) == before_delete
    assert subscription_row(current_point, subscription["id"]).record.payload == page_three
    assert pure(context, "notify_list", %{"boardId" => "alpha"}) == %{"subscriptions" => []}

    assert pure(context, "notify_events", %{"boardId" => "alpha"}) == %{
             "events" => [one, two, three]
           }

    deleted_history = history(initial_key) |> Enum.sort_by(& &1.mod_revision)
    assert Enum.drop(deleted_history, -1) == versions
    tombstone = List.last(deleted_history)
    assert tombstone.value == nil and tombstone.version == 0
    assert tombstone.create_revision == initial_row.storage_revision
    assert tombstone.mod_revision > fresh_row.storage_revision
  end

  test "subscription normalization retains all optional metadata without requiring a board record",
       %{context: context} do
    card_id = Ecto.UUID.generate()

    {subscription, point} =
      subscribe(context, %{
        "boardId" => " Explicit-Board ",
        "cardId" => " " <> card_id <> " ",
        "sessionKey" => " agent:fixture-agent:topic ",
        "runId" => " run-ordinary-387 ",
        "target" => " Review target 雪😀 ",
        "eventKinds" => [" stale ", "completed", "stale"]
      })

    assert subscription == %{
             "id" => uuid(subscription["id"]),
             "boardId" => "explicit-board",
             "cardId" => card_id,
             "sessionKey" => "agent:fixture-agent:topic",
             "runId" => "run-ordinary-387",
             "target" => "Review target 雪😀",
             "eventKinds" => ["stale", "completed"],
             "createdAt" => subscription["createdAt"],
             "updatedAt" => subscription["createdAt"]
           }

    assert Store.get_board(point, "explicit-board", deadline()) == :not_found
    assert subscription_row(point, subscription["id"]).record.provenance == @creator
    assert pure(context, "notify_list", %{}) == %{"subscriptions" => [subscription]}

    assert pure(context, "notify_list", %{
             "boardId" => " EXPLICIT-BOARD ",
             "cardId" => " " <> card_id <> " "
           }) ==
             %{"subscriptions" => [subscription]}
  end

  test "mixed same-millisecond stored sequences page in literal source order and clear legacy cursor sequence",
       %{context: context} do
    board(context, "alpha")

    events = [
      notification("legacy-y", @epoch, nil, "Legacy y"),
      notification("seq-z", @epoch, @epoch * 1_000 + 7, "Sequence z"),
      notification("legacy-b", @epoch, nil, "Legacy b"),
      notification("seq-q", @epoch, @epoch * 1_000 + 8, "Sequence q"),
      notification("seq-a", @epoch, @epoch * 1_000 + 7, "Sequence a")
    ]

    seed_card(context, "alpha", events)
    [legacy_y, seq_z, legacy_b, seq_q, seq_a] = events

    {subscription, _point} =
      subscribe(context, %{"boardId" => "alpha", "target" => "Mixed history"})

    assert pure(context, "notify_events", %{"subscriptionId" => subscription["id"]}) ==
             %{
               "subscription" => subscription,
               "events" => [seq_a, seq_z, seq_q, legacy_b, legacy_y]
             }

    {first, _} = advance(context, subscription, [seq_a, seq_z], 2)
    assert first["lastEventSequence"] == @epoch * 1_000 + 7
    {second, _} = advance(context, first, [seq_q, legacy_b], 2)
    refute Map.has_key?(second, "lastEventSequence")
    assert second["lastEventAt"] == @epoch and second["lastEventId"] == "legacy-b"

    assert pure(context, "notify_events", %{"subscriptionId" => subscription["id"]}) ==
             %{"subscription" => second, "events" => [legacy_y]}

    {third, _} = advance(context, second, [legacy_y], 1)
    refute Map.has_key?(third, "lastEventSequence")

    assert pure(context, "notify_advance", %{"subscriptionId" => subscription["id"]}) ==
             %{"subscription" => third, "events" => []}
  end

  test "card selection overrides board selection and target is descriptive metadata only",
       %{context: context} do
    board(context, "alpha")
    board(context, "beta")
    alpha = completed(context, "alpha", "Selected card", nil)
    beta = completed(context, "beta", "Other valid card", nil)
    alpha_event = List.last(alpha["metadata"]["notifications"])
    beta_event = List.last(beta["metadata"]["notifications"])

    {by_card, _} =
      subscribe(context, %{
        "boardId" => "beta",
        "cardId" => " " <> alpha["id"] <> " ",
        "target" => "Named destination"
      })

    assert pure(context, "notify_events", %{
             "subscriptionId" => by_card["id"],
             "boardId" => "beta",
             "cardId" => beta["id"]
           }) ==
             %{"subscription" => by_card, "events" => [alpha_event]}

    assert pure(context, "notify_events", %{
             "boardId" => "beta",
             "cardId" => " " <> alpha["id"] <> " "
           }) ==
             %{"events" => [alpha_event]}

    {target_only, _} =
      subscribe(context, %{"boardId" => "alpha", "target" => "Unrelated descriptive name"})

    assert pure(context, "notify_events", %{"subscriptionId" => target_only["id"]}) ==
             %{"subscription" => target_only, "events" => [alpha_event]}

    assert pure(context, "notify_events", %{"boardId" => " BETA "}) == %{"events" => [beta_event]}

    assert pure(context, "notify_list", %{"cardId" => " " <> alpha["id"] <> " "}) ==
             %{"subscriptions" => [by_card]}
  end

  test "valid stored session and run identities use event fields with card and execution fallback",
       %{context: context} do
    board(context, "alpha")
    session = "agent:fixture-agent:topic"
    run = "run-ordinary-387"
    fallback = notification(Ecto.UUID.generate(), @epoch, @epoch * 1_000, "Card fallback")

    explicit =
      Map.merge(
        notification(Ecto.UUID.generate(), @epoch + 1, (@epoch + 1) * 1_000, "Event identities"),
        %{"sessionKey" => session, "runId" => run}
      )

    other =
      Map.merge(
        notification(
          Ecto.UUID.generate(),
          @epoch + 2,
          (@epoch + 2) * 1_000,
          "Other valid identities"
        ),
        %{"sessionKey" => "agent:fixture-agent:other", "runId" => "run-ordinary-other"}
      )

    seed_card(context, "alpha", [fallback, explicit, other], %{
      "sessionKey" => session,
      "runId" => run
    })

    execution_fallback =
      notification(Ecto.UUID.generate(), @epoch + 3, (@epoch + 3) * 1_000, "Execution fallback")

    seed_card(context, "alpha", [execution_fallback], %{
      "execution" => %{
        "id" => Ecto.UUID.generate(),
        "kind" => "agent-session",
        "mode" => "autonomous",
        "sessionKey" => session,
        "runId" => run,
        "status" => "done",
        "startedAt" => @epoch - 100,
        "updatedAt" => @epoch + 3
      }
    })

    {subscription, _} =
      subscribe(context, %{
        "boardId" => "alpha",
        "sessionKey" => " " <> session <> " ",
        "runId" => " " <> run <> " ",
        "target" => "Identity reader",
        "eventKinds" => ["completed"]
      })

    assert pure(context, "notify_events", %{"subscriptionId" => subscription["id"]}) ==
             %{
               "subscription" => subscription,
               "events" => [fallback, explicit, execution_fallback]
             }

    {advanced, _} = advance(context, subscription, [fallback, explicit, execution_fallback], 50)

    assert pure(context, "notify_events", %{"subscriptionId" => subscription["id"]}) ==
             %{"subscription" => advanced, "events" => []}
  end

  test "multiple persisted subscriptions list in creation and canonical ID order with normalized filters",
       %{context: context} do
    card_id = Ecto.UUID.generate()

    alpha_first =
      seed_subscription(context, "38700000-0000-4000-8000-000000000001", "alpha", @epoch, %{
        "cardId" => card_id,
        "target" => "First"
      })

    beta =
      seed_subscription(context, "38700000-0000-4000-8000-000000000003", "beta", @epoch + 1, %{
        "target" => "Beta"
      })

    alpha_second =
      seed_subscription(context, "38700000-0000-4000-8000-000000000002", "alpha", @epoch, %{
        "target" => "Second"
      })

    assert pure(context, "notify_list", %{}) == %{
             "subscriptions" => [alpha_first, alpha_second, beta]
           }

    assert pure(context, "notify_list", %{"boardId" => " ALPHA "}) == %{
             "subscriptions" => [alpha_first, alpha_second]
           }

    assert pure(context, "notify_list", %{"cardId" => " " <> card_id <> " "}) == %{
             "subscriptions" => [alpha_first]
           }

    assert pure(context, "notify_list", %{"boardId" => "alpha", "cardId" => card_id}) == %{
             "subscriptions" => [alpha_first]
           }

    rows = subscription_rows(snapshot(context))

    assert Enum.sort(Enum.map(rows, & &1.record.id)) ==
             Enum.sort([alpha_first["id"], alpha_second["id"], beta["id"]])
  end

  defp subscribe(context, args) do
    before = card_facts(context)
    lower = System.system_time(:millisecond)

    assert {:ok, %{"subscription" => subscription} = result} =
             execute(context, "notify_subscribe", args)

    upper = System.system_time(:millisecond)
    assert Map.keys(result) == ["subscription"]
    uuid(subscription["id"])
    assert subscription["createdAt"] >= lower and subscription["createdAt"] <= upper
    assert subscription["updatedAt"] == subscription["createdAt"]
    point = snapshot(context)
    row = subscription_row(point, subscription["id"])

    assert row.record == %{
             schema_version: 1,
             id: subscription["id"],
             scope: context.scope,
             revision: 1,
             payload: subscription,
             provenance: @creator
           }

    assert card_facts(context) == before
    {subscription, point}
  end

  defp advance(context, previous, expected_events, limit) do
    old_point = snapshot(context)
    old_row = subscription_row(old_point, previous["id"])
    before = card_facts(context)
    lower = System.system_time(:millisecond)

    assert {:ok, %{"subscription" => actual, "events" => ^expected_events}} =
             execute(writer(context), "notify_advance", %{
               "subscriptionId" => " " <> previous["id"] <> " ",
               "limit" => limit
             })

    upper = System.system_time(:millisecond)
    last = List.last(expected_events)

    expected =
      previous
      |> Map.put("lastEventAt", last["createdAt"])
      |> Map.put("lastEventId", last["id"])
      |> Map.put("updatedAt", actual["updatedAt"])
      |> Map.delete("deliveredEventIds")

    expected =
      if Map.has_key?(last, "sequence"),
        do: Map.put(expected, "lastEventSequence", last["sequence"]),
        else: Map.delete(expected, "lastEventSequence")

    assert actual == expected
    assert actual["updatedAt"] >= lower and actual["updatedAt"] <= upper
    point = snapshot(context)
    row = subscription_row(point, previous["id"])

    assert row.record == %{
             old_row.record
             | revision: old_row.record.revision + 1,
               payload: actual
           }

    assert row.storage_revision > old_row.storage_revision
    assert subscription_row(old_point, previous["id"]) == old_row
    assert card_facts(context) == before
    {actual, point}
  end

  defp pure(context, action, args) do
    point = snapshot(context)
    assert {:ok, revision} = KV.revision(engine: :turso, timeout: 5_000)
    assert {:ok, result} = execute(writer(context), action, args)
    assert snapshot(context) == point
    assert KV.revision(engine: :turso, timeout: 5_000) == {:ok, revision}
    result
  end

  defp card_facts(context) do
    point = snapshot(context)

    assert {:ok, %{rows: boards, next_cursor: nil}} =
             Store.boards_page(point, [limit: 100], deadline())

    assert {:ok, %{rows: projections, next_cursor: nil}} =
             Store.items_page(point, [limit: 100], deadline())

    cards =
      Enum.map(projections, fn row ->
        assert {:ok, item} = Store.get_item(point, row.record.id, deadline())
        assert {:ok, events} = Store.events_page(point, row.record.id, [limit: 100], deadline())
        {item, events}
      end)

    assert {:ok, sequence} = Store.notification_sequence(point, deadline())
    %{boards: boards, projections: projections, cards: cards, sequence: sequence}
  end

  defp completed(context, slug, title, summary) do
    assert {:ok, %{"card" => initial}} =
             execute(context, "create", %{"boardId" => slug, "title" => title})

    assert {:ok, %{"card" => claimed, "token" => token}} =
             execute(writer(context), "claim", %{"id" => initial["id"], "ownerId" => @owner})

    args = %{"id" => initial["id"], "ownerId" => @owner, "token" => token}
    args = if summary, do: Map.put(args, "summary", summary), else: args
    lower = System.system_time(:millisecond)
    assert {:ok, %{"card" => done}} = execute(writer(context), "complete", args)
    upper = System.system_time(:millisecond)
    event = List.last(done["metadata"]["notifications"])
    assert done["status"] == "done"
    assert length(done["events"]) == length(claimed["events"]) + 1

    assert event["kind"] == "completed" and
             event["message"] ==
               if(summary, do: String.trim(summary), else: "Workboard card completed.")

    assert event["createdAt"] >= lower and event["createdAt"] <= upper
    assert is_integer(event["sequence"]) and event["sequence"] >= event["createdAt"] * 1_000
    uuid(event["id"])
    done
  end

  defp seed_card(context, slug, notifications, extra \\ %{}) do
    point = snapshot(context)
    assert {:ok, %{record: board}} = Store.get_board(point, slug, deadline())
    id = Ecto.UUID.generate()

    event = %{
      "id" => Ecto.UUID.generate(),
      "kind" => "created",
      "at" => @epoch - 100,
      "toStatus" => "done"
    }

    card =
      Map.merge(
        %{
          "id" => id,
          "title" => "Supplied completed notification data",
          "status" => "done",
          "priority" => "normal",
          "labels" => [],
          "position" => 1000,
          "createdAt" => @epoch - 100,
          "updatedAt" => @epoch + 10,
          "completedAt" => @epoch + 10,
          "events" => [event],
          "metadata" => %{"automation" => %{"boardId" => slug}, "notifications" => notifications}
        },
        extra
      )

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

    assert {:ok, ack} =
             Store.commit_item(
               point,
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

    assert ack.item == item and ack.event == stored_event

    assert {:ok, %{record: ^item, storage_revision: revision}} =
             Store.get_item(snapshot(context), id, deadline())

    assert revision == ack.storage_revision
    card
  end

  defp seed_subscription(context, id, slug, at, extra) do
    payload =
      Map.merge(%{"id" => id, "boardId" => slug, "createdAt" => at, "updatedAt" => at}, extra)

    envelope = %{
      schema_version: 1,
      id: uuid(id),
      scope: context.scope,
      revision: 1,
      payload: payload,
      provenance: @creator
    }

    assert {:ok, ack} =
             Store.commit_subscription(
               snapshot(context),
               %{kind: :create, subscription: envelope},
               deadline()
             )

    assert Map.keys(ack) |> Enum.sort() == [:storage_revision, :subscription]
    assert ack.subscription == envelope

    assert subscription_row(snapshot(context), id) == %{
             record: envelope,
             storage_revision: ack.storage_revision
           }

    payload
  end

  defp notification(id, at, sequence, message) do
    base = %{"id" => id, "kind" => "completed", "createdAt" => at, "message" => message}
    if sequence, do: Map.put(base, "sequence", sequence), else: base
  end

  defp board(context, slug) do
    assert {:ok, %{"board" => board}} =
             execute(context, "board_create", %{"id" => slug, "name" => String.capitalize(slug)})

    board
  end

  defp subscription_row(point, id) do
    assert {:ok, row} = Store.get_subscription(point, id, deadline())
    row
  end

  defp subscription_rows(point) do
    assert {:ok, %{rows: rows, next_cursor: nil}} =
             Store.subscriptions_page(point, [limit: 100], deadline())

    rows
  end

  defp subscription_key(envelope) do
    assert {:ok, revision} = KV.revision(engine: :turso, timeout: 5_000)

    records(revision, "coord/workboard/v1/", [])
    |> Enum.find(fn row -> row.value == envelope end)
    |> Map.fetch!(:key)
  end

  defp records(revision, from, accumulated) do
    assert {:ok, rows, page} =
             KV.list(
               engine: :turso,
               range: {from, "coord/workboard/v1/" <> <<255>>},
               revision: revision,
               limit: 100,
               timeout: 5_000
             )

    all = accumulated ++ rows
    if page.has_more, do: records(revision, page.last_key <> <<0>>, all), else: all
  end

  defp history(key) do
    assert {:ok, rows} = KV.history(key, engine: :turso, limit: 100, timeout: 5_000)
    rows
  end

  defp snapshot(context) do
    assert {:ok, point} = Store.snapshot(context.scope, deadline())
    point
  end

  defp uuid(id) do
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    id
  end

  defp writer(context), do: %{context | provenance: @writer}

  defp execute(context, action, args),
    do: Synapsis.Workboard.execute(action, args, context, deadline())

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
