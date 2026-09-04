defmodule Synapsis.Agent.RunState do
  @moduledoc """
  Pure run projection used by `RunReducer`.

  Wraps an `AgentRun` plus reducer-only bookkeeping that is also mirrored into
  `AgentRun.recovery_state` when persisted.
  """

  alias Synapsis.AgentRun

  @enforce_keys [:run]
  defstruct [:run, applied_event_ids: MapSet.new()]

  @type t :: %__MODULE__{
          run: AgentRun.t(),
          applied_event_ids: MapSet.t(String.t())
        }

  @spec from_run(AgentRun.t()) :: t()
  def from_run(%AgentRun{} = run) do
    ids =
      run.recovery_state
      |> Map.get("applied_event_ids", [])
      |> List.wrap()
      |> MapSet.new()

    %__MODULE__{run: run, applied_event_ids: ids}
  end

  @spec to_run(t()) :: AgentRun.t()
  def to_run(%__MODULE__{run: run, applied_event_ids: ids}) do
    capped =
      ids
      |> MapSet.to_list()
      |> Enum.take(-64)

    recovery =
      run.recovery_state
      |> Map.put("applied_event_ids", capped)

    %{run | recovery_state: recovery}
  end

  @spec status(t()) :: String.t()
  def status(%__MODULE__{run: run}), do: run.status
end
