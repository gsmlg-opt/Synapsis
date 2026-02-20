defmodule Synapsis.Session.Monitor do
  @moduledoc """
  Deterministic loop detection for agent sessions.

  Tracks tool call hashes across iterations, detects stagnation patterns,
  and emits signals that the Orchestrator uses for continue/pause/escalate
  decisions. All state is pure — no GenServer, called from the Worker.

  Signals emitted:
  - `:ok` — no issues detected
  - `{:duplicate_tool_call, hash, count}` — same tool+input seen N times
  - `{:stagnation, consecutive_empty}` — N iterations with no meaningful output
  - `{:iteration_warning, count}` — approaching max iterations
  - `{:test_regression, %{pass_to_fail: n}}` — tests went from passing to failing
  """

  require Logger

  @max_duplicate_threshold 3
  @stagnation_threshold 3
  @iteration_warn_at 20

  defstruct tool_call_counts: %{},
            iteration_count: 0,
            consecutive_empty_iterations: 0,
            last_test_status: nil,
            test_regressions: 0,
            signals: []

  @type t :: %__MODULE__{
          tool_call_counts: %{non_neg_integer() => non_neg_integer()},
          iteration_count: non_neg_integer(),
          consecutive_empty_iterations: non_neg_integer(),
          last_test_status: nil | :passing | :failing,
          test_regressions: non_neg_integer(),
          signals: [signal()]
        }

  @type signal ::
          :ok
          | {:duplicate_tool_call, non_neg_integer(), non_neg_integer()}
          | {:stagnation, non_neg_integer()}
          | {:iteration_warning, non_neg_integer()}
          | {:test_regression, map()}

  @doc "Creates a fresh monitor state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Records a tool call and checks for duplicate patterns.

  Returns `{signal, updated_monitor}` where signal is `:ok` or
  `{:duplicate_tool_call, hash, count}`.
  """
  @spec record_tool_call(t(), String.t(), map()) :: {signal(), t()}
  def record_tool_call(%__MODULE__{} = monitor, tool_name, input) do
    hash = :erlang.phash2({tool_name, input})
    count = Map.get(monitor.tool_call_counts, hash, 0) + 1
    updated = %{monitor | tool_call_counts: Map.put(monitor.tool_call_counts, hash, count)}

    if count >= @max_duplicate_threshold do
      signal = {:duplicate_tool_call, hash, count}
      Logger.warning("duplicate_tool_call", hash: hash, count: count, tool: tool_name)
      {signal, %{updated | signals: [signal | updated.signals]}}
    else
      {:ok, updated}
    end
  end

  @doc """
  Records the completion of an iteration.

  `has_meaningful_output` should be true if the iteration produced
  text content, tool calls, or other substantive output.

  Returns `{signals, updated_monitor}` where signals is a list
  of any triggered conditions.
  """
  @spec record_iteration(t(), boolean()) :: {[signal()], t()}
  def record_iteration(%__MODULE__{} = monitor, has_meaningful_output) do
    iteration = monitor.iteration_count + 1

    consecutive_empty =
      if has_meaningful_output,
        do: 0,
        else: monitor.consecutive_empty_iterations + 1

    updated = %{
      monitor
      | iteration_count: iteration,
        consecutive_empty_iterations: consecutive_empty
    }

    signals = []

    signals =
      if consecutive_empty >= @stagnation_threshold do
        signal = {:stagnation, consecutive_empty}
        Logger.warning("stagnation_detected", consecutive_empty: consecutive_empty)
        [signal | signals]
      else
        signals
      end

    signals =
      if iteration >= @iteration_warn_at do
        signal = {:iteration_warning, iteration}
        [signal | signals]
      else
        signals
      end

    {signals, %{updated | signals: updated.signals ++ signals}}
  end

  @doc """
  Records a test run result. Detects regressions (pass → fail transitions).

  Returns `{signal, updated_monitor}`.
  """
  @spec record_test_result(t(), :passing | :failing) :: {signal(), t()}
  def record_test_result(%__MODULE__{} = monitor, status) when status in [:passing, :failing] do
    case {monitor.last_test_status, status} do
      {:passing, :failing} ->
        regressions = monitor.test_regressions + 1
        signal = {:test_regression, %{pass_to_fail: regressions}}

        Logger.warning("test_regression_detected",
          regressions: regressions,
          transition: "passing -> failing"
        )

        updated = %{
          monitor
          | last_test_status: status,
            test_regressions: regressions,
            signals: [signal | monitor.signals]
        }

        {signal, updated}

      _ ->
        {:ok, %{monitor | last_test_status: status}}
    end
  end

  @doc """
  Returns a summary of the monitor's current state for diagnostics.
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = monitor) do
    %{
      iteration_count: monitor.iteration_count,
      unique_tool_calls: map_size(monitor.tool_call_counts),
      max_duplicate_count: max_duplicate(monitor.tool_call_counts),
      consecutive_empty_iterations: monitor.consecutive_empty_iterations,
      test_regressions: monitor.test_regressions,
      total_signals: length(monitor.signals)
    }
  end

  @doc """
  Returns the highest severity signal from the monitor, or `:ok`.
  """
  @spec worst_signal(t()) :: signal()
  def worst_signal(%__MODULE__{signals: []}), do: :ok

  def worst_signal(%__MODULE__{signals: signals}) do
    signals
    |> Enum.max_by(&signal_severity/1)
  end

  defp signal_severity(:ok), do: 0
  defp signal_severity({:iteration_warning, _}), do: 1
  defp signal_severity({:stagnation, _}), do: 2
  defp signal_severity({:duplicate_tool_call, _, _}), do: 3
  defp signal_severity({:test_regression, _}), do: 4

  defp max_duplicate(counts) when map_size(counts) == 0, do: 0
  defp max_duplicate(counts), do: counts |> Map.values() |> Enum.max()
end
