defmodule Synapsis.Agent.Routine.Clock do
  @moduledoc """
  Controllable clock for routine scheduling tests.

  Default: `DateTime.utc_now/0`. Tests may `freeze/1` or `set/1` in the
  current process (and optionally clear with `reset/0`).
  """

  @process_key :synapsis_routine_clock

  @spec now() :: DateTime.t()
  def now do
    case Process.get(@process_key) do
      %DateTime{} = frozen -> frozen
      {:fn, fun} when is_function(fun, 0) -> fun.()
      _ -> DateTime.utc_now()
    end
  end

  @spec freeze(DateTime.t()) :: :ok
  def freeze(%DateTime{} = dt) do
    Process.put(@process_key, dt)
    :ok
  end

  @spec advance(non_neg_integer(), System.time_unit()) :: DateTime.t()
  def advance(amount, unit \\ :millisecond) when is_integer(amount) and amount >= 0 do
    next = DateTime.add(now(), amount, unit)
    freeze(next)
    next
  end

  @spec reset() :: :ok
  def reset do
    Process.delete(@process_key)
    :ok
  end
end
