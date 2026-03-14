defmodule Synapsis.Workspace.ProjectionTest do
  use ExUnit.Case

  alias Synapsis.Workspace.Projection
  alias Synapsis.Workspace.Resource
  alias Synapsis.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    {:ok, project} =
      Repo.insert(%Synapsis.Project{
        slug: "proj-test-#{System.unique_integer([:positive])}",
        path: "/tmp/proj-test"
      })

    {:ok, session} =
      Repo.insert(%Synapsis.Session{
        project_id: project.id,
        provider: "anthropic",
        model: "claude-3-5-sonnet"
      })

    %{project: project, session: session}
  end

  # ---------------------------------------------------------------------------
  # project_skill/1
  # ---------------------------------------------------------------------------

  describe "project_skill/1" do
    test "maps a global skill to a Resource with correct path" do
      now = DateTime.utc_now()
      id = Ecto.UUID.generate()

      skill = %{
        id: id,
        scope: "global",
        project_id: nil,
        name: "elixir-patterns",
        description: "Idiomatic Elixir patterns",
        system_prompt_fragment: "Use pattern matching liberally.",
        tool_allowlist: ["file_read", "grep"],
        config_overrides: %{"model" => "claude-3-5-sonnet"},
        is_builtin: false,
        metadata: %{"tags" => ["elixir"]},
        inserted_at: now,
        updated_at: now
      }

      resource = Projection.project_skill(skill)

      assert %Resource{} = resource
      assert resource.id == id
      assert resource.path == "/shared/skills/elixir-patterns/SKILL.md"
      assert resource.kind == :skill
      assert resource.content_format == :markdown
      assert resource.visibility == :global_shared
      assert resource.lifecycle == :shared
      assert resource.version == 1
      assert resource.created_at == now
      assert resource.updated_at == now
    end

    test "maps a project-scoped skill to a Resource with project path", %{project: project} do
      now = DateTime.utc_now()
      id = Ecto.UUID.generate()

      skill = %{
        id: id,
        scope: "project",
        project_id: project.id,
        name: "api-design",
        description: "REST API conventions",
        system_prompt_fragment: nil,
        tool_allowlist: [],
        config_overrides: %{},
        is_builtin: true,
        metadata: nil,
        inserted_at: now,
        updated_at: now
      }

      resource = Projection.project_skill(skill)

      assert resource.path == "/projects/#{project.id}/skills/api-design/SKILL.md"
      assert resource.visibility == :project_shared
      assert resource.metadata["scope"] == "project"
      assert resource.metadata["project_id"] == project.id
      assert resource.metadata["is_builtin"] == true
    end

    test "includes tool_allowlist and config_overrides in metadata" do
      now = DateTime.utc_now()

      skill = %{
        id: Ecto.UUID.generate(),
        scope: "global",
        project_id: nil,
        name: "testing",
        description: nil,
        system_prompt_fragment: nil,
        tool_allowlist: ["bash_exec", "file_write"],
        config_overrides: %{"temperature" => 0.2},
        is_builtin: false,
        metadata: %{},
        inserted_at: now,
        updated_at: now
      }

      resource = Projection.project_skill(skill)

      assert resource.metadata["tool_allowlist"] == ["bash_exec", "file_write"]
      assert resource.metadata["config_overrides"] == %{"temperature" => 0.2}
    end

    test "builds markdown content from skill fields" do
      now = DateTime.utc_now()

      skill = %{
        id: Ecto.UUID.generate(),
        scope: "global",
        project_id: nil,
        name: "refactor",
        description: "Refactoring guidance",
        system_prompt_fragment: "Keep functions small.",
        tool_allowlist: ["file_edit"],
        config_overrides: %{},
        is_builtin: false,
        metadata: %{},
        inserted_at: now,
        updated_at: now
      }

      resource = Projection.project_skill(skill)

      assert resource.content =~ "# refactor"
      assert resource.content =~ "Refactoring guidance"
      assert resource.content =~ "Keep functions small."
      assert resource.content =~ "file_edit"
    end

    test "builds content without system_prompt when nil" do
      now = DateTime.utc_now()

      skill = %{
        id: Ecto.UUID.generate(),
        scope: "global",
        project_id: nil,
        name: "minimal",
        description: "Minimal skill",
        system_prompt_fragment: nil,
        tool_allowlist: [],
        config_overrides: %{},
        is_builtin: false,
        metadata: %{},
        inserted_at: now,
        updated_at: now
      }

      resource = Projection.project_skill(skill)

      assert resource.content =~ "# minimal"
      refute resource.content =~ "## System Prompt"
      refute resource.content =~ "## Tool Allowlist"
    end
  end

  # ---------------------------------------------------------------------------
  # project_memory/1
  # ---------------------------------------------------------------------------

  describe "project_memory/1" do
    test "maps a global memory entry to a Resource" do
      now = DateTime.utc_now()
      id = Ecto.UUID.generate()

      entry = %{
        id: id,
        scope: "global",
        scope_id: nil,
        key: "auth-patterns",
        content: "Use JWT tokens with short expiry.",
        metadata: %{"category" => "semantic"},
        inserted_at: now,
        updated_at: now
      }

      resource = Projection.project_memory(entry)

      assert %Resource{} = resource
      assert resource.id == id
      assert resource.path == "/shared/memory/semantic/auth-patterns.md"
      assert resource.kind == :memory
      assert resource.content == "Use JWT tokens with short expiry."
      assert resource.content_format == :markdown
      assert resource.visibility == :global_shared
      assert resource.lifecycle == :shared
      assert resource.version == 1
    end

    test "maps a project-scoped memory entry with project path", %{project: project} do
      now = DateTime.utc_now()
      id = Ecto.UUID.generate()

      entry = %{
        id: id,
        scope: "project",
        scope_id: project.id,
        key: "db-schema",
        content: "Users table has UUID primary keys.",
        metadata: %{"category" => "architecture"},
        inserted_at: now,
        updated_at: now
      }

      resource = Projection.project_memory(entry)

      assert resource.path == "/projects/#{project.id}/memory/architecture/db-schema.md"
      assert resource.visibility == :project_shared
    end

    test "uses 'general' as default category when metadata has no category" do
      now = DateTime.utc_now()

      entry = %{
        id: Ecto.UUID.generate(),
        scope: "global",
        scope_id: nil,
        key: "uncategorized-note",
        content: "Some note.",
        metadata: %{},
        inserted_at: now,
        updated_at: now
      }

      resource = Projection.project_memory(entry)

      assert resource.path == "/shared/memory/general/uncategorized-note.md"
    end

    test "uses 'general' when metadata is nil" do
      now = DateTime.utc_now()

      entry = %{
        id: Ecto.UUID.generate(),
        scope: "global",
        scope_id: nil,
        key: "nil-meta-note",
        content: "Content.",
        metadata: nil,
        inserted_at: now,
        updated_at: now
      }

      resource = Projection.project_memory(entry)

      assert resource.path == "/shared/memory/general/nil-meta-note.md"
      assert resource.metadata == %{}
    end

    test "session-scoped memory entry has private visibility" do
      now = DateTime.utc_now()
      session_id = Ecto.UUID.generate()

      entry = %{
        id: Ecto.UUID.generate(),
        scope: "session",
        scope_id: session_id,
        key: "context-note",
        content: "Temporary context.",
        metadata: %{"category" => "scratch"},
        inserted_at: now,
        updated_at: now
      }

      resource = Projection.project_memory(entry)

      assert resource.visibility == :private
      assert resource.path =~
               "/projects/unknown/sessions/#{session_id}/memory/scratch/context-note.md"
    end
  end

  # ---------------------------------------------------------------------------
  # project_todo/1
  # ---------------------------------------------------------------------------

  describe "project_todo/1" do
    test "maps a session todo to a Resource", %{project: project, session: session} do
      now = DateTime.utc_now()
      id = Ecto.UUID.generate()

      todo = %{
        id: id,
        session_id: session.id,
        project_id: project.id,
        todo_id: "todo-1",
        content: "Write tests for projection module",
        status: :pending,
        sort_order: 0,
        inserted_at: now,
        updated_at: now
      }

      resource = Projection.project_todo(todo)

      assert %Resource{} = resource
      assert resource.id == id
      assert resource.path == "/projects/#{project.id}/sessions/#{session.id}/todo.md"
      assert resource.kind == :todo
      assert resource.content_format == :markdown
      assert resource.visibility == :private
      assert resource.lifecycle == :scratch
      assert resource.version == 1
    end

    test "renders pending todo with unchecked markdown mark", %{
      project: project,
      session: session
    } do
      now = DateTime.utc_now()

      todo = %{
        id: Ecto.UUID.generate(),
        session_id: session.id,
        project_id: project.id,
        todo_id: "t-pend",
        content: "Fix the bug",
        status: :pending,
        sort_order: 0,
        inserted_at: now,
        updated_at: now
      }

      resource = Projection.project_todo(todo)

      assert resource.content == "- [ ] Fix the bug"
    end

    test "renders completed todo with checked markdown mark", %{
      project: project,
      session: session
    } do
      now = DateTime.utc_now()

      todo = %{
        id: Ecto.UUID.generate(),
        session_id: session.id,
        project_id: project.id,
        todo_id: "t-done",
        content: "Deploy to staging",
        status: :completed,
        sort_order: 1,
        inserted_at: now,
        updated_at: now
      }

      resource = Projection.project_todo(todo)

      assert resource.content == "- [x] Deploy to staging"
    end

    test "renders in_progress todo with dash mark", %{project: project, session: session} do
      now = DateTime.utc_now()

      todo = %{
        id: Ecto.UUID.generate(),
        session_id: session.id,
        project_id: project.id,
        todo_id: "t-wip",
        content: "Refactor context module",
        status: :in_progress,
        sort_order: 2,
        inserted_at: now,
        updated_at: now
      }

      resource = Projection.project_todo(todo)

      assert resource.content == "- [-] Refactor context module"
    end

    test "includes session_id and todo_id in metadata", %{project: project, session: session} do
      now = DateTime.utc_now()

      todo = %{
        id: Ecto.UUID.generate(),
        session_id: session.id,
        project_id: project.id,
        todo_id: "meta-check",
        content: "Check metadata",
        status: :pending,
        sort_order: 0,
        inserted_at: now,
        updated_at: now
      }

      resource = Projection.project_todo(todo)

      assert resource.metadata["session_id"] == session.id
      assert resource.metadata["project_id"] == project.id
      assert resource.metadata["todo_id"] == "meta-check"
      assert resource.metadata["status"] == "pending"
      assert resource.metadata["sort_order"] == 0
    end

    test "resolves project_id from preloaded session association", %{
      project: project,
      session: session
    } do
      now = DateTime.utc_now()

      todo = %{
        id: Ecto.UUID.generate(),
        session_id: session.id,
        session: %{project_id: project.id},
        todo_id: "via-assoc",
        content: "Via association",
        status: :pending,
        sort_order: 0,
        inserted_at: now,
        updated_at: now
      }

      resource = Projection.project_todo(todo)

      assert resource.path == "/projects/#{project.id}/sessions/#{session.id}/todo.md"
    end

    test "falls back to 'unknown' project_id when not resolvable", %{session: session} do
      now = DateTime.utc_now()

      todo = %{
        id: Ecto.UUID.generate(),
        session_id: session.id,
        todo_id: "no-project",
        content: "Orphan todo",
        status: :pending,
        sort_order: 0,
        inserted_at: now,
        updated_at: now
      }

      resource = Projection.project_todo(todo)

      assert resource.path =~ "/projects/unknown/sessions/#{session.id}/todo.md"
    end
  end

  # ---------------------------------------------------------------------------
  # list_projected/2
  # ---------------------------------------------------------------------------

  describe "list_projected/2" do
    test "returns global skills for /shared/skills prefix", %{project: _project} do
      {:ok, _} =
        Repo.insert(%Synapsis.Skill{
          scope: "global",
          name: "global-listed-skill-#{System.unique_integer([:positive])}",
          description: "Test skill"
        })

      results = Projection.list_projected("/shared/skills")

      assert is_list(results)
      assert length(results) >= 1
      assert Enum.all?(results, fn r -> r.kind == :skill end)
      assert Enum.all?(results, fn r -> String.starts_with?(r.path, "/shared/skills/") end)
    end

    test "returns project skills for /projects/:id/skills prefix", %{project: project} do
      {:ok, _} =
        Repo.insert(%Synapsis.Skill{
          scope: "project",
          project_id: project.id,
          name: "proj-skill-#{System.unique_integer([:positive])}",
          description: "Project specific"
        })

      results = Projection.list_projected("/projects/#{project.id}/skills")

      assert is_list(results)
      assert length(results) >= 1
      assert Enum.all?(results, fn r -> r.kind == :skill end)
      assert Enum.all?(results, fn r -> String.contains?(r.path, "/projects/#{project.id}/skills/") end)
    end

    @tag :skip
    test "returns global memory entries for /shared/memory prefix" do
      {:ok, _} =
        Repo.insert(%Synapsis.MemoryEntry{
          scope: "global",
          key: "mem-listed-#{System.unique_integer([:positive])}",
          content: "Global memory content",
          metadata: %{"category" => "general"}
        })

      results = Projection.list_projected("/shared/memory")

      assert is_list(results)
      assert length(results) >= 1
      assert Enum.all?(results, fn r -> r.kind == :memory end)
    end

    @tag :skip
    test "returns project memory entries for /projects/:id/memory prefix", %{project: project} do
      {:ok, _} =
        Repo.insert(%Synapsis.MemoryEntry{
          scope: "project",
          scope_id: project.id,
          key: "proj-mem-#{System.unique_integer([:positive])}",
          content: "Project memory content",
          metadata: %{"category" => "architecture"}
        })

      results = Projection.list_projected("/projects/#{project.id}/memory")

      assert is_list(results)
      assert length(results) >= 1
      assert Enum.all?(results, fn r -> r.kind == :memory end)
    end

    test "returns todo resources for /projects/:id/sessions/:sid prefix", %{
      project: project,
      session: session
    } do
      {:ok, _} =
        Repo.insert(%Synapsis.SessionTodo{
          session_id: session.id,
          todo_id: "listed-todo-#{System.unique_integer([:positive])}",
          content: "Do something",
          status: :pending,
          sort_order: 0
        })

      results = Projection.list_projected("/projects/#{project.id}/sessions/#{session.id}")

      assert is_list(results)
      assert length(results) >= 1
      assert Enum.all?(results, fn r -> r.kind == :todo end)
    end

    test "returns empty list for unrecognized path prefix" do
      assert Projection.list_projected("/unknown/path/prefix") == []
    end

    @tag :skip
    test "filters by kind option", %{project: project} do
      {:ok, _} =
        Repo.insert(%Synapsis.Skill{
          scope: "project",
          project_id: project.id,
          name: "kind-filter-skill-#{System.unique_integer([:positive])}",
          description: "Kind filter test"
        })

      {:ok, _} =
        Repo.insert(%Synapsis.MemoryEntry{
          scope: "project",
          scope_id: project.id,
          key: "kind-filter-mem-#{System.unique_integer([:positive])}",
          content: "Memory for filter test",
          metadata: %{}
        })

      skill_results =
        Projection.list_projected("/projects/#{project.id}/skills", kind: :skill)

      assert Enum.all?(skill_results, fn r -> r.kind == :skill end)
    end

    test "respects :limit option", %{project: project} do
      for i <- 1..5 do
        Repo.insert!(%Synapsis.Skill{
          scope: "project",
          project_id: project.id,
          name: "limit-skill-#{i}-#{System.unique_integer([:positive])}",
          description: "Limit test skill #{i}"
        })
      end

      results = Projection.list_projected("/projects/#{project.id}/skills", limit: 2)

      assert length(results) <= 2
    end
  end

  # ---------------------------------------------------------------------------
  # find_projected/1
  # ---------------------------------------------------------------------------

  describe "find_projected/1" do
    test "finds a global skill by exact path" do
      unique = System.unique_integer([:positive])

      {:ok, skill} =
        Repo.insert(%Synapsis.Skill{
          scope: "global",
          name: "find-global-skill-#{unique}",
          description: "Findable global skill"
        })

      path = "/shared/skills/find-global-skill-#{unique}/SKILL.md"
      assert {:ok, resource} = Projection.find_projected(path)

      assert resource.id == skill.id
      assert resource.path == path
      assert resource.kind == :skill
      assert resource.visibility == :global_shared
    end

    test "finds a project skill by exact path", %{project: project} do
      unique = System.unique_integer([:positive])

      {:ok, skill} =
        Repo.insert(%Synapsis.Skill{
          scope: "project",
          project_id: project.id,
          name: "find-project-skill-#{unique}",
          description: "Findable project skill"
        })

      path = "/projects/#{project.id}/skills/find-project-skill-#{unique}/SKILL.md"
      assert {:ok, resource} = Projection.find_projected(path)

      assert resource.id == skill.id
      assert resource.path == path
      assert resource.visibility == :project_shared
    end

    test "returns :not_found for skill that does not exist" do
      assert {:error, :not_found} =
               Projection.find_projected("/shared/skills/nonexistent-skill-xyz/SKILL.md")
    end

    @tag :skip
    test "finds a global memory entry by path" do
      unique = System.unique_integer([:positive])
      key = "find-global-mem-#{unique}"

      {:ok, entry} =
        Repo.insert(%Synapsis.MemoryEntry{
          scope: "global",
          key: key,
          content: "Findable global memory",
          metadata: %{"category" => "technical"}
        })

      path = "/shared/memory/technical/#{key}.md"
      assert {:ok, resource} = Projection.find_projected(path)

      assert resource.id == entry.id
      assert resource.path == path
      assert resource.kind == :memory
    end

    @tag :skip
    test "finds a project memory entry by path", %{project: project} do
      unique = System.unique_integer([:positive])
      key = "find-proj-mem-#{unique}"

      {:ok, entry} =
        Repo.insert(%Synapsis.MemoryEntry{
          scope: "project",
          scope_id: project.id,
          key: key,
          content: "Findable project memory",
          metadata: %{"category" => "semantic"}
        })

      path = "/projects/#{project.id}/memory/semantic/#{key}.md"
      assert {:ok, resource} = Projection.find_projected(path)

      assert resource.id == entry.id
      assert resource.kind == :memory
      assert resource.visibility == :project_shared
    end

    @tag :skip
    test "returns :not_found for memory entry that does not exist" do
      assert {:error, :not_found} =
               Projection.find_projected("/shared/memory/general/no-such-entry.md")
    end

    test "finds todos for a session as aggregated resource", %{
      project: project,
      session: session
    } do
      unique = System.unique_integer([:positive])

      {:ok, _} =
        Repo.insert(%Synapsis.SessionTodo{
          session_id: session.id,
          todo_id: "found-todo-#{unique}",
          content: "First todo item",
          status: :pending,
          sort_order: 0
        })

      {:ok, _} =
        Repo.insert(%Synapsis.SessionTodo{
          session_id: session.id,
          todo_id: "found-todo-2-#{unique}",
          content: "Second todo item",
          status: :completed,
          sort_order: 1
        })

      path = "/projects/#{project.id}/sessions/#{session.id}/todo.md"
      assert {:ok, resource} = Projection.find_projected(path)

      assert resource.id == session.id
      assert resource.path == path
      assert resource.kind == :todo
      assert resource.content =~ "First todo item"
      assert resource.content =~ "Second todo item"
      assert resource.metadata["count"] == 2
    end

    test "returns :not_found for session with no todos", %{project: project, session: session} do
      path = "/projects/#{project.id}/sessions/#{session.id}/todo.md"

      assert {:error, :not_found} = Projection.find_projected(path)
    end

    test "returns :not_found for unrecognized path pattern" do
      assert {:error, :not_found} =
               Projection.find_projected("/shared/unknown-thing/foo.md")
    end

    @tag :skip
    test "strips .md extension correctly when looking up memory entries" do
      unique = System.unique_integer([:positive])
      key = "ext-strip-test-#{unique}"

      {:ok, _} =
        Repo.insert(%Synapsis.MemoryEntry{
          scope: "global",
          key: key,
          content: "Extension stripping test.",
          metadata: %{"category" => "general"}
        })

      assert {:ok, resource} =
               Projection.find_projected("/shared/memory/general/#{key}.md")

      assert resource.content == "Extension stripping test."
    end
  end
end
