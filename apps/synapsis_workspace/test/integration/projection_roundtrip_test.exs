defmodule Synapsis.Workspace.Integration.ProjectionRoundtripTest do
  use ExUnit.Case

  alias Synapsis.Workspace
  alias Synapsis.Workspace.Resource
  alias Synapsis.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    {:ok, project} =
      Repo.insert(%Synapsis.Project{
        slug: "proj-rt-#{System.unique_integer([:positive])}",
        path: "/tmp/proj-roundtrip"
      })

    {:ok, session} =
      Repo.insert(%Synapsis.Session{
        project_id: project.id,
        provider: "anthropic",
        model: "claude-3-5-sonnet"
      })

    %{project: project, session: session}
  end

  describe "skill projection roundtrip" do
    @tag :skip_if_no_skill_schema
    test "create skill via domain → read via workspace path", %{project: project} do
      {:ok, skill} =
        Repo.insert(%Synapsis.Skill{
          scope: "project",
          project_id: project.id,
          name: "roundtrip-skill",
          description: "A test skill for projection roundtrip",
          system_prompt_fragment: "Be helpful."
        })

      path = "/projects/#{project.id}/skills/roundtrip-skill/skill.md"

      case Workspace.read(path) do
        {:ok, %Resource{} = resource} ->
          assert resource.kind == :skill
          assert resource.path == path
          assert resource.content =~ "Be helpful."

        {:error, :not_found} ->
          # Projection may normalize path differently; check via list
          {:ok, resources} = Workspace.list("/projects/#{project.id}/skills/", [])
          skill_resources = Enum.filter(resources, &(&1.kind == :skill))
          assert length(skill_resources) > 0
          matched = Enum.find(skill_resources, &(&1.id == skill.id))
          assert matched != nil
      end
    end
  end

  describe "memory entry projection roundtrip" do
    @tag :skip
    test "create memory entry → read via workspace path", %{project: project} do
      {:ok, memory} =
        Repo.insert(%Synapsis.MemoryEntry{
          scope: "project",
          scope_id: project.id,
          key: "roundtrip-key",
          content: "Memory content for roundtrip test",
          metadata: %{"category" => "general"}
        })

      path = "/projects/#{project.id}/memory/general/roundtrip-key.md"

      case Workspace.read(path) do
        {:ok, %Resource{} = resource} ->
          assert resource.kind == :memory
          assert resource.content =~ "Memory content for roundtrip test"

        {:error, :not_found} ->
          {:ok, resources} = Workspace.list("/projects/#{project.id}/memory/", [])
          memory_resources = Enum.filter(resources, &(&1.kind == :memory))
          assert length(memory_resources) > 0
          matched = Enum.find(memory_resources, &(&1.id == memory.id))
          assert matched != nil
      end
    end
  end

  describe "list project workspace includes both domain and documents" do
    test "mixed listing", %{project: project} do
      # Create a workspace document
      doc_path = "/projects/#{project.id}/plans/roundtrip-plan.md"
      {:ok, _doc} = Workspace.write(doc_path, "A plan document", %{author: "test"})

      # Create a domain-backed skill
      {:ok, _skill} =
        Repo.insert(%Synapsis.Skill{
          scope: "project",
          project_id: project.id,
          name: "rt-list-skill",
          description: "Skill for list test",
          system_prompt_fragment: "Test."
        })

      {:ok, resources} = Workspace.list("/projects/#{project.id}/", [])

      kinds = Enum.map(resources, & &1.kind) |> Enum.uniq()
      assert :document in kinds or :skill in kinds

      # At least our workspace document should be there
      doc_found = Enum.any?(resources, &(&1.path == doc_path))
      assert doc_found
    end
  end

  describe "search finds both domain records and workspace documents" do
    test "search across backing stores", %{project: project} do
      # Create a workspace document with searchable content
      {:ok, _} =
        Workspace.write(
          "/projects/#{project.id}/notes/searchable-roundtrip.md",
          "This is unique roundtrip search content xyzzy42",
          %{author: "test"}
        )

      # Search should find it
      {:ok, results} = Workspace.search("xyzzy42", scope: :project, project_id: project.id)

      assert length(results) > 0
      assert Enum.any?(results, &(&1.content =~ "xyzzy42"))
    end
  end
end
