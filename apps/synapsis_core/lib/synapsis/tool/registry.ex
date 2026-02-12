defmodule Synapsis.Tool.Registry do
  @moduledoc "ETS-backed tool definition registry."
  use GenServer

  @table :synapsis_tools

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def register(tool) do
    :ets.insert(@table, {tool.name, tool})
    :ok
  end

  def get(tool_name) do
    case :ets.lookup(@table, tool_name) do
      [{^tool_name, tool}] -> {:ok, tool}
      [] -> {:error, :not_found}
    end
  end

  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {_name, tool} -> tool end)
  end

  def unregister(tool_name) do
    :ets.delete(@table, tool_name)
    :ok
  end

  @impl true
  def init(:ok) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, table}
  end
end
