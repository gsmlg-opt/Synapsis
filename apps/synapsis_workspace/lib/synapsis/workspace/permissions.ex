defmodule Synapsis.Workspace.Permissions do
  @moduledoc """
  Path-based access control for agent workspace operations.

  Rules (per WS-17):
  - User role: unrestricted read/write everywhere.
  - Global agent: read/write `/shared/**`, `/global/**`, and any delegated agent workspace.
  - Agent role: read/write own `/agents/:agent/**`, read-only `/shared/**`.
  - Session role: read/write own `/agents/:agent/sessions/<own-session>/**`,
    read-only for its agent-level workspace and `/shared/**`.
  """

  alias Synapsis.Workspace.PathResolver

  @type agent_context :: %{
          required(:role) => :global | :agent | :session | :user,
          optional(:agent_id) => String.t() | nil,
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

  defp check_role(:global, _ctx, %{scope: :global}, _action), do: :allowed

  defp check_role(:global, ctx, %{scope: scope, agent_id: path_agent_id}, _action)
       when scope in [:agent, :session] do
    if delegated_to?(ctx, path_agent_id), do: :allowed, else: :denied
  end

  defp check_role(:agent, ctx, %{scope: :agent, agent_id: path_agent_id}, _action) do
    if own_agent?(ctx, path_agent_id), do: :allowed, else: :denied
  end

  defp check_role(:agent, ctx, %{scope: :session, agent_id: path_agent_id}, _action) do
    if own_agent?(ctx, path_agent_id), do: :allowed, else: :denied
  end

  defp check_role(:agent, _ctx, %{scope: :global}, :read), do: :allowed
  defp check_role(:agent, _ctx, %{scope: :global}, :write), do: :denied

  defp check_role(:session, ctx, %{scope: :session, agent_id: agent_id, session_id: sid}, action) do
    cond do
      own_agent?(ctx, agent_id) and own_session?(ctx, sid) -> :allowed
      own_agent?(ctx, agent_id) -> gate_action(action)
      true -> :denied
    end
  end

  defp check_role(:session, ctx, %{scope: :agent, agent_id: path_agent_id}, :read) do
    if own_agent?(ctx, path_agent_id), do: :allowed, else: :denied
  end

  defp check_role(:session, _ctx, %{scope: :agent}, :write), do: :denied

  defp check_role(:session, _ctx, %{scope: :global}, :read), do: :allowed
  defp check_role(:session, _ctx, %{scope: :global}, :write), do: :denied

  # Catch-all: deny anything not explicitly allowed.
  defp check_role(_role, _ctx, _resolved, _action), do: :denied

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp own_agent?(%{agent_id: ctx_agent_id}, path_agent_id)
       when is_binary(ctx_agent_id) and is_binary(path_agent_id),
       do: ctx_agent_id == path_agent_id

  defp own_agent?(_ctx, _path_agent_id), do: false

  defp own_session?(%{session_id: ctx_sid}, path_sid)
       when is_binary(ctx_sid) and is_binary(path_sid),
       do: ctx_sid == path_sid

  defp own_session?(_ctx, _path_sid), do: false

  defp delegated_to?(%{agent_id: nil}, _path_agent_id), do: true

  defp delegated_to?(%{agent_id: ctx_agent_id}, path_agent_id) when is_binary(ctx_agent_id),
    do: ctx_agent_id == path_agent_id

  defp delegated_to?(_ctx, _path_agent_id), do: false

  # Enforce read-only access: read stays :allowed, write becomes :denied.
  defp gate_action(:read), do: :allowed
  defp gate_action(:write), do: :denied
end
