defmodule Synapsis.Workspace.TestCase do
  @moduledoc "Shared test helpers for workspace tests."
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Synapsis.Workspace
      alias Synapsis.Workspace.Resource
      alias Synapsis.Repo
      import Ecto.Query
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Synapsis.Repo)

    agent_id = "ws-test-#{System.unique_integer([:positive])}"

    {:ok, session} =
      Synapsis.Repo.insert(%Synapsis.Session{
        agent: agent_id,
        provider: "anthropic",
        model: "claude-3-5-sonnet"
      })

    %{agent_id: agent_id, session: session}
  end
end
