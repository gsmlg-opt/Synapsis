defmodule Synapsis.Backplane.StartupRefresh do
  @moduledoc "Refresh enabled Backplane capability sources asynchronously at startup."

  use GenServer

  alias Synapsis.Backplane.{Connection, Sync}

  @timeout_ms 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :refresh)
    {:ok, %{tasks: %{}}}
  end

  @impl true
  def handle_info(:refresh, state) do
    tasks =
      Connection.list()
      |> Enum.filter(& &1.enabled)
      |> Enum.reduce(state.tasks, fn connection, tasks ->
        case Task.Supervisor.start_child(Synapsis.Tool.TaskSupervisor, fn ->
               Task.async(fn -> Sync.run(connection.id) end)
               |> Task.await(@timeout_ms)
             end) do
          {:ok, pid} -> Map.put(tasks, Process.monitor(pid), connection.id)
          {:error, _} -> tasks
        end
      end)

    {:noreply, %{state | tasks: tasks}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | tasks: Map.delete(state.tasks, ref)}}
end
