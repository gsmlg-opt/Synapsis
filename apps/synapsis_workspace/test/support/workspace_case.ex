defmodule Synapsis.Workspace.TestCase do
  @moduledoc "Shared test helpers for workspace tests (ADR-006 C4: Concord-backed)."
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Synapsis.Workspace
      alias Synapsis.Workspace.Resource
    end
  end

  setup do
    Synapsis.Session.Store.ensure_started()

    agent_id = "ws-test-#{System.unique_integer([:positive])}"

    {:ok, session} =
      Synapsis.Sessions.create(agent_id, %{provider: "anthropic", model: "claude-3-5-sonnet"})

    %{agent_id: agent_id, session: session}
  end
end
