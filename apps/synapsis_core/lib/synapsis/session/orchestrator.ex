defmodule Synapsis.Session.Orchestrator do
  @moduledoc """
  Rules engine for agent loop control decisions.

  Consumes signals from `Synapsis.Session.Monitor` and decides whether
  the agent loop should continue, pause, escalate, or terminate.
  Pure functions — no GenServer. Called by the Worker at each iteration
  boundary (after tools complete, before starting next LLM call).

  ## Decision hierarchy (highest priority first)

  1. `:terminate` — max iterations reached, or multiple test regressions
  2. `:escalate` — duplicate tool calls or test regression (invoke auditor)
  3. `:pause` — stagnation detected (ask user for guidance)
  4. `:continue` — no issues, proceed normally

  Each decision includes a reason string for logging and UI display.
  """

  require Logger

  alias Synapsis.Session.Monitor

  @type decision :: :continue | :pause | :escalate | :terminate
  @type result :: {decision(), String.t()}

  @max_test_regressions 3

  @doc """
  Evaluates the monitor state and returns a decision.

  Called by the Worker after each iteration's tools complete.
  The Worker acts on the decision before starting the next LLM call.
  """
  @spec decide(Monitor.t(), keyword()) :: result()
  def decide(%Monitor{} = monitor, opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, 25)

    cond do
      # Hard stop: max iterations exceeded
      monitor.iteration_count >= max_iterations ->
        {:terminate, "Reached maximum iterations (#{max_iterations})"}

      # Hard stop: repeated test regressions
      monitor.test_regressions >= @max_test_regressions ->
        {:terminate,
         "#{monitor.test_regressions} test regressions detected — aborting to prevent further damage"}

      # Escalate: duplicate tool calls indicate a loop
      has_duplicate_signals?(monitor) ->
        {:escalate, "Duplicate tool calls detected — requesting auditor review"}

      # Escalate: test regression needs smarter analysis
      monitor.test_regressions > 0 ->
        {:escalate, "Test regression detected — requesting auditor review"}

      # Pause: stagnation means the agent isn't making progress
      monitor.consecutive_empty_iterations >= 3 ->
        {:pause,
         "#{monitor.consecutive_empty_iterations} consecutive empty iterations — waiting for user guidance"}

      # Warn but continue: approaching iteration limit
      monitor.iteration_count >= max_iterations - 5 ->
        {:continue, "Approaching iteration limit (#{monitor.iteration_count}/#{max_iterations})"}

      # All clear
      true ->
        {:continue, "ok"}
    end
  end

  @doc """
  Applies the decision, returning actions for the Worker to execute.

  Returns a map with:
  - `:decision` — the decision atom
  - `:reason` — human-readable explanation
  - `:actions` — list of action tuples the Worker should perform
  """
  @spec apply_decision(result(), binary()) :: map()
  def apply_decision({decision, reason}, session_id) do
    Logger.info("orchestrator_decision",
      session_id: session_id,
      decision: decision,
      reason: reason
    )

    base = %{decision: decision, reason: reason}

    case decision do
      :continue ->
        Map.put(base, :actions, [])

      :pause ->
        Map.put(base, :actions, [
          {:broadcast, "orchestrator_pause", %{reason: reason}},
          {:set_status, :idle}
        ])

      :escalate ->
        Map.put(base, :actions, [
          {:broadcast, "orchestrator_escalate", %{reason: reason}},
          {:invoke_auditor, reason}
        ])

      :terminate ->
        Map.put(base, :actions, [
          {:broadcast, "orchestrator_terminate", %{reason: reason}},
          {:persist_message, reason},
          {:set_status, :idle}
        ])
    end
  end

  defp has_duplicate_signals?(%Monitor{signals: signals}) do
    Enum.any?(signals, fn
      {:duplicate_tool_call, _, _} -> true
      _ -> false
    end)
  end
end
