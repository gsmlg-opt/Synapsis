defmodule Synapsis.Agent.Heartbeat.LocalScheduler do
  @moduledoc """
  Compatibility façade for the durable `Synapsis.Agent.Routine.Scheduler`.

  Application still starts this module; `start_link/1` boots the routine
  scheduler under this process name so health checks and callers keep working.
  """

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc false
  def start_link(opts \\ []) do
    Synapsis.Agent.Routine.Scheduler.start_link(Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Return scheduler snapshot.

  `%{degraded?: boolean, degrade_reason: term() | nil, entries: [map()]}`
  """
  @spec status() :: %{
          degraded?: boolean(),
          degrade_reason: term() | nil,
          entries: [%{name: String.t(), schedule: String.t(), next_run_at: DateTime.t() | nil}]
        }
  def status do
    Synapsis.Agent.Routine.Scheduler.status(__MODULE__)
  end

  @doc false
  def reconcile do
    Synapsis.Agent.Routine.Scheduler.reconcile(__MODULE__)
  end
end
