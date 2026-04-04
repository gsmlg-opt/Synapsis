defmodule Synapsis.Agent.Agents.AssistantAgent do
  @moduledoc "Singleton Assistant agent — manages project context and coordinates Build Agents."
  use GenServer

  defstruct [:context_mode, :project_id]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def switch_project(project_id) do
    GenServer.call(__MODULE__, {:switch_project, project_id})
  end

  def current_mode do
    GenServer.call(__MODULE__, :current_mode)
  end

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{context_mode: :global, project_id: nil}}
  end

  @impl true
  def handle_call({:switch_project, project_id}, _from, state) do
    new_state = %{state | context_mode: {:project, project_id}, project_id: project_id}
    {:reply, :ok, new_state}
  end

  def handle_call(:current_mode, _from, state) do
    {:reply, state.context_mode, state}
  end

  # Handle Build Agent notifications
  @impl true
  def handle_info({:notification, _payload}, state) do
    # Will be implemented when Build Agent system is complete
    {:noreply, state}
  end
end
