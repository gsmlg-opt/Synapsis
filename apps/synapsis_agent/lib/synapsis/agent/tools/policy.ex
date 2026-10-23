defmodule Synapsis.Agent.Tools.Policy do
  @moduledoc """
  Fail-closed host policy for Backplane's native `prepare_tool/2` hook.

  The host supplies `tool_scope`, `tool_policy`, and `tool_readiness` in trusted
  hook context. These sidecars and classifiers are in-process host metadata,
  not provider arguments or a replacement runtime contract. Caller is explicitly
  host-trusted; invocation run, incarnation, and catalog revision must match it.

  Policy is `%{scope: scope, tools: %{name => %{tool_revision: revision,
  classify: classifier}}, decisions: %{{name, action, resource} => decision}}`.
  Each trusted classifier accepts the original invocation and returns
  `{:ok, %{action: nonempty_string, resource: nonempty_string}}` or
  `{:error, reason}`. The host owns classification of tool-specific arguments;
  model-supplied permission labels have no authority. Classifiers should be
  bounded and pure. Backplane bounds the preparation worker.

  Decisions are exact `:allow`, `:deny`, or `:ask`. No globs, defaults, legacy
  Registry/Grant interpretation, or autonomous-mode shortcuts apply. `:ask`
  requires an explicit trusted interactive Approval context; without it the
  result remains `{:deny, :approval_required}`. Approval never edits input.
  Allow returns `:allow`, preserving the original function or custom input.

  Resource IDs are opaque: matching them provides neither filesystem containment
  nor live credential verification. Host classifiers and readiness producers must
  enforce those domain requirements. This module is not wired into production.
  """

  alias Synapsis.Agent.Tools.{Approval, Readiness}

  @spec prepare_tool(map(), map()) :: :allow | {:deny, term()}
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
