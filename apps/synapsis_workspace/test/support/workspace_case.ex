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

    {:ok, project} =
      Synapsis.Repo.insert(%Synapsis.Project{
        slug: "ws-test-#{System.unique_integer([:positive])}",
        path: "/tmp/ws-test",
        name: "ws-test"
      })

    {:ok, session} =
      Synapsis.Repo.insert(%Synapsis.Session{
        project_id: project.id,
        provider: "anthropic",
        model: "claude-3-5-sonnet"
      })

    %{project: project, session: session}
  end
end
