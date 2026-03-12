defmodule Synapsis.Memory.RetrieverTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.Memory.Retriever
  alias Synapsis.{SemanticMemory, Repo}

  setup do
    Synapsis.Memory.Cache.clear()

    {:ok, shared} =
      %SemanticMemory{}
      |> SemanticMemory.changeset(%{
        scope: "shared",
        scope_id: "",
        kind: "fact",
        title: "Elixir naming conventions",
        summary: "Always use snake_case for function names and variables",
        tags: ["elixir", "style"],
        importance: 0.9,
        confidence: 0.8,
        freshness: 1.0
      })
      |> Repo.insert()

    {:ok, project} =
      %SemanticMemory{}
      |> SemanticMemory.changeset(%{
        scope: "project",
        scope_id: "proj-1",
        kind: "decision",
        title: "Use Phoenix 1.8",
        summary: "Project uses Phoenix 1.8 with LiveView",
        tags: ["phoenix", "framework"],
        importance: 0.7,
        confidence: 0.9,
        freshness: 1.0
      })
      |> Repo.insert()

    {:ok, agent} =
      %SemanticMemory{}
      |> SemanticMemory.changeset(%{
        scope: "agent",
        scope_id: "agent-1",
        kind: "preference",
        title: "Verbose output preferred",
        summary: "Agent prefers detailed explanations",
        tags: ["style"],
        importance: 0.5,
        confidence: 0.7,
        freshness: 0.8
      })
      |> Repo.insert()

    {:ok, shared: shared, project: project, agent: agent}
  end

  describe "retrieve/1" do
    test "returns shared memories when querying shared scope" do
      results = Retriever.retrieve(%{scope: :shared})
      titles = Enum.map(results, & &1.title)
      assert "Elixir naming conventions" in titles
    end

    test "returns project memories for matching project_id" do
      results = Retriever.retrieve(%{scope: :project, project_id: "proj-1"})
      titles = Enum.map(results, & &1.title)
      assert "Use Phoenix 1.8" in titles
    end

    test "does not return memories from other projects" do
      results = Retriever.retrieve(%{scope: :project, project_id: "other-proj"})
      titles = Enum.map(results, & &1.title)
      refute "Use Phoenix 1.8" in titles
    end

    test "filters by query keyword" do
      results = Retriever.retrieve(%{scope: :shared, query: "snake_case"})
      titles = Enum.map(results, & &1.title)
      assert "Elixir naming conventions" in titles
    end

    test "returns empty list for unmatched query" do
      results = Retriever.retrieve(%{scope: :shared, query: "xyznonexistent123"})
      assert results == []
    end

    test "respects limit option" do
      for i <- 1..5 do
        %SemanticMemory{}
        |> SemanticMemory.changeset(%{
          scope: "shared",
          scope_id: "",
          kind: "fact",
          title: "Extra fact #{i}",
          summary: "Extra summary #{i}"
        })
        |> Repo.insert!()
      end

      results = Retriever.retrieve(%{scope: :shared, limit: 3})
      assert length(results) <= 3
    end

    test "returns agent-scoped memories when agent scope requested" do
      results =
        Retriever.retrieve(%{scope: :agent, agent_id: "agent-1", project_id: "proj-1"})

      titles = Enum.map(results, & &1.title)
      assert "Verbose output preferred" in titles
      # Agent scope also includes project + shared
      assert "Use Phoenix 1.8" in titles
      assert "Elixir naming conventions" in titles
    end

    test "results include score field" do
      results = Retriever.retrieve(%{scope: :shared})
      assert Enum.all?(results, fn r -> is_float(r.score) end)
    end
  end
end
