defmodule Synapsis.Memory.Supervisor do
  @moduledoc "Supervises memory storage, capture, cache and bounded workspace cursors."
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    adapter = Application.get_env(:synapsis_core, :memory_adapter, Synapsis.Memory.FileAdapter)

    adapter_child =
      if function_exported?(adapter, :start_link, 1) do
        [adapter]
      else
        []
      end

    children =
      adapter_child ++
        [
          Synapsis.Memory.EventLog,
          Synapsis.Memory.Cache,
          Synapsis.Memory.Writer,
          Synapsis.Memory.Capture,
          Synapsis.Memory.WorkspaceCursors
        ]

    # Never escalate: a transient child crash must not terminate the supervisor
    # and take down the file adapter / event log siblings.
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 1_000_000, max_seconds: 1)
  end
end
