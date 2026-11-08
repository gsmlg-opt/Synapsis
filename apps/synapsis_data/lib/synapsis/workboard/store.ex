defmodule Synapsis.Workboard.Store do
  @moduledoc """
  Explicit-scope, revision-pinned Workboard persistence in the existing Concord store.

  Callers supply complete records and projections. This module preserves them
  without choosing sharing, board defaults, normalization or card behavior.
  Each board or item change publishes its related facts in one fenced transaction.

  Snapshots and cursors retain a local file-backed owner and committed revision.
  Every operation shares its absolute monotonic deadline, capped at five seconds.
  Transaction acknowledgements remain successful after that deadline; uncertain
  dispatched outcomes are returned without retrying.
  """

  alias Concord.KV
  alias Concord.KV.Record

  @prefix "coord/workboard/v1/"
  @maximum_timeout 5_000
  @board_keys ~w(schema_version id scope slug revision payload provenance)a
  @board_delete_keys ~w(slug board subscriptions)a
  @item_keys ~w(schema_version id scope board_id board_slug revision payload provenance)a
  @event_keys ~w(schema_version id scope item_id board_id kind payload provenance)a
  @projection_keys ~w(schema_version id scope board_id board_slug payload)a
  @change_keys ~w(kind board item event projection create_key)a
  @specify_keys ~w(kind source_board board item event projection previous_create_key create_key)a
  @attachment_keys ~w(schema_version id scope item_id payload provenance)a
  @attachment_change_keys ~w(kind board item event projection attachment)a
  @link_keys ~w(kind parent_id child_id read_item_ids stages)a
  @link_stage_keys ~w(role board item event projection detached)a
  @subscription_keys ~w(schema_version id scope revision payload provenance)a
  @subscription_change_keys ~w(kind subscription)a
  @workflow_keys ~w(kind board item event projection detached read_item_ids notification_sequence)a
  @membership_limit 32 * 1024 * 1024

  @opaque snapshot :: {:workboard_snapshot, pid(), binary(), non_neg_integer()}

  @spec snapshot(binary(), integer()) :: {:ok, snapshot()} | {:error, term()}
  def snapshot(scope, deadline) do
    with true <- nonempty_binary?(scope),
         {:ok, context} <- capture(deadline),
         {:ok, revision} <- read_revision(context),
         {:ok, _remaining} <- check(context) do
      {:ok, {:workboard_snapshot, context.owner, scope, revision}}
    else
      false -> {:error, :invalid_scope}
      error -> error
    end
  end

  @doc "Refreshes an acknowledged multi-step operation without changing its storage owner."
  @spec refresh_snapshot(snapshot(), integer()) :: {:ok, snapshot()} | {:error, term()}
  def refresh_snapshot(snapshot, deadline) do
    with {:ok, context, scope, _revision} <- snapshot_context(snapshot, deadline),
         {:ok, revision} <- read_revision(context),
         {:ok, _remaining} <- check(context) do
      {:ok, {:workboard_snapshot, context.owner, scope, revision}}
    end
  end

  @spec get_board(snapshot(), binary(), integer()) :: {:ok, map()} | :not_found | {:error, term()}
  def get_board(snapshot, slug, deadline) do
    with {:ok, context, scope, revision} <- snapshot_context(snapshot, deadline),
         true <- nonempty_binary?(slug),
         {:ok, %Record{value: id}} <- read_record(context, name_key(scope, slug), revision),
         true <- canonical_id?(id),
         {:ok, %Record{} = record} <- read_record(context, board_key(scope, id), revision),
         true <-
           valid_board?(record.value) and record.value.scope == scope and
             record.value.id == id and record.value.slug == slug,
         {:ok, _remaining} <- check(context) do
      {:ok, row(record)}
    else
      {:ok, nil} -> :not_found
      false -> {:error, :invalid_record}
      error -> error
    end
  end

  @spec get_item(snapshot(), binary(), integer()) :: {:ok, map()} | :not_found | {:error, term()}
  def get_item(snapshot, id, deadline) do
    with {:ok, context, scope, revision} <- snapshot_context(snapshot, deadline),
         true <- canonical_id?(id),
         {:ok, %Record{} = record} <- read_record(context, item_key(scope, id), revision),
         true <-
           valid_item?(record.value) and record.value.scope == scope and
             record.value.id == id,
         {:ok, _remaining} <- check(context) do
      {:ok, row(record)}
    else
      {:ok, nil} -> :not_found
      false -> {:error, :invalid_record}
      error -> error
    end
  end

  @spec get_attachment(snapshot(), binary(), integer()) ::
          {:ok, map()} | :not_found | {:error, term()}
  def get_attachment(snapshot, id, deadline) do
    with {:ok, context, scope, revision} <- snapshot_context(snapshot, deadline),
         true <- canonical_id?(id),
         {:ok, %Record{} = record} <- read_record(context, attachment_key(scope, id), revision),
         true <-
           valid_attachment?(record.value) and record.value.scope == scope and
             record.value.id == id,
         {:ok, _remaining} <- check(context) do
      {:ok, row(record)}
    else
      {:ok, nil} -> :not_found
      false -> {:error, :invalid_record}
      error -> error
    end
  end

  @spec get_subscription(snapshot(), binary(), integer()) ::
          {:ok, map()} | :not_found | {:error, term()}
  def get_subscription(snapshot, id, deadline) do
    with {:ok, context, scope, revision} <- snapshot_context(snapshot, deadline),
         true <- canonical_id?(id),
         {:ok, %Record{} = record} <- read_record(context, subscription_key(scope, id), revision),
         true <-
           valid_subscription?(record.value) and record.value.scope == scope and
             record.value.id == id,
         {:ok, _remaining} <- check(context) do
      {:ok, row(record)}
    else
      {:ok, nil} -> :not_found
      false -> {:error, :invalid_record}
      error -> error
    end
  end

  @spec subscriptions_page(snapshot(), keyword(), integer()) :: {:ok, map()} | {:error, term()}
  def subscriptions_page(snapshot, opts, deadline),
    do: page(snapshot, :subscriptions, nil, opts, deadline)

  @doc "Commits an opaque subscription; advance fences the event-selection snapshot."
  @spec commit_subscription(snapshot(), map(), integer()) :: {:ok, map()} | {:error, term()}
  def commit_subscription(snapshot, change, deadline) do
    with {:ok, context, scope, revision} <- snapshot_context(snapshot, deadline),
         true <- valid_subscription_change?(change, scope),
         {:ok, compares} <- prepare_subscription(context, scope, revision, change),
         writes = subscription_writes(scope, change),
         {:ok, transaction_revision} <- transact(context, scope, compares, writes) do
      acknowledgement =
        if change.kind == :delete,
          do: %{deleted: true, storage_revision: transaction_revision},
          else: %{subscription: change.subscription, storage_revision: transaction_revision}

      {:ok, acknowledgement}
    else
      false -> {:error, :invalid_subscription_change}
      error -> error
    end
  end

  defp prepare_subscription(context, scope, revision, change) do
    key = subscription_key(scope, change.subscription.id)

    with {:ok, previous} <- read_record(context, key, revision),
         :ok <- subscription_transition(previous, change.subscription, change.kind),
         {:ok, frontier} <- subscription_frontier(context, scope, revision, change.kind) do
      {:ok, [compare(key, previous) | frontier]}
    end
  end

  defp subscription_transition(nil, %{revision: 1}, :create), do: :ok

  defp subscription_transition(%Record{value: previous}, subscription, :advance) do
    if valid_subscription?(previous) and
         same_fields?(previous, subscription, [:id, :scope, :provenance]) and
         subscription.revision == previous.revision + 1,
       do: :ok,
       else: {:error, :invalid_subscription_transition}
  end

  defp subscription_transition(%Record{value: previous}, subscription, :delete) do
    if valid_subscription?(previous) and previous === subscription,
      do: :ok,
      else: {:error, :invalid_subscription_transition}
  end

  defp subscription_transition(_, _, _), do: {:error, :invalid_subscription_transition}

  defp subscription_frontier(context, scope, revision, :advance) do
    key = mutation_frontier_key(scope)
    with {:ok, record} <- read_record(context, key, revision), do: {:ok, [compare(key, record)]}
  end

  defp subscription_frontier(_context, _scope, _revision, _kind), do: {:ok, []}

  defp subscription_writes(scope, %{kind: :delete, subscription: subscription}),
    do: [{:delete, {:key, subscription_key(scope, subscription.id)}, %{}}]

  defp subscription_writes(scope, %{subscription: subscription}),
    do: [put(subscription_key(scope, subscription.id), subscription)]

  @spec boards_page(snapshot(), keyword(), integer()) :: {:ok, map()} | {:error, term()}
  def boards_page(snapshot, opts, deadline),
    do: page(snapshot, :boards, nil, opts, deadline)

  @spec items_page(snapshot(), keyword(), integer()) :: {:ok, map()} | {:error, term()}
  def items_page(snapshot, opts, deadline),
    do: page(snapshot, :items, nil, opts, deadline)

  @spec events_page(snapshot(), binary(), keyword(), integer()) :: {:ok, map()} | {:error, term()}
  def events_page(snapshot, item_id, opts, deadline) do
    if canonical_id?(item_id),
      do: page(snapshot, :events, item_id, opts, deadline),
      else: {:error, :invalid_item_id}
  end

  @doc "Storage-order convenience; domain selection must rank all current candidates."
  @spec lookup_create_key(snapshot(), tuple(), integer()) ::
          {:ok, binary()} | :not_found | {:error, term()}
  def lookup_create_key(snapshot, key, deadline) do
    case lookup_create_key_candidates(snapshot, key, deadline) do
      {:ok, %{ids: [id | _]}} -> {:ok, id}
      result -> result
    end
  end

  @doc "Returns every current tuple member in UUID order, with its committed row revision."
  @spec lookup_create_key_candidates(snapshot(), tuple(), integer()) ::
          {:ok, map()} | :not_found | {:error, term()}
  def lookup_create_key_candidates(snapshot, key, deadline) do
    with {:ok, context, scope, revision} <- snapshot_context(snapshot, deadline),
         true <- valid_create_key?(key),
         {:ok, record} <- read_record(context, create_key(scope, key), revision),
         {:ok, ids} <- members(record),
         {:ok, _remaining} <- check(context) do
      if ids == [],
        do: :not_found,
        else: {:ok, %{ids: ids, storage_revision: record.mod_revision}}
    else
      false -> {:error, :invalid_create_key}
      error -> error
    end
  end

  @spec commit_board(snapshot(), map(), integer()) :: {:ok, map()} | {:error, term()}
  def commit_board(snapshot, board, deadline) do
    with {:ok, context, scope, revision} <- snapshot_context(snapshot, deadline),
         true <- valid_board?(board) and board.scope == scope,
         {:ok, compares} <- prepare_board(context, scope, revision, board, :upsert),
         {:ok, transaction_revision} <- transact(context, scope, compares, board_puts(board)) do
      {:ok, %{board: board, storage_revision: transaction_revision}}
    else
      false -> {:error, :invalid_board}
      error -> error
    end
  end

  @doc "Deletes exact historical board/subscription envelopes with a scope collection fence."
  @spec commit_board_delete(snapshot(), map(), integer()) :: {:ok, map()} | {:error, term()}
  def commit_board_delete(snapshot, change, deadline) do
    with {:ok, context, scope, revision} <- snapshot_context(snapshot, deadline),
         true <- valid_board_delete?(change, scope),
         {:ok, board_compares, board_writes} <-
           prepare_board_delete(context, scope, revision, change),
         {:ok, subscription_compares, subscription_writes} <-
           prepare_board_delete_subscriptions(context, scope, revision, change.subscriptions),
         key = mutation_frontier_key(scope),
         {:ok, frontier} <- read_record(context, key, revision),
         {:ok, transaction_revision} <-
           transact(
             context,
             scope,
             board_compares ++ subscription_compares ++ [compare(key, frontier)],
             board_writes ++ subscription_writes
           ) do
      {:ok, %{deleted: not is_nil(change.board), storage_revision: transaction_revision}}
    else
      false -> {:error, :invalid_board_delete}
      error -> error
    end
  end

  @spec commit_item(snapshot(), map(), integer()) :: {:ok, map()} | {:error, term()}
  def commit_item(snapshot, change, deadline, detached \\ [], read_item_ids \\ []) do
    with {:ok, context, scope, revision} <- snapshot_context(snapshot, deadline),
         true <- valid_change?(change, scope),
         {:ok, board_compares} <-
           prepare_board(context, scope, revision, change.board, :existing),
         {:ok, item_compares} <- prepare_item(context, scope, revision, change),
         {:ok, event_compare} <- absent(context, event_key(scope, change.event), revision),
         {:ok, key_compares, key_puts} <- prepare_create_key(context, scope, revision, change),
         {:ok, blob_compares, blob_writes} <-
           prepare_detached(context, scope, revision, change.item.id, detached),
         {:ok, read_compares} <- prepare_item_reads(context, scope, revision, read_item_ids),
         {:ok, transaction_revision} <-
           transact(
             context,
             scope,
             Enum.uniq(
               board_compares ++
                 item_compares ++
                 [event_compare] ++ key_compares ++ blob_compares ++ read_compares
             ),
             board_puts(change.board) ++ item_puts(change) ++ key_puts ++ blob_writes
           ) do
      {:ok,
       %{
         board: change.board,
         item: change.item,
         event: change.event,
         storage_revision: transaction_revision
       }}
    else
      false -> {:error, :invalid_change}
      error -> error
    end
  end

  @doc "Reads the durable namespace notification highwater at this exact snapshot."
  @spec notification_sequence(snapshot(), integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def notification_sequence(snapshot, deadline) do
    with {:ok, context, scope, revision} <- snapshot_context(snapshot, deadline),
         {:ok, record} <- read_record(context, notification_sequence_key(scope), revision),
         {:ok, value} <- sequence_value(record),
         {:ok, _remaining} <- check(context) do
      {:ok, value}
    end
  end

  @doc "Commits caller-prepared lifecycle records and their collection/sequence fences."
  @spec commit_workflow(snapshot(), map(), integer()) :: {:ok, map()} | {:error, term()}
  def commit_workflow(snapshot, change, deadline) do
    with {:ok, context, scope, revision} <- snapshot_context(snapshot, deadline),
         true <- valid_workflow?(change, scope),
         {:ok, board_compares} <-
           prepare_board(context, scope, revision, change.board, :existing),
         {:ok, item_compares} <- prepare_item(context, scope, revision, change),
         {:ok, event_compare} <- absent(context, event_key(scope, change.event), revision),
         {:ok, blob_compares, blob_writes} <-
           prepare_detached(context, scope, revision, change.item.id, change.detached),
         {:ok, read_compares} <-
           prepare_item_reads(context, scope, revision, change.read_item_ids),
         {:ok, workflow_compares, workflow_writes} <-
           prepare_workflow(context, scope, revision, change),
         {:ok, transaction_revision} <-
           transact(
             context,
             scope,
             Enum.uniq(
               board_compares ++
                 item_compares ++
                 [event_compare] ++
                 blob_compares ++
                 read_compares ++ workflow_compares
             ),
             board_puts(change.board) ++ item_puts(change) ++ blob_writes ++ workflow_writes
           ) do
      {:ok,
       %{
         board: change.board,
         item: change.item,
         event: change.event,
         storage_revision: transaction_revision
       }}
    else
      false -> {:error, :invalid_workflow_change}
      error -> error
    end
  end

  defp prepare_workflow(context, scope, revision, %{kind: :claim}) do
    key = mutation_frontier_key(scope)

    with {:ok, record} <- read_record(context, key, revision),
         do: {:ok, [compare(key, record)], []}
  end

  defp prepare_workflow(context, scope, revision, %{kind: :complete, notification_sequence: next}) do
    key = notification_sequence_key(scope)

    with {:ok, record} <- read_record(context, key, revision),
         {:ok, previous} <- sequence_value(record),
         true <- next > previous do
      {:ok, [compare(key, record)], [put(key, next)]}
    else
      false -> {:error, :invalid_notification_sequence}
      error -> error
    end
  end

  defp prepare_workflow(_context, _scope, _revision, _change), do: {:ok, [], []}
  defp sequence_value(nil), do: {:ok, 0}

  defp sequence_value(%Record{value: value}) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp sequence_value(_), do: {:error, :invalid_notification_sequence}

  defp valid_workflow?(change, scope) do
    closed?(change, @workflow_keys) and change.kind in [:claim, :heartbeat, :release, :complete] and
      valid_board?(change.board) and valid_item?(change.item) and valid_event?(change.event) and
      json_map?(change.projection) and is_list(change.detached) and is_list(change.read_item_ids) and
      change.board.scope == scope and change.item.scope == scope and change.event.scope == scope and
      change.item.board_id == change.board.id and change.item.board_slug == change.board.slug and
      change.event.board_id == change.board.id and change.event.item_id == change.item.id and
      workflow_event?(change.kind, change.event.kind) and
      ((change.kind == :complete and positive_integer?(change.notification_sequence)) or
         (change.kind != :complete and is_nil(change.notification_sequence)))
  end

  defp workflow_event?(:claim, kind), do: kind in [:moved, :claimed]
  defp workflow_event?(:heartbeat, kind), do: kind == :heartbeat
  defp workflow_event?(:release, kind), do: kind in [:moved, :claimed, :edited]

  defp workflow_event?(:complete, kind),
    do:
      kind in [
        :moved,
        :claimed,
        :commented,
        :proof_added,
        :artifact_added,
        :diagnostic,
        :notification,
        :edited
      ]

  @doc "Publishes the final reciprocal pair and every supplied logical stage in one transaction."
  @spec commit_link(snapshot(), map(), integer()) :: {:ok, map()} | {:error, term()}
  def commit_link(snapshot, change, deadline) do
    with {:ok, context, scope, revision} <- snapshot_context(snapshot, deadline),
         true <- valid_link_change?(change, scope),
         {:ok, read_compares} <-
           prepare_item_reads(context, scope, revision, change.read_item_ids),
         {:ok, prepared} <- prepare_link(context, scope, revision, change.stages),
         {:ok, transaction_revision} <-
           transact(
             context,
             scope,
             Enum.uniq(prepared.compares ++ read_compares),
             prepared.writes |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
           ) do
      {:ok,
       %{
         parent: prepared.items[change.parent_id].value,
         child: prepared.items[change.child_id].value,
         boards: prepared.boards |> Map.values() |> Enum.map(& &1.value) |> Enum.sort_by(& &1.id),
         events: Enum.map(change.stages, & &1.event),
         storage_revision: transaction_revision
       }}
    else
      false -> {:error, :invalid_link_change}
      error -> error
    end
  end

  defp prepare_item_reads(context, scope, revision, ids) when is_list(ids) do
    if :erlang.external_size(ids) <= @membership_limit and Enum.all?(ids, &canonical_id?/1) do
      Enum.reduce_while(Enum.uniq(ids), {:ok, []}, fn id, {:ok, compares} ->
        key = item_key(scope, id)

        with {:ok, record} <- read_record(context, key, revision),
             true <-
               is_nil(record) or
                 (valid_item?(record.value) and record.value.id == id and
                    record.value.scope == scope) do
          {:cont, {:ok, [compare(key, record) | compares]}}
        else
          false -> {:halt, {:error, :invalid_item_read}}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :invalid_item_reads}
    end
  end

  defp prepare_item_reads(_, _, _, _), do: {:error, :invalid_item_reads}

  defp prepare_link(context, scope, revision, stages) do
    initial = %{boards: %{}, items: %{}, compares: [], writes: %{}}

    Enum.reduce_while(stages, {:ok, initial}, fn stage, {:ok, state} ->
      with {:ok, previous_board, board_compares} <-
             link_board_previous(context, scope, revision, state, stage.board),
           true <- previous_board.value.payload === stage.board.payload,
           :ok <-
             board_transition(
               previous_board,
               %Record{value: stage.board.id},
               stage.board,
               :existing
             ),
           {:ok, previous_item, item_compares} <-
             link_item_previous(context, scope, revision, state, stage.item),
           :ok <- item_transition(previous_item, stage.item, :link),
           {:ok, event_compare} <- absent(context, event_key(scope, stage.event), revision),
           {:ok, blob_compares, blob_writes} <-
             prepare_detached(context, scope, revision, stage.item.id, stage.detached) do
        state = %{
          state
          | boards: Map.put(state.boards, stage.board.id, %{previous_board | value: stage.board}),
            items: Map.put(state.items, stage.item.id, %{previous_item | value: stage.item}),
            compares:
              state.compares ++
                board_compares ++ item_compares ++ [event_compare] ++ blob_compares,
            writes:
              link_writes(
                state.writes,
                board_puts(stage.board) ++ item_puts(stage) ++ blob_writes
              )
        }

        {:cont, {:ok, state}}
      else
        false -> {:halt, {:error, :invalid_link_transition}}
        error -> {:halt, error}
      end
    end)
  end

  defp link_board_previous(context, scope, revision, state, board) do
    case Map.fetch(state.boards, board.id) do
      {:ok, previous} ->
        {:ok, previous, []}

      :error ->
        key = board_key(scope, board.id)
        name_key = name_key(scope, board.slug)

        with {:ok, %Record{} = previous} <- read_record(context, key, revision),
             {:ok, %Record{value: id} = name} <- read_record(context, name_key, revision),
             true <- id == board.id do
          {:ok, previous, [compare(key, previous), compare(name_key, name)]}
        else
          false -> {:error, :invalid_board_transition}
          {:ok, _} -> {:error, :invalid_board_transition}
          error -> error
        end
    end
  end

  defp link_item_previous(context, scope, revision, state, item) do
    case Map.fetch(state.items, item.id) do
      {:ok, previous} ->
        {:ok, previous, []}

      :error ->
        key = item_key(scope, item.id)

        with {:ok, %Record{} = previous} <- read_record(context, key, revision) do
          {:ok, previous, [compare(key, previous)]}
        else
          {:ok, _} -> {:error, :invalid_item_transition}
          error -> error
        end
    end
  end

  defp link_writes(writes, operations) do
    Enum.reduce(operations, writes, fn
      {:put, key, _, _} = operation, result -> Map.put(result, key, operation)
      {:delete, {:key, key}, _} = operation, result -> Map.put(result, key, operation)
    end)
  end

  defp valid_link_change?(change, scope) do
    closed?(change, @link_keys) and change.kind == :link and
      canonical_id?(change.parent_id) and canonical_id?(change.child_id) and
      change.parent_id != change.child_id and is_list(change.read_item_ids) and
      is_list(change.stages) and Enum.all?(change.stages, &is_map/1) and
      :erlang.external_size(change) <= @membership_limit and
      Enum.map(change.stages, &Map.get(&1, :role)) in [
        [:parent_metadata, :child_metadata],
        [:parent_metadata, :child_metadata, :child_readiness]
      ] and
      Enum.all?(change.stages, &valid_link_stage?(&1, scope, change)) and
      length(Enum.uniq_by(change.stages, & &1.event.id)) == length(change.stages)
  end

  defp valid_link_stage?(stage, scope, change) do
    closed?(stage, @link_stage_keys) and valid_board?(stage.board) and
      valid_item?(stage.item) and valid_event?(stage.event) and json_map?(stage.projection) and
      is_list(stage.detached) and stage.board.scope == scope and stage.item.scope == scope and
      stage.event.scope == scope and stage.item.board_id == stage.board.id and
      stage.item.board_slug == stage.board.slug and stage.event.board_id == stage.board.id and
      stage.event.item_id == stage.item.id and
      ((stage.role == :parent_metadata and stage.item.id == change.parent_id and
          stage.event.kind in [:link_added, :edited]) or
         (stage.role == :child_metadata and stage.item.id == change.child_id and
            stage.event.kind in [:link_added, :edited]) or
         (stage.role == :child_readiness and stage.item.id == change.child_id and
            stage.event.kind == :moved))
  end

  @spec commit_specify(snapshot(), map(), integer()) :: {:ok, map()} | {:error, term()}
  def commit_specify(snapshot, change, deadline, detached \\ []) do
    with {:ok, context, scope, revision} <- snapshot_context(snapshot, deadline),
         true <- valid_specify?(change, scope),
         {:ok, board_compares, board_writes} <-
           prepare_specify_boards(context, scope, revision, change),
         {:ok, item_compares} <- prepare_specify_item(context, scope, revision, change),
         {:ok, event_compare} <- absent(context, event_key(scope, change.event), revision),
         {:ok, key_compares, key_writes} <-
           prepare_specify_keys(context, scope, revision, change),
         {:ok, blob_compares, blob_writes} <-
           prepare_detached(context, scope, revision, change.item.id, detached),
         {:ok, transaction_revision} <-
           transact(
             context,
             scope,
             board_compares ++ item_compares ++ [event_compare] ++ key_compares ++ blob_compares,
             board_writes ++
               item_puts(change) ++ detached_projection(change) ++ key_writes ++ blob_writes
           ) do
      {:ok,
       %{
         source_board: change.source_board,
         board: change.board,
         item: change.item,
         event: change.event,
         storage_revision: transaction_revision
       }}
    else
      false -> {:error, :invalid_specify_change}
      error -> error
    end
  end

  @spec commit_attachment(snapshot(), map(), integer()) :: {:ok, map()} | {:error, term()}
  def commit_attachment(snapshot, change, deadline, detached \\ []) do
    with {:ok, context, scope, revision} <- snapshot_context(snapshot, deadline),
         true <- valid_attachment_change?(change, scope),
         true <- is_list(detached) and Enum.all?(detached, &valid_attachment?/1),
         {:ok, board_compares} <-
           prepare_board(context, scope, revision, change.board, :existing),
         {:ok, item_compares} <- prepare_item(context, scope, revision, change),
         {:ok, event_compare} <- absent(context, event_key(scope, change.event), revision),
         {:ok, attachment_compares, attachment_writes} <-
           prepare_attachment(context, scope, revision, change),
         detached =
           Enum.reject(
             detached,
             &(change.kind == :attachment_delete and &1.id == change.attachment.id)
           ),
         {:ok, blob_compares, blob_writes} <-
           prepare_detached(context, scope, revision, change.item.id, detached),
         {:ok, transaction_revision} <-
           transact(
             context,
             scope,
             board_compares ++
               item_compares ++ [event_compare] ++ attachment_compares ++ blob_compares,
             board_puts(change.board) ++ item_puts(change) ++ attachment_writes ++ blob_writes
           ) do
      {:ok,
       %{
         board: change.board,
         item: change.item,
         event: change.event,
         attachment: change.attachment,
         storage_revision: transaction_revision
       }}
    else
      false -> {:error, :invalid_attachment_change}
      error -> error
    end
  end

  defp prepare_attachment(context, scope, revision, %{
         kind: :attachment_add,
         attachment: attachment
       }) do
    key = attachment_key(scope, attachment.id)

    with {:ok, condition} <- absent(context, key, revision),
         do: {:ok, [condition], [put(key, attachment)]}
  end

  defp prepare_attachment(context, scope, revision, %{attachment: attachment}) do
    key = attachment_key(scope, attachment.id)

    with {:ok, %Record{value: ^attachment} = record} <- read_record(context, key, revision) do
      {:ok, [compare(key, record)], [{:delete, {:key, key}, %{}}]}
    else
      {:ok, _} -> {:error, :invalid_attachment_transition}
      error -> error
    end
  end

  defp prepare_detached(context, scope, revision, item_id, detached) when is_list(detached) do
    Enum.reduce_while(Enum.uniq(detached), {:ok, [], []}, fn attachment,
                                                             {:ok, compares, writes} ->
      if valid_attachment?(attachment) and attachment.scope == scope and
           attachment.item_id == item_id do
        case prepare_attachment(context, scope, revision, %{attachment: attachment}) do
          {:ok, conditions, operations} ->
            {:cont, {:ok, compares ++ conditions, writes ++ operations}}

          error ->
            {:halt, error}
        end
      else
        {:halt, {:error, :invalid_attachment_transition}}
      end
    end)
  end

  defp prepare_detached(_, _, _, _, _), do: {:error, :invalid_attachment_transition}

  defp prepare_specify_boards(context, scope, revision, change) do
    with {:ok, source_compares} <-
           prepare_board(context, scope, revision, change.source_board, :existing) do
      if change.source_board.id == change.board.id do
        {:ok, source_compares, board_puts(change.board)}
      else
        with {:ok, destination_compares} <-
               prepare_board(context, scope, revision, change.board, :upsert),
             do:
               {:ok, source_compares ++ destination_compares,
                board_puts(change.source_board) ++ board_puts(change.board)}
      end
    end
  end

  defp prepare_specify_item(context, scope, revision, change) do
    key = item_key(scope, change.item.id)

    with {:ok, %Record{value: previous} = record} <- read_record(context, key, revision),
         true <-
           valid_item?(previous) and previous.board_id == change.source_board.id and
             previous.board_slug == change.source_board.slug and
             same_fields?(previous, change.item, [:id, :scope, :provenance]) and
             change.item.revision == previous.revision + 1 do
      {:ok, [compare(key, record)]}
    else
      false -> {:error, :invalid_item_transition}
      {:ok, nil} -> {:error, :invalid_item_transition}
      error -> error
    end
  end

  defp prepare_specify_keys(context, scope, revision, change) do
    keys =
      [change.previous_create_key, change.create_key] |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Enum.reduce_while(keys, {:ok, [], []}, fn identity, {:ok, compares, writes} ->
      key = create_key(scope, identity)

      with {:ok, record} <- read_record(context, key, revision),
           {:ok, ids} <- members(record),
           true <- identity != change.previous_create_key or change.item.id in ids do
        next =
          if identity == change.previous_create_key,
            do: List.delete(ids, change.item.id),
            else: ids

        next =
          if identity == change.create_key,
            do: Enum.sort(Enum.uniq([change.item.id | next])),
            else: next

        next_writes = if ids == next, do: [], else: [members_write(key, next)]
        {:cont, {:ok, compares ++ [compare(key, record)], writes ++ next_writes}}
      else
        false -> {:halt, {:error, :invalid_create_key_membership}}
        error -> {:halt, error}
      end
    end)
  end

  defp members(nil), do: {:ok, []}

  defp members(%Record{value: id}) when is_binary(id) do
    if canonical_id?(id), do: {:ok, [id]}, else: {:error, :invalid_create_key_membership}
  end

  defp members(%Record{value: ids}) when is_list(ids) do
    if :erlang.external_size(ids) <= @membership_limit and length(ids) >= 2 and
         Enum.all?(ids, &canonical_id?/1) and Enum.sort(Enum.uniq(ids)) == ids,
       do: {:ok, ids},
       else: {:error, :invalid_create_key_membership}
  end

  defp members(_), do: {:error, :invalid_create_key_membership}
  defp members_write(key, []), do: {:delete, {:key, key}, %{}}
  defp members_write(key, [id]), do: put(key, id)
  defp members_write(key, ids), do: put(key, ids)
  defp detached_projection(%{source_board: %{id: id}, board: %{id: id}}), do: []

  defp detached_projection(change),
    do: [
      {:delete,
       {:key, board_items_prefix(change.item.scope, change.source_board.id) <> change.item.id},
       %{}}
    ]

  defp prepare_board_delete(context, scope, revision, %{slug: slug, board: nil}) do
    key = name_key(scope, slug)

    case read_record(context, key, revision) do
      {:ok, nil} -> {:ok, [compare(key, nil)], []}
      {:ok, _} -> {:error, :invalid_board_delete_transition}
      error -> error
    end
  end

  defp prepare_board_delete(context, scope, revision, %{slug: slug, board: board}) do
    name_key = name_key(scope, slug)
    board_key = board_key(scope, board.id)

    with {:ok, %Record{value: id} = name} <- read_record(context, name_key, revision),
         true <- id == board.id,
         {:ok, %Record{value: previous} = record} <- read_record(context, board_key, revision),
         true <- previous === board,
         :ok <- board_delete_empty(context, scope, revision, board.id) do
      {:ok, [compare(name_key, name), compare(board_key, record)],
       [{:delete, {:key, board_key}, %{}}, {:delete, {:key, name_key}, %{}}]}
    else
      false -> {:error, :invalid_board_delete_transition}
      {:ok, nil} -> {:error, :invalid_board_delete_transition}
      error -> error
    end
  end

  defp board_delete_empty(context, scope, revision, id) do
    case read_page(context, board_items_prefix(scope, id), nil, revision, 1) do
      {:ok, [], %{has_more: false}} -> :ok
      {:ok, [_ | _], _} -> {:error, :board_not_empty}
      {:ok, _, _} -> {:error, :invalid_record}
      error -> error
    end
  end

  defp prepare_board_delete_subscriptions(context, scope, revision, subscriptions) do
    Enum.reduce_while(subscriptions, {:ok, [], []}, fn subscription, {:ok, compares, writes} ->
      key = subscription_key(scope, subscription.id)

      with {:ok, %Record{value: previous} = record} <- read_record(context, key, revision),
           true <- previous === subscription do
        {:cont, {:ok, [compare(key, record) | compares], [{:delete, {:key, key}, %{}} | writes]}}
      else
        false -> {:halt, {:error, :invalid_board_delete_transition}}
        {:ok, nil} -> {:halt, {:error, :invalid_board_delete_transition}}
        error -> {:halt, error}
      end
    end)
  end

  defp prepare_board(context, scope, revision, board, mode) do
    name_key = name_key(scope, board.slug)
    board_key = board_key(scope, board.id)

    with {:ok, name} <- read_record(context, name_key, revision),
         {:ok, previous} <- read_record(context, board_key, revision),
         :ok <- board_transition(previous, name, board, mode) do
      {:ok, [compare(name_key, name), compare(board_key, previous)]}
    end
  end

  defp board_transition(nil, nil, %{revision: 1}, :upsert), do: :ok

  defp board_transition(%Record{value: previous}, %Record{value: id}, board, _mode) do
    if valid_board?(previous) and id == board.id and
         same_fields?(previous, board, [:id, :scope, :slug, :provenance]) and
         board.revision == previous.revision + 1,
       do: :ok,
       else: {:error, :invalid_board_transition}
  end

  defp board_transition(_, _, _, _), do: {:error, :invalid_board_transition}

  defp prepare_item(context, scope, revision, change) do
    key = item_key(scope, change.item.id)

    with {:ok, previous} <- read_record(context, key, revision),
         :ok <- item_transition(previous, change.item, change.kind) do
      {:ok, [compare(key, previous)]}
    end
  end

  defp item_transition(nil, %{revision: 1}, :create), do: :ok

  defp item_transition(%Record{value: previous}, item, kind)
       when kind in [
              :comment,
              :move,
              :promote,
              :proof,
              :attachment_add,
              :attachment_delete,
              :link,
              :claim,
              :heartbeat,
              :release,
              :complete,
              :decompose
            ] do
    if valid_item?(previous) and
         same_fields?(previous, item, [:id, :scope, :board_id, :board_slug, :provenance]) and
         item.revision == previous.revision + 1,
       do: :ok,
       else: {:error, :invalid_item_transition}
  end

  defp item_transition(_, _, _), do: {:error, :invalid_item_transition}

  defp prepare_create_key(_context, _scope, _revision, %{create_key: nil}),
    do: {:ok, [], []}

  defp prepare_create_key(context, scope, revision, change) do
    key = create_key(scope, change.create_key)

    with {:ok, comparison} <- absent(context, key, revision) do
      {:ok, [comparison], [put(key, change.item.id)]}
    end
  end

  defp absent(context, key, revision) do
    case read_record(context, key, revision) do
      {:ok, nil} -> {:ok, compare(key, nil)}
      {:ok, _} -> {:error, :record_exists}
      error -> error
    end
  end

  defp compare(key, nil), do: {:exists, key, :==, false}
  defp compare(key, %Record{mod_revision: revision}), do: {:mod_revision, key, :==, revision}
  defp put(key, value), do: {:put, key, value, %{}}

  defp board_puts(board) do
    [
      put(name_key(board.scope, board.slug), board.id),
      put(board_key(board.scope, board.id), board)
    ]
  end

  defp item_puts(change) do
    item = change.item

    projection = %{
      schema_version: 1,
      id: item.id,
      scope: item.scope,
      board_id: item.board_id,
      board_slug: item.board_slug,
      payload: change.projection
    }

    [
      put(item_key(item.scope, item.id), item),
      put(scope_items_prefix(item.scope) <> item.id, projection),
      put(board_items_prefix(item.scope, item.board_id) <> item.id, projection),
      put(event_key(item.scope, change.event), change.event)
    ]
  end

  defp page(snapshot, kind, item_id, opts, deadline) do
    with {:ok, context, scope, revision} <- snapshot_context(snapshot, deadline),
         {:ok, limit, cursor, board_id} <- page_options(opts, kind),
         prefix = page_prefix(scope, kind, item_id, board_id),
         {:ok, after_key} <- page_cursor(cursor, snapshot, prefix),
         {:ok, records, metadata} <- read_page(context, prefix, after_key, revision, limit),
         {:ok, rows} <- page_rows(context, records, revision, scope, kind, item_id, board_id),
         {:ok, _remaining} <- check(context) do
      next =
        if metadata.has_more,
          do: {:workboard_cursor, snapshot, prefix, metadata.last_key},
          else: nil

      {:ok, %{rows: rows, next_cursor: next}}
    end
  end

  defp page_options(opts, kind) when is_list(opts) do
    allowed = if kind == :items, do: [:limit, :cursor, :board_id], else: [:limit, :cursor]

    if Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed == [] and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      limit = Keyword.get(opts, :limit, 50)
      board_id = Keyword.get(opts, :board_id)

      if is_integer(limit) and limit > 0 and (is_nil(board_id) or canonical_id?(board_id)),
        do: {:ok, min(limit, 100), Keyword.get(opts, :cursor), board_id},
        else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  defp page_options(_, _), do: {:error, :invalid_options}

  defp page_cursor(nil, _snapshot, _prefix), do: {:ok, nil}

  defp page_cursor({:workboard_cursor, snapshot, prefix, key}, snapshot, prefix) do
    if is_binary(key) and String.starts_with?(key, prefix),
      do: {:ok, key},
      else: {:error, :invalid_cursor}
  end

  defp page_cursor(_, _, _), do: {:error, :invalid_cursor}

  defp page_rows(context, records, revision, scope, kind, item_id, board_id) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, rows} ->
      with {:ok, record} <- load_value(context, record, revision),
           true <- valid_page_record?(record, scope, kind, item_id, board_id) do
        {:cont, {:ok, [row(record) | rows]}}
      else
        false -> {:halt, {:error, :invalid_record}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp valid_page_record?(%Record{value: value} = record, scope, :boards, _, _) do
    valid_board?(value) and value.scope == scope and
      Map.get(record, :key) == board_key(scope, value.id)
  end

  defp valid_page_record?(%Record{value: value} = record, scope, :items, _, board_id) do
    valid_projection?(value) and value.scope == scope and
      (is_nil(board_id) or value.board_id == board_id) and
      Map.get(record, :key) == page_prefix(scope, :items, nil, board_id) <> value.id
  end

  defp valid_page_record?(%Record{value: value} = record, scope, :events, item_id, _) do
    valid_event?(value) and value.scope == scope and value.item_id == item_id and
      Map.get(record, :key) == event_key(scope, value)
  end

  defp valid_page_record?(%Record{value: value} = record, scope, :subscriptions, _, _) do
    valid_subscription?(value) and value.scope == scope and
      Map.get(record, :key) == subscription_key(scope, value.id)
  end

  defp valid_page_record?(_, _, _, _, _), do: false

  defp row(%Record{value: value, mod_revision: revision}),
    do: %{record: value, storage_revision: revision}

  defp valid_subscription?(value),
    do:
      closed?(value, @subscription_keys) and common?(value) and positive_integer?(value.revision)

  defp valid_subscription_change?(change, scope),
    do:
      closed?(change, @subscription_change_keys) and change.kind in [:create, :advance, :delete] and
        valid_subscription?(change.subscription) and change.subscription.scope == scope

  defp valid_board_delete?(change, scope) do
    closed?(change, @board_delete_keys) and nonempty_binary?(change.slug) and
      (is_nil(change.board) or
         (valid_board?(change.board) and change.board.scope == scope and
            change.board.slug == change.slug)) and
      is_list(change.subscriptions) and
      Enum.all?(change.subscriptions, &(valid_subscription?(&1) and &1.scope == scope)) and
      length(Enum.uniq_by(change.subscriptions, & &1.id)) == length(change.subscriptions) and
      (not is_nil(change.board) or change.subscriptions != [])
  end

  defp valid_board?(value) do
    closed?(value, @board_keys) and common?(value) and nonempty_binary?(value.slug) and
      positive_integer?(value.revision)
  end

  defp valid_item?(value) do
    closed?(value, @item_keys) and common?(value) and canonical_id?(value.board_id) and
      nonempty_binary?(value.board_slug) and positive_integer?(value.revision)
  end

  defp valid_event?(value) do
    closed?(value, @event_keys) and common?(value) and canonical_id?(value.item_id) and
      canonical_id?(value.board_id) and
      value.kind in [
        :created,
        :commented,
        :moved,
        :edited,
        :specified,
        :proof_added,
        :attachment_added,
        :link_added,
        :claimed,
        :heartbeat,
        :artifact_added,
        :diagnostic,
        :notification,
        :decomposed
      ]
  end

  defp valid_attachment?(value) do
    closed?(value, @attachment_keys) and common?(value) and canonical_id?(value.item_id)
  end

  defp valid_attachment_change?(change, scope) do
    closed?(change, @attachment_change_keys) and
      change.kind in [:attachment_add, :attachment_delete] and
      valid_board?(change.board) and valid_item?(change.item) and valid_event?(change.event) and
      json_map?(change.projection) and valid_attachment?(change.attachment) and
      change.board.scope == scope and change.item.scope == scope and change.event.scope == scope and
      change.attachment.scope == scope and change.attachment.item_id == change.item.id and
      change.item.board_id == change.board.id and change.item.board_slug == change.board.slug and
      change.event.board_id == change.board.id and change.event.item_id == change.item.id and
      ((change.kind == :attachment_add and change.event.kind in [:attachment_added, :edited]) or
         (change.kind == :attachment_delete and change.event.kind == :edited))
  end

  defp valid_projection?(value) do
    closed?(value, @projection_keys) and value.schema_version === 1 and canonical_id?(value.id) and
      nonempty_binary?(value.scope) and canonical_id?(value.board_id) and
      nonempty_binary?(value.board_slug) and json_map?(value.payload)
  end

  defp common?(value) do
    value.schema_version === 1 and canonical_id?(value.id) and nonempty_binary?(value.scope) and
      json_map?(value.payload) and json_map?(value.provenance)
  end

  defp valid_change?(change, scope) do
    closed?(change, @change_keys) and
      change.kind in [:create, :comment, :move, :promote, :proof, :decompose] and
      valid_board?(change.board) and valid_item?(change.item) and valid_event?(change.event) and
      json_map?(change.projection) and change.board.scope == scope and change.item.scope == scope and
      change.event.scope == scope and change.item.board_id == change.board.id and
      change.item.board_slug == change.board.slug and change.event.board_id == change.board.id and
      change.event.item_id == change.item.id and
      ((change.kind == :create and change.event.kind == :created and
          (is_nil(change.create_key) or
             (valid_create_key?(change.create_key) and
                elem(change.create_key, 1) == change.board.slug))) or
         (change.kind == :comment and change.event.kind == :commented and
            is_nil(change.create_key)) or
         (change.kind == :move and change.event.kind in [:moved, :edited] and
            is_nil(change.create_key)) or
         (change.kind == :promote and change.event.kind == :moved and
            is_nil(change.create_key)) or
         (change.kind == :proof and change.event.kind == :proof_added and
            is_nil(change.create_key)) or
         (change.kind == :decompose and change.event.kind in [:moved, :edited, :decomposed] and
            is_nil(change.create_key)))
  end

  defp valid_specify?(change, scope) do
    closed?(change, @specify_keys) and change.kind == :specify and
      valid_board?(change.source_board) and valid_board?(change.board) and
      valid_item?(change.item) and valid_event?(change.event) and json_map?(change.projection) and
      change.source_board.scope == scope and change.board.scope == scope and
      change.item.scope == scope and change.event.scope == scope and
      change.item.board_id == change.board.id and change.item.board_slug == change.board.slug and
      change.event.board_id == change.board.id and
      change.event.item_id == change.item.id and change.event.kind == :specified and
      (change.source_board.id != change.board.id or change.source_board == change.board) and
      (is_nil(change.previous_create_key) or
         (valid_create_key?(change.previous_create_key) and
            elem(change.previous_create_key, 1) == change.source_board.slug)) and
      (is_nil(change.create_key) or
         (valid_create_key?(change.create_key) and elem(change.create_key, 1) == change.board.slug))
  end

  defp closed?(value, keys),
    do:
      is_map(value) and not is_struct(value) and map_size(value) == length(keys) and
        Enum.all?(keys, &Map.has_key?(value, &1))

  defp same_fields?(previous, proposed, fields),
    do: Enum.all?(fields, &(Map.fetch!(previous, &1) === Map.fetch!(proposed, &1)))

  defp valid_create_key?({tenant, slug, key}),
    do: (is_nil(tenant) or is_binary(tenant)) and nonempty_binary?(slug) and nonempty_binary?(key)

  defp valid_create_key?(_), do: false

  defp json_map?(value) when is_map(value) and not is_struct(value),
    do:
      Enum.all?(value, fn {key, value} ->
        is_binary(key) and String.valid?(key) and json?(value)
      end)

  defp json_map?(_), do: false
  defp json?(value) when is_map(value), do: json_map?(value)
  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)
  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value), do: is_number(value) or is_boolean(value) or is_nil(value)
  defp nonempty_binary?(value), do: is_binary(value) and byte_size(value) > 0
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp canonical_id?(id) when is_binary(id), do: match?({:ok, ^id}, Ecto.UUID.cast(id))
  defp canonical_id?(_), do: false

  # Historical point reads return values; historical list metadata supplies the
  # actual storage fence. Both reads use the same snapshot revision and budget.
  defp read_record(context, key, revision) do
    case read(
           context,
           &Concord.Turso.list(
             range: {key, key <> <<0>>},
             revision: revision,
             keys_only: true,
             limit: 1,
             timeout: &1
           )
         ) do
      {:ok, [], %{has_more: false}} ->
        {:ok, nil}

      {:ok, [record], %{has_more: false}} ->
        if Map.get(record, :key) == key,
          do: load_value(context, record, revision),
          else: {:error, :invalid_record}

      {:ok, _, _} ->
        {:error, :invalid_record}

      {:error, _} = error ->
        error
    end
  end

  defp load_value(context, %Record{mod_revision: mod_revision} = record, revision)
       when is_integer(mod_revision) and mod_revision > 0 and mod_revision <= revision do
    case read(
           context,
           &KV.get(Map.get(record, :key), engine: :turso, revision: revision, timeout: &1)
         ) do
      {:ok, value} -> {:ok, %{record | value: value}}
      {:error, _} = error -> error
    end
  end

  defp load_value(_, _, _), do: {:error, :invalid_record}

  defp read_page(context, prefix, after_key, revision, limit) do
    start = if is_nil(after_key), do: prefix, else: after_key <> <<0>>

    read(
      context,
      &Concord.Turso.list(
        range: {start, prefix <> <<255>>},
        revision: revision,
        keys_only: true,
        limit: limit,
        timeout: &1
      )
    )
  end

  defp read_revision(context) do
    case read(context, &KV.revision(engine: :turso, timeout: &1)) do
      {:ok, revision} when is_integer(revision) and revision >= 0 -> {:ok, revision}
      {:ok, _} -> {:error, :invalid_record}
      {:error, _} = error -> error
    end
  end

  defp snapshot_context({:workboard_snapshot, owner, scope, revision}, deadline)
       when is_pid(owner) and is_integer(revision) and revision >= 0 do
    with true <- nonempty_binary?(scope),
         {:ok, context} <- capture(deadline, owner) do
      {:ok, context, scope, revision}
    else
      false -> {:error, :invalid_snapshot}
      error -> error
    end
  end

  defp snapshot_context(_, _), do: {:error, :invalid_snapshot}

  defp capture(deadline, expected_owner \\ nil)

  defp capture(deadline, expected_owner) when is_integer(deadline) do
    now = System.monotonic_time(:millisecond)
    config = Application.get_env(:concord, :turso, [])
    database = Keyword.get(config, :database)
    owner = Process.whereis(Concord.Turso.DB)

    cond do
      deadline <= now ->
        {:error, :timeout}

      not is_nil(expected_owner) and owner != expected_owner ->
        {:error, :owner_changed}

      Keyword.get(config, :enabled, false) and is_binary(database) and database != "" and
        database != ":memory:" and
        not String.starts_with?(database, ["file:", "libsql:", "http:", "https:"]) and
        is_nil(Keyword.get(config, :remote_url)) and is_pid(owner) and node(owner) == node() ->
        {:ok, %{owner: owner, deadline: min(deadline, now + @maximum_timeout)}}

      true ->
        {:error, :storage_unavailable}
    end
  end

  defp capture(_, _), do: {:error, :invalid_deadline}

  defp check(%{owner: owner, deadline: deadline}) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      Process.whereis(Concord.Turso.DB) != owner -> {:error, :owner_changed}
      remaining <= 0 -> {:error, :timeout}
      true -> {:ok, remaining}
    end
  end

  defp read(context, operation) do
    with {:ok, remaining} <- check(context) do
      result = invoke(operation, remaining)
      with {:ok, _remaining} <- check(context), do: result
    end
  end

  defp transact(context, scope, compares, puts) do
    # Unconditional publication only: ordinary writes never read/compare this marker.
    writes = puts ++ [put(mutation_frontier_key(scope), %{schema_version: 1})]
    spec = %{compare: compares, success: writes, failure: []}

    with {:ok, remaining} <- check(context) do
      case invoke(&Concord.Turso.txn(spec, timeout: &1), remaining) do
        {:ok, %{succeeded: true, revision: revision}}
        when is_integer(revision) and revision > 0 ->
          {:ok, revision}

        {:ok, %{succeeded: false}} ->
          {:error, :resource_conflict}

        {:error, reason} ->
          {:error, {:unknown_outcome, reason}}

        _ ->
          {:error, {:unknown_outcome, :invalid_transaction_result}}
      end
    end
  end

  defp invoke(operation, timeout) do
    operation.(timeout)
  rescue
    _ -> {:error, :storage_unavailable}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, :timeout -> {:error, :timeout}
    _, _ -> {:error, :storage_unavailable}
  end

  defp encode(value), do: Base.url_encode64(value, padding: false)
  defp scope_prefix(scope), do: @prefix <> "scopes/" <> encode(scope) <> "/"
  defp mutation_frontier_key(scope), do: scope_prefix(scope) <> "control/mutation_frontier"

  defp notification_sequence_key(scope),
    do: scope_prefix(scope) <> "control/notification_sequence"

  defp subscriptions_prefix(scope), do: scope_prefix(scope) <> "subscriptions/"
  defp subscription_key(scope, id), do: subscriptions_prefix(scope) <> id
  defp boards_prefix(scope), do: scope_prefix(scope) <> "boards/"
  defp board_key(scope, id), do: boards_prefix(scope) <> id
  defp name_key(scope, slug), do: scope_prefix(scope) <> "names/" <> encode(slug)
  defp item_key(scope, id), do: scope_prefix(scope) <> "records/" <> id
  defp attachment_key(scope, id), do: scope_prefix(scope) <> "attachments/" <> id
  defp scope_items_prefix(scope), do: scope_prefix(scope) <> "items/"
  defp board_items_prefix(scope, id), do: scope_prefix(scope) <> "board_items/" <> id <> "/"
  defp events_prefix(scope, item_id), do: scope_prefix(scope) <> "events/" <> item_id <> "/"
  defp event_key(scope, event), do: events_prefix(scope, event.item_id) <> event.id

  defp create_key(scope, key),
    do: scope_prefix(scope) <> "create_keys/" <> encode(:erlang.term_to_binary(key))

  defp page_prefix(scope, :subscriptions, _, _), do: subscriptions_prefix(scope)
  defp page_prefix(scope, :boards, _, _), do: boards_prefix(scope)
  defp page_prefix(scope, :items, _, nil), do: scope_items_prefix(scope)
  defp page_prefix(scope, :items, _, board_id), do: board_items_prefix(scope, board_id)
  defp page_prefix(scope, :events, item_id, _), do: events_prefix(scope, item_id)
end
