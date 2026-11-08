defmodule Synapsis.Agent.Tools.Approval do
  @moduledoc """
  Host consent for a dynamic policy `:ask` during native tool preparation.

  Trusted context supplies `tool_approval` with interactive `mode`, a `scope`
  extending the exact tool scope with `session_id` and `requester_id`, an absolute
  millisecond `expires_at`, and `refresh: fn -> {:ok, current_context} end`.
  Refresh must read current host policy/readiness and interactive scope; it must
  not simply return a cached permission snapshot. No functions or process handles
  enter the native persisted interaction request.

  Synapsis treats access to its UI/API as trusted operator access and supplies the
  server-owned `synapsis:operator` identity. `resolve/4` receives that host decision. Its final
  argument contains trusted `scope` and the original server-held `operation`;
  neither identity may come from model fields. Native Approval validates the
  operation decision, not user authentication. Conversation owns interaction IDs,
  single-use resolution, cancellation, persistence and preparation deadlines.

  Expiry is enforced at request and resolution, including after refresh. There is
  no background human timer here. A waiting request can remain pending after its
  host expiry, but it cannot authorize execution. Callers may explicitly cancel it.
  Input edits are refused: preparation runs once, so native approval edits would
  otherwise skip this action/resource policy check. `resolve/4` handles only this
  module's scoped dynamic requests. Built-in descriptor approval is independent
  and can require a second consent; safe host integration with that later gate is
  not supported here. The host must restrict its input edits and revalidate dynamic
  policy and expiry after its wait. Passing the dynamic gate does not establish
  host freshness or TTL across both approvals.
  """

  alias Backplane.AgentRuntime.{Conversation, Error}
  alias Backplane.AgentRuntime.Approval, as: NativeApproval
  alias Backplane.AgentRuntime.Codex.MultiAgent
  alias Synapsis.Agent.Tools.Policy

  def operator_id, do: "synapsis:operator"

  @spec request(map(), map(), map()) :: :allow | {:deny, term()}
  def request(invocation, context, evaluation) do
    with {:ok, approval} <- approval_context(context),
         :ok <- unexpired(approval.expires_at),
         :ok <- serializable_request(invocation, approval, evaluation),
         {:ok, :approved} <- context.interact.(request_map(invocation, approval, evaluation)),
         :ok <- unexpired(approval.expires_at),
         {:ok, current} <- refresh(approval),
         {:ok, current_expiry} <- current_context(context, current, approval),
         {:ok, actual} <- Policy.evaluate(invocation, current),
         true <-
           Map.take(actual, [:action, :resource]) === Map.take(evaluation, [:action, :resource]),
         :ok <- unexpired(current_expiry) do
      :allow
    else
      {:deny, _} = denial -> denial
      {:error, reason} -> {:deny, reason}
      false -> {:deny, :approval_target_changed}
      _ -> {:deny, :approval_denied}
    end
  end

  @spec resolve(pid(), String.t(), :approved | :denied, map()) :: :ok | {:error, Error.t()}
  def resolve(pid, id, decision, %{scope: scope, operation: operation})
      when is_pid(pid) and is_binary(id) and decision in [:approved, :denied] and is_map(scope) do
    status = Conversation.status(pid)

    with %{id: ^id, request: %{kind: :permission, operation: ^operation, scope: ^scope} = request} <-
           status.conversation.pending_interaction,
         true <- valid_scope?(scope),
         true <- current_operation?(operation, status),
         :ok <- unexpired(request.expires_at),
         {:ok, ^decision} <- native_decision(id, request, decision, scope.requester_id) do
      Conversation.resolve(pid, id, decision)
    else
      {:error, %Error{}} = error ->
        error

      _ ->
        {:error,
         Error.new(:forbidden, "approval is stale, expired or outside trusted host scope")}
    end
  catch
    :exit, _ -> {:error, Error.new(:resource_conflict, "approval conversation is unavailable")}
  end

  def resolve(_, _, _, _),
    do: {:error, Error.new(:validation, "a trusted host decision and exact scope are required")}

  @doc "Resolves a manager-observed child request using its exact native correlation."
  def resolve_managed(manager, correlation, decision, %{scope: scope, operation: operation})
      when is_pid(manager) and is_map(correlation) and is_map(scope) and is_map(operation) and
             decision in [:approved, :denied] do
    with {:ok, snapshot} <- MultiAgent.snapshot(manager),
         %{pending_interaction: %{correlation: ^correlation, request: request}} <-
           Enum.find(snapshot.agents, &(&1.agent_id == correlation.agent_id)),
         true <- field(request, :kind) == "permission",
         true <- field(request, :scope) === scope and field(request, :operation) === operation,
         true <- valid_scope?(scope),
         true <-
           field(operation, :run_id) === correlation.run_id and
             field(operation, :incarnation) === correlation.incarnation and
             field(operation, :catalog_revision) === field(scope, :catalog_revision),
         :ok <- unexpired(field(request, :expires_at)),
         {:ok, ^decision} <-
           native_decision(
             correlation.interaction_id,
             request,
             decision,
             field(scope, :requester_id)
           ) do
      MultiAgent.resolve_interaction(manager, correlation, decision)
    else
      {:error, %Error{}} = error ->
        error

      _ ->
        {:error, Error.new(:forbidden, "child approval is stale or outside trusted host scope")}
    end
  catch
    :exit, _ -> {:error, Error.new(:resource_conflict, "approval manager is unavailable")}
  end

  defp approval_context(%{tool_approval: approval, tool_scope: scope, interact: interact})
       when is_map(approval) and is_map(scope) and is_function(interact, 1) do
    with %{mode: :interactive, scope: approval_scope, expires_at: expiry, refresh: refresh} <-
           approval,
         true <- valid_scope?(approval_scope) and is_integer(expiry) and is_function(refresh, 0),
         true <-
           Enum.all?(scope, fn {key, value} -> Map.fetch(approval_scope, key) === {:ok, value} end) do
      {:ok, approval}
    else
      _ -> {:error, :approval_unavailable}
    end
  end

  defp approval_context(%{tool_approval: _}), do: {:error, :approval_unavailable}
  defp approval_context(_), do: {:error, :approval_required}

  defp current_context(original, current, approval) when is_map(current) do
    with true <-
           current[:tool_scope] === original.tool_scope and
             current[:input_kind] === original.input_kind,
         {:ok, refreshed} <- approval_context(current),
         true <-
           refreshed.scope === approval.scope and refreshed.expires_at <= approval.expires_at,
         :ok <- unexpired(refreshed.expires_at) do
      {:ok, refreshed.expires_at}
    else
      {:error, :approval_expired} = expired -> expired
      _ -> {:error, :approval_context_changed}
    end
  end

  defp current_context(_, _, _), do: {:error, :approval_context_changed}

  defp refresh(approval) do
    case approval.refresh.() do
      {:ok, current} when is_map(current) -> {:ok, current}
      _ -> {:error, :approval_refresh_failed}
    end
  end

  defp request_map(invocation, approval, evaluation),
    do: %{
      kind: :permission,
      operation: invocation,
      scope: approval.scope,
      expires_at: approval.expires_at,
      action: evaluation.action,
      resource: evaluation.resource
    }

  defp serializable_request(invocation, approval, evaluation) do
    if not Map.has_key?(invocation, :backend_context) and
         match?({:ok, _}, Jason.encode(request_map(invocation, approval, evaluation))),
       do: :ok,
       else: {:error, :invalid_approval_request}
  end

  defp valid_scope?(scope) when is_map(scope) do
    Enum.all?([:caller, :run_id, :session_id, :requester_id], fn key ->
      is_binary(field(scope, key)) and String.trim(field(scope, key)) != ""
    end) and
      Enum.all?([:incarnation, :catalog_revision], fn key ->
        is_integer(field(scope, key)) and field(scope, key) > 0
      end)
  end

  defp valid_scope?(_), do: false

  defp current_operation?(operation, status) do
    operation.run_id === status.run.run_id and operation.incarnation === status.run.incarnation and
      operation.catalog_revision === status.catalog_revision
  end

  defp native_decision(id, request, decision, requester) do
    operation = field(request, :operation)

    approval =
      %{
        approval_id: id,
        run_id: field(operation, :run_id),
        tool_name: field(operation, :tool_name),
        tool_revision: field(operation, :tool_revision),
        arguments_digest:
          :crypto.hash(:sha256, :erlang.term_to_binary(field(operation, :arguments)))
          |> Base.encode16(case: :lower),
        current_time: System.system_time(:millisecond),
        expires_at: field(request, :expires_at)
      }
      |> Map.put(:collaboration_binding, field(operation, :collaboration_binding))

    answer =
      approval
      |> Map.drop([:run_id, :current_time, :expires_at])
      |> Map.merge(%{decision: decision, resolver_id: requester})

    NativeApproval.decide(approval, answer)
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp unexpired(expiry) do
    if is_integer(expiry) and System.system_time(:millisecond) <= expiry,
      do: :ok,
      else: {:error, :approval_expired}
  end
end
