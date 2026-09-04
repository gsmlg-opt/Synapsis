defmodule Synapsis.Agent.RunReconciler do
  @moduledoc """
  Classifies incomplete runs after process/node restart.

  Never blindly replays non-idempotent side effects. When a side-effect intent
  was recorded and no terminal fact exists, the outcome is `unknown_outcome`.
  """

  alias Synapsis.AgentRun

  @type context :: %{
          optional(:alive?) => boolean(),
          optional(:now) => DateTime.t(),
          optional(:side_effect_intent?) => boolean()
        }

  @spec classify(AgentRun.t(), context()) ::
          {:keep, AgentRun.t()}
          | {:reconcile, String.t(), map()}
  def classify(%AgentRun{} = run, context \\ %{}) when is_map(context) do
    cond do
      AgentRun.terminal?(run) ->
        {:keep, run}

      Map.get(context, :alive?, false) ->
        {:keep, run}

      timed_out?(run, context) ->
        {:reconcile, "timed_out",
         %{
           "error" => "deadline exceeded before reconciliation",
           "failure_class" => "timeout"
         }}

      side_effect_intent?(run, context) ->
        {:reconcile, "unknown_outcome",
         %{
           "error" => "uncertain side effect after restart",
           "failure_class" => "unknown_outcome"
         }}

      true ->
        {:reconcile, "failed",
         %{
           "error" => "daemon restarted before completion",
           "failure_class" => "restart"
         }}
    end
  end

  defp timed_out?(%AgentRun{deadline_at: %DateTime{} = deadline}, context) do
    now = Map.get(context, :now, DateTime.utc_now())
    DateTime.compare(now, deadline) != :lt
  end

  defp timed_out?(_run, _context), do: false

  defp side_effect_intent?(%AgentRun{} = run, context) do
    Map.get(context, :side_effect_intent?) ||
      Map.get(run.recovery_state || %{}, "side_effect_intent") == true
  end
end
