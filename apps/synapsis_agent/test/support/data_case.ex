defmodule Synapsis.Agent.DataCase do
  @moduledoc "Test case for agent tests (ADR-006 C4: Concord-backed, no Ecto sandbox)."
  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Changeset
    end
  end

  setup _tags do
    Synapsis.Session.Store.ensure_started()
    :ok
  end
end
