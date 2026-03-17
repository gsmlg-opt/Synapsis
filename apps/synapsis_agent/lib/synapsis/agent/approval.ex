defmodule Synapsis.Agent.Approval do
  @moduledoc """
  Persistent tool approval checking (AI-7).

  Resolves tool approval policy by checking persistent approvals in the database.
  Resolution order: project-scoped → global → most specific pattern → default :ask.
  """

  alias Synapsis.{Repo, ToolApproval}
  import Ecto.Query
  require Logger

  @doc """
  Check the approval policy for a tool invocation.

  Returns `:allow`, `:record`, `:ask`, or `:deny`.

  ## Resolution Order

  1. Check project-scoped approvals (if project_id given)
  2. Check global approvals
  3. Most specific pattern wins (longer pattern = more specific)
  4. If no match → default to `:ask`
  """
  @spec check_approval(String.t(), map(), keyword()) :: :allow | :record | :ask | :deny
  def check_approval(tool_name, input, opts \\ []) do
    project_id = Keyword.get(opts, :project_id)

    approvals = load_approvals(project_id)

    matching =
      approvals
      |> Enum.filter(fn approval ->
        ToolApproval.matches?(approval, tool_name, input)
      end)
      |> Enum.sort_by(fn a ->
        # Sort by: 1) project-scoped first, 2) longest pattern first
        scope_priority = if a.scope == :project, do: 0, else: 1
        {scope_priority, -byte_size(a.pattern)}
      end)

    case matching do
      [best | _] -> best.policy
      [] -> :ask
    end
  end

  @doc """
  Persist a new tool approval rule.

  If an approval with the same scope/project/pattern exists, updates the policy.
  Broadcasts `:tool_approval_changed` via PubSub.
  """
  @spec persist_approval(String.t(), atom(), keyword()) ::
          {:ok, ToolApproval.t()} | {:error, term()}
  def persist_approval(pattern, policy, opts \\ []) do
    scope = Keyword.get(opts, :scope, :global)
    project_id = Keyword.get(opts, :project_id)
    created_by = Keyword.get(opts, :created_by, :user)

    attrs = %{
      pattern: pattern,
      scope: scope,
      project_id: project_id,
      policy: policy,
      created_by: created_by
    }

    existing =
      ToolApproval
      |> where([a], a.scope == ^scope and a.pattern == ^pattern)
      |> maybe_filter_project(project_id)
      |> Repo.one()

    result =
      case existing do
        nil ->
          %ToolApproval{}
          |> ToolApproval.changeset(attrs)
          |> Repo.insert()

        existing ->
          existing
          |> ToolApproval.changeset(%{policy: policy})
          |> Repo.update()
      end

    case result do
      {:ok, approval} ->
        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "tool_approvals",
          {:tool_approval_changed, pattern}
        )

        {:ok, approval}

      error ->
        error
    end
  end

  @doc "List all approvals, optionally filtered by scope and project."
  @spec list_approvals(keyword()) :: [ToolApproval.t()]
  def list_approvals(opts \\ []) do
    scope = Keyword.get(opts, :scope)
    project_id = Keyword.get(opts, :project_id)

    ToolApproval
    |> maybe_filter_scope(scope)
    |> maybe_filter_project(project_id)
    |> order_by([a], asc: a.pattern)
    |> Repo.all()
  end

  @doc "Delete an approval by ID."
  @spec delete_approval(String.t()) :: :ok | {:error, :not_found}
  def delete_approval(approval_id) do
    case Repo.get(ToolApproval, approval_id) do
      nil ->
        {:error, :not_found}

      approval ->
        Repo.delete(approval)

        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "tool_approvals",
          {:tool_approval_changed, approval.pattern}
        )

        :ok
    end
  end

  # -- Private --

  defp load_approvals(nil) do
    ToolApproval
    |> where([a], a.scope == :global)
    |> Repo.all()
  end

  defp load_approvals(project_id) do
    # Project-scoped first, then global
    ToolApproval
    |> where(
      [a],
      (a.scope == :project and a.project_id == ^project_id) or a.scope == :global
    )
    |> order_by([a], asc: a.scope)
    |> Repo.all()
  end

  defp maybe_filter_scope(query, nil), do: query
  defp maybe_filter_scope(query, scope), do: where(query, [a], a.scope == ^scope)

  defp maybe_filter_project(query, nil), do: query
  defp maybe_filter_project(query, pid), do: where(query, [a], a.project_id == ^pid)
end
