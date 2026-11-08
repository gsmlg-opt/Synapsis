defmodule Synapsis.Workboard do
  @moduledoc """
  Explicit-scope ordinary Workboard records on the existing Data-owned store.

  Callers supply scope and complete JSON provenance. Boards must already exist
  before card creation; listing boards never synthesizes an implicit default.
  Board archive/restore changes metadata only and can upsert an explicit named board.
  Empty ordinary board deletion removes its metadata and directly matching subscriptions.
  This component does not expose native tools or choose public sharing policy.
  Specify can change explicit board/tenant and atomically maintains current-key membership.
  Stats reads all current cards, including archived ones, at the same snapshot.
  Internal move accepts source-domain status/position and retains the same board;
  it supports scheduled timestamps and ordinary dependency links without claim/execution state.
  Claim, heartbeat, release and completion retain explicit-scope internal identity.
  Claim fences full namespace occupancy; completion advances a durable notification highwater.
  Notification subscriptions retain snapshot reads and fence nonempty cursor advances.
  Execution/attempt finishing and public/native consumers remain outside this boundary.
  Promote changes todo to ready with optional reason and diagnostic/stale cleanup.
  Reads use revision-pinned snapshots and one capped five-second deadline.
  Create refreshes its same-owner snapshot between acknowledged parent links.
  Decompose composes ordered child create/link and parent completion or open updates;
  every successful call appends a separate forced decomposed event.
  Inventory bounds apply after decoding, not to allocation itself.
  """

  alias Synapsis.Workboard.{Records, Store}

  @inventory_limit 32 * 1024 * 1024

  @spec execute(String.t(), map(), map(), integer()) :: {:ok, map()} | {:error, term()}
  def execute(action, args, %{scope: scope, provenance: provenance}, deadline)
      when is_binary(scope) and byte_size(scope) > 0 and is_integer(deadline) do
    with true <- Records.json_map?(provenance),
         {:ok, input} <- Records.normalize(action, args),
         deadline = min(deadline, monotonic_now() + 5_000),
         :ok <- remaining(deadline),
         {:ok, snapshot} <- Store.snapshot(scope, deadline) do
      operate(action, input, %{
        scope: scope,
        provenance: provenance,
        snapshot: snapshot,
        deadline: deadline
      })
    else
      false -> {:error, :invalid_provenance}
      error -> error
    end
  end

  def execute(_, _, _, _), do: {:error, :invalid_context}

  defp operate(action, input, context) when action in ["board_create", "board_archive"] do
    case Store.get_board(context.snapshot, input["id"], context.deadline) do
      :not_found -> publish_board(input, nil, context)
      {:ok, %{record: board}} -> publish_board(input, board, context)
      error -> error
    end
  end

  defp operate("board_delete", input, context) do
    slug = input["id"]

    with {:ok, cards} <- inventory(:items, context),
         false <- Enum.any?(cards, &(&1.record.board_slug == slug)),
         {:ok, board} <- board_delete_target(context, slug),
         {:ok, rows} <- inventory(:subscriptions, context) do
      subscriptions =
        rows
        |> Enum.map(& &1.record)
        |> Enum.filter(&(&1.payload["boardId"] == slug))

      if is_nil(board) and subscriptions == [] do
        with :ok <- remaining(context.deadline), do: {:ok, %{"deleted" => false}}
      else
        change = %{slug: slug, board: board, subscriptions: subscriptions}
        metadata_present = not is_nil(board) and Map.has_key?(board.payload, "createdAt")

        case Store.commit_board_delete(context.snapshot, change, context.deadline) do
          {:ok, _ack} -> {:ok, %{"deleted" => metadata_present}}
          error -> error
        end
      end
    else
      true -> {:error, :board_not_empty}
      error -> error
    end
  end

  defp operate("boards", _input, context) do
    with {:ok, boards} <- inventory(:boards, context),
         {:ok, cards} <- inventory(:items, context),
         result =
           boards
           |> Enum.filter(fn row ->
             Map.has_key?(row.record.payload, "createdAt") or
               Enum.any?(cards, &(&1.record.board_id == row.record.id))
           end)
           |> Enum.map(
             &Records.board_summary(
               &1.record.payload,
               Enum.map(cards, fn row -> row.record.payload end)
             )
           )
           |> Records.sort_boards(),
         :ok <- remaining(context.deadline) do
      {:ok, %{"boards" => result}}
    end
  end

  defp operate("create", input, context) do
    slug = input["automation"]["boardId"]

    with {:ok, %{record: board}} <- require_board(context, slug) do
      key = create_key(input)

      case lookup_current_card(context, key) do
        {:ok, card} ->
          {:ok, %{"card" => card}}

        :not_found ->
          with :ok <- validate_create_parents(input["parents"], context) do
            create_card(input, board, key, context)
          end

        error ->
          error
      end
    end
  end

  defp operate("list", input, context) do
    with {:ok, rows} <- inventory(:items, context),
         cards =
           rows
           |> Enum.map(& &1.record.payload)
           |> Records.sort()
           |> Records.filter(input)
           |> Enum.take(input["limit"])
           |> Enum.map(&Records.public_projection/1),
         :ok <- remaining(context.deadline) do
      {:ok, %{"cards" => cards}}
    end
  end

  defp operate("stats", input, context) do
    now = System.system_time(:millisecond)

    with {:ok, rows} <- inventory(:items, context),
         result = Records.stats(Enum.map(rows, & &1.record.payload), input["boardId"], now),
         :ok <- remaining(context.deadline) do
      {:ok, result}
    end
  end

  defp operate("read", input, context) do
    with {:ok, %{record: item}} <- require_item(context, input["id"]),
         {:ok, recent} <- recent_done(item.payload, context),
         {:ok, parents} <- parent_results(item.payload, context),
         worker_context =
           Records.worker_context(item.payload, recent, System.system_time(:millisecond), parents),
         :ok <- remaining(context.deadline) do
      {:ok, %{"card" => item.payload, "workerContext" => worker_context}}
    end
  end

  defp operate("comment", input, context) do
    with {:ok, %{record: item}} <- require_item(context, input["id"]),
         {:ok, %{record: board}} <- require_board(context, item.board_slug) do
      card =
        Records.comment(
          item.payload,
          input["body"],
          Ecto.UUID.generate(),
          Ecto.UUID.generate(),
          System.system_time(:millisecond)
        )

      event = List.last(card["events"])

      publish_item(
        :comment,
        %{item | revision: item.revision + 1, payload: card},
        board,
        event,
        nil,
        context
      )
    end
  end

  defp operate("attachment_read", input, context) do
    with {:ok, %{record: attachment}} <- require_attachment(context, input["id"]),
         do: {:ok, attachment.payload}
  end

  defp operate("attachment_add", input, context) do
    with {:ok, %{record: item}} <- require_item(context, input["id"]),
         {:ok, %{record: board}} <- require_board(context, item.board_slug),
         id = Ecto.UUID.generate(),
         {:ok, card, payload} <-
           Records.attachment_add(
             item.payload,
             input,
             id,
             Ecto.UUID.generate(),
             System.system_time(:millisecond),
             System.system_time(:millisecond)
           ) do
      attachment = %{
        schema_version: 1,
        id: id,
        scope: context.scope,
        item_id: item.id,
        payload: payload,
        provenance: context.provenance
      }

      publish_attachment(:attachment_add, item, card, board, attachment, context)
    end
  end

  defp operate("attachment_delete", input, context) do
    with {:ok, %{record: item}} <- require_item(context, input["id"]),
         {:ok, %{record: board}} <- require_board(context, item.board_slug),
         {:ok, %{record: attachment}} <- require_attachment(context, input["attachmentId"]),
         true <- attachment.item_id == item.id,
         {:ok, card} <-
           Records.attachment_delete(
             item.payload,
             attachment.id,
             Ecto.UUID.generate(),
             System.system_time(:millisecond)
           ) do
      publish_attachment(:attachment_delete, item, card, board, attachment, context)
    else
      false -> {:error, :invalid_attachment}
      error -> error
    end
  end

  defp operate("proof", input, context) do
    with {:ok, %{record: item}} <- require_item(context, input["id"]),
         {:ok, %{record: board}} <- require_board(context, item.board_slug),
         proof_id = Ecto.UUID.generate(),
         {:ok, card} <-
           Records.proof(
             item.payload,
             input,
             proof_id,
             Ecto.UUID.generate(),
             Ecto.UUID.generate(),
             System.system_time(:millisecond),
             System.system_time(:millisecond)
           ),
         {:ok, result} <-
           publish_item(
             :proof,
             %{item | revision: item.revision + 1, payload: card},
             board,
             List.last(card["events"]),
             nil,
             context
           ) do
      {:ok, Map.put(result, "proofId", proof_id)}
    end
  end

  defp operate("specify", input, context) do
    with {:ok, %{record: item}} <- require_item(context, input["id"]),
         {:ok, %{record: source}} <- require_board(context, item.board_slug),
         event_now = System.system_time(:millisecond),
         {:ok, card} <-
           Records.specify(
             item.payload,
             input,
             Ecto.UUID.generate(),
             Ecto.UUID.generate(),
             event_now,
             System.system_time(:millisecond)
           ),
         slug = get_in(card, ["metadata", "automation", "boardId"]),
         {:ok, board} <- specify_board(context, source, slug) do
      event = List.last(card["events"])
      source_next = %{source | revision: source.revision + 1}

      board_next =
        if board.id == source.id, do: source_next, else: %{board | revision: board.revision + 1}

      next = %{
        item
        | revision: item.revision + 1,
          board_id: board.id,
          board_slug: board.slug,
          payload: card
      }

      change = %{
        kind: :specify,
        source_board: source_next,
        board: board_next,
        item: next,
        event: %{
          schema_version: 1,
          id: event["id"],
          scope: context.scope,
          item_id: item.id,
          board_id: board.id,
          kind: :specified,
          payload: event,
          provenance: context.provenance
        },
        projection: Records.projection(card),
        previous_create_key: card_create_key(item.payload),
        create_key: card_create_key(card)
      }

      with {:ok, detached} <- detached_attachments(item.payload, card, context) do
        case Store.commit_specify(context.snapshot, change, context.deadline, detached) do
          {:ok, _ack} -> {:ok, %{"card" => card}}
          error -> error
        end
      end
    end
  end

  defp operate("move", input, context) do
    with {:ok, %{record: item}} <- require_item(context, input["id"]),
         {:ok, %{record: board}} <- require_board(context, item.board_slug),
         {:ok, dependencies, read_ids} <-
           read_dependencies(Records.parent_ids(item.payload), context),
         {:ok, card} <-
           Records.move(
             item.payload,
             input,
             Ecto.UUID.generate(),
             System.system_time(:millisecond)
           ),
         :ok <- move_dependencies(item.payload, card, dependencies) do
      publish_item(
        :move,
        %{item | revision: item.revision + 1, payload: card},
        board,
        List.last(card["events"]),
        nil,
        context,
        read_ids
      )
    end
  end

  defp operate("link", input, context) do
    link_cards(input["parentId"], input["childId"], System.system_time(:millisecond), context)
  end

  defp operate("promote", input, context) do
    with {:ok, %{record: item}} <- require_item(context, input["id"]),
         {:ok, %{record: board}} <- require_board(context, item.board_slug),
         {:ok, dependencies, read_ids} <-
           read_dependencies(
             if(input["force"], do: [], else: Records.parent_ids(item.payload)),
             context
           ),
         {:ok, card} <-
           Records.promote(
             item.payload,
             input,
             Ecto.UUID.generate(),
             Ecto.UUID.generate(),
             System.system_time(:millisecond),
             System.system_time(:millisecond)
           ),
         :ok <-
           if(input["force"], do: :ok, else: move_dependencies(item.payload, card, dependencies)) do
      publish_item(
        :promote,
        %{item | revision: item.revision + 1, payload: card},
        board,
        List.last(card["events"]),
        nil,
        context,
        read_ids
      )
    end
  end

  defp operate("claim", input, context) do
    now = System.system_time(:millisecond)
    input = Map.put_new(input, "token", Ecto.UUID.generate())

    with {:ok, context} <- claim_dependency_promotion(input["id"], now, context),
         {:ok, %{record: item}} <- require_item(context, input["id"]),
         {:ok, %{record: board}} <- require_board(context, item.board_slug),
         {:ok, dependencies, read_ids} <-
           read_dependencies(Records.parent_ids(item.payload), context),
         {:ok, card} <-
           Records.claim(
             item.payload,
             input,
             Ecto.UUID.generate(),
             now,
             System.system_time(:millisecond),
             parents_done?(Records.parent_ids(item.payload), dependencies)
           ),
         {:ok, cards} <- full_inventory(context),
         :ok <- Records.owner_available(cards, item.id, input["ownerId"], now),
         {:ok, result} <- publish_workflow(:claim, item, card, board, read_ids, nil, context) do
      {:ok, Map.put(result, "token", input["token"])}
    end
  end

  defp operate("heartbeat", input, context) do
    with {:ok, %{record: item}} <- require_item(context, input["id"]),
         {:ok, %{record: board}} <- require_board(context, item.board_slug),
         {:ok, card} <-
           Records.heartbeat(
             item.payload,
             input,
             Ecto.UUID.generate(),
             Ecto.UUID.generate(),
             System.system_time(:millisecond),
             System.system_time(:millisecond)
           ) do
      publish_workflow(:heartbeat, item, card, board, [], nil, context)
    end
  end

  defp operate("release", input, context) do
    with {:ok, %{record: item}} <- require_item(context, input["id"]),
         {:ok, %{record: board}} <- require_board(context, item.board_slug),
         {:ok, dependencies, read_ids} <-
           read_dependencies(
             if(Map.has_key?(input, "status"), do: Records.parent_ids(item.payload), else: []),
             context
           ),
         {:ok, card} <-
           Records.release(
             item.payload,
             input,
             Ecto.UUID.generate(),
             System.system_time(:millisecond)
           ),
         :ok <-
           if(Map.has_key?(input, "status"),
             do: move_dependencies(item.payload, card, dependencies),
             else: :ok
           ) do
      publish_workflow(:release, item, card, board, read_ids, nil, context)
    end
  end

  defp operate("complete", input, context) do
    with {:ok, %{record: item}} <- require_item(context, input["id"]),
         {:ok, %{record: board}} <- require_board(context, item.board_slug),
         now = System.system_time(:millisecond),
         {:ok, created_ids} <- Records.created_card_ids(input),
         {:ok, dependencies, read_ids} <-
           read_dependencies(Enum.uniq(Records.parent_ids(item.payload) ++ created_ids), context),
         :ok <- validate_created_cards(item.payload, created_ids, dependencies),
         {:ok, previous_sequence} <-
           Store.notification_sequence(context.snapshot, context.deadline),
         sequence = Records.next_notification_sequence(previous_sequence, now),
         ids = %{
           proof: Ecto.UUID.generate(),
           comment: Ecto.UUID.generate(),
           notification: Ecto.UUID.generate(),
           event: Ecto.UUID.generate(),
           artifacts:
             Enum.map(if(is_list(input["artifacts"]), do: input["artifacts"], else: []), fn _ ->
               Ecto.UUID.generate()
             end)
         },
         {:ok, card} <-
           Records.complete(
             item.payload,
             input,
             ids,
             now,
             System.system_time(:millisecond),
             sequence
           ),
         :ok <- move_dependencies(item.payload, card, dependencies) do
      publish_workflow(:complete, item, card, board, read_ids, sequence, context)
    end
  end

  defp operate("decompose", input, context) do
    with {:ok, %{record: parent}} <- require_item(context, input["id"]),
         :ok <- Records.validate_decompose_parent(parent.payload, input),
         {:ok, children, next_context} <-
           decompose_children(input["children"], parent.payload, context, [], 1),
         {:ok, summary} <- Records.decompose_summary(input),
         {:ok, %{"card" => updated}} <-
           finalize_decomposition(input, summary, children, next_context),
         {:ok, final_context} <- refresh_decomposition(next_context),
         {:ok, %{"card" => decomposed}} <-
           publish_decomposed(updated, final_context) do
      {:ok, %{"parent" => decomposed, "children" => children}}
    end
  end

  defp operate("notify_subscribe", input, context) do
    id = Ecto.UUID.generate()
    subscription = Records.notification_subscription(input, id, System.system_time(:millisecond))

    envelope = %{
      schema_version: 1,
      id: id,
      scope: context.scope,
      revision: 1,
      payload: subscription,
      provenance: context.provenance
    }

    case Store.commit_subscription(
           context.snapshot,
           %{kind: :create, subscription: envelope},
           context.deadline
         ) do
      {:ok, _ack} -> {:ok, %{"subscription" => subscription}}
      error -> error
    end
  end

  defp operate("notify_list", input, context) do
    with {:ok, rows} <- inventory(:subscriptions, context),
         subscriptions =
           rows
           |> Enum.map(& &1.record.payload)
           |> Records.notification_subscriptions(input),
         :ok <- remaining(context.deadline) do
      {:ok, %{"subscriptions" => subscriptions}}
    end
  end

  defp operate("notify_events", input, context) do
    with {:ok, result, _subscription} <- notification_result(input, context), do: {:ok, result}
  end

  defp operate("notify_advance", input, context) do
    with {:ok, result, subscription} <- notification_result(input, context) do
      case result["events"] do
        [] ->
          {:ok, result}

        events ->
          payload =
            Records.advance_notification_subscription(
              subscription.payload,
              events,
              System.system_time(:millisecond)
            )

          next = %{subscription | revision: subscription.revision + 1, payload: payload}

          case Store.commit_subscription(
                 context.snapshot,
                 %{kind: :advance, subscription: next},
                 context.deadline
               ) do
            {:ok, _ack} -> {:ok, %{"subscription" => payload, "events" => events}}
            error -> error
          end
      end
    end
  end

  defp operate("notify_unsubscribe", input, context) do
    case lookup_subscription(input["id"], context) do
      :not_found ->
        {:ok, %{"deleted" => false}}

      {:ok, %{record: subscription}} ->
        case Store.commit_subscription(
               context.snapshot,
               %{kind: :delete, subscription: subscription},
               context.deadline
             ) do
          {:ok, _ack} -> {:ok, %{"deleted" => true}}
          error -> error
        end

      error ->
        error
    end
  end

  # Keep validation and writes in source order. Earlier acknowledgements remain
  # durable if a later child, summary or parent stage cannot complete.
  defp decompose_children([], _parent, context, children, _index),
    do: {:ok, children, context}

  defp decompose_children([child | rest], parent, context, children, index) do
    with {:ok, normalized} <- Records.decompose_child(parent, child, index),
         {:ok, %{"card" => created}} <- operate("create", normalized, context),
         {:ok, next_context} <- refresh_decomposition(context),
         {:ok, linked, linked_context} <-
           ensure_decomposition_link(parent["id"], created, next_context) do
      decompose_children(rest, parent, linked_context, children ++ [linked], index + 1)
    end
  end

  defp ensure_decomposition_link(parent_id, child, context) do
    if parent_id in Records.parent_ids(child) do
      {:ok, child, context}
    else
      with {:ok, %{"card" => linked}} <-
             link_cards(parent_id, child["id"], System.system_time(:millisecond), context, true),
           {:ok, next_context} <- refresh_decomposition(context) do
        {:ok, linked, next_context}
      end
    end
  end

  defp refresh_decomposition(context) do
    with {:ok, snapshot} <- Store.refresh_snapshot(context.snapshot, context.deadline),
         do: {:ok, %{context | snapshot: snapshot}}
  end

  defp finalize_decomposition(input, summary, children, context) do
    created_ids = Enum.map(children, & &1["id"])

    if input["completeParent"] !== false do
      completion =
        input
        |> Map.take(~w(id ownerId token))
        |> Map.put("summary", summary)
        |> Map.put("createdCardIds", created_ids)

      operate("complete", completion, context)
    else
      with {:ok, %{record: item}} <- require_item(context, input["id"]),
           {:ok, %{record: board}} <- require_board(context, item.board_slug),
           {:ok, dependencies, read_ids} <-
             read_dependencies(Records.parent_ids(item.payload), context),
           {:ok, card} <-
             Records.decompose_open(
               item.payload,
               summary,
               created_ids,
               Ecto.UUID.generate(),
               System.system_time(:millisecond)
             ),
           :ok <- move_dependencies(item.payload, card, dependencies) do
        publish_item(
          :decompose,
          %{item | revision: item.revision + 1, payload: card},
          board,
          List.last(card["events"]),
          nil,
          context,
          read_ids
        )
      end
    end
  end

  defp publish_decomposed(updated, context) do
    with {:ok, %{record: item}} <- require_item(context, updated["id"]),
         {:ok, %{record: board}} <- require_board(context, item.board_slug),
         {:ok, card} <-
           Records.decomposed(
             item.payload,
             updated["updatedAt"],
             Ecto.UUID.generate(),
             System.system_time(:millisecond)
           ) do
      publish_item(
        :decompose,
        %{item | revision: item.revision + 1, payload: card},
        board,
        List.last(card["events"]),
        nil,
        context
      )
    end
  end

  defp notification_result(input, context) do
    with {:ok, subscription} <- selected_subscription(input["subscriptionId"], context),
         payload = if(subscription, do: subscription.payload),
         {card_id, board_id} = Records.notification_selection(input, payload),
         {:ok, cards} <- notification_cards(card_id, board_id, context),
         events = Records.notification_events(cards, input, payload),
         :ok <- remaining(context.deadline) do
      result =
        if subscription,
          do: %{"subscription" => payload, "events" => events},
          else: %{"events" => events}

      {:ok, result, subscription}
    end
  end

  defp selected_subscription(nil, _context), do: {:ok, nil}

  defp selected_subscription(id, context) do
    case lookup_subscription(id, context) do
      {:ok, %{record: subscription}} ->
        if :erlang.external_size(subscription) <= @inventory_limit,
          do: {:ok, subscription},
          else: {:error, :payload_too_large}

      :not_found ->
        {:error, :notification_subscription_not_found}

      error ->
        error
    end
  end

  defp lookup_subscription(id, context) do
    if canonical_id?(id),
      do: Store.get_subscription(context.snapshot, id, context.deadline),
      else: :not_found
  end

  defp notification_cards(nil, board_id, context), do: full_inventory(context, board_id)

  defp notification_cards(id, _board_id, context) do
    if canonical_id?(id) do
      case Store.get_item(context.snapshot, id, context.deadline) do
        {:ok, %{record: item}} ->
          if :erlang.external_size(item) <= @inventory_limit,
            do: {:ok, [item.payload]},
            else: {:error, :payload_too_large}

        :not_found ->
          {:ok, []}

        error ->
          error
      end
    else
      {:ok, []}
    end
  end

  defp canonical_id?(id) when is_binary(id), do: match?({:ok, ^id}, Ecto.UUID.cast(id))
  defp canonical_id?(_), do: false

  # Promotion is an acknowledged source-visible write before admission. Refresh
  # only after that write, retaining the same owner and operation deadline.
  defp claim_dependency_promotion(id, claim_now, context) do
    with {:ok, %{record: item}} <- require_item(context, id),
         {:ok, dependencies, read_ids} <-
           read_dependencies(Records.parent_ids(item.payload), context),
         status =
           if(get_in(item.payload, ["metadata", "archivedAt"]) not in [nil, false, 0, ""],
             do: item.payload["status"],
             else:
               Records.dependency_status(
                 item.payload,
                 parents_done?(Records.parent_ids(item.payload), dependencies),
                 claim_now
               )
           ) do
      if status == item.payload["status"] do
        {:ok, context}
      else
        with {:ok, %{record: board}} <- require_board(context, item.board_slug),
             {:ok, card} <-
               Records.move(
                 item.payload,
                 %{"status" => status},
                 Ecto.UUID.generate(),
                 System.system_time(:millisecond)
               ),
             {:ok, _} <-
               publish_item(
                 :move,
                 %{item | revision: item.revision + 1, payload: card},
                 board,
                 List.last(card["events"]),
                 nil,
                 context,
                 read_ids
               ),
             {:ok, snapshot} <- Store.refresh_snapshot(context.snapshot, context.deadline) do
          {:ok, %{context | snapshot: snapshot}}
        end
      end
    end
  end

  defp validate_created_cards(card, ids, records) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case records[id] do
        nil ->
          {:halt, {:error, {:invalid_input, "created card not found: " <> id}}}

        %{payload: child} ->
          if id in Records.child_ids(card) and card["id"] in Records.parent_ids(child),
            do: {:cont, :ok},
            else:
              {:halt,
               {:error, {:invalid_input, "created card is not linked to this card: " <> id}}}
      end
    end)
  end

  defp publish_workflow(kind, item, card, board, read_ids, sequence, context) do
    public = List.last(card["events"])

    event_kind =
      case public["kind"] do
        "moved" -> :moved
        "claimed" -> :claimed
        "heartbeat" -> :heartbeat
        "comment_added" -> :commented
        "proof_added" -> :proof_added
        "artifact_added" -> :artifact_added
        # Imported non-dependency-link trimming remains outside the closed workflow.
        "link_added" -> :link_added
        "diagnostic" -> :diagnostic
        "notification" -> :notification
        "edited" -> :edited
      end

    with {:ok, detached} <- detached_attachments(item.payload, card, context) do
      change = %{
        kind: kind,
        board: %{board | revision: board.revision + 1},
        item: %{item | revision: item.revision + 1, payload: card},
        event: %{
          schema_version: 1,
          id: public["id"],
          scope: context.scope,
          item_id: item.id,
          board_id: board.id,
          kind: event_kind,
          payload: public,
          provenance: context.provenance
        },
        projection: Records.projection(card),
        detached: detached,
        read_item_ids: read_ids,
        notification_sequence: sequence
      }

      case Store.commit_workflow(context.snapshot, change, context.deadline) do
        {:ok, _ack} -> {:ok, %{"card" => card}}
        error -> error
      end
    end
  end

  defp full_inventory(context, board_id \\ nil) do
    with {:ok, rows} <- inventory(:items, context) do
      selected = Enum.filter(rows, &(is_nil(board_id) or &1.record.board_slug == board_id))

      Enum.reduce_while(selected, {:ok, [], :erlang.external_size(rows)}, fn row,
                                                                             {:ok, cards, bytes} ->
        with {:ok, %{record: item}} <- require_item(context, row.record.id),
             total = bytes + :erlang.external_size(item),
             true <- total <= @inventory_limit do
          {:cont, {:ok, [item.payload | cards], total}}
        else
          false -> {:halt, {:error, :payload_too_large}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, cards, _bytes} -> {:ok, Enum.reverse(cards)}
        error -> error
      end
    end
  end

  # Source performs separate parent, child and optional readiness writes. The
  # host publishes the same ordered stages through one Data-owned fenced commit.
  defp link_cards(parent_id, child_id, created_at, context, allow_status_only \\ false) do
    with {:ok, %{record: parent}} <- require_item(context, parent_id),
         {:ok, %{record: child}} <- require_item(context, child_id),
         {:ok, %{record: parent_board}} <- require_board(context, parent.board_slug),
         {:ok, %{record: child_board}} <- require_board(context, child.board_slug),
         {:ok, records, read_ids} <- read_dependencies([parent_id, child_id], context, true),
         parent_ids = Enum.uniq(Records.parent_ids(child.payload) ++ [parent_id]),
         all_done = parents_done?(parent_ids, records),
         :ok <-
           Records.validate_link(
             parent.payload,
             child.payload,
             all_done,
             depends_on?(parent_id, child_id, records, MapSet.new()),
             allow_status_only
           ),
         {:ok, parent_card} <-
           Records.dependency_metadata(
             parent.payload,
             child_id,
             "child",
             Ecto.UUID.generate(),
             Ecto.UUID.generate(),
             created_at,
             System.system_time(:millisecond)
           ),
         {:ok, child_card} <-
           Records.dependency_metadata(
             child.payload,
             parent_id,
             "parent",
             Ecto.UUID.generate(),
             Ecto.UUID.generate(),
             created_at,
             System.system_time(:millisecond)
           ),
         {:ok, readiness} <- dependency_readiness(child_card, all_done),
         stages =
           [
             {:parent_metadata, parent, parent_card},
             {:child_metadata, child, child_card}
           ] ++
             if(readiness,
               do: [
                 {:child_readiness, %{child | revision: child.revision + 1, payload: child_card},
                  readiness}
               ],
               else: []
             ),
         {:ok, changes} <-
           link_stages(
             stages,
             %{parent_board.id => parent_board, child_board.id => child_board},
             context
           ),
         change = %{
           kind: :link,
           parent_id: parent_id,
           child_id: child_id,
           read_item_ids: read_ids,
           stages: changes
         } do
      case Store.commit_link(context.snapshot, change, context.deadline) do
        {:ok, _ack} -> {:ok, %{"card" => readiness || child_card}}
        error -> error
      end
    end
  end

  defp dependency_readiness(card, all_done) do
    status = Records.dependency_status(card, all_done, System.system_time(:millisecond))

    if status == card["status"] do
      {:ok, nil}
    else
      Records.move(
        card,
        %{"status" => status},
        Ecto.UUID.generate(),
        System.system_time(:millisecond)
      )
    end
  end

  defp link_stages(stages, boards, context) do
    Enum.reduce_while(stages, {:ok, [], boards}, fn {role, item, card}, {:ok, changes, boards} ->
      board = Map.fetch!(boards, item.board_id)
      next_board = %{board | revision: board.revision + 1}
      event = List.last(card["events"])

      with {:ok, detached} <- detached_attachments(item.payload, card, context) do
        stage = %{
          role: role,
          board: next_board,
          item: %{item | revision: item.revision + 1, payload: card},
          event: %{
            schema_version: 1,
            id: event["id"],
            scope: context.scope,
            item_id: item.id,
            board_id: board.id,
            kind: link_event_kind(event),
            payload: event,
            provenance: context.provenance
          },
          projection: Records.projection(card),
          detached: detached
        }

        {:cont, {:ok, changes ++ [stage], Map.put(boards, board.id, next_board)}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, changes, _boards} -> {:ok, changes}
      error -> error
    end
  end

  defp link_event_kind(%{"kind" => "link_added"}), do: :link_added
  defp link_event_kind(%{"kind" => "edited"}), do: :edited
  defp link_event_kind(%{"kind" => "moved"}), do: :moved

  defp specify_board(_context, source, slug) when source.slug == slug, do: {:ok, source}

  defp specify_board(context, _source, slug) do
    case Store.get_board(context.snapshot, slug, context.deadline) do
      {:ok, %{record: board}} ->
        {:ok, board}

      :not_found ->
        {:ok,
         %{
           schema_version: 1,
           id: Ecto.UUID.generate(),
           scope: context.scope,
           slug: slug,
           revision: 0,
           payload: %{"id" => slug},
           provenance: context.provenance
         }}

      error ->
        error
    end
  end

  defp publish_board(input, previous, context) do
    now = System.system_time(:millisecond)

    board =
      if previous do
        %{
          previous
          | revision: previous.revision + 1,
            payload: Records.board_payload(input, previous.payload, now)
        }
      else
        %{
          schema_version: 1,
          id: Ecto.UUID.generate(),
          scope: context.scope,
          slug: input["id"],
          revision: 1,
          payload: Records.board_payload(input, nil, now),
          provenance: context.provenance
        }
      end

    # Preserve an acknowledged dispatched commit even if its deadline just elapsed.
    case Store.commit_board(context.snapshot, board, context.deadline) do
      {:ok, _ack} -> {:ok, %{"board" => board.payload}}
      error -> error
    end
  end

  defp create_card(input, board, key, context) do
    now = System.system_time(:millisecond)
    input = Map.put(input, "status", Records.creation_status(input, now))

    with {:ok, rows} <- inventory(:items, context),
         :ok <- remaining(context.deadline) do
      max_position =
        Enum.reduce(rows, 0, fn row, maximum ->
          card = row.record.payload

          if card["status"] == input["status"] and row.record.board_id == board.id,
            do: max(maximum, card["position"]),
            else: maximum
        end)

      id = Ecto.UUID.generate()

      card =
        Records.card(
          input,
          id,
          Ecto.UUID.generate(),
          max_position + 1000,
          now
        )

      item = %{
        schema_version: 1,
        id: id,
        scope: context.scope,
        board_id: board.id,
        board_slug: board.slug,
        revision: 1,
        payload: card,
        provenance: context.provenance
      }

      with {:ok, %{"card" => created}} <-
             publish_item(:create, item, board, List.last(card["events"]), key, context) do
        create_parent_links(input["parents"], created, now, context)
      end
    end
  end

  defp create_parent_links([], card, _now, _context), do: {:ok, %{"card" => card}}

  defp create_parent_links([parent_id | rest], card, now, context) do
    with {:ok, snapshot} <- Store.refresh_snapshot(context.snapshot, context.deadline),
         next_context = %{context | snapshot: snapshot},
         {:ok, %{"card" => linked}} <- link_cards(parent_id, card["id"], now, next_context) do
      create_parent_links(rest, linked, now, next_context)
    end
  end

  defp validate_create_parents(parent_ids, context) do
    Enum.reduce_while(parent_ids, :ok, fn id, :ok ->
      with {:ok, %{record: item}} <- require_item(context, id),
           :ok <- Records.validate_parent(item.payload) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp publish_item(kind, item, board, public_event, key, context, read_ids \\ []) do
    event = %{
      schema_version: 1,
      id: public_event["id"],
      scope: context.scope,
      item_id: item.id,
      board_id: board.id,
      kind: event_kind(kind, public_event),
      payload: public_event,
      provenance: context.provenance
    }

    change = %{
      kind: kind,
      board: %{board | revision: board.revision + 1},
      item: item,
      event: event,
      projection: Records.projection(item.payload),
      create_key: key
    }

    with {:ok, previous} <- previous_card(kind, item, context),
         {:ok, detached} <- detached_attachments(previous, item.payload, context) do
      case Store.commit_item(context.snapshot, change, context.deadline, detached, read_ids) do
        {:ok, _ack} -> {:ok, %{"card" => item.payload}}
        error -> error
      end
    end
  end

  defp previous_card(:create, _item, _context), do: {:ok, %{}}

  defp previous_card(_kind, item, context) do
    with {:ok, %{record: previous}} <- require_item(context, item.id), do: {:ok, previous.payload}
  end

  defp publish_attachment(kind, item, card, board, attachment, context) do
    public = List.last(card["events"])

    event = %{
      schema_version: 1,
      id: public["id"],
      scope: context.scope,
      item_id: item.id,
      board_id: board.id,
      kind: if(public["kind"] == "attachment_added", do: :attachment_added, else: :edited),
      payload: public,
      provenance: context.provenance
    }

    change = %{
      kind: kind,
      board: %{board | revision: board.revision + 1},
      item: %{item | revision: item.revision + 1, payload: card},
      event: event,
      projection: Records.projection(card),
      attachment: attachment
    }

    with {:ok, detached} <- detached_attachments(item.payload, card, context) do
      case Store.commit_attachment(context.snapshot, change, context.deadline, detached) do
        {:ok, _ack} -> {:ok, %{"card" => card}}
        error -> error
      end
    end
  end

  defp detached_attachments(previous, next, context) do
    retained = MapSet.new(Enum.map(get_in(next, ["metadata", "attachments"]) || [], & &1["id"]))

    (get_in(previous, ["metadata", "attachments"]) || [])
    |> Enum.reject(&MapSet.member?(retained, &1["id"]))
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, records} ->
      case Store.get_attachment(context.snapshot, entry["id"], context.deadline) do
        {:ok, %{record: record}} -> {:cont, {:ok, records ++ [record]}}
        :not_found -> {:cont, {:ok, records}}
        error -> {:halt, error}
      end
    end)
  end

  defp require_attachment(context, id) do
    case Store.get_attachment(context.snapshot, id, context.deadline) do
      :not_found -> {:error, :attachment_not_found}
      result -> result
    end
  end

  defp event_kind(:create, _), do: :created
  defp event_kind(:comment, _), do: :commented
  defp event_kind(:proof, _), do: :proof_added
  defp event_kind(:promote, _), do: :moved
  defp event_kind(:move, %{"kind" => "moved"}), do: :moved
  defp event_kind(:move, %{"kind" => "edited"}), do: :edited
  defp event_kind(:decompose, %{"kind" => "moved"}), do: :moved
  defp event_kind(:decompose, %{"kind" => "edited"}), do: :edited
  defp event_kind(:decompose, %{"kind" => "decomposed"}), do: :decomposed

  defp move_dependencies(card, next, records) do
    status = next["status"]

    if status in ~w(ready running review done) and
         not parents_done?(Records.parent_ids(card), records),
       do: {:error, {:invalid_input, "card dependencies are not done"}},
       else: :ok
  end

  defp parents_done?(ids, records) do
    Enum.all?(ids, fn id ->
      case Map.get(records, id) do
        %{payload: %{"status" => "done"}} -> true
        _ -> false
      end
    end)
  end

  defp depends_on?(id, target, records, seen) do
    cond do
      id == target ->
        true

      MapSet.member?(seen, id) ->
        false

      is_nil(records[id]) ->
        false

      true ->
        seen = MapSet.put(seen, id)

        Enum.any?(
          Records.parent_ids(records[id].payload),
          &depends_on?(&1, target, records, seen)
        )
    end
  end

  # Full records are read at one snapshot; missing referenced IDs remain in the
  # fence rather than being treated as completed dependencies.
  defp read_dependencies(ids, context, walk \\ false),
    do: read_dependencies(ids, context, walk, %{}, [], 0)

  defp read_dependencies([], _context, _walk, records, ids, _bytes), do: {:ok, records, ids}

  defp read_dependencies([id | rest], context, walk, records, ids, bytes) do
    if Map.has_key?(records, id) do
      read_dependencies(rest, context, walk, records, ids, bytes)
    else
      case Store.get_item(context.snapshot, id, context.deadline) do
        {:ok, %{record: item}} ->
          next_bytes = bytes + :erlang.external_size(item) + :erlang.external_size(id)
          next = if walk, do: rest ++ Records.parent_ids(item.payload), else: rest

          if next_bytes <= @inventory_limit,
            do:
              read_dependencies(
                next,
                context,
                walk,
                Map.put(records, id, item),
                ids ++ [id],
                next_bytes
              ),
            else: {:error, :payload_too_large}

        :not_found ->
          next_bytes = bytes + :erlang.external_size(id)

          if next_bytes <= @inventory_limit,
            do:
              read_dependencies(
                rest,
                context,
                walk,
                Map.put(records, id, nil),
                ids ++ [id],
                next_bytes
              ),
            else: {:error, :payload_too_large}

        error ->
          error
      end
    end
  end

  defp parent_results(card, context) do
    with {:ok, records, _ids} <- read_dependencies(Records.parent_ids(card), context) do
      parents =
        Records.parent_ids(card)
        |> Enum.flat_map(fn id ->
          case records[id] do
            %{payload: payload} -> [payload]
            nil -> []
          end
        end)

      {:ok, parents}
    end
  end

  defp recent_done(%{"agentId" => agent} = card, context) do
    with {:ok, rows} <- inventory(:items, context) do
      matches =
        rows
        |> Enum.map(& &1.record.payload)
        |> Records.sort()
        |> Enum.filter(
          &(&1["id"] != card["id"] and
              &1["boardId"] == get_in(card, ["metadata", "automation", "boardId"]) and
              &1["agentId"] == agent and &1["status"] == "done")
        )
        |> Enum.sort_by(& &1["updatedAt"], :desc)
        |> Enum.take(5)

      Enum.reduce_while(matches, {:ok, []}, fn projection, {:ok, cards} ->
        case require_item(context, projection["id"]) do
          {:ok, %{record: item}} -> {:cont, {:ok, cards ++ [item.payload]}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp recent_done(_, _), do: {:ok, []}

  defp lookup_current_card(_context, nil), do: :not_found

  defp lookup_current_card(context, key) do
    with {:ok, %{ids: ids}} <-
           Store.lookup_create_key_candidates(context.snapshot, key, context.deadline),
         true <- :erlang.external_size(ids) <= @inventory_limit,
         {:ok, cards, _bytes} <-
           Enum.reduce_while(ids, {:ok, [], 0}, fn id, {:ok, cards, bytes} ->
             with {:ok, %{record: item}} <- require_item(context, id),
                  true <- card_create_key(item.payload) == key,
                  total = bytes + :erlang.external_size(item.payload),
                  true <- total <= @inventory_limit do
               {:cont, {:ok, [item.payload | cards], total}}
             else
               false -> {:halt, {:error, :invalid_or_oversized_key_membership}}
               error -> {:halt, error}
             end
           end),
         :ok <- remaining(context.deadline) do
      # Candidate IDs are canonical UUID order. Stable source sorting then retains
      # the original SQLite id tiebreak after status, position and createdAt.
      {:ok, cards |> Enum.reverse() |> Records.sort() |> hd()}
    else
      false -> {:error, :payload_too_large}
      result -> result
    end
  end

  defp card_create_key(card),
    do: create_key(%{"automation" => get_in(card, ["metadata", "automation"]) || %{}})

  defp create_key(input) do
    automation = input["automation"]

    if automation["idempotencyKey"],
      do: {automation["tenant"], automation["boardId"], automation["idempotencyKey"]}
  end

  defp board_delete_target(context, slug) do
    case Store.get_board(context.snapshot, slug, context.deadline) do
      :not_found ->
        {:ok, nil}

      {:ok, %{record: %{payload: %{"kind" => "sessions"}}}} ->
        {:error, :sessions_board_unsupported}

      {:ok, %{record: board}} ->
        {:ok, board}

      error ->
        error
    end
  end

  defp require_board(context, slug) do
    case Store.get_board(context.snapshot, slug, context.deadline) do
      :not_found -> {:error, :board_not_found}
      result -> result
    end
  end

  defp require_item(context, id) do
    case Store.get_item(context.snapshot, id, context.deadline) do
      :not_found -> {:error, :card_not_found}
      result -> result
    end
  end

  defp inventory(kind, context), do: inventory(kind, context, nil, [], 0)

  defp inventory(kind, context, cursor, rows, bytes) do
    with :ok <- remaining(context.deadline),
         opts = [limit: 100, cursor: cursor],
         {:ok, page} <-
           (case kind do
              :boards -> Store.boards_page(context.snapshot, opts, context.deadline)
              :items -> Store.items_page(context.snapshot, opts, context.deadline)
              :subscriptions -> Store.subscriptions_page(context.snapshot, opts, context.deadline)
            end),
         next_bytes = bytes + :erlang.external_size(page.rows),
         true <- next_bytes <= @inventory_limit do
      next_rows = [page.rows | rows]

      if page.next_cursor do
        inventory(kind, context, page.next_cursor, next_rows, next_bytes)
      else
        {:ok, next_rows |> Enum.reverse() |> List.flatten()}
      end
    else
      false -> {:error, :payload_too_large}
      error -> error
    end
  end

  defp monotonic_now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: if(monotonic_now() < deadline, do: :ok, else: {:error, :timeout})
end
