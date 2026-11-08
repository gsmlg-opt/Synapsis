defmodule Synapsis.Workboard.CoreBoardDeleteFunctionalTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Synapsis.Workboard.Store

  # Independent positive expectations from original OpenClaw 488631c factory,
  # domain and SQLite board/card/subscription stores. Source evidence:
  # /tmp/synapsis-workboard388-source-u8niog13/source-report.json.
  # No batch388 product candidate or new Data test was read. Explicit scope,
  # UUID board envelopes and an atomic deletion are approved host adaptations.
  # Missing/default/nonempty/Sessions refusal and other excluded cases are not run.
  @creator %{
    "runId" => "fixture:388:create",
    "incarnation" => 81,
    "extra" => %{"ordinary" => [nil, true, 1.5, "café 雪😀"]}
  }
  @writer %{
    "runId" => "fixture:388:delete",
    "incarnation" => 82,
    "toolCallId" => "fixture:388:ordinary-call",
    "extra" => %{"supplied" => [false, 2, "雪😀"]}
  }
  @key {"fixture:388", "beta", "retained-key"}

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()

    %{
      context: %{
        scope: "fixture:388:board-delete/雪/" <> Ecto.UUID.generate(),
        provenance: @creator
      }
    }
  end

  test "delete removes matching board subscriptions, retains cross-board facts and recreates a fresh identity",
       %{context: context} do
    original = board(context, "alpha", "Removable 雪😀", "Original description")
    board(context, "beta", "Retained board")
    retained = completed_retained_card(context)
    one = subscribe(context, "alpha", %{"target" => "First listener 雪😀"})

    two =
      subscribe(context, "alpha", %{
        "cardId" => retained["id"],
        "target" => "Other-board card selector",
        "eventKinds" => ["completed"]
      })

    retained_subscription =
      subscribe(context, "beta", %{
        "cardId" => retained["id"],
        "target" => "Retained listener"
      })

    retained_namespace = subscribe(context, "gamma", %{"target" => "Unrelated namespace"})
    point = snapshot(context)
    old_board = board_row(point, "alpha")
    assert old_board.record.payload == original
    assert old_board.record.provenance == @creator
    before = facts(context)
    assert before.sequence > 0
    assert {:ok, current_key} = Store.lookup_create_key_candidates(point, @key, deadline())
    assert current_key.ids == [retained["id"]]
    selected_ids = [one["id"], two["id"]]
    selected_rows = Enum.filter(before.subscriptions, &(&1.record.id in selected_ids))

    keys =
      [board_key(context, old_board.record.id), name_key(context, "alpha")] ++
        Enum.map(selected_rows, &subscription_key(context, &1.record.id))

    histories = Map.new(keys, &{&1, history(&1)})
    before_marker = marker(context)

    assert {:ok, %{"deleted" => true}} =
             execute(writer(context), "board_delete", %{"id" => " ALPHA "})

    deleted_point = snapshot(context)
    deleted_revision = elem(deleted_point, 3)
    assert deleted_revision > elem(point, 3)

    assert marker(context) == %{
             before_marker
             | mod_revision: deleted_revision,
               version: before_marker.version + 1
           }

    after_facts = facts(context)

    expected =
      before
      |> Map.update!(
        :boards,
        &Enum.reject(&1, fn row -> row.record.id == old_board.record.id end)
      )
      |> Map.update!(
        :subscriptions,
        &Enum.reject(&1, fn row -> row.record.id in selected_ids end)
      )

    assert after_facts == expected
    assert Store.get_board(deleted_point, "alpha", deadline()) == :not_found
    assert board_row(point, "alpha") == old_board

    assert Store.lookup_create_key_candidates(deleted_point, @key, deadline()) ==
             {:ok, current_key}

    for row <- selected_rows do
      assert Store.get_subscription(deleted_point, row.record.id, deadline()) == :not_found
      assert subscription_row(point, row.record.id) == row
    end

    assert Enum.sort(Enum.map(after_facts.subscriptions, & &1.record.id)) ==
             Enum.sort([retained_subscription["id"], retained_namespace["id"]])

    for {key, versions} <- histories, do: assert_deleted_history(key, versions, deleted_revision)
    assert snapshot(context) == deleted_point

    lower = System.system_time(:millisecond)
    recreated = board(writer(context), "alpha", "Fresh name")
    upper = System.system_time(:millisecond)

    assert recreated == %{
             "id" => "alpha",
             "name" => "Fresh name",
             "createdAt" => recreated["createdAt"],
             "updatedAt" => recreated["createdAt"]
           }

    assert recreated["createdAt"] >= lower and recreated["createdAt"] <= upper
    fresh_point = snapshot(context)
    fresh_row = board_row(fresh_point, "alpha")
    uuid(fresh_row.record.id)
    assert fresh_row.record.id != old_board.record.id
    assert fresh_row.record.revision == 1
    assert fresh_row.record.scope == context.scope
    assert fresh_row.record.payload == recreated
    assert fresh_row.record.provenance == @writer
    assert board_row(point, "alpha") == old_board
    assert Store.get_board(deleted_point, "alpha", deadline()) == :not_found

    assert Map.take(facts(context), [
             :projections,
             :cards,
             :attachments,
             :sequence,
             :subscriptions
           ]) ==
             Map.take(expected, [:projections, :cards, :attachments, :sequence, :subscriptions])

    assert raw_record(name_key(context, "alpha")).value == fresh_row.record.id

    assert List.last(history(name_key(context, "alpha"))).mod_revision ==
             fresh_row.storage_revision

    assert List.last(history(board_key(context, old_board.record.id))).value == nil
  end

  test "ordinary empty board deletion with no subscriptions removes its name and metadata in one revision",
       %{context: context} do
    board(context, "solo", "Empty board")
    point = snapshot(context)
    row = board_row(point, "solo")
    before = facts(context)
    assert before.subscriptions == [] and before.cards == [] and before.projections == []
    board_history = history(board_key(context, row.record.id))
    name_history = history(name_key(context, "solo"))
    before_marker = marker(context)

    assert {:ok, %{"deleted" => true}} =
             execute(writer(context), "board_delete", %{"id" => "solo"})

    after_point = snapshot(context)
    revision = elem(after_point, 3)
    assert facts(context) == %{before | boards: []}
    assert Store.get_board(after_point, "solo", deadline()) == :not_found
    assert board_row(point, "solo") == row
    assert marker(context).mod_revision == revision
    assert marker(context).version == before_marker.version + 1
    assert_deleted_history(board_key(context, row.record.id), board_history, revision)
    assert_deleted_history(name_key(context, "solo"), name_history, revision)
    assert pure(context, "boards", %{}) == %{"boards" => []}
    assert snapshot(context) == after_point
  end

  test "existing archived empty board and its single subscription are deleted without touching retained namespace",
       %{context: context} do
    original = board(context, "archived", "Archived removable", "Keep historical metadata")
    board(context, "retained", "Retained empty board")
    selected = subscribe(context, "archived", %{"target" => "Selected listener"})
    retained = subscribe(context, "retained", %{"target" => "Retained listener"})

    assert {:ok, %{"board" => archived}} =
             execute(context, "board_archive", %{"id" => "archived"})

    assert archived["createdAt"] == original["createdAt"]
    assert archived["archivedAt"] == archived["updatedAt"]
    point = snapshot(context)
    row = board_row(point, "archived")
    selected_row = subscription_row(point, selected["id"])
    before = facts(context)

    keys = [
      board_key(context, row.record.id),
      name_key(context, "archived"),
      subscription_key(context, selected["id"])
    ]

    histories = Map.new(keys, &{&1, history(&1)})

    assert {:ok, %{"deleted" => true}} =
             execute(writer(context), "board_delete", %{"id" => " ARCHIVED "})

    after_point = snapshot(context)
    revision = elem(after_point, 3)

    expected =
      before
      |> Map.update!(:boards, &Enum.reject(&1, fn value -> value.record.id == row.record.id end))
      |> Map.update!(
        :subscriptions,
        &Enum.reject(&1, fn value -> value.record.id == selected["id"] end)
      )

    assert facts(context) == expected
    assert Enum.map(expected.subscriptions, & &1.record.id) == [retained["id"]]
    assert board_row(point, "archived") == row
    assert row.record.payload == archived
    assert subscription_row(point, selected["id"]) == selected_row
    assert Store.get_board(after_point, "archived", deadline()) == :not_found
    assert Store.get_subscription(after_point, selected["id"], deadline()) == :not_found
    for {key, versions} <- histories, do: assert_deleted_history(key, versions, revision)
    assert marker(context).mod_revision == revision
    assert snapshot(context) == after_point
  end

  test "normal creator completion leaves acknowledged board and subscription for a distinct reader to delete",
       %{context: context} do
    creator =
      Task.async(fn ->
        payload = board(context, "handoff", "Caller handoff 雪😀")
        subscription = subscribe(context, "handoff", %{"target" => "Handoff listener"})
        point = snapshot(context)

        %{
          payload: payload,
          subscription: subscription,
          point: point,
          board: board_row(point, "handoff"),
          subscription_row: subscription_row(point, subscription["id"])
        }
      end)

    created = Task.await(creator, 5_000)
    refute Process.alive?(creator.pid)

    keys = [
      board_key(context, created.board.record.id),
      name_key(context, "handoff"),
      subscription_key(context, created.subscription["id"])
    ]

    histories = Map.new(keys, &{&1, history(&1)})

    reader =
      Task.async(fn ->
        assert board_row(snapshot(context), "handoff") == created.board

        assert subscription_row(snapshot(context), created.subscription["id"]) ==
                 created.subscription_row

        assert pure(context, "notify_list", %{"boardId" => "handoff"}) == %{
                 "subscriptions" => [created.subscription]
               }

        assert {:ok, %{"deleted" => true}} =
                 execute(writer(context), "board_delete", %{"id" => "handoff"})

        snapshot(context)
      end)

    deleted_point = Task.await(reader, 5_000)
    refute Process.alive?(reader.pid)
    assert creator.pid != reader.pid
    assert Store.get_board(deleted_point, "handoff", deadline()) == :not_found

    assert Store.get_subscription(deleted_point, created.subscription["id"], deadline()) ==
             :not_found

    assert board_row(created.point, "handoff") == created.board
    assert subscription_row(created.point, created.subscription["id"]) == created.subscription_row

    assert facts(context) == %{
             boards: [],
             subscriptions: [],
             projections: [],
             cards: [],
             attachments: [],
             sequence: 0
           }

    for {key, versions} <- histories,
        do: assert_deleted_history(key, versions, elem(deleted_point, 3))

    assert marker(context).mod_revision == elem(deleted_point, 3)
    assert snapshot(context) == deleted_point
  end

  defp board(context, slug, name, description \\ nil) do
    args = %{"id" => slug, "name" => name}
    args = if description, do: Map.put(args, "description", description), else: args
    assert {:ok, %{"board" => board}} = execute(context, "board_create", args)
    board
  end

  defp subscribe(context, slug, extra) do
    assert {:ok, %{"subscription" => subscription}} =
             execute(context, "notify_subscribe", Map.put(extra, "boardId", slug))

    subscription
  end

  defp completed_retained_card(context) do
    assert {:ok, %{"card" => initial}} =
             execute(context, "create", %{
               "title" => "Retained rich card 雪😀",
               "notes" => "Retained body",
               "boardId" => "beta",
               "tenant" => "fixture:388",
               "idempotencyKey" => "retained-key",
               "labels" => ["source", "雪😀"],
               "priority" => "high"
             })

    assert {:ok, %{"card" => _commented}} =
             execute(writer(context), "comment", %{
               "id" => initial["id"],
               "body" => "Retained comment 雪😀"
             })

    content = Base.encode64("Retained café 雪😀\n")

    assert {:ok, %{"card" => attached}} =
             execute(writer(context), "attachment_add", %{
               "id" => initial["id"],
               "fileName" => "Retained 雪😀.txt",
               "contentBase64" => content,
               "mimeType" => "text/plain",
               "note" => "Retained attachment"
             })

    [attachment] = attached["metadata"]["attachments"]

    assert {:ok, %{"contentBase64" => ^content}} =
             execute(context, "attachment_read", %{"id" => attachment["id"]})

    assert {:ok, %{"token" => token}} =
             execute(writer(context), "claim", %{
               "id" => initial["id"],
               "ownerId" => "fixture:388:owner"
             })

    assert {:ok, %{"card" => completed}} =
             execute(writer(context), "complete", %{
               "id" => initial["id"],
               "ownerId" => "fixture:388:owner",
               "token" => token,
               "summary" => "Retained completion 雪😀"
             })

    assert completed["status"] == "done"
    assert List.last(completed["metadata"]["notifications"])["kind"] == "completed"
    completed
  end

  defp facts(context) do
    point = snapshot(context)

    boards =
      pages(fn cursor -> Store.boards_page(point, [limit: 1, cursor: cursor], deadline()) end)

    subscriptions =
      pages(fn cursor ->
        Store.subscriptions_page(point, [limit: 1, cursor: cursor], deadline())
      end)

    projections =
      pages(fn cursor -> Store.items_page(point, [limit: 1, cursor: cursor], deadline()) end)

    cards =
      Enum.map(projections, fn row ->
        assert {:ok, item} = Store.get_item(point, row.record.id, deadline())

        events =
          pages(fn cursor ->
            Store.events_page(point, row.record.id, [limit: 1, cursor: cursor], deadline())
          end)

        {item, events}
      end)

    attachments =
      Enum.flat_map(cards, fn {item, _events} ->
        Enum.map(get_in(item.record.payload, ["metadata", "attachments"]) || [], fn metadata ->
          assert {:ok, attachment} = Store.get_attachment(point, metadata["id"], deadline())
          attachment
        end)
      end)

    assert {:ok, sequence} = Store.notification_sequence(point, deadline())

    %{
      boards: boards,
      subscriptions: subscriptions,
      projections: projections,
      cards: cards,
      attachments: attachments,
      sequence: sequence
    }
  end

  defp pages(read), do: pages(read, nil, [])

  defp pages(read, cursor, accumulated) do
    assert {:ok, page} = read.(cursor)
    next = accumulated ++ page.rows
    if page.next_cursor, do: pages(read, page.next_cursor, next), else: next
  end

  defp assert_deleted_history(key, before, revision) do
    versions = history(key)
    assert Enum.drop(versions, -1) == before
    tombstone = List.last(versions)
    assert tombstone.value == nil and tombstone.version == 0
    assert tombstone.mod_revision == revision
    assert tombstone.create_revision == hd(before).create_revision
  end

  defp board_row(point, slug) do
    assert {:ok, row} = Store.get_board(point, slug, deadline())
    row
  end

  defp subscription_row(point, id) do
    assert {:ok, row} = Store.get_subscription(point, id, deadline())
    row
  end

  defp pure(context, action, args) do
    point = snapshot(context)
    assert {:ok, revision} = KV.revision(engine: :turso, timeout: 5_000)
    assert {:ok, result} = execute(writer(context), action, args)
    assert snapshot(context) == point
    assert KV.revision(engine: :turso, timeout: 5_000) == {:ok, revision}
    result
  end

  defp raw_record(key) do
    assert {:ok, [row], %{has_more: false}} =
             KV.list(prefix: key, limit: 1, keys_only: false, engine: :turso, timeout: 5_000)

    assert row.key == key
    row
  end

  defp history(key) do
    assert {:ok, rows} = KV.history(key, engine: :turso, limit: 100, timeout: 5_000)
    Enum.sort_by(rows, & &1.mod_revision)
  end

  defp marker(context), do: raw_record(prefix(context) <> "control/mutation_frontier")
  defp board_key(context, id), do: prefix(context) <> "boards/" <> id

  defp name_key(context, slug),
    do: prefix(context) <> "names/" <> Base.url_encode64(slug, padding: false)

  defp subscription_key(context, id), do: prefix(context) <> "subscriptions/" <> id

  defp prefix(context),
    do: "coord/workboard/v1/scopes/" <> Base.url_encode64(context.scope, padding: false) <> "/"

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
