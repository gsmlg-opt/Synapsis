defmodule Synapsis.Agent.Tools.Readiness do
  @moduledoc """
  Checks trusted, in-process host readiness evidence for every selected tool.

  `check/2` accepts `%{scope: scope, tools: %{name => revision}}` and evidence
  `%{scope: scope, tools: %{name => %{tool_revision: revision, status: status}}}`.
  Scope contains exact `caller`, `run_id`, `incarnation`, and `catalog_revision`.
  Status is `:ready` or `{:unavailable, reason}`; unavailable reasons are retained.
  Empty selection must be explicit. Missing or stale evidence rejects selection
  instead of dropping tools. Extra unselected evidence grants nothing.

  This is host metadata, not a runtime protocol or live credential verifier.
  The host must obtain fresh evidence and invalidate it when dependencies change.
  """

  @spec check(map(), map()) :: :ok | {:error, term()}
  def check(%{scope: scope, tools: selected}, %{scope: evidence_scope, tools: evidence})
      when is_map(selected) and is_map(evidence) do
    cond do
      not valid_scope?(scope) -> {:error, :invalid_scope}
      scope !== evidence_scope -> {:error, :scope_mismatch}
      true -> check_tools(selected, evidence)
    end
  end

  def check(_, _), do: {:error, :invalid_readiness}

  defp check_tools(selected, evidence) do
    selected
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn {name, revision}, :ok ->
      result =
        if is_binary(name) and name != "" and is_integer(revision) and revision > 0,
          do: check_tool(name, revision, Map.get(evidence, name)),
          else: {:error, :invalid_selection}

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_tool(name, _, nil), do: {:error, {:missing_evidence, name}}

  defp check_tool(name, revision, %{tool_revision: actual}) when actual !== revision,
    do: {:error, {:stale_evidence, name}}

  defp check_tool(_, revision, %{tool_revision: revision, status: :ready}), do: :ok

  defp check_tool(name, revision, %{tool_revision: revision, status: {:unavailable, reason}}),
    do: {:error, {:unavailable, name, reason}}

  defp check_tool(name, _, _), do: {:error, {:unknown_readiness, name}}

  defp valid_scope?(%{
         caller: caller,
         run_id: run,
         incarnation: incarnation,
         catalog_revision: revision
       }) do
    is_binary(caller) and caller != "" and is_binary(run) and run != "" and
      is_integer(incarnation) and incarnation > 0 and is_integer(revision) and revision > 0
  end

  defp valid_scope?(_), do: false
end
