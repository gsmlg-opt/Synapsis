defmodule Synapsis.Session.Worker.GoalHost do
  @moduledoc """
  Native Goal callbacks at the existing Worker's resident admission boundary.

  The ordinary lifecycle does not enable host mutations or automatic continuation.
  These callbacks never invent instruction acknowledgements or release work. A
  later continuation implementation must reserve and release through this Worker,
  after the existing input lane and native readiness have both acknowledged idle.
  """
  @behaviour Backplane.AgentRuntime.Goal.Host

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Session.Worker.PendingInputs

  @impl true
  def record_user_instruction(context, thread_id, instruction),
    do: call(context, thread_id, :instruction, instruction)

  @impl true
  def start_turn_if_idle(context, thread_id, request),
    do: call(context, thread_id, :idle, request)

  @doc false
  def reply(data, context, thread_id, operation, _request) do
    if context[:owner] == self() and context[:adapter] == data.runtime_pid and
         context[:epoch] == data.runtime_epoch and thread_id == data.session_id and
         context[:session_id] == data.session_id do
      case operation do
        :instruction ->
          {:error,
           Error.new(:unsupported_capability, "Canonical Goal host controls are not enabled")}

        :idle ->
          reason =
            if PendingInputs.idle?(data) and not data.runtime_roster[:recovery_required] and
                 is_nil(data.runtime_roster[:error]),
               do: :continuation_inactive,
               else: :host_not_idle

          {:ok, {:not_submitted, reason}}
      end
    else
      {:error, Error.new(:resource_conflict, "Goal host owner is no longer current")}
    end
  end

  defp call(%{owner: owner} = context, thread_id, operation, request) when is_pid(owner) do
    :gen_statem.call(owner, {:goal_host, context, thread_id, operation, request}, 1_000)
  catch
    :exit, _ -> {:error, Error.new(:execution_failure, "Goal host is unavailable")}
  end
end
