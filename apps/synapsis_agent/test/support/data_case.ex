defmodule Synapsis.Agent.DataCase do
  @moduledoc "Test case for agent tests that require database access."
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Synapsis.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Synapsis.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
