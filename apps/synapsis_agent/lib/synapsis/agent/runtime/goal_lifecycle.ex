defmodule Synapsis.Agent.Runtime.GoalLifecycle do
  @moduledoc """
  Closed host attribution facts and public native terminal-outbox recovery.

  Facts contain no capabilities. Child facts describe intended native delegation,
  captured before MultiAgent issues its binding. Recovery runs only after former
  live owners have settled; ordinary Conversation owns its own delivery/unbind.
  """

  alias Backplane.AgentRuntime.{Error, Goal, GoalBridge}
  alias Backplane.AgentRuntime.Store, as: NativeStore
  alias Synapsis.Agent.Runtime.Store
  alias Synapsis.Runtime.Store, as: Journal

  @attribution [
    :thread_id,
    :run_id,
    :incarnation,
    :mode,
    :expected_goal_id,
    :root_thread_id,
    :root_goal_id
  ]
  @fact_keys [
    :version,
    :session_id,
    :namespace,
    :run_id,
    :incarnation,
    :thread_id,
    :mode_provenance,
    :mode,
    :expected_goal_id,
    :root_thread_id,
    :root_goal_id,
    :provenance
  ]
  @terminal [:completed, :failed, :cancelled, :timed_out]
  @events [
    :turn_started,
    :usage,
    :tool_finished,
    :item_completed,
    :turn_stopped,
    :turn_aborted,
    :turn_error
  ]

  # The caller must first validate this actual root binding with Goal.attribution.
  def root_fact(session_id, store, binding, mode_provenance) do
    binding
    |> projection()
    |> Map.merge(%{
      version: 1,
      session_id: session_id,
      namespace: store.namespace,
      mode_provenance: mode_provenance,
      provenance: :bound_root,
      root_thread_id: nil,
      root_goal_id: nil
    })
  end

  def child_fact(session_id, store, identity, validated_parent_binding, mode_provenance) do
    %{
      version: 1,
      session_id: session_id,
      namespace: store.namespace,
      run_id: identity.run_id,
      incarnation: identity.incarnation,
      thread_id: identity.run_id,
      mode_provenance: mode_provenance,
      mode: validated_parent_binding.mode,
      expected_goal_id: validated_parent_binding.expected_goal_id,
      root_thread_id: session_id,
      root_goal_id: validated_parent_binding.expected_goal_id,
      provenance: :intended_child,
      parent_attribution: projection(validated_parent_binding)
    }
  end

  def retain(fact) do
    identity =
      {fact.namespace, fact.run_id, fact.incarnation}
      |> :erlang.term_to_binary()
      |> Base.url_encode64(padding: false)

    Journal.put_fact(fact.session_id, :goal_attribution, identity, fact)
  end

  def plan(%{entries: entries}, facts, goal_record)
      when is_list(entries) and is_list(facts) and is_map(goal_record) do
    if Enum.all?(entries, &inventory_entry?/1) do
      entries
      |> Enum.uniq_by(&{&1.locator.namespace, &1.locator.run_id})
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, groups} ->
        case plan_entry(entry, entries, facts, goal_record) do
          {:ok, next} -> {:cont, {:ok, groups ++ next}}
          error -> {:halt, error}
        end
      end)
    else
      failure("Goal recovery inventory is malformed")
    end
  end

  def plan(_, _, _), do: failure("Goal recovery inventory is malformed")

  defp inventory_entry?(%{locator: locator, availability: availability} = entry)
       when is_map(locator) do
    valid_locator =
      is_binary(locator[:namespace]) and is_binary(locator[:session_id]) and
        is_binary(locator[:run_id]) and is_integer(locator[:incarnation]) and
        locator.incarnation >= 0

    valid_locator and
      case {availability, entry[:aggregate]} do
        {:absent, nil} ->
          true

        {:present, %{run: run, revision: revision, incarnation: incarnation}} when is_map(run) ->
          is_binary(run[:run_id]) and is_integer(run[:incarnation]) and
            is_integer(run[:expected_revision]) and is_atom(run[:state]) and
            is_map(run[:context]) and is_integer(revision) and is_integer(incarnation)

        _ ->
          false
      end
  end

  defp inventory_entry?(_), do: false

  # Called by the actual Goal owner, never by the delivery job.
  def bind_recovery(goal, group) do
    root = group.root_fact || group.fact

    with {:ok, binding} <- native_call(fn -> Goal.bind(goal, binding_attrs(root)) end) do
      case validate_binding(goal, binding, root) do
        {:ok, binding} ->
          if group.root_fact do
            bind_descendant(goal, group.fact, binding)
          else
            {:ok, %{binding: binding, bindings: [binding]}}
          end

        error ->
          cleanup_result(goal, [binding], error)
      end
    end
  end

  # The existing monitored preparation job owns this bounded synchronous work.
  # Always retire only the fresh recovery capabilities, including on exceptions.
  def deliver_and_ack(goal, group, bound) do
    result =
      try do
        with {:ok, aggregate} <- Store.load(group.context, group.locator.run_id),
             :ok <- retained_group(aggregate, group),
             {:ok, _responses} <- GoalBridge.deliver(goal, bound.binding, group.receipts),
             context = %{group.context | incarnation: aggregate.run.incarnation},
             command =
               {:goal_outbox_acknowledged, System.system_time(:millisecond),
                %{
                  run_id: aggregate.run.run_id,
                  incarnation: aggregate.run.incarnation,
                  receipts: group.receipts
                }},
             {:ok, staged} <-
               NativeStore.stage(Store, context, aggregate.run, %{command: command}),
             {:ok, _ack} <- NativeStore.acknowledge_commit(Store, context, staged.stage, %{}),
             {:ok, reloaded} <- Store.load(context, group.locator.run_id) do
          {:ok, reloaded}
        end
      catch
        kind, reason ->
          failure("Goal recovery delivery or acknowledgement failed", %{
            kind: kind,
            reason: reason
          })
      end

    cleanup_result(goal, bound.bindings, result)
  end

  defp plan_entry(%{availability: :absent}, _entries, _facts, _record), do: {:ok, []}

  defp plan_entry(%{locator: locator, aggregate: %{run: run} = aggregate}, entries, facts, record) do
    outbox =
      case run.context[:conversation] do
        nil -> nil
        conversation when is_map(conversation) -> Map.get(conversation, :goal_outbox)
        _ -> :malformed
      end

    case outbox do
      value when value in [nil, []] ->
        {:ok, []}

      receipts when is_list(receipts) ->
        with true <- run.state in @terminal,
             true <- run.run_id == locator.run_id,
             true <- aggregate.incarnation == run.incarnation,
             true <- aggregate.revision == run.expected_revision,
             true <- consistent_aggregate?(locator, aggregate, entries),
             true <- unique_receipts?(receipts) do
          receipts
          |> Enum.chunk_by(fn receipt ->
            {receipt[:thread_id], receipt[:run_id], receipt[:incarnation],
             receipt[:expected_goal_id]}
          end)
          |> Enum.reduce_while({:ok, []}, fn receipts, {:ok, groups} ->
            case plan_group(locator, aggregate, receipts, entries, facts, record) do
              {:ok, group} -> {:cont, {:ok, groups ++ [group]}}
              error -> {:halt, error}
            end
          end)
        else
          false -> failure("Goal recovery requires an exact terminal aggregate")
        end

      _ ->
        failure("Retained Goal outbox is malformed")
    end
  end

  defp plan_entry(_, _, _, _), do: failure("Goal recovery aggregate is malformed")

  defp consistent_aggregate?(locator, aggregate, entries) do
    Enum.all?(entries, fn entry ->
      if entry.locator.namespace == locator.namespace and entry.locator.run_id == locator.run_id,
        do: entry[:availability] == :present and entry[:aggregate] === aggregate,
        else: true
    end)
  end

  defp plan_group(locator, aggregate, receipts, entries, facts, record) do
    receipt = hd(receipts)

    candidates =
      Enum.filter(facts, fn fact ->
        is_map(fact) and fact[:namespace] == locator.namespace and
          fact[:session_id] == locator.session_id and fact[:run_id] == receipt.run_id and
          fact[:incarnation] == receipt.incarnation
      end)

    with [fact] <- candidates,
         {:ok, source_locator} <- validate_fact(fact, entries),
         true <- fact.run_id == aggregate.run.run_id,
         true <- record[:thread_id] == fact.session_id,
         true <- is_binary(fact.expected_goal_id) and fact.expected_goal_id != "",
         true <- is_map(record[:goal]) and record.goal[:goal_id] == fact.expected_goal_id,
         true <- Enum.all?(receipts, &receipt_matches?(&1, fact)),
         {:ok, root} <- root_for(fact, entries, facts, []),
         true <- fact.provenance == :bound_root or Enum.all?(receipts, &(&1.type == :usage)) do
      {:ok,
       %{
         locator: source_locator,
         context: %{namespace: source_locator.namespace, incarnation: aggregate.run.incarnation},
         fact: fact,
         root_fact: if(fact.provenance == :bound_root, do: nil, else: root),
         receipts: receipts
       }}
    else
      {:error, _} = error -> error
      _ -> failure("Retained Goal receipt attribution is incomplete or conflicting")
    end
  end

  defp validate_fact(fact, entries) do
    keys =
      if fact[:provenance] == :intended_child,
        do: @fact_keys ++ [:parent_attribution],
        else: @fact_keys

    locators =
      entries
      |> Enum.map(& &1.locator)
      |> Enum.filter(fn locator ->
        locator.session_id == fact[:session_id] and locator.namespace == fact[:namespace] and
          locator.run_id == fact[:run_id] and locator.incarnation == fact[:incarnation]
      end)
      |> Enum.uniq()

    with true <- Enum.sort(Map.keys(fact)) == Enum.sort(keys),
         true <- fact.version == 1 and is_binary(fact.session_id) and is_binary(fact.namespace),
         true <-
           is_binary(fact.run_id) and is_integer(fact.incarnation) and fact.incarnation >= 0,
         true <- fact.mode in [:execution, :plan] and valid_mode_provenance?(fact),
         true <- is_nil(fact.expected_goal_id) or is_binary(fact.expected_goal_id),
         [locator] <- locators,
         true <- locator[:mode_provenance] === fact.mode_provenance,
         true <- valid_kind?(fact, locator) do
      {:ok, locator}
    else
      _ -> failure("Retained Goal attribution fact does not match its original locator")
    end
  end

  defp valid_kind?(%{provenance: :bound_root} = fact, locator) do
    locator[:kind] == :root and fact.thread_id == fact.session_id and
      is_nil(fact.root_thread_id) and is_nil(fact.root_goal_id)
  end

  defp valid_kind?(%{provenance: :intended_child} = fact, locator) do
    locator[:kind] == :child and fact.thread_id == fact.run_id and
      fact.root_thread_id == fact.session_id and fact.root_goal_id == fact.expected_goal_id and
      is_map(fact.parent_attribution) and
      Enum.sort(Map.keys(fact.parent_attribution)) == Enum.sort(@attribution) and
      locator[:parent_run_id] == fact.parent_attribution.run_id
  end

  defp valid_kind?(_, _), do: false

  defp valid_mode_provenance?(%{mode: mode, mode_provenance: provenance}) do
    case provenance do
      %{version: 1, mode: :execution, source: :default, selected_mode: nil} ->
        mode == :execution

      %{version: 1, mode: :plan, source: :user_mode, selected_mode: "plan_mode"} ->
        mode == :plan

      %{version: 1, mode: :execution, source: :user_mode, selected_mode: selected}
      when selected in [
             "bypass_permissions",
             "ask_before_edits",
             "edit_automatically",
             "assistant_mode"
           ] ->
        mode == :execution

      _ ->
        false
    end
  end

  defp root_for(%{provenance: :bound_root} = fact, _entries, _facts, _seen), do: {:ok, fact}

  defp root_for(fact, entries, facts, seen) do
    identity = {fact.namespace, fact.run_id, fact.incarnation}

    parents =
      Enum.filter(facts, fn parent ->
        is_map(parent) and parent[:session_id] == fact.session_id and
          parent[:namespace] == fact.namespace and projection(parent) === fact.parent_attribution
      end)

    with false <- identity in seen,
         [parent] <- parents,
         {:ok, _locator} <- validate_fact(parent, entries),
         true <- parent.mode == fact.mode and parent.expected_goal_id == fact.expected_goal_id,
         {:ok, root} <- root_for(parent, entries, facts, [identity | seen]),
         true <-
           root.thread_id == fact.root_thread_id and root.expected_goal_id == fact.root_goal_id do
      {:ok, root}
    else
      {:error, _} = error -> error
      _ -> failure("Retained Goal parent chain is incomplete or conflicting")
    end
  end

  defp receipt_matches?(receipt, fact) when is_map(receipt) do
    receipt[:thread_id] == fact.thread_id and receipt[:run_id] == fact.run_id and
      receipt[:incarnation] == fact.incarnation and
      receipt[:expected_goal_id] == fact.expected_goal_id and
      is_binary(receipt[:receipt_id]) and receipt.receipt_id != "" and
      is_binary(receipt[:turn_id]) and is_integer(receipt[:revision]) and receipt.revision > 0 and
      receipt[:type] in @events and is_map(receipt[:payload])
  end

  defp receipt_matches?(_, _), do: false

  defp unique_receipts?(receipts) do
    ids = Enum.map(receipts, fn receipt -> if is_map(receipt), do: receipt[:receipt_id] end)
    Enum.all?(ids, &(is_binary(&1) and &1 != "")) and length(ids) == length(Enum.uniq(ids))
  end

  defp bind_descendant(goal, fact, root_binding) do
    case native_call(fn -> Goal.delegate(goal, root_binding, binding_attrs(fact)) end) do
      {:ok, binding} ->
        case validate_binding(goal, binding, fact) do
          {:ok, binding} -> {:ok, %{binding: binding, bindings: [binding, root_binding]}}
          error -> cleanup_result(goal, [binding, root_binding], error)
        end

      error ->
        cleanup_result(goal, [root_binding], error)
    end
  end

  defp binding_attrs(fact) do
    %{
      thread_id: fact.thread_id,
      run_id: fact.run_id,
      incarnation: fact.incarnation,
      mode: fact.mode,
      usage_authoritative: false,
      authority: %{
        caller: "synapsis:" <> fact.session_id,
        run_id: fact.run_id,
        grants: [],
        tool_revision: 1,
        tool_revisions: %{}
      }
    }
  end

  defp validate_binding(goal, binding, fact) do
    with {:ok, validated} <- native_call(fn -> Goal.attribution(goal, binding) end),
         true <- projection(validated) === projection(fact),
         true <- validated.usage_authoritative == false do
      {:ok, validated}
    else
      false -> failure("Fresh Goal recovery binding differs from retained attribution")
      error -> error
    end
  end

  defp retained_group(%{run: run}, group) do
    outbox = get_in(run, [:context, :conversation, :goal_outbox])

    if run.state in @terminal and run.run_id == group.locator.run_id and is_list(outbox) and
         group.receipts != [] and
         Enum.all?(group.receipts, fn receipt ->
           Enum.filter(outbox, &(&1[:receipt_id] == receipt.receipt_id)) === [receipt]
         end) do
      :ok
    else
      failure("Goal recovery receipts no longer match the terminal aggregate")
    end
  end

  defp cleanup_result(goal, bindings, result) do
    errors =
      Enum.flat_map(bindings, fn binding ->
        outcome = native_call(fn -> Goal.unbind(goal, binding) end)

        case outcome do
          {:ok, :unbound} -> []
          error -> [error]
        end
      end)

    case errors do
      [] ->
        result

      errors ->
        failure("Goal recovery binding cleanup was not acknowledged", %{
          result: result,
          errors: errors
        })
    end
  end

  defp projection(binding), do: Map.new(@attribution, &{&1, Map.get(binding, &1)})

  defp native_call(fun) do
    fun.()
  catch
    kind, reason ->
      {:error,
       Error.new(:execution_failure, "Goal recovery native operation failed",
         details: %{kind: kind, reason: reason}
       )}
  end

  defp failure(message, details \\ %{}),
    do: {:error, Error.new(:resource_conflict, message, details: details)}
end
