defmodule Synapsis.Tool.Registry do
  @moduledoc """
  ETS-backed tool definition registry supporting dual dispatch.

  Entries are stored as:
  - `{name, {:module, module, opts}}` for module-based tools
  - `{name, {:process, pid, opts}}` for process-based tools (plugins)
  """
  use GenServer

  @table :synapsis_tools

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Register a module-based tool."
  def register_module(name, module, opts \\ []) do
    :ets.insert(@table, {name, {:module, module, opts}})
    :ok
  end

  @doc "Register a process-based tool (plugin GenServer)."
  def register_process(name, pid, opts \\ []) do
    :ets.insert(@table, {name, {:process, pid, opts}})
    :ok
  end

  @doc "Backward-compatible register from a map with :name, :module, etc."
  def register(tool) when is_map(tool) do
    opts = [
      timeout: tool[:timeout],
      description: tool[:description] || tool.module.description(),
      parameters: tool[:parameters] || tool.module.parameters()
    ]

    extra =
      tool
      |> Map.drop([:name, :module, :description, :parameters, :timeout])
      |> Enum.to_list()

    opts = opts ++ extra

    :ets.insert(@table, {tool.name, {:module, tool.module, opts}})
    :ok
  end

  @doc "Lookup a tool, returning the dispatch tuple."
  def lookup(tool_name) do
    case :ets.lookup(@table, tool_name) do
      [{^tool_name, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  @doc "Backward-compatible get returning a map format."
  def get(tool_name) do
    case :ets.lookup(@table, tool_name) do
      [{^tool_name, {:module, module, opts}}] ->
        tool = %{
          name: tool_name,
          module: module,
          description: opts[:description] || module.description(),
          parameters: opts[:parameters] || module.parameters(),
          timeout: opts[:timeout]
        }

        {:ok, tool}

      [{^tool_name, {:process, pid, opts}}] ->
        tool = %{
          name: tool_name,
          process: pid,
          description: opts[:description] || "",
          parameters: opts[:parameters] || %{},
          timeout: opts[:timeout]
        }

        {:ok, tool}

      [] ->
        {:error, :not_found}
    end
  end

  @doc "List all tools in a format suitable for LLM tool definitions."
  def list_for_llm do
    :ets.tab2list(@table)
    |> Enum.map(fn {name, entry} ->
      case entry do
        {:module, module, opts} ->
          %{
            name: name,
            description: opts[:description] || module.description(),
            parameters: opts[:parameters] || module.parameters()
          }

        {:process, _pid, opts} ->
          %{
            name: name,
            description: opts[:description] || "",
            parameters: opts[:parameters] || %{}
          }
      end
    end)
  end

  @doc "List all registered tools (backward-compatible)."
  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {name, entry} ->
      case entry do
        {:module, module, opts} ->
          %{
            name: name,
            module: module,
            description: opts[:description] || module.description(),
            parameters: opts[:parameters] || module.parameters(),
            timeout: opts[:timeout]
          }

        {:process, pid, opts} ->
          %{
            name: name,
            process: pid,
            description: opts[:description] || "",
            parameters: opts[:parameters] || %{},
            timeout: opts[:timeout]
          }
      end
    end)
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
