defmodule Synapsis.Agent.RunSupervisor do
  @moduledoc """
  DynamicSupervisor for one `RunCoordinator` per active run.

  Process identity is the run ID via `Synapsis.Agent.RunRegistry`.
  Children are temporary: terminal stops and crashes do not auto-restart;
  the Daemon reconciles incomplete projections instead of replaying side effects.
  """

  use DynamicSupervisor

  alias Synapsis.Agent.RunCoordinator

  @registry Synapsis.Agent.RunRegistry

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a coordinator for `run_id`, or return the existing PID."
  @spec start_run(keyword() | map()) :: {:ok, pid()} | {:error, term()}
  def start_run(opts) when is_list(opts), do: start_run(Map.new(opts))

  def start_run(%{run_id: run_id} = opts) when is_binary(run_id) do
    case whereis(run_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        child = {RunCoordinator, opts}

        case DynamicSupervisor.start_child(__MODULE__, child) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  def start_run(_opts), do: {:error, :missing_run_id}

  @spec whereis(String.t()) :: pid() | nil
  def whereis(run_id) when is_binary(run_id) do
    case Registry.lookup(@registry, run_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @spec alive?(String.t()) :: boolean()
  def alive?(run_id) when is_binary(run_id), do: is_pid(whereis(run_id))

  @spec stop_run(String.t()) :: :ok | {:error, :not_found}
  def stop_run(run_id) when is_binary(run_id) do
    case whereis(run_id) do
      pid when is_pid(pid) ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      nil ->
        {:error, :not_found}
    end
  end

  @spec list_active_run_ids() :: [String.t()]
  def list_active_run_ids do
    Registry.select(@registry, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
  end

  @spec via(String.t()) :: {:via, module(), term()}
  def via(run_id) when is_binary(run_id), do: {:via, Registry, {@registry, run_id}}
end
