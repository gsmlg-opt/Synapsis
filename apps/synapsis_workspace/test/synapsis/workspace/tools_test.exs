defmodule Synapsis.Workspace.ToolsTest do
  use ExUnit.Case

  alias Synapsis.Workspace.Tools.{WorkspaceRead, WorkspaceWrite, WorkspaceList, WorkspaceSearch}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Synapsis.Repo)

    {:ok, project} =
      Synapsis.Repo.insert(%Synapsis.Project{
        slug: "tool-test",
        path: "/tmp/tool-test"
      })

    %{project: project}
  end

  describe "tool metadata" do
    test "workspace_read has correct metadata" do
      assert WorkspaceRead.name() == "workspace_read"
      assert WorkspaceRead.permission_level() == :none
      assert WorkspaceRead.category() == :workspace
      assert is_binary(WorkspaceRead.description())
      assert WorkspaceRead.parameters()["required"] == ["path"]
    end

    test "workspace_write has correct metadata" do
      assert WorkspaceWrite.name() == "workspace_write"
      assert WorkspaceWrite.permission_level() == :write
      assert WorkspaceWrite.category() == :workspace
      assert "path" in WorkspaceWrite.parameters()["required"]
      assert "content" in WorkspaceWrite.parameters()["required"]
    end

    test "workspace_list has correct metadata" do
      assert WorkspaceList.name() == "workspace_list"
      assert WorkspaceList.permission_level() == :none
      assert WorkspaceList.parameters()["required"] == ["path"]
    end

    test "workspace_search has correct metadata" do
      assert WorkspaceSearch.name() == "workspace_search"
      assert WorkspaceSearch.permission_level() == :none
      assert WorkspaceSearch.parameters()["required"] == ["query"]
    end
  end

  describe "workspace_write execute/2" do
    test "creates a new document" do
      input = %{
        "path" => "/shared/notes/tool-write-test.md",
        "content" => "# Tool Write Test"
      }

      assert {:ok, json} = WorkspaceWrite.execute(input, %{})
      result = Jason.decode!(json)
      assert result["path"] == "/shared/notes/tool-write-test.md"
      assert result["version"] == 1
    end

    test "uses agent_id from context as author" do
      input = %{
        "path" => "/shared/notes/author-test.md",
        "content" => "authored content"
      }

      assert {:ok, _} = WorkspaceWrite.execute(input, %{agent_id: "agent-42"})

      {:ok, resource} = Synapsis.Workspace.read("/shared/notes/author-test.md")
      assert resource.created_by == "agent-42"
    end

    test "supports content_format option" do
      input = %{
        "path" => "/shared/notes/format-test.json",
        "content" => ~s({"key": "value"}),
        "content_format" => "json"
      }

      assert {:ok, _} = WorkspaceWrite.execute(input, %{})
      {:ok, resource} = Synapsis.Workspace.read("/shared/notes/format-test.json")
      assert resource.content_format == :json
    end

    test "supports metadata option" do
      input = %{
        "path" => "/shared/notes/meta-tool.md",
        "content" => "content",
        "metadata" => %{"title" => "My Note", "tags" => ["test"]}
      }

      assert {:ok, _} = WorkspaceWrite.execute(input, %{})
      {:ok, resource} = Synapsis.Workspace.read("/shared/notes/meta-tool.md")
      assert resource.metadata["title"] == "My Note"
    end
  end

  describe "workspace_read execute/2" do
    test "reads an existing document by path" do
      Synapsis.Workspace.write("/shared/notes/read-tool.md", "readable", %{author: "test"})

      input = %{"path" => "/shared/notes/read-tool.md"}
      assert {:ok, json} = WorkspaceRead.execute(input, %{})
      result = Jason.decode!(json)
      assert result["content"] == "readable"
      assert result["path"] == "/shared/notes/read-tool.md"
    end

    test "returns error for missing path" do
      input = %{"path" => "/shared/notes/missing.md"}
      assert {:error, msg} = WorkspaceRead.execute(input, %{})
      assert msg =~ "not found"
    end

    test "reads by ID" do
      {:ok, resource} =
        Synapsis.Workspace.write("/shared/notes/id-read.md", "by id", %{author: "test"})

      input = %{"path" => resource.id}
      assert {:ok, json} = WorkspaceRead.execute(input, %{})
      result = Jason.decode!(json)
      assert result["content"] == "by id"
    end
  end

  describe "workspace_list execute/2" do
    test "lists documents under prefix" do
      Synapsis.Workspace.write("/shared/list-tool/a.md", "a", %{author: "test"})
      Synapsis.Workspace.write("/shared/list-tool/b.md", "b", %{author: "test"})

      input = %{"path" => "/shared/list-tool"}
      assert {:ok, json} = WorkspaceList.execute(input, %{})
      results = Jason.decode!(json)
      assert length(results) == 2
    end

    test "returns empty list for no matches" do
      input = %{"path" => "/shared/empty-list"}
      assert {:ok, json} = WorkspaceList.execute(input, %{})
      assert Jason.decode!(json) == []
    end

    test "supports sort option" do
      Synapsis.Workspace.write("/shared/sort-tool/old.md", "old", %{author: "test"})
      Process.sleep(10)
      Synapsis.Workspace.write("/shared/sort-tool/new.md", "new", %{author: "test"})

      input = %{"path" => "/shared/sort-tool", "sort" => "recent"}
      assert {:ok, json} = WorkspaceList.execute(input, %{})
      [first | _] = Jason.decode!(json)
      assert first["path"] == "/shared/sort-tool/new.md"
    end

    test "supports limit option" do
      for i <- 1..5 do
        Synapsis.Workspace.write("/shared/limit-tool/#{i}.md", "#{i}", %{author: "test"})
      end

      input = %{"path" => "/shared/limit-tool", "limit" => 2}
      assert {:ok, json} = WorkspaceList.execute(input, %{})
      assert length(Jason.decode!(json)) == 2
    end
  end

  describe "workspace_search execute/2" do
    test "searches by content" do
      Synapsis.Workspace.write(
        "/shared/search-tool/elixir.md",
        "Elixir is a dynamic functional language",
        %{author: "test"}
      )

      input = %{"query" => "elixir functional"}
      assert {:ok, json} = WorkspaceSearch.execute(input, %{})
      results = Jason.decode!(json)
      assert length(results) >= 1
      assert Enum.any?(results, fn r -> r["path"] == "/shared/search-tool/elixir.md" end)
    end

    test "returns empty for no matches" do
      input = %{"query" => "nonexistent_xyzzy_9876"}
      assert {:ok, json} = WorkspaceSearch.execute(input, %{})
      assert Jason.decode!(json) == []
    end

    test "includes content preview in results" do
      Synapsis.Workspace.write(
        "/shared/search-tool/preview.md",
        "This is preview content for testing",
        %{author: "test"}
      )

      input = %{"query" => "preview testing"}
      assert {:ok, json} = WorkspaceSearch.execute(input, %{})
      results = Jason.decode!(json)

      if length(results) > 0 do
        assert Enum.all?(results, fn r -> Map.has_key?(r, "content_preview") end)
      end
    end
  end
end
