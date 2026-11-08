defmodule Synapsis.Swarm.Store do
  @moduledoc """
  Sole supervised owner of ephemeral saved teammate metadata.

  Registry restarts do not affect this table. Restarting this owner loses all
  records; no caller recreates the table or adopts another process's table.
  Mutations belong to `Synapsis.Swarm`, including legacy tool calls.
  """
  use GenServer

  @table :synapsis_swarm_teammates

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc false
  def table do
    table = :ets.whereis(@table)
    owner = Process.whereis(__MODULE__)

    if table != :undefined and is_pid(owner) and :ets.info(table, :owner) == owner,
      do: {:ok, table},
      else: {:error, :unavailable}
  end

  @impl true
  def init(:ok) do
    case :ets.whereis(@table) do
      :undefined ->
        table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
        {:ok, table}

      table ->
        {:stop, {:unexpected_owner, :ets.info(table, :owner)}}
    end
  rescue
    ArgumentError -> {:stop, {:unexpected_owner, :ets.info(@table, :owner)}}
  end
end
