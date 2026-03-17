defmodule Synapsis.Workspace.Permissions do
  @moduledoc """
  Path-based access control for agent workspace operations.

  Rules (per WS-17):
  - User role: unrestricted read/write everywhere.
  - Global agent: read/write `/shared/**` and any `/projects/:id/**` it is delegated to.
  - Project agent: read/write own `/projects/:id/**`, read-only `/shared/**`.
  - Session agent: read/write own `/projects/:id/sessions/<own-session>/**`,
    read-only for project-level paths (`/projects/:id/**`) and `/shared/**`.
  """

  alias Synapsis.Workspace.PathResolver

  @type agent_context :: %{
          required(:role) => :global | :project | :session | :user,
          optional(:project_id) => String.t() | nil,
          optional(:session_id) => String.t() | nil
        }

  @doc """
  Check whether the given agent context is allowed to perform `action` on `path`.

  Returns `:allowed` or `:denied`.
  """
  @spec check(agent_context(), String.t(), :read | :write) :: :allowed | :denied
  def check(%{role: :user}, _path, _action), do: :allowed

  def check(%{role: role} = ctx, path, action) do
    case PathResolver.resolve(path) do
      {:error, _} ->
        :denied

      {:ok, resolved} ->
        check_role(role, ctx, resolved, action)
    end
  end

  # ---------------------------------------------------------------------------
  # Role-specific checks
  # ---------------------------------------------------------------------------

  # Global agent: read/write /shared/**, read/write any /projects/:id/** it is
  # explicitly delegated to (project_id in context must match).
  defp check_role(:global, _ctx, %{scope: :global}, _action), do: :allowed

  defp check_role(:global, ctx, %{scope: scope, project_id: path_project_id}, _action)
       when scope in [:project, :session] do
    if delegated_to?(ctx, path_project_id), do: :allowed, else: :denied
  end

  # Project agent: read/write own project tree, read-only on /shared.
  defp check_role(:project, ctx, %{scope: :project, project_id: path_project_id}, _action) do
    if own_project?(ctx, path_project_id), do: :allowed, else: :denied
  end

  defp check_role(:project, ctx, %{scope: :session, project_id: path_project_id}, _action) do
    if own_project?(ctx, path_project_id), do: :allowed, else: :denied
  end

  defp check_role(:project, _ctx, %{scope: :global}, :read), do: :allowed
  defp check_role(:project, _ctx, %{scope: :global}, :write), do: :denied

  # Session agent: read/write own session subtree, read-only for project and
  # shared paths (within the same project).
  defp check_role(:session, ctx, %{scope: :session, project_id: pid, session_id: sid}, action) do
    cond do
      own_project?(ctx, pid) and own_session?(ctx, sid) -> :allowed
      own_project?(ctx, pid) -> gate_action(action)
      true -> :denied
    end
  end

  defp check_role(:session, ctx, %{scope: :project, project_id: path_project_id}, :read) do
    if own_project?(ctx, path_project_id), do: :allowed, else: :denied
  end

  defp check_role(:session, _ctx, %{scope: :project}, :write), do: :denied

  defp check_role(:session, _ctx, %{scope: :global}, :read), do: :allowed
  defp check_role(:session, _ctx, %{scope: :global}, :write), do: :denied

  # Catch-all: deny anything not explicitly allowed.
  defp check_role(_role, _ctx, _resolved, _action), do: :denied

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp own_project?(%{project_id: ctx_pid}, path_pid)
       when is_binary(ctx_pid) and is_binary(path_pid),
       do: ctx_pid == path_pid

  defp own_project?(_ctx, _path_pid), do: false

  defp own_session?(%{session_id: ctx_sid}, path_sid)
       when is_binary(ctx_sid) and is_binary(path_sid),
       do: ctx_sid == path_sid

  defp own_session?(_ctx, _path_sid), do: false

  # A global agent is considered delegated to a project when its context
  # carries a matching project_id.  If no project_id is set the global agent
  # has unrestricted access to all project trees.
  defp delegated_to?(%{project_id: nil}, _path_pid), do: true
  defp delegated_to?(%{project_id: ctx_pid}, path_pid) when is_binary(ctx_pid), do: ctx_pid == path_pid
  defp delegated_to?(_ctx, _path_pid), do: false

  # Enforce read-only access: read stays :allowed, write becomes :denied.
  defp gate_action(:read), do: :allowed
  defp gate_action(:write), do: :denied
end
