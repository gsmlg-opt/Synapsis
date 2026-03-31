defmodule Synapsis.Agent.AgentRegistry do
  @moduledoc """
  ETS-backed registry tracking spawned Code Agents for a parent session.

  Maps `parent_session_id → [%{session_id, task, status, spawned_at}]`.

  Used by the UI to display embedded Code Agent panels and by the two-agent
  system to correlate completion messages back to the parent.
  """

  use GenServer

  require Logger

  @table :agent_registry

  @type entry :: %{
          session_id: String.t(),
          parent_session_id: String.t(),
          task: String.t(),
          status: :running | :complete | :failed,
          spawned_at: DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Register a newly-spawned Code Agent under its parent session."
  @spec register(String.t(), String.t(), String.t()) :: :ok
  def register(parent_session_id, child_session_id, task) do
    GenServer.call(__MODULE__, {:register, parent_session_id, child_session_id, task})
  end

  @doc "Update the status of a registered Code Agent."
  @spec update_status(String.t(), :running | :complete | :failed) :: :ok
  def update_status(child_session_id, status) do
    GenServer.call(__MODULE__, {:update_status, child_session_id, status})
  end

  @doc "List all Code Agents spawned by a given parent session."
  @spec list_for_parent(String.t()) :: [entry()]
  def list_for_parent(parent_session_id) do
    :ets.lookup(@table, parent_session_id)
    |> Enum.map(fn {_, entries} -> entries end)
    |> List.flatten()
  end

  @doc "Remove all entries for a parent session (cleanup on session teardown)."
  @spec clear_parent(String.t()) :: :ok
  def clear_parent(parent_session_id) do
    GenServer.call(__MODULE__, {:clear_parent, parent_session_id})
  end

  @impl true
  def init(:ok) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, parent_id, child_id, task}, _from, state) do
    entry = %{
      session_id: child_id,
      parent_session_id: parent_id,
      task: task,
      status: :running,
      spawned_at: DateTime.utc_now()
    }

    existing = fetch_entries(parent_id)
    :ets.insert(@table, {parent_id, [entry | existing]})

    Logger.info("code_agent_registered",
      parent_session_id: parent_id,
      child_session_id: child_id,
      task: task
    )

    {:reply, :ok, state}
  end

  def handle_call({:update_status, child_id, status}, _from, state) do
    :ets.match_object(@table, {:"$1", :"$2"})
    |> Enum.each(fn {parent_id, entries} ->
      updated =
        Enum.map(entries, fn
          %{session_id: ^child_id} = e -> %{e | status: status}
          e -> e
        end)

      :ets.insert(@table, {parent_id, updated})
    end)

    {:reply, :ok, state}
  end

  def handle_call({:clear_parent, parent_id}, _from, state) do
    :ets.delete(@table, parent_id)
    {:reply, :ok, state}
  end

  defp fetch_entries(parent_id) do
    case :ets.lookup(@table, parent_id) do
      [{_, entries}] -> entries
      [] -> []
    end
  end
end
