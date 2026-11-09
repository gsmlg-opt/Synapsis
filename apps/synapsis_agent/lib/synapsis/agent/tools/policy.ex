defmodule Synapsis.Agent.Tools.Policy do
  @moduledoc """
  Fail-closed host policy for Backplane's native `prepare_tool/2` hook.

  The host supplies `tool_scope`, `tool_policy`, and `tool_readiness` in trusted
  hook context. These sidecars and classifiers are in-process host metadata,
  not provider arguments or a replacement runtime contract. Caller is explicitly
  host-trusted; invocation run, incarnation, and catalog revision must match it.

  Policy is `%{scope: scope, tools: %{name => %{tool_revision: revision,
  classify: classifier}}, decisions: %{{name, action, resource} => decision}}`.
  Each trusted classifier accepts the prepared invocation and returns
  `{:ok, %{action: nonempty_string, resource: nonempty_string}}` or
  `{:error, reason}`. The host owns classification of tool-specific arguments;
  model-supplied permission labels have no authority. Classifiers should be
  bounded and pure. Backplane bounds the preparation worker.

  Decisions are exact `:allow`, `:deny`, or `:ask`. No globs, defaults, legacy
  Registry/Grant interpretation, or autonomous-mode shortcuts apply. `:ask`
  requires an explicit trusted interactive Approval context; without it the
  result remains `{:deny, :approval_required}`. Approval never edits input.
  Allow preserves the original function or custom input, except canonical
  filesystem tools return their prepared argument map to native admission.

  Resource IDs are opaque: matching them provides neither filesystem containment
  nor live credential verification. Host classifiers and readiness producers must
  enforce those domain requirements. Production resolves immutable run snapshots
  through the trusted `tool_context_resolver` before evaluating each invocation.
  """

  alias Synapsis.Agent.Tools.{Approval, Filesystem, Profiles, Readiness}

  @approval_timeout 300_000

  def tool_effect_timeout(invocation, context) do
    Synapsis.Agent.Tools.Browser.tool_effect_timeout(invocation, context)
  end

  @spec prepare_tool(map(), map()) :: :allow | {:allow, map()} | {:deny, term()}
  def prepare_tool(invocation, %{tool_context_resolver: resolver} = context)
      when is_function(resolver, 2) or is_function(resolver, 1) do
    expiry = System.system_time(:millisecond) + @approval_timeout

    with {:ok, snapshot} <- resolve_snapshot(invocation, context),
         {:ok, %{descriptor: descriptor}} <- Profiles.preparation_binding(invocation, snapshot),
         {:ok, prepared, canonical?} <- prepare_arguments(invocation, descriptor, context),
         {:ok, trusted} <- production_context(prepared, snapshot, context, expiry) do
      case prepare_tool(prepared, trusted) do
        :allow when canonical? -> {:allow, prepared.arguments}
        result -> result
      end
    else
      {:error, reason} -> {:deny, reason}
      _ -> {:deny, :invalid_policy_context}
    end
  rescue
    _ -> {:deny, :tool_context_unavailable}
  catch
    _, _ -> {:deny, :tool_context_unavailable}
  end

  def prepare_tool(invocation, context) do
    case evaluate(invocation, context) do
      {:ok, %{decision: :allow}} -> :allow
      {:ok, %{decision: :ask} = evaluation} -> Approval.request(invocation, context, evaluation)
      {:deny, _} = denial -> denial
    end
  end

  @doc "Evaluates trusted policy and readiness without requesting an interaction."
  @spec evaluate(map(), map()) :: {:ok, map()} | {:deny, term()}
  def evaluate(
        %{tool_name: name, tool_revision: revision} = invocation,
        %{
          tool_scope: scope,
          tool_policy: %{scope: policy_scope, tools: tools, decisions: decisions},
          tool_readiness: readiness,
          input_kind: kind
        }
      )
      when is_map(scope) and is_map(tools) and is_map(decisions) and
             kind in [:function, :custom] do
    with :ok <- matching_scope(invocation, scope, policy_scope),
         {:ok, classifier} <- classifier(tools, name, revision),
         :ok <- Readiness.check(%{scope: scope, tools: %{name => revision}}, readiness),
         {:ok, action, resource} <- classify(classifier, invocation) do
      decide(Map.get(decisions, {name, action, resource}, :missing), action, resource)
    else
      {:error, reason} -> {:deny, reason}
    end
  end

  def evaluate(_, _), do: {:deny, :invalid_policy_context}

  defp prepare_arguments(
         invocation,
         %{backend: Filesystem, tool_revision: 1, tool_name: name} = descriptor,
         context
       )
       when name in ~w(synapsis::read synapsis::write synapsis::edit synapsis::ls) do
    with {:ok, arguments} <- Filesystem.prepare_arguments(invocation, descriptor, context),
         do: {:ok, %{invocation | arguments: arguments}, true}
  end

  defp prepare_arguments(invocation, _descriptor, _context), do: {:ok, invocation, false}

  defp production_context(invocation, snapshot, context, expiry) do
    with {:ok, sidecars} <- Profiles.prepare_context(invocation, snapshot) do
      trusted = Map.merge(Map.take(context, [:input_kind, :interact]), sidecars)

      if snapshot.permission.mode == :interactive and
           context[:tool_operator_id] == Approval.operator_id() do
        approval = %{
          mode: :interactive,
          scope: Map.put(sidecars.tool_scope, :requester_id, Approval.operator_id()),
          expires_at: expiry,
          refresh: fn ->
            with {:ok, current} <- resolve_snapshot(invocation, context),
                 do: production_context(invocation, current, context, expiry)
          end
        }

        {:ok, Map.put(trusted, :tool_approval, approval)}
      else
        {:ok, trusted}
      end
    end
  end

  defp resolve_snapshot(invocation, %{tool_context_resolver: resolver, catalog_snapshot: catalog})
       when is_function(resolver, 2),
       do: resolver.(invocation, catalog)

  defp resolve_snapshot(invocation, %{tool_context_resolver: resolver})
       when is_function(resolver, 1),
       do: resolver.(invocation)

  defp resolve_snapshot(_, _), do: {:error, :invalid_tool_snapshot}

  defp matching_scope(invocation, scope, policy_scope) do
    if policy_scope === scope and
         Enum.all?([:run_id, :incarnation, :catalog_revision], fn field ->
           Map.has_key?(scope, field) and Map.get(invocation, field) === scope[field]
         end),
       do: :ok,
       else: {:error, :scope_mismatch}
  end

  defp classifier(tools, name, revision) do
    case Map.get(tools, name) do
      nil ->
        {:error, :unknown_tool}

      %{tool_revision: actual} when actual !== revision ->
        {:error, :stale_policy}

      %{tool_revision: ^revision, classify: classifier} when is_function(classifier, 1) ->
        {:ok, classifier}

      _ ->
        {:error, :unsupported_classification}
    end
  end

  defp classify(classifier, invocation) do
    case classifier.(invocation) do
      {:ok, %{action: action, resource: resource}}
      when is_binary(action) and action != "" and is_binary(resource) and resource != "" ->
        {:ok, action, resource}

      {:error, reason} ->
        {:error, {:classification_failed, reason}}

      _ ->
        {:error, :unsupported_classification}
    end
  end

  defp decide(decision, action, resource) when decision in [:allow, :ask],
    do: {:ok, %{decision: decision, action: action, resource: resource}}

  defp decide(:deny, _, _), do: {:deny, :policy_denied}
  defp decide(:missing, _, _), do: {:deny, :missing_decision}
  defp decide(_, _, _), do: {:deny, :unsupported_decision}
end
