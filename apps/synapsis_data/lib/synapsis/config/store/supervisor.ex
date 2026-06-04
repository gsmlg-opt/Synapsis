defmodule Synapsis.Config.Store.Supervisor do
  @moduledoc "Supervises one Store.Server per config type plus the FileSystem watcher."
  use Supervisor

  alias Synapsis.Config.Store

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    type_children =
      Enum.map(Store.types(), fn type ->
        %{
          id: {Store.Server, type},
          start: {Store.Server, :start_link, [type]},
          restart: :permanent
        }
      end)

    children =
      [{Registry, keys: :unique, name: Synapsis.Config.Store.Registry} | type_children] ++
        [Store.Watcher]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
