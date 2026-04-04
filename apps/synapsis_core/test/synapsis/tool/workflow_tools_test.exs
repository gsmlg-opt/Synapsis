defmodule Synapsis.Tool.WorkflowToolsTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{Repo, Projects}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_project do
    unique = System.unique_integer([:positive])

    {:ok, project} =
      Projects.create(%{
        path: "/tmp/wf-test-#{unique}",
        slug: "wf-test-#{unique}",
        name: "wf-test-#{unique}"
      })

    project
  end

  defp write_board(project_id, content) do
    path = "/projects/#{project_id}/board.yaml"

    %Synapsis.WorkspaceDocument{}
    |> Synapsis.WorkspaceDocument.changeset(%{
      path: path,
      content_body: content,
      content_format: :yaml,
      kind: :document,
      project_id: project_id,
      created_by: "test",
      updated_by: "test"
    })
    |> Repo.insert!()
  end

  defp write_devlog(project_id, content) do
    path = "/projects/#{project_id}/logs/devlog.md"

    %Synapsis.WorkspaceDocument{}
    |> Synapsis.WorkspaceDocument.changeset(%{
      path: path,
      content_body: content,
      content_format: :markdown,
      kind: :document,
      project_id: project_id,
      created_by: "test",
      updated_by: "test"
    })
    |> Repo.insert!()
  end

  defp minimal_board_yaml do
    """
    version: 1
    columns:
      - id: backlog
        name: Backlog
      - id: ready
        name: Ready
      - id: in_progress
        name: In Progress
      - id: review
        name: Review
      - id: done
        name: Done
    cards:
      - id: card-001
        title: "Test card"
        description: "A sample card"
        column: backlog
        priority: 0
        labels:
          - elixir
        design_refs: []
        created_at: 2026-01-01T00:00:00Z
        updated_at: 2026-01-01T00:00:00Z
    """
  end

  # ---------------------------------------------------------------------------
  # BoardRead
  # ---------------------------------------------------------------------------

  describe "BoardRead metadata" do
    test "name, category, permission_level" do
      assert Synapsis.Tool.BoardRead.name() == "board_read"
      assert Synapsis.Tool.BoardRead.category() == :workflow
      assert Synapsis.Tool.BoardRead.permission_level() == :none
      assert Synapsis.Tool.BoardRead.side_effects() == []
      assert is_map(Synapsis.Tool.BoardRead.parameters())
    end
  end

  describe "BoardRead.execute/2" do
    test "returns empty board when document does not exist" do
      project = make_project()
      context = %{project_id: project.id}

      assert {:ok, json} = Synapsis.Tool.BoardRead.execute(%{}, context)
      result = Jason.decode!(json)
      assert result["cards"] == []
      assert is_list(result["columns"])
    end

    test "returns parsed board cards" do
      project = make_project()
      write_board(project.id, minimal_board_yaml())
      context = %{project_id: project.id}

      assert {:ok, json} = Synapsis.Tool.BoardRead.execute(%{}, context)
      result = Jason.decode!(json)
      assert length(result["cards"]) == 1
      assert hd(result["cards"])["title"] == "Test card"
    end

    test "filters by column" do
      project = make_project()
      write_board(project.id, minimal_board_yaml())
      context = %{project_id: project.id}

      assert {:ok, json} = Synapsis.Tool.BoardRead.execute(%{"column" => "backlog"}, context)
      result = Jason.decode!(json)
      assert length(result["cards"]) == 1

      assert {:ok, json2} = Synapsis.Tool.BoardRead.execute(%{"column" => "done"}, context)
      result2 = Jason.decode!(json2)
      assert result2["cards"] == []
    end

    test "filters by label" do
      project = make_project()
      write_board(project.id, minimal_board_yaml())
      context = %{project_id: project.id}

      assert {:ok, json} = Synapsis.Tool.BoardRead.execute(%{"label" => "elixir"}, context)
      result = Jason.decode!(json)
      assert length(result["cards"]) == 1

      assert {:ok, json2} = Synapsis.Tool.BoardRead.execute(%{"label" => "python"}, context)
      result2 = Jason.decode!(json2)
      assert result2["cards"] == []
    end

    test "returns error when project_id missing" do
      assert {:error, msg} = Synapsis.Tool.BoardRead.execute(%{}, %{})
      assert msg =~ "project_id"
    end
  end

  # ---------------------------------------------------------------------------
  # BoardUpdate
  # ---------------------------------------------------------------------------

  describe "BoardUpdate metadata" do
    test "name, category, side_effects" do
      assert Synapsis.Tool.BoardUpdate.name() == "board_update"
      assert Synapsis.Tool.BoardUpdate.category() == :workflow
      assert Synapsis.Tool.BoardUpdate.permission_level() == :none
      assert :workspace_changed in Synapsis.Tool.BoardUpdate.side_effects()
      assert :board_changed in Synapsis.Tool.BoardUpdate.side_effects()
    end
  end

  describe "BoardUpdate.execute/2 - create_card" do
    test "creates a card on empty board" do
      project = make_project()
      context = %{project_id: project.id}

      input = %{
        "action" => "create_card",
        "card" => %{"title" => "New feature", "column" => "backlog"}
      }

      assert {:ok, json} = Synapsis.Tool.BoardUpdate.execute(input, context)
      result = Jason.decode!(json)
      assert result["action"] == "created"
      assert is_binary(result["card_id"])
    end

    test "card persisted in workspace after create" do
      project = make_project()
      context = %{project_id: project.id}

      input = %{
        "action" => "create_card",
        "card" => %{"title" => "Persisted card"}
      }

      Synapsis.Tool.BoardUpdate.execute(input, context)

      doc = Synapsis.WorkspaceDocuments.get_by_path("/projects/#{project.id}/board.yaml")
      assert doc != nil
      assert doc.content_body =~ "Persisted card"
    end
  end

  describe "BoardUpdate.execute/2 - move_card" do
    test "moves card to valid column" do
      project = make_project()
      write_board(project.id, minimal_board_yaml())
      context = %{project_id: project.id}

      input = %{"action" => "move_card", "card_id" => "card-001", "column" => "ready"}
      assert {:ok, json} = Synapsis.Tool.BoardUpdate.execute(input, context)
      result = Jason.decode!(json)
      assert result["action"] == "moved"
      assert result["column"] == "ready"
    end

    test "returns error for invalid transition" do
      project = make_project()
      write_board(project.id, minimal_board_yaml())
      context = %{project_id: project.id}

      # done -> backlog is invalid per Board transitions (done has no allowed transitions)
      # First move card to done
      Synapsis.Tool.BoardUpdate.execute(
        %{"action" => "move_card", "card_id" => "card-001", "column" => "ready"},
        context
      )

      Synapsis.Tool.BoardUpdate.execute(
        %{"action" => "move_card", "card_id" => "card-001", "column" => "in_progress"},
        context
      )

      Synapsis.Tool.BoardUpdate.execute(
        %{"action" => "move_card", "card_id" => "card-001", "column" => "review"},
        context
      )

      Synapsis.Tool.BoardUpdate.execute(
        %{"action" => "move_card", "card_id" => "card-001", "column" => "done"},
        context
      )

      # Now try to move from done -> backlog (invalid: done has no allowed transitions)
      input = %{"action" => "move_card", "card_id" => "card-001", "column" => "backlog"}
      assert {:error, msg} = Synapsis.Tool.BoardUpdate.execute(input, context)
      assert msg =~ "transition"
    end
  end

  # ---------------------------------------------------------------------------
  # DevlogWrite
  # ---------------------------------------------------------------------------

  describe "DevlogWrite metadata" do
    test "name, category, side_effects" do
      assert Synapsis.Tool.DevlogWrite.name() == "devlog_write"
      assert Synapsis.Tool.DevlogWrite.category() == :workflow
      assert Synapsis.Tool.DevlogWrite.permission_level() == :none
      assert :workspace_changed in Synapsis.Tool.DevlogWrite.side_effects()
    end
  end

  describe "DevlogWrite.execute/2" do
    test "creates devlog with first entry" do
      project = make_project()
      context = %{project_id: project.id}

      input = %{"category" => "progress", "content" => "Implemented feature X"}

      assert {:ok, msg} = Synapsis.Tool.DevlogWrite.execute(input, context)
      assert msg =~ "progress"

      doc =
        Synapsis.WorkspaceDocuments.get_by_path("/projects/#{project.id}/logs/devlog.md")

      assert doc != nil
      assert doc.content_body =~ "Implemented feature X"
      assert doc.content_body =~ "progress"
    end

    test "appends to existing devlog" do
      project = make_project()
      write_devlog(project.id, "# Dev Log\n")
      context = %{project_id: project.id}

      input = %{"category" => "decision", "content" => "Chose GenServer"}
      assert {:ok, _} = Synapsis.Tool.DevlogWrite.execute(input, context)

      doc =
        Synapsis.WorkspaceDocuments.get_by_path("/projects/#{project.id}/logs/devlog.md")

      assert doc.content_body =~ "Chose GenServer"
    end

    test "returns error when project_id missing" do
      assert {:error, msg} =
               Synapsis.Tool.DevlogWrite.execute(
                 %{"category" => "progress", "content" => "x"},
                 %{}
               )

      assert msg =~ "project_id"
    end
  end

  # ---------------------------------------------------------------------------
  # DevlogRead
  # ---------------------------------------------------------------------------

  describe "DevlogRead metadata" do
    test "name, category, no side_effects" do
      assert Synapsis.Tool.DevlogRead.name() == "devlog_read"
      assert Synapsis.Tool.DevlogRead.category() == :workflow
      assert Synapsis.Tool.DevlogRead.permission_level() == :none
      assert Synapsis.Tool.DevlogRead.side_effects() == []
    end
  end

  describe "DevlogRead.execute/2" do
    test "returns empty list when no log exists" do
      project = make_project()
      context = %{project_id: project.id}

      assert {:ok, json} = Synapsis.Tool.DevlogRead.execute(%{}, context)
      entries = Jason.decode!(json)
      assert entries == []
    end

    test "returns recent entries" do
      project = make_project()
      context = %{project_id: project.id}

      # Write two entries
      input1 = %{"category" => "progress", "content" => "Entry one"}
      input2 = %{"category" => "decision", "content" => "Entry two"}
      Synapsis.Tool.DevlogWrite.execute(input1, context)
      Synapsis.Tool.DevlogWrite.execute(input2, context)

      assert {:ok, json} = Synapsis.Tool.DevlogRead.execute(%{"count" => 10}, context)
      entries = Jason.decode!(json)
      assert length(entries) == 2
    end

    test "filters by category" do
      project = make_project()
      context = %{project_id: project.id}

      Synapsis.Tool.DevlogWrite.execute(
        %{"category" => "progress", "content" => "Progress"},
        context
      )

      Synapsis.Tool.DevlogWrite.execute(
        %{"category" => "decision", "content" => "Decision"},
        context
      )

      assert {:ok, json} =
               Synapsis.Tool.DevlogRead.execute(%{"category" => "decision"}, context)

      entries = Jason.decode!(json)
      assert length(entries) == 1
      assert hd(entries)["category"] == "decision"
    end
  end

  # ---------------------------------------------------------------------------
  # RepoLink (metadata only — actual cloning requires real git)
  # ---------------------------------------------------------------------------

  describe "RepoLink metadata" do
    test "name, category, side_effects" do
      assert Synapsis.Tool.RepoLink.name() == "repo_link"
      assert Synapsis.Tool.RepoLink.category() == :workflow
      assert Synapsis.Tool.RepoLink.permission_level() == :none
      assert :repo_linked in Synapsis.Tool.RepoLink.side_effects()
      assert is_map(Synapsis.Tool.RepoLink.parameters())
    end

    test "parameters include required fields" do
      params = Synapsis.Tool.RepoLink.parameters()
      assert "name" in params["required"]
      assert "urls" in params["required"]
    end
  end

  # ---------------------------------------------------------------------------
  # RepoSync (metadata only)
  # ---------------------------------------------------------------------------

  describe "RepoSync metadata" do
    test "name, category, no side_effects" do
      assert Synapsis.Tool.RepoSync.name() == "repo_sync"
      assert Synapsis.Tool.RepoSync.category() == :workflow
      assert Synapsis.Tool.RepoSync.permission_level() == :none
      assert Synapsis.Tool.RepoSync.side_effects() == []
    end

    test "returns error for unknown repo_id" do
      bogus_id = Ecto.UUID.generate()
      assert {:error, msg} = Synapsis.Tool.RepoSync.execute(%{"repo_id" => bogus_id}, %{})
      assert msg =~ "not found"
    end
  end

  # ---------------------------------------------------------------------------
  # RepoStatus (metadata only)
  # ---------------------------------------------------------------------------

  describe "RepoStatus metadata" do
    test "name, category, no side_effects" do
      assert Synapsis.Tool.RepoStatus.name() == "repo_status"
      assert Synapsis.Tool.RepoStatus.category() == :workflow
      assert Synapsis.Tool.RepoStatus.permission_level() == :none
      assert Synapsis.Tool.RepoStatus.side_effects() == []
    end

    test "returns error for unknown repo_id" do
      bogus_id = Ecto.UUID.generate()
      assert {:error, msg} = Synapsis.Tool.RepoStatus.execute(%{"repo_id" => bogus_id}, %{})
      assert msg =~ "not found"
    end
  end

  # ---------------------------------------------------------------------------
  # WorktreeCreate (metadata only — actual git ops require real bare repo)
  # ---------------------------------------------------------------------------

  describe "WorktreeCreate metadata" do
    test "name, category, side_effects" do
      assert Synapsis.Tool.WorktreeCreate.name() == "worktree_create"
      assert Synapsis.Tool.WorktreeCreate.category() == :workflow
      assert Synapsis.Tool.WorktreeCreate.permission_level() == :none
      assert :worktree_created in Synapsis.Tool.WorktreeCreate.side_effects()
    end

    test "returns error for unknown repo_id" do
      bogus_id = Ecto.UUID.generate()

      assert {:error, msg} =
               Synapsis.Tool.WorktreeCreate.execute(
                 %{"repo_id" => bogus_id, "branch" => "feature/x"},
                 %{}
               )

      assert msg =~ "not found"
    end
  end

  # ---------------------------------------------------------------------------
  # WorktreeList
  # ---------------------------------------------------------------------------

  describe "WorktreeList metadata" do
    test "name, category, no side_effects" do
      assert Synapsis.Tool.WorktreeList.name() == "worktree_list"
      assert Synapsis.Tool.WorktreeList.category() == :workflow
      assert Synapsis.Tool.WorktreeList.permission_level() == :none
      assert Synapsis.Tool.WorktreeList.side_effects() == []
    end

    test "returns empty list for unknown repo_id" do
      bogus_id = Ecto.UUID.generate()
      assert {:ok, json} = Synapsis.Tool.WorktreeList.execute(%{"repo_id" => bogus_id}, %{})
      assert Jason.decode!(json) == []
    end
  end

  # ---------------------------------------------------------------------------
  # WorktreeRemove (metadata only)
  # ---------------------------------------------------------------------------

  describe "WorktreeRemove metadata" do
    test "name, category, side_effects" do
      assert Synapsis.Tool.WorktreeRemove.name() == "worktree_remove"
      assert Synapsis.Tool.WorktreeRemove.category() == :workflow
      assert Synapsis.Tool.WorktreeRemove.permission_level() == :none
      assert :worktree_removed in Synapsis.Tool.WorktreeRemove.side_effects()
    end

    test "returns error for unknown worktree_id" do
      bogus_id = Ecto.UUID.generate()

      assert {:error, msg} =
               Synapsis.Tool.WorktreeRemove.execute(%{"worktree_id" => bogus_id}, %{})

      assert msg =~ "not found"
    end
  end

  # ---------------------------------------------------------------------------
  # AgentSpawn (stub)
  # ---------------------------------------------------------------------------

  describe "AgentSpawn stub" do
    test "name, category, side_effects" do
      assert Synapsis.Tool.AgentSpawn.name() == "agent_spawn"
      assert Synapsis.Tool.AgentSpawn.category() == :workflow
      assert Synapsis.Tool.AgentSpawn.permission_level() == :none
      assert :agent_spawned in Synapsis.Tool.AgentSpawn.side_effects()
      assert :board_changed in Synapsis.Tool.AgentSpawn.side_effects()
    end

    test "returns not-implemented error" do
      assert {:error, msg} = Synapsis.Tool.AgentSpawn.execute(%{"task_id" => "t1"}, %{})
      assert msg =~ "not yet implemented"
    end
  end

  # ---------------------------------------------------------------------------
  # AgentStatus (stub)
  # ---------------------------------------------------------------------------

  describe "AgentStatus stub" do
    test "name, category, no side_effects" do
      assert Synapsis.Tool.AgentStatus.name() == "agent_status"
      assert Synapsis.Tool.AgentStatus.category() == :workflow
      assert Synapsis.Tool.AgentStatus.permission_level() == :none
      assert Synapsis.Tool.AgentStatus.side_effects() == []
    end

    test "returns stub JSON" do
      assert {:ok, json} = Synapsis.Tool.AgentStatus.execute(%{}, %{})
      result = Jason.decode!(json)
      assert result["agents"] == []
      assert result["message"] =~ "not yet implemented"
    end
  end

  # ---------------------------------------------------------------------------
  # :workflow category in Builtin
  # ---------------------------------------------------------------------------

  describe "workflow tools registration" do
    test "all 12 workflow tools are in builtin list" do
      workflow_tools = [
        Synapsis.Tool.BoardRead,
        Synapsis.Tool.BoardUpdate,
        Synapsis.Tool.DevlogRead,
        Synapsis.Tool.DevlogWrite,
        Synapsis.Tool.RepoLink,
        Synapsis.Tool.RepoSync,
        Synapsis.Tool.RepoStatus,
        Synapsis.Tool.WorktreeCreate,
        Synapsis.Tool.WorktreeList,
        Synapsis.Tool.WorktreeRemove,
        Synapsis.Tool.AgentSpawn,
        Synapsis.Tool.AgentStatus
      ]

      for mod <- workflow_tools do
        assert mod.category() == :workflow,
               "Expected #{inspect(mod)}.category() == :workflow, got #{mod.category()}"
      end
    end
  end
end
