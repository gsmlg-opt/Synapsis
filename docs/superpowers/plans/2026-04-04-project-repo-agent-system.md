# Project/Repo/Agent System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce the three-tier entity hierarchy (Global → Project → Repo), git worktree-based parallel execution, workflow tools, and two-role agent model (Assistant + Build Agent).

**Architecture:** Projects are organizational containers with kanban boards, devlogs, plans, and design docs stored as workspace documents (YAML/Markdown). Repos are bare git clones managed by the system; worktrees are ephemeral checkouts for Build Agents. All git operations go through a pure-function CLI wrapper module. 12 new workflow tools expose project management to the Assistant. The existing four-archetype agent model is replaced by a two-role model: singleton Assistant + ephemeral Build Agents.

**Tech Stack:** Elixir 1.18+/OTP 28+, Ecto/PostgreSQL, Phoenix PubSub, `yaml_elixir` (new dep), Port-based git CLI, Oban for cleanup jobs.

---

## Scope Check

This PRD covers 6 subsystems (Entity Model, Git Ops, Workspace, Tools, Agents, Web UI). They are **not independent** — each layer depends on the one below it. This plan implements them bottom-up as 5 phases. The plan is designed so each phase produces compilable, testable code.

---

## File Structure

### Phase 1: Entity Model (synapsis_data)

| Action | File | Responsibility |
|--------|------|----------------|
| NEW | `apps/synapsis_data/priv/repo/migrations/*_alter_projects_add_status.exs` | Add `name`, `description`, `status`, `metadata` columns; drop `path` constraint requirement |
| NEW | `apps/synapsis_data/priv/repo/migrations/*_create_repos.exs` | Create `repos` table |
| NEW | `apps/synapsis_data/priv/repo/migrations/*_create_repo_remotes.exs` | Create `repo_remotes` table |
| NEW | `apps/synapsis_data/priv/repo/migrations/*_create_repo_worktrees.exs` | Create `repo_worktrees` table |
| MODIFY | `apps/synapsis_data/lib/synapsis/project.ex` | Add `name`, `description`, `status`, `metadata` fields; add `has_many :repos` |
| NEW | `apps/synapsis_data/lib/synapsis/repo_record.ex` | Repo schema (named `RepoRecord` to avoid collision with `Synapsis.Repo`) |
| NEW | `apps/synapsis_data/lib/synapsis/repo_remote.ex` | RepoRemote schema |
| NEW | `apps/synapsis_data/lib/synapsis/repo_worktree.ex` | RepoWorktree schema |
| NEW | `apps/synapsis_data/lib/synapsis/projects.ex` | Projects context (CRUD + archive) |
| NEW | `apps/synapsis_data/lib/synapsis/repos.ex` | Repos context (CRUD + remotes) |
| NEW | `apps/synapsis_data/lib/synapsis/worktrees.ex` | Worktrees context (lifecycle + query) |

### Phase 2: Git Operations (synapsis_core)

| Action | File | Responsibility |
|--------|------|----------------|
| NEW | `apps/synapsis_core/lib/synapsis/git/runner.ex` | Shared Port-based git command execution (extracted from existing `Synapsis.Git`) |
| NEW | `apps/synapsis_core/lib/synapsis/git/repo_ops.ex` | `clone_bare`, `add_remote`, `remove_remote`, `set_push_url`, `fetch_all`, `fetch_remote` |
| NEW | `apps/synapsis_core/lib/synapsis/git/branch.ex` | `create`, `delete`, `list`, `exists?` |
| NEW | `apps/synapsis_core/lib/synapsis/git/worktree.ex` | `create`, `remove`, `list`, `prune` (distinct from existing `Synapsis.GitWorktree`) |
| NEW | `apps/synapsis_core/lib/synapsis/git/log.ex` | `recent` — parsed commit log |
| NEW | `apps/synapsis_core/lib/synapsis/git/diff.ex` | `from_base`, `stat` |
| NEW | `apps/synapsis_core/lib/synapsis/git/status.ex` | `summary` — porcelain status parser |

### Phase 3: Workspace + Board + DevLog (synapsis_core + synapsis_workspace)

| Action | File | Responsibility |
|--------|------|----------------|
| NEW | `apps/synapsis_core/lib/synapsis/board.ex` | Board YAML parse/serialize/mutate (pure functions) |
| NEW | `apps/synapsis_core/lib/synapsis/dev_log.ex` | DevLog markdown parse/append (pure functions) |
| MODIFY | `apps/synapsis_workspace/lib/synapsis/workspace/path_resolver.ex` | Add new path patterns (board, plan, design_doc, devlog, repo_config) |
| NEW | `apps/synapsis_workspace/lib/synapsis/workspace/seeding.ex` | `seed_project/1` — create default workspace docs on project creation |
| MODIFY | `apps/synapsis_core/mix.exs` | Add `yaml_elixir` dependency |

### Phase 4: Workflow Tools (synapsis_core)

| Action | File | Responsibility |
|--------|------|----------------|
| NEW | `apps/synapsis_core/lib/synapsis/tool/board_read.ex` | Read kanban board |
| NEW | `apps/synapsis_core/lib/synapsis/tool/board_update.ex` | Create/move/update/remove board cards |
| NEW | `apps/synapsis_core/lib/synapsis/tool/devlog_write.ex` | Append devlog entry |
| NEW | `apps/synapsis_core/lib/synapsis/tool/devlog_read.ex` | Read devlog entries |
| NEW | `apps/synapsis_core/lib/synapsis/tool/repo_link.ex` | Link git repo to project |
| NEW | `apps/synapsis_core/lib/synapsis/tool/repo_sync.ex` | Fetch all remotes |
| NEW | `apps/synapsis_core/lib/synapsis/tool/repo_status.ex` | Repo summary |
| NEW | `apps/synapsis_core/lib/synapsis/tool/worktree_create.ex` | Create worktree for task |
| NEW | `apps/synapsis_core/lib/synapsis/tool/worktree_list.ex` | List active worktrees |
| NEW | `apps/synapsis_core/lib/synapsis/tool/worktree_remove.ex` | Remove worktree |
| NEW | `apps/synapsis_core/lib/synapsis/tool/agent_spawn.ex` | Spawn Build Agent |
| NEW | `apps/synapsis_core/lib/synapsis/tool/agent_status.ex` | Query agent status |
| MODIFY | `apps/synapsis_core/lib/synapsis/tool.ex` | Add `:workflow` to category type |
| MODIFY | `apps/synapsis_core/lib/synapsis/tool/builtin.ex` | Register 12 new workflow tools |

### Phase 5: Agent Architecture (synapsis_agent)

| Action | File | Responsibility |
|--------|------|----------------|
| NEW | `apps/synapsis_agent/lib/synapsis/agent/agents/assistant_agent.ex` | Singleton Assistant GenServer |
| NEW | `apps/synapsis_agent/lib/synapsis/agent/agents/build_agent.ex` | Ephemeral Build Agent |
| NEW | `apps/synapsis_agent/lib/synapsis/agent/project_context_builder.ex` | Assemble project context for Assistant |
| NEW | `apps/synapsis_agent/lib/synapsis/agent/repo_context_builder.ex` | Assemble repo context for Build Agent |
| NEW | `apps/synapsis_agent/lib/synapsis/agent/tool_scoping.ex` | Role-based tool filtering |
| NEW | `apps/synapsis_agent/lib/synapsis/agent/build_agent_supervisor.ex` | DynamicSupervisor for Build Agents |
| NEW | `apps/synapsis_agent/lib/synapsis/agent/worktree_cleanup.ex` | Oban worker for worktree GC |

---

## Phase 1: Entity Model

### Task 1: Migration — alter projects table

**Files:**
- Create: `apps/synapsis_data/priv/repo/migrations/20260404000001_alter_projects_add_fields.exs`

- [ ] **Step 1: Write the migration**

```elixir
defmodule Synapsis.Repo.Migrations.AlterProjectsAddFields do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :name, :string
      add :description, :text
      add :status, :string, default: "active", null: false
      add :metadata, :map, default: %{}
    end

    # Backfill name from slug for existing rows
    execute(
      "UPDATE projects SET name = slug WHERE name IS NULL",
      "SELECT 1"
    )

    # Now make name not null
    alter table(:projects) do
      modify :name, :string, null: false
    end

    create unique_index(:projects, [:name])
  end
end
```

- [ ] **Step 2: Run migration**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix ecto.migrate'`
Expected: Migration succeeds.

- [ ] **Step 3: Commit**

```bash
git add apps/synapsis_data/priv/repo/migrations/20260404000001_alter_projects_add_fields.exs
git commit -m "feat(data): add name, description, status, metadata to projects"
```

### Task 2: Migration — create repos table

**Files:**
- Create: `apps/synapsis_data/priv/repo/migrations/20260404000002_create_repos.exs`

- [ ] **Step 1: Write the migration**

```elixir
defmodule Synapsis.Repo.Migrations.CreateRepos do
  use Ecto.Migration

  def change do
    create table(:repos, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false
      add :name, :string, null: false
      add :bare_path, :string, null: false
      add :default_branch, :string, null: false, default: "main"
      add :status, :string, null: false, default: "active"
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repos, [:project_id, :name])
    create index(:repos, [:project_id])
  end
end
```

- [ ] **Step 2: Run migration**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix ecto.migrate'`

- [ ] **Step 3: Commit**

```bash
git add apps/synapsis_data/priv/repo/migrations/20260404000002_create_repos.exs
git commit -m "feat(data): create repos table"
```

### Task 3: Migration — create repo_remotes table

**Files:**
- Create: `apps/synapsis_data/priv/repo/migrations/20260404000003_create_repo_remotes.exs`

- [ ] **Step 1: Write the migration**

```elixir
defmodule Synapsis.Repo.Migrations.CreateRepoRemotes do
  use Ecto.Migration

  def change do
    create table(:repo_remotes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :repo_id, references(:repos, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :url, :string, null: false
      add :push_url, :string
      add :is_primary, :boolean, default: false, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repo_remotes, [:repo_id, :name])
    create index(:repo_remotes, [:repo_id])
  end
end
```

- [ ] **Step 2: Run migration and commit**

```bash
git add apps/synapsis_data/priv/repo/migrations/20260404000003_create_repo_remotes.exs
git commit -m "feat(data): create repo_remotes table"
```

### Task 4: Migration — create repo_worktrees table

**Files:**
- Create: `apps/synapsis_data/priv/repo/migrations/20260404000004_create_repo_worktrees.exs`

- [ ] **Step 1: Write the migration**

```elixir
defmodule Synapsis.Repo.Migrations.CreateRepoWorktrees do
  use Ecto.Migration

  def change do
    create table(:repo_worktrees, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :repo_id, references(:repos, type: :binary_id, on_delete: :restrict), null: false
      add :branch, :string, null: false
      add :base_branch, :string
      add :local_path, :string, null: false
      add :status, :string, null: false, default: "active"
      add :agent_session_id, :string
      add :task_id, :string
      add :metadata, :map, default: %{}
      add :completed_at, :utc_datetime_usec
      add :cleaned_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repo_worktrees, [:repo_id, :branch],
             where: "status = 'active'",
             name: :repo_worktrees_repo_id_branch_active_index)
    create index(:repo_worktrees, [:repo_id])
    create index(:repo_worktrees, [:status])
  end
end
```

- [ ] **Step 2: Run migration and commit**

```bash
git add apps/synapsis_data/priv/repo/migrations/20260404000004_create_repo_worktrees.exs
git commit -m "feat(data): create repo_worktrees table"
```

### Task 5: Modify Project schema

**Files:**
- Modify: `apps/synapsis_data/lib/synapsis/project.ex`
- Test: `apps/synapsis_data/test/synapsis/project_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# apps/synapsis_data/test/synapsis/project_test.exs
defmodule Synapsis.ProjectTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.Project

  describe "changeset/2" do
    test "valid with name, path, slug" do
      cs = Project.changeset(%Project{}, %{
        name: "my-project",
        path: "/tmp/my-project",
        slug: "my-project"
      })
      assert cs.valid?
    end

    test "requires name" do
      cs = Project.changeset(%Project{}, %{path: "/tmp/x", slug: "x"})
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "validates name format — lowercase alphanumeric with hyphens" do
      cs = Project.changeset(%Project{}, %{
        name: "My Project!",
        path: "/tmp/x",
        slug: "x"
      })
      assert %{name: [_]} = errors_on(cs)
    end

    test "validates name length 1–64" do
      cs = Project.changeset(%Project{}, %{
        name: String.duplicate("a", 65),
        path: "/tmp/x",
        slug: "x"
      })
      assert %{name: [_]} = errors_on(cs)

      cs_empty = Project.changeset(%Project{}, %{name: "", path: "/tmp/x", slug: "x"})
      assert %{name: [_]} = errors_on(cs_empty)
    end

    test "validates name uniqueness" do
      {:ok, _} = %Project{}
        |> Project.changeset(%{name: "unique-proj", path: "/tmp/a", slug: "a"})
        |> Repo.insert()

      {:error, cs} = %Project{}
        |> Project.changeset(%{name: "unique-proj", path: "/tmp/b", slug: "b"})
        |> Repo.insert()

      assert %{name: ["has already been taken"]} = errors_on(cs)
    end

    test "defaults status to active" do
      cs = Project.changeset(%Project{}, %{name: "proj", path: "/tmp/x", slug: "x"})
      assert Ecto.Changeset.get_field(cs, :status) == :active
    end

    test "validates status enum" do
      cs = Project.changeset(%Project{}, %{
        name: "proj",
        path: "/tmp/x",
        slug: "x",
        status: :invalid
      })
      assert %{status: [_]} = errors_on(cs)
    end

    test "accepts valid status values" do
      for status <- [:active, :paused, :archived] do
        cs = Project.changeset(%Project{}, %{
          name: "proj-#{status}",
          path: "/tmp/#{status}",
          slug: "#{status}",
          status: status
        })
        assert cs.valid?, "expected #{status} to be valid"
      end
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix test apps/synapsis_data/test/synapsis/project_test.exs --trace'`
Expected: Failures — `name` field doesn't exist yet, `status` enum doesn't exist.

- [ ] **Step 3: Update the Project schema**

```elixir
# apps/synapsis_data/lib/synapsis/project.ex
defmodule Synapsis.Project do
  @moduledoc "Project entity — organizational container for repos and work artifacts."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @name_format ~r/^[a-z0-9][a-z0-9-]*$/

  schema "projects" do
    field(:path, :string)
    field(:slug, :string)
    field(:name, :string)
    field(:description, :string)
    field(:status, Ecto.Enum, values: [:active, :paused, :archived], default: :active)
    field(:config, :map, default: %{})
    field(:metadata, :map, default: %{})

    has_many(:sessions, Synapsis.Session)
    has_many(:repos, Synapsis.RepoRecord)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:path, :slug, :name, :description, :status, :config, :metadata])
    |> validate_required([:path, :slug, :name])
    |> validate_format(:name, @name_format, message: "must be lowercase alphanumeric with hyphens, starting with a letter or digit")
    |> validate_length(:name, min: 1, max: 64)
    |> unique_constraint(:path)
    |> unique_constraint(:slug)
    |> unique_constraint(:name)
  end

  def slug_from_path(path) do
    path
    |> Path.basename()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "-")
    |> String.trim("-")
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix test apps/synapsis_data/test/synapsis/project_test.exs --trace'`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add apps/synapsis_data/lib/synapsis/project.ex apps/synapsis_data/test/synapsis/project_test.exs
git commit -m "feat(data): add name, description, status to Project schema"
```

### Task 6: RepoRecord schema

**Files:**
- Create: `apps/synapsis_data/lib/synapsis/repo_record.ex`
- Test: `apps/synapsis_data/test/synapsis/repo_record_test.exs`

Note: Named `RepoRecord` because `Synapsis.Repo` is the Ecto Repo module.

- [ ] **Step 1: Write failing tests**

```elixir
# apps/synapsis_data/test/synapsis/repo_record_test.exs
defmodule Synapsis.RepoRecordTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{RepoRecord, Project}

  setup do
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{name: "test-proj", path: "/tmp/rr-test", slug: "rr-test"})
      |> Repo.insert()

    %{project: project}
  end

  describe "changeset/2" do
    test "valid with project_id, name, bare_path", %{project: project} do
      cs = RepoRecord.changeset(%RepoRecord{}, %{
        project_id: project.id,
        name: "my-repo",
        bare_path: "/tmp/repos/abc/bare.git"
      })
      assert cs.valid?
    end

    test "requires project_id, name, bare_path" do
      cs = RepoRecord.changeset(%RepoRecord{}, %{})
      errors = errors_on(cs)
      assert Map.has_key?(errors, :project_id)
      assert Map.has_key?(errors, :name)
      assert Map.has_key?(errors, :bare_path)
    end

    test "validates name format", %{project: project} do
      cs = RepoRecord.changeset(%RepoRecord{}, %{
        project_id: project.id,
        name: "Bad Name!",
        bare_path: "/tmp/x"
      })
      assert %{name: [_]} = errors_on(cs)
    end

    test "validates name uniqueness within project", %{project: project} do
      {:ok, _} =
        %RepoRecord{}
        |> RepoRecord.changeset(%{project_id: project.id, name: "repo-a", bare_path: "/tmp/a"})
        |> Repo.insert()

      {:error, cs} =
        %RepoRecord{}
        |> RepoRecord.changeset(%{project_id: project.id, name: "repo-a", bare_path: "/tmp/b"})
        |> Repo.insert()

      assert %{name: ["has already been taken"]} = errors_on(cs)
    end

    test "defaults default_branch to main", %{project: project} do
      cs = RepoRecord.changeset(%RepoRecord{}, %{
        project_id: project.id,
        name: "repo-b",
        bare_path: "/tmp/b"
      })
      assert Ecto.Changeset.get_field(cs, :default_branch) == "main"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix test apps/synapsis_data/test/synapsis/repo_record_test.exs --trace'`
Expected: Compilation error — `RepoRecord` module doesn't exist.

- [ ] **Step 3: Implement RepoRecord schema**

```elixir
# apps/synapsis_data/lib/synapsis/repo_record.ex
defmodule Synapsis.RepoRecord do
  @moduledoc "Git repository entity belonging to a project."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @name_format ~r/^[a-z0-9][a-z0-9-]*$/

  schema "repos" do
    field :name, :string
    field :bare_path, :string
    field :default_branch, :string, default: "main"
    field :status, Ecto.Enum, values: [:active, :archived], default: :active
    field :metadata, :map, default: %{}

    belongs_to :project, Synapsis.Project
    has_many :remotes, Synapsis.RepoRemote
    has_many :worktrees, Synapsis.RepoWorktree

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:project_id, :name, :bare_path, :default_branch, :status, :metadata])
    |> validate_required([:project_id, :name, :bare_path])
    |> validate_format(:name, @name_format, message: "must be lowercase alphanumeric with hyphens")
    |> validate_length(:name, min: 1, max: 64)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:project_id, :name])
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix test apps/synapsis_data/test/synapsis/repo_record_test.exs --trace'`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add apps/synapsis_data/lib/synapsis/repo_record.ex apps/synapsis_data/test/synapsis/repo_record_test.exs
git commit -m "feat(data): add RepoRecord schema"
```

### Task 7: RepoRemote schema

**Files:**
- Create: `apps/synapsis_data/lib/synapsis/repo_remote.ex`
- Test: `apps/synapsis_data/test/synapsis/repo_remote_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# apps/synapsis_data/test/synapsis/repo_remote_test.exs
defmodule Synapsis.RepoRemoteTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{RepoRemote, RepoRecord, Project}

  setup do
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{name: "rmt-proj", path: "/tmp/rmt", slug: "rmt"})
      |> Repo.insert()

    {:ok, repo} =
      %RepoRecord{}
      |> RepoRecord.changeset(%{project_id: project.id, name: "rmt-repo", bare_path: "/tmp/rmt/bare"})
      |> Repo.insert()

    %{repo: repo}
  end

  describe "changeset/2" do
    test "valid with repo_id, name, url", %{repo: repo} do
      cs = RepoRemote.changeset(%RepoRemote{}, %{
        repo_id: repo.id,
        name: "origin",
        url: "https://github.com/user/repo.git"
      })
      assert cs.valid?
    end

    test "requires repo_id, name, url" do
      cs = RepoRemote.changeset(%RepoRemote{}, %{})
      errors = errors_on(cs)
      assert Map.has_key?(errors, :repo_id)
      assert Map.has_key?(errors, :name)
      assert Map.has_key?(errors, :url)
    end

    test "validates url format — HTTPS", %{repo: repo} do
      cs = RepoRemote.changeset(%RepoRemote{}, %{
        repo_id: repo.id,
        name: "origin",
        url: "https://github.com/user/repo.git"
      })
      assert cs.valid?
    end

    test "validates url format — SSH", %{repo: repo} do
      cs = RepoRemote.changeset(%RepoRemote{}, %{
        repo_id: repo.id,
        name: "origin",
        url: "git@github.com:user/repo.git"
      })
      assert cs.valid?
    end

    test "rejects invalid url", %{repo: repo} do
      cs = RepoRemote.changeset(%RepoRemote{}, %{
        repo_id: repo.id,
        name: "origin",
        url: "not a url"
      })
      assert %{url: [_]} = errors_on(cs)
    end

    test "validates name uniqueness within repo", %{repo: repo} do
      {:ok, _} =
        %RepoRemote{}
        |> RepoRemote.changeset(%{repo_id: repo.id, name: "origin", url: "https://a.com/r.git"})
        |> Repo.insert()

      {:error, cs} =
        %RepoRemote{}
        |> RepoRemote.changeset(%{repo_id: repo.id, name: "origin", url: "https://b.com/r.git"})
        |> Repo.insert()

      assert %{name: ["has already been taken"]} = errors_on(cs)
    end

    test "defaults is_primary to false", %{repo: repo} do
      cs = RepoRemote.changeset(%RepoRemote{}, %{
        repo_id: repo.id,
        name: "origin",
        url: "https://a.com/r.git"
      })
      assert Ecto.Changeset.get_field(cs, :is_primary) == false
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix test apps/synapsis_data/test/synapsis/repo_remote_test.exs --trace'`

- [ ] **Step 3: Implement RepoRemote schema**

```elixir
# apps/synapsis_data/lib/synapsis/repo_remote.ex
defmodule Synapsis.RepoRemote do
  @moduledoc "Git remote for a repository."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @url_format ~r/^(https?:\/\/.+|git@.+:.+)$/

  schema "repo_remotes" do
    field :name, :string
    field :url, :string
    field :push_url, :string
    field :is_primary, :boolean, default: false

    belongs_to :repo, Synapsis.RepoRecord

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(remote, attrs) do
    remote
    |> cast(attrs, [:repo_id, :name, :url, :push_url, :is_primary])
    |> validate_required([:repo_id, :name, :url])
    |> validate_format(:url, @url_format, message: "must be HTTPS or SSH git URL")
    |> foreign_key_constraint(:repo_id)
    |> unique_constraint([:repo_id, :name])
  end
end
```

- [ ] **Step 4: Run tests, verify pass, commit**

```bash
git add apps/synapsis_data/lib/synapsis/repo_remote.ex apps/synapsis_data/test/synapsis/repo_remote_test.exs
git commit -m "feat(data): add RepoRemote schema"
```

### Task 8: RepoWorktree schema

**Files:**
- Create: `apps/synapsis_data/lib/synapsis/repo_worktree.ex`
- Test: `apps/synapsis_data/test/synapsis/repo_worktree_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# apps/synapsis_data/test/synapsis/repo_worktree_test.exs
defmodule Synapsis.RepoWorktreeTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{RepoWorktree, RepoRecord, Project}

  setup do
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{name: "wt-proj", path: "/tmp/wt", slug: "wt"})
      |> Repo.insert()

    {:ok, repo} =
      %RepoRecord{}
      |> RepoRecord.changeset(%{project_id: project.id, name: "wt-repo", bare_path: "/tmp/wt/bare"})
      |> Repo.insert()

    %{repo: repo}
  end

  describe "changeset/2" do
    test "valid with repo_id, branch, local_path", %{repo: repo} do
      cs = RepoWorktree.changeset(%RepoWorktree{}, %{
        repo_id: repo.id,
        branch: "feature/auth",
        local_path: "/tmp/worktrees/abc"
      })
      assert cs.valid?
    end

    test "requires repo_id, branch, local_path" do
      cs = RepoWorktree.changeset(%RepoWorktree{}, %{})
      errors = errors_on(cs)
      assert Map.has_key?(errors, :repo_id)
      assert Map.has_key?(errors, :branch)
      assert Map.has_key?(errors, :local_path)
    end

    test "defaults status to active", %{repo: repo} do
      cs = RepoWorktree.changeset(%RepoWorktree{}, %{
        repo_id: repo.id,
        branch: "feat/x",
        local_path: "/tmp/wt/x"
      })
      assert Ecto.Changeset.get_field(cs, :status) == :active
    end

    test "validates status enum", %{repo: repo} do
      cs = RepoWorktree.changeset(%RepoWorktree{}, %{
        repo_id: repo.id,
        branch: "feat/x",
        local_path: "/tmp/wt/x",
        status: :invalid
      })
      assert %{status: [_]} = errors_on(cs)
    end

    test "validates branch uniqueness within repo for active worktrees", %{repo: repo} do
      {:ok, _} =
        %RepoWorktree{}
        |> RepoWorktree.changeset(%{repo_id: repo.id, branch: "feat/dup", local_path: "/tmp/wt/1"})
        |> Repo.insert()

      {:error, cs} =
        %RepoWorktree{}
        |> RepoWorktree.changeset(%{repo_id: repo.id, branch: "feat/dup", local_path: "/tmp/wt/2"})
        |> Repo.insert()

      assert %{branch: ["has already been taken"]} = errors_on(cs)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix test apps/synapsis_data/test/synapsis/repo_worktree_test.exs --trace'`

- [ ] **Step 3: Implement RepoWorktree schema**

```elixir
# apps/synapsis_data/lib/synapsis/repo_worktree.ex
defmodule Synapsis.RepoWorktree do
  @moduledoc "Git worktree — an isolated checkout for a Build Agent."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "repo_worktrees" do
    field :branch, :string
    field :base_branch, :string
    field :local_path, :string
    field :status, Ecto.Enum, values: [:active, :completed, :failed, :cleaning], default: :active
    field :agent_session_id, :string
    field :task_id, :string
    field :metadata, :map, default: %{}
    field :completed_at, :utc_datetime_usec
    field :cleaned_at, :utc_datetime_usec

    belongs_to :repo, Synapsis.RepoRecord

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(worktree, attrs) do
    worktree
    |> cast(attrs, [
      :repo_id, :branch, :base_branch, :local_path, :status,
      :agent_session_id, :task_id, :metadata, :completed_at, :cleaned_at
    ])
    |> validate_required([:repo_id, :branch, :local_path])
    |> foreign_key_constraint(:repo_id)
    |> unique_constraint([:repo_id, :branch],
         name: :repo_worktrees_repo_id_branch_active_index)
  end
end
```

- [ ] **Step 4: Run tests, verify pass, commit**

```bash
git add apps/synapsis_data/lib/synapsis/repo_worktree.ex apps/synapsis_data/test/synapsis/repo_worktree_test.exs
git commit -m "feat(data): add RepoWorktree schema"
```

### Task 9: Projects context

**Files:**
- Create: `apps/synapsis_data/lib/synapsis/projects.ex`
- Test: `apps/synapsis_data/test/synapsis/projects_context_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# apps/synapsis_data/test/synapsis/projects_context_test.exs
defmodule Synapsis.ProjectsContextTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.Projects

  @valid_attrs %{name: "ctx-proj", path: "/tmp/ctx", slug: "ctx-proj"}

  describe "create/1" do
    test "creates project with valid attrs" do
      assert {:ok, project} = Projects.create(@valid_attrs)
      assert project.name == "ctx-proj"
      assert project.status == :active
    end

    test "rejects duplicate name" do
      {:ok, _} = Projects.create(@valid_attrs)
      assert {:error, _cs} = Projects.create(%{@valid_attrs | path: "/tmp/ctx2", slug: "ctx2"})
    end
  end

  describe "get/1" do
    test "returns project by id" do
      {:ok, project} = Projects.create(@valid_attrs)
      assert Projects.get(project.id).id == project.id
    end

    test "returns nil for missing id" do
      assert Projects.get(Ecto.UUID.generate()) == nil
    end
  end

  describe "update/2" do
    test "updates description" do
      {:ok, project} = Projects.create(@valid_attrs)
      {:ok, updated} = Projects.update(project, %{description: "Hello"})
      assert updated.description == "Hello"
    end
  end

  describe "list/1" do
    test "returns active projects by default" do
      {:ok, _active} = Projects.create(@valid_attrs)
      {:ok, archived} = Projects.create(%{name: "arch", path: "/tmp/arch", slug: "arch"})
      {:ok, _} = Projects.archive(archived)

      results = Projects.list()
      assert length(results) == 1
      assert hd(results).name == "ctx-proj"
    end

    test "includes archived with option" do
      {:ok, _} = Projects.create(@valid_attrs)
      {:ok, archived} = Projects.create(%{name: "arch2", path: "/tmp/arch2", slug: "arch2"})
      {:ok, _} = Projects.archive(archived)

      results = Projects.list(include_archived: true)
      assert length(results) == 2
    end
  end

  describe "archive/1" do
    test "transitions active to archived" do
      {:ok, project} = Projects.create(@valid_attrs)
      assert {:ok, archived} = Projects.archive(project)
      assert archived.status == :archived
    end

    test "rejects already archived" do
      {:ok, project} = Projects.create(@valid_attrs)
      {:ok, archived} = Projects.archive(project)
      assert {:error, _} = Projects.archive(archived)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix test apps/synapsis_data/test/synapsis/projects_context_test.exs --trace'`

- [ ] **Step 3: Implement Projects context**

```elixir
# apps/synapsis_data/lib/synapsis/projects.ex
defmodule Synapsis.Projects do
  @moduledoc "Context for project CRUD operations."
  import Ecto.Query
  alias Synapsis.{Project, Repo}

  @spec create(map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  @spec get(binary()) :: Project.t() | nil
  def get(id), do: Repo.get(Project, id)

  @spec get!(binary()) :: Project.t()
  def get!(id), do: Repo.get!(Project, id)

  @spec update(Project.t(), map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def update(project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  @spec list(keyword()) :: [Project.t()]
  def list(opts \\ []) do
    query = from(p in Project, order_by: [desc: p.updated_at])

    query =
      if Keyword.get(opts, :include_archived, false) do
        query
      else
        from(p in query, where: p.status != :archived)
      end

    Repo.all(query)
  end

  @spec archive(Project.t()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def archive(%Project{status: :archived}),
    do: {:error, Ecto.Changeset.change(%Project{}, %{}) |> Ecto.Changeset.add_error(:status, "already archived")}

  def archive(%Project{} = project) do
    project
    |> Ecto.Changeset.change(%{status: :archived})
    |> Repo.update()
  end
end
```

- [ ] **Step 4: Run tests, verify pass, commit**

```bash
git add apps/synapsis_data/lib/synapsis/projects.ex apps/synapsis_data/test/synapsis/projects_context_test.exs
git commit -m "feat(data): add Projects context"
```

### Task 10: Repos context

**Files:**
- Create: `apps/synapsis_data/lib/synapsis/repos.ex`
- Test: `apps/synapsis_data/test/synapsis/repos_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# apps/synapsis_data/test/synapsis/repos_test.exs
defmodule Synapsis.ReposTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{Repos, Projects, RepoRecord, RepoWorktree}

  setup do
    {:ok, project} = Projects.create(%{name: "repos-proj", path: "/tmp/rp", slug: "rp"})
    %{project: project}
  end

  describe "create/2" do
    test "creates repo for project", %{project: project} do
      assert {:ok, repo} = Repos.create(project.id, %{name: "my-repo", bare_path: "/tmp/rp/bare"})
      assert repo.name == "my-repo"
      assert repo.project_id == project.id
    end

    test "rejects duplicate name within project", %{project: project} do
      {:ok, _} = Repos.create(project.id, %{name: "dup-repo", bare_path: "/tmp/a"})
      assert {:error, _} = Repos.create(project.id, %{name: "dup-repo", bare_path: "/tmp/b"})
    end

    test "allows same name in different projects", %{project: project} do
      {:ok, project2} = Projects.create(%{name: "other-proj", path: "/tmp/other", slug: "other"})
      {:ok, _} = Repos.create(project.id, %{name: "same-name", bare_path: "/tmp/a"})
      assert {:ok, _} = Repos.create(project2.id, %{name: "same-name", bare_path: "/tmp/b"})
    end
  end

  describe "list_for_project/1" do
    test "returns repos for project", %{project: project} do
      {:ok, _} = Repos.create(project.id, %{name: "r1", bare_path: "/tmp/r1"})
      {:ok, _} = Repos.create(project.id, %{name: "r2", bare_path: "/tmp/r2"})
      assert length(Repos.list_for_project(project.id)) == 2
    end
  end

  describe "add_remote/2" do
    test "adds remote to repo", %{project: project} do
      {:ok, repo} = Repos.create(project.id, %{name: "rmt-repo", bare_path: "/tmp/rmt"})
      assert {:ok, remote} = Repos.add_remote(repo.id, %{name: "origin", url: "https://gh.com/r.git"})
      assert remote.name == "origin"
    end

    test "rejects duplicate remote name", %{project: project} do
      {:ok, repo} = Repos.create(project.id, %{name: "rmt-dup", bare_path: "/tmp/rmt-dup"})
      {:ok, _} = Repos.add_remote(repo.id, %{name: "origin", url: "https://a.com/r.git"})
      assert {:error, _} = Repos.add_remote(repo.id, %{name: "origin", url: "https://b.com/r.git"})
    end

    test "validates URL format", %{project: project} do
      {:ok, repo} = Repos.create(project.id, %{name: "rmt-url", bare_path: "/tmp/rmt-url"})
      assert {:error, _} = Repos.add_remote(repo.id, %{name: "origin", url: "not-a-url"})
    end
  end

  describe "set_primary_remote/1" do
    test "sets primary and clears previous", %{project: project} do
      {:ok, repo} = Repos.create(project.id, %{name: "pri-repo", bare_path: "/tmp/pri"})
      {:ok, r1} = Repos.add_remote(repo.id, %{name: "origin", url: "https://a.com/r.git", is_primary: true})
      {:ok, r2} = Repos.add_remote(repo.id, %{name: "upstream", url: "https://b.com/r.git"})

      assert {:ok, updated_r2} = Repos.set_primary_remote(r2.id)
      assert updated_r2.is_primary == true

      refreshed_r1 = Synapsis.Repo.get!(Synapsis.RepoRemote, r1.id)
      assert refreshed_r1.is_primary == false
    end
  end

  describe "archive/1" do
    test "archives repo with no active worktrees", %{project: project} do
      {:ok, repo} = Repos.create(project.id, %{name: "arch-repo", bare_path: "/tmp/arch"})
      assert {:ok, archived} = Repos.archive(repo)
      assert archived.status == :archived
    end

    test "fails if active worktrees exist", %{project: project} do
      {:ok, repo} = Repos.create(project.id, %{name: "wt-repo", bare_path: "/tmp/wt"})
      {:ok, _wt} =
        %RepoWorktree{}
        |> RepoWorktree.changeset(%{repo_id: repo.id, branch: "feat/x", local_path: "/tmp/wt/x"})
        |> Synapsis.Repo.insert()

      assert {:error, :active_worktrees_exist} = Repos.archive(repo)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement Repos context**

```elixir
# apps/synapsis_data/lib/synapsis/repos.ex
defmodule Synapsis.Repos do
  @moduledoc "Context for repository CRUD and remote management."
  import Ecto.Query
  alias Synapsis.{Repo, RepoRecord, RepoRemote, RepoWorktree}

  @spec create(binary(), map()) :: {:ok, RepoRecord.t()} | {:error, Ecto.Changeset.t()}
  def create(project_id, attrs) do
    %RepoRecord{}
    |> RepoRecord.changeset(Map.put(attrs, :project_id, project_id))
    |> Repo.insert()
  end

  @spec get(binary()) :: RepoRecord.t() | nil
  def get(id), do: Repo.get(RepoRecord, id)

  @spec get_with_remotes(binary()) :: RepoRecord.t() | nil
  def get_with_remotes(id) do
    RepoRecord
    |> Repo.get(id)
    |> Repo.preload(:remotes)
  end

  @spec list_for_project(binary()) :: [RepoRecord.t()]
  def list_for_project(project_id) do
    from(r in RepoRecord,
      where: r.project_id == ^project_id and r.status == :active,
      order_by: [asc: r.name]
    )
    |> Repo.all()
  end

  @spec add_remote(binary(), map()) :: {:ok, RepoRemote.t()} | {:error, Ecto.Changeset.t()}
  def add_remote(repo_id, attrs) do
    %RepoRemote{}
    |> RepoRemote.changeset(Map.put(attrs, :repo_id, repo_id))
    |> Repo.insert()
  end

  @spec remove_remote(binary()) :: {:ok, RepoRemote.t()} | {:error, term()}
  def remove_remote(remote_id) do
    case Repo.get(RepoRemote, remote_id) do
      nil -> {:error, :not_found}
      remote -> Repo.delete(remote)
    end
  end

  @spec set_primary_remote(binary()) :: {:ok, RepoRemote.t()} | {:error, term()}
  def set_primary_remote(remote_id) do
    Repo.transaction(fn ->
      remote = Repo.get!(RepoRemote, remote_id)

      # Clear all primaries for this repo
      from(r in RepoRemote, where: r.repo_id == ^remote.repo_id and r.is_primary == true)
      |> Repo.update_all(set: [is_primary: false])

      # Set this one as primary
      remote
      |> Ecto.Changeset.change(%{is_primary: true})
      |> Repo.update!()
    end)
  end

  @spec archive(RepoRecord.t()) :: {:ok, RepoRecord.t()} | {:error, term()}
  def archive(%RepoRecord{} = repo) do
    active_count =
      from(w in RepoWorktree, where: w.repo_id == ^repo.id and w.status == :active)
      |> Repo.aggregate(:count)

    if active_count > 0 do
      {:error, :active_worktrees_exist}
    else
      repo
      |> Ecto.Changeset.change(%{status: :archived})
      |> Repo.update()
    end
  end
end
```

- [ ] **Step 4: Run tests, verify pass, commit**

```bash
git add apps/synapsis_data/lib/synapsis/repos.ex apps/synapsis_data/test/synapsis/repos_test.exs
git commit -m "feat(data): add Repos context"
```

### Task 11: Worktrees context

**Files:**
- Create: `apps/synapsis_data/lib/synapsis/worktrees.ex`
- Test: `apps/synapsis_data/test/synapsis/worktrees_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# apps/synapsis_data/test/synapsis/worktrees_test.exs
defmodule Synapsis.WorktreesTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{Worktrees, Projects, Repos}

  setup do
    {:ok, project} = Projects.create(%{name: "wt-ctx", path: "/tmp/wt-ctx", slug: "wt-ctx"})
    {:ok, repo} = Repos.create(project.id, %{name: "wt-repo", bare_path: "/tmp/wt-ctx/bare"})
    %{project: project, repo: repo}
  end

  describe "create/2" do
    test "creates worktree for repo", %{repo: repo} do
      assert {:ok, wt} = Worktrees.create(repo.id, %{branch: "feat/a", local_path: "/tmp/wt/a"})
      assert wt.status == :active
      assert wt.repo_id == repo.id
    end

    test "rejects duplicate branch within repo", %{repo: repo} do
      {:ok, _} = Worktrees.create(repo.id, %{branch: "feat/dup", local_path: "/tmp/wt/1"})
      assert {:error, _} = Worktrees.create(repo.id, %{branch: "feat/dup", local_path: "/tmp/wt/2"})
    end
  end

  describe "mark_completed/1" do
    test "transitions active to completed", %{repo: repo} do
      {:ok, wt} = Worktrees.create(repo.id, %{branch: "feat/comp", local_path: "/tmp/wt/c"})
      assert {:ok, completed} = Worktrees.mark_completed(wt)
      assert completed.status == :completed
      assert completed.completed_at != nil
    end

    test "rejects non-active", %{repo: repo} do
      {:ok, wt} = Worktrees.create(repo.id, %{branch: "feat/done", local_path: "/tmp/wt/d"})
      {:ok, completed} = Worktrees.mark_completed(wt)
      assert {:error, _} = Worktrees.mark_completed(completed)
    end
  end

  describe "mark_failed/1" do
    test "transitions active to failed", %{repo: repo} do
      {:ok, wt} = Worktrees.create(repo.id, %{branch: "feat/fail", local_path: "/tmp/wt/f"})
      assert {:ok, failed} = Worktrees.mark_failed(wt)
      assert failed.status == :failed
      assert failed.completed_at != nil
    end
  end

  describe "assign_agent/2" do
    test "sets agent_session_id", %{repo: repo} do
      {:ok, wt} = Worktrees.create(repo.id, %{branch: "feat/agent", local_path: "/tmp/wt/ag"})
      assert {:ok, assigned} = Worktrees.assign_agent(wt, "session-123")
      assert assigned.agent_session_id == "session-123"
    end

    test "allows reassignment for retry", %{repo: repo} do
      {:ok, wt} = Worktrees.create(repo.id, %{branch: "feat/retry", local_path: "/tmp/wt/rt"})
      {:ok, assigned} = Worktrees.assign_agent(wt, "session-1")
      assert {:ok, reassigned} = Worktrees.assign_agent(assigned, "session-2")
      assert reassigned.agent_session_id == "session-2"
    end
  end

  describe "list_active_for_repo/1" do
    test "returns only active worktrees", %{repo: repo} do
      {:ok, _} = Worktrees.create(repo.id, %{branch: "feat/1", local_path: "/tmp/wt/1"})
      {:ok, wt2} = Worktrees.create(repo.id, %{branch: "feat/2", local_path: "/tmp/wt/2"})
      {:ok, _} = Worktrees.mark_completed(wt2)

      active = Worktrees.list_active_for_repo(repo.id)
      assert length(active) == 1
    end
  end

  describe "stale/1" do
    test "returns completed worktrees older than threshold", %{repo: repo} do
      {:ok, wt} = Worktrees.create(repo.id, %{branch: "feat/stale", local_path: "/tmp/wt/s"})
      # Manually set completed_at in the past
      past = DateTime.add(DateTime.utc_now(), -25 * 3600, :second)
      {:ok, _} =
        wt
        |> Ecto.Changeset.change(%{status: :completed, completed_at: past})
        |> Synapsis.Repo.update()

      stale = Worktrees.stale(24)
      assert length(stale) == 1
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement Worktrees context**

```elixir
# apps/synapsis_data/lib/synapsis/worktrees.ex
defmodule Synapsis.Worktrees do
  @moduledoc "Context for worktree lifecycle management."
  import Ecto.Query
  alias Synapsis.{Repo, RepoWorktree}

  @spec create(binary(), map()) :: {:ok, RepoWorktree.t()} | {:error, Ecto.Changeset.t()}
  def create(repo_id, attrs) do
    %RepoWorktree{}
    |> RepoWorktree.changeset(Map.put(attrs, :repo_id, repo_id))
    |> Repo.insert()
  end

  @spec get(binary()) :: RepoWorktree.t() | nil
  def get(id), do: Repo.get(RepoWorktree, id)

  @spec list_active_for_repo(binary()) :: [RepoWorktree.t()]
  def list_active_for_repo(repo_id) do
    from(w in RepoWorktree,
      where: w.repo_id == ^repo_id and w.status == :active,
      order_by: [desc: w.inserted_at]
    )
    |> Repo.all()
  end

  @spec list_active_for_project(binary()) :: [RepoWorktree.t()]
  def list_active_for_project(project_id) do
    from(w in RepoWorktree,
      join: r in assoc(w, :repo),
      where: r.project_id == ^project_id and w.status == :active,
      order_by: [desc: w.inserted_at]
    )
    |> Repo.all()
  end

  @spec mark_completed(RepoWorktree.t()) :: {:ok, RepoWorktree.t()} | {:error, Ecto.Changeset.t()}
  def mark_completed(%RepoWorktree{status: :active} = wt) do
    wt
    |> Ecto.Changeset.change(%{status: :completed, completed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def mark_completed(_wt),
    do: {:error, Ecto.Changeset.change(%RepoWorktree{}, %{}) |> Ecto.Changeset.add_error(:status, "must be active")}

  @spec mark_failed(RepoWorktree.t()) :: {:ok, RepoWorktree.t()} | {:error, Ecto.Changeset.t()}
  def mark_failed(%RepoWorktree{status: :active} = wt) do
    wt
    |> Ecto.Changeset.change(%{status: :failed, completed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def mark_failed(_wt),
    do: {:error, Ecto.Changeset.change(%RepoWorktree{}, %{}) |> Ecto.Changeset.add_error(:status, "must be active")}

  @spec mark_cleaning(RepoWorktree.t()) :: {:ok, RepoWorktree.t()} | {:error, Ecto.Changeset.t()}
  def mark_cleaning(%RepoWorktree{status: status} = wt) when status in [:completed, :failed] do
    wt
    |> Ecto.Changeset.change(%{status: :cleaning})
    |> Repo.update()
  end

  @spec mark_cleaned(RepoWorktree.t()) :: {:ok, RepoWorktree.t()} | {:error, Ecto.Changeset.t()}
  def mark_cleaned(%RepoWorktree{status: :cleaning} = wt) do
    wt
    |> Ecto.Changeset.change(%{cleaned_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @spec assign_agent(RepoWorktree.t(), String.t()) :: {:ok, RepoWorktree.t()} | {:error, Ecto.Changeset.t()}
  def assign_agent(%RepoWorktree{} = wt, session_id) do
    wt
    |> Ecto.Changeset.change(%{agent_session_id: session_id})
    |> Repo.update()
  end

  @spec stale(pos_integer()) :: [RepoWorktree.t()]
  def stale(age_hours) do
    cutoff = DateTime.add(DateTime.utc_now(), -age_hours * 3600, :second)

    from(w in RepoWorktree,
      where: w.status in [:completed, :failed] and w.completed_at < ^cutoff
    )
    |> Repo.all()
  end
end
```

- [ ] **Step 4: Run tests, verify pass, commit**

```bash
git add apps/synapsis_data/lib/synapsis/worktrees.ex apps/synapsis_data/test/synapsis/worktrees_test.exs
git commit -m "feat(data): add Worktrees context"
```

### Task 12: Phase 1 verification

- [ ] **Step 1: Run full data app test suite**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix test apps/synapsis_data --trace'`
Expected: All tests pass.

- [ ] **Step 2: Compile with warnings as errors**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix compile --warnings-as-errors'`
Expected: Zero warnings, zero errors.

- [ ] **Step 3: Format check**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix format --check-formatted'`
Expected: No formatting issues.

---

## Phase 2: Git Operations

### Task 13: Git Runner (shared command execution)

**Files:**
- Create: `apps/synapsis_core/lib/synapsis/git/runner.ex`
- Test: `apps/synapsis_core/test/synapsis/git/runner_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
# apps/synapsis_core/test/synapsis/git/runner_test.exs
defmodule Synapsis.Git.RunnerTest do
  use ExUnit.Case, async: true

  alias Synapsis.Git.Runner

  describe "run/2" do
    test "runs git command and returns stdout on success" do
      assert {:ok, output} = Runner.run(System.tmp_dir!(), ["--version"])
      assert String.starts_with?(output, "git version")
    end

    test "returns error tuple on failure" do
      assert {:error, msg} = Runner.run("/nonexistent", ["status"])
      assert is_binary(msg)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix test apps/synapsis_core/test/synapsis/git/runner_test.exs --trace'`

- [ ] **Step 3: Implement Runner**

```elixir
# apps/synapsis_core/lib/synapsis/git/runner.ex
defmodule Synapsis.Git.Runner do
  @moduledoc "Shared Port-based git command execution."

  @default_timeout 30_000

  @spec run(String.t(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(cwd, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case System.find_executable("git") do
      nil ->
        {:error, "git executable not found"}

      git_path ->
        port =
          Port.open({:spawn_executable, git_path}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args,
            cd: cwd
          ])

        collect_output(port, "", timeout)
    end
  rescue
    e in [RuntimeError, ArgumentError, ErlangError] ->
      {:error, "git error: #{Exception.message(e)}"}
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data, timeout)

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, code}} ->
        {:error, "git exited with #{code}: #{acc}"}
    after
      timeout ->
        Port.close(port)
        {:error, "git command timed out after #{timeout}ms"}
    end
  end
end
```

- [ ] **Step 4: Run test, verify pass, commit**

```bash
git add apps/synapsis_core/lib/synapsis/git/runner.ex apps/synapsis_core/test/synapsis/git/runner_test.exs
git commit -m "feat(core): add Git.Runner for shared git command execution"
```

### Task 14: Git.RepoOps (clone, remote, fetch)

**Files:**
- Create: `apps/synapsis_core/lib/synapsis/git/repo_ops.ex`
- Test: `apps/synapsis_core/test/synapsis/git/repo_ops_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# apps/synapsis_core/test/synapsis/git/repo_ops_test.exs
defmodule Synapsis.Git.RepoOpsTest do
  use ExUnit.Case, async: true

  alias Synapsis.Git.RepoOps

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Create a source repo to clone from
    source = Path.join(tmp_dir, "source")
    File.mkdir_p!(source)
    System.cmd("git", ["init", source])
    System.cmd("git", ["-C", source, "config", "user.email", "test@test.com"])
    System.cmd("git", ["-C", source, "config", "user.name", "Test"])
    File.write!(Path.join(source, "README.md"), "# Test")
    System.cmd("git", ["-C", source, "add", "."])
    System.cmd("git", ["-C", source, "commit", "-m", "init"])

    %{source: source, tmp_dir: tmp_dir}
  end

  describe "clone_bare/2" do
    test "clones a local repo as bare", %{source: source, tmp_dir: tmp_dir} do
      bare = Path.join(tmp_dir, "bare.git")
      assert :ok = RepoOps.clone_bare(source, bare)
      assert File.exists?(Path.join(bare, "HEAD"))
    end

    test "creates parent directories", %{source: source, tmp_dir: tmp_dir} do
      bare = Path.join([tmp_dir, "nested", "deep", "bare.git"])
      assert :ok = RepoOps.clone_bare(source, bare)
      assert File.exists?(bare)
    end

    test "returns error for invalid URL", %{tmp_dir: tmp_dir} do
      bare = Path.join(tmp_dir, "fail.git")
      assert {:error, _} = RepoOps.clone_bare("/nonexistent/repo", bare)
    end
  end

  describe "add_remote/3" do
    test "adds named remote", %{source: source, tmp_dir: tmp_dir} do
      bare = Path.join(tmp_dir, "r-bare.git")
      :ok = RepoOps.clone_bare(source, bare)
      assert :ok = RepoOps.add_remote(bare, "upstream", source)
    end

    test "returns error for duplicate name", %{source: source, tmp_dir: tmp_dir} do
      bare = Path.join(tmp_dir, "r-dup.git")
      :ok = RepoOps.clone_bare(source, bare)
      assert {:error, _} = RepoOps.add_remote(bare, "origin", source)
    end
  end

  describe "fetch_all/1" do
    test "fetches from all remotes", %{source: source, tmp_dir: tmp_dir} do
      bare = Path.join(tmp_dir, "f-bare.git")
      :ok = RepoOps.clone_bare(source, bare)
      assert :ok = RepoOps.fetch_all(bare)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement RepoOps**

```elixir
# apps/synapsis_core/lib/synapsis/git/repo_ops.ex
defmodule Synapsis.Git.RepoOps do
  @moduledoc "Git bare clone and remote management operations."

  alias Synapsis.Git.Runner

  @spec clone_bare(String.t(), String.t()) :: :ok | {:error, String.t()}
  def clone_bare(url, bare_path) do
    File.mkdir_p!(Path.dirname(bare_path))

    case Runner.run(Path.dirname(bare_path), ["clone", "--bare", url, bare_path]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec add_remote(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def add_remote(bare_path, name, url) do
    case Runner.run(bare_path, ["remote", "add", name, url]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec remove_remote(String.t(), String.t()) :: :ok | {:error, String.t()}
  def remove_remote(bare_path, name) do
    case Runner.run(bare_path, ["remote", "remove", name]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec set_push_url(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def set_push_url(bare_path, remote, url) do
    case Runner.run(bare_path, ["remote", "set-url", "--push", remote, url]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec fetch_all(String.t()) :: :ok | {:error, String.t()}
  def fetch_all(bare_path) do
    case Runner.run(bare_path, ["fetch", "--all", "--prune"]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec fetch_remote(String.t(), String.t()) :: :ok | {:error, String.t()}
  def fetch_remote(bare_path, remote) do
    case Runner.run(bare_path, ["fetch", remote]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end
end
```

- [ ] **Step 4: Run tests, verify pass, commit**

```bash
git add apps/synapsis_core/lib/synapsis/git/repo_ops.ex apps/synapsis_core/test/synapsis/git/repo_ops_test.exs
git commit -m "feat(core): add Git.RepoOps for bare clone and remote management"
```

### Task 15: Git.Branch

**Files:**
- Create: `apps/synapsis_core/lib/synapsis/git/branch.ex`
- Test: `apps/synapsis_core/test/synapsis/git/branch_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# apps/synapsis_core/test/synapsis/git/branch_test.exs
defmodule Synapsis.Git.BranchTest do
  use ExUnit.Case, async: true

  alias Synapsis.Git.{Branch, RepoOps}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source")
    File.mkdir_p!(source)
    System.cmd("git", ["init", source])
    System.cmd("git", ["-C", source, "config", "user.email", "test@test.com"])
    System.cmd("git", ["-C", source, "config", "user.name", "Test"])
    File.write!(Path.join(source, "README.md"), "# Test")
    System.cmd("git", ["-C", source, "add", "."])
    System.cmd("git", ["-C", source, "commit", "-m", "init"])

    bare = Path.join(tmp_dir, "bare.git")
    :ok = RepoOps.clone_bare(source, bare)

    %{bare: bare}
  end

  describe "create/3" do
    test "creates branch from base", %{bare: bare} do
      assert :ok = Branch.create(bare, "feature/new", "main")
    end

    test "returns error if branch exists", %{bare: bare} do
      :ok = Branch.create(bare, "feat/dup", "main")
      assert {:error, _} = Branch.create(bare, "feat/dup", "main")
    end

    test "returns error if base does not exist", %{bare: bare} do
      assert {:error, _} = Branch.create(bare, "feat/bad", "nonexistent")
    end
  end

  describe "list/1" do
    test "returns all local branches", %{bare: bare} do
      :ok = Branch.create(bare, "feat/a", "main")
      assert {:ok, branches} = Branch.list(bare)
      assert "main" in branches
      assert "feat/a" in branches
    end
  end

  describe "exists?/2" do
    test "true for existing branch", %{bare: bare} do
      assert Branch.exists?(bare, "main")
    end

    test "false for nonexistent", %{bare: bare} do
      refute Branch.exists?(bare, "nonexistent")
    end
  end

  describe "delete/3" do
    test "deletes branch with force", %{bare: bare} do
      :ok = Branch.create(bare, "feat/del", "main")
      assert :ok = Branch.delete(bare, "feat/del", true)
      refute Branch.exists?(bare, "feat/del")
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement Branch**

```elixir
# apps/synapsis_core/lib/synapsis/git/branch.ex
defmodule Synapsis.Git.Branch do
  @moduledoc "Git branch operations on bare repositories."

  alias Synapsis.Git.Runner

  @spec create(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def create(bare_path, name, base) do
    case Runner.run(bare_path, ["branch", name, base]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec delete(String.t(), String.t(), boolean()) :: :ok | {:error, String.t()}
  def delete(bare_path, name, force \\ false) do
    flag = if force, do: "-D", else: "-d"

    case Runner.run(bare_path, ["branch", flag, name]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec list(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def list(bare_path) do
    case Runner.run(bare_path, ["branch", "--format=%(refname:short)"]) do
      {:ok, output} ->
        branches =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)

        {:ok, branches}

      {:error, _} = err ->
        err
    end
  end

  @spec exists?(String.t(), String.t()) :: boolean()
  def exists?(bare_path, name) do
    case Runner.run(bare_path, ["rev-parse", "--verify", "refs/heads/#{name}"]) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
end
```

- [ ] **Step 4: Run tests, verify pass, commit**

```bash
git add apps/synapsis_core/lib/synapsis/git/branch.ex apps/synapsis_core/test/synapsis/git/branch_test.exs
git commit -m "feat(core): add Git.Branch operations"
```

### Task 16: Git.Worktree (new module, distinct from existing GitWorktree)

**Files:**
- Create: `apps/synapsis_core/lib/synapsis/git/worktree.ex`
- Test: `apps/synapsis_core/test/synapsis/git/worktree_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# apps/synapsis_core/test/synapsis/git/worktree_test.exs
defmodule Synapsis.Git.WorktreeTest do
  use ExUnit.Case, async: true

  alias Synapsis.Git.{Worktree, Branch, RepoOps}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source")
    File.mkdir_p!(source)
    System.cmd("git", ["init", source])
    System.cmd("git", ["-C", source, "config", "user.email", "test@test.com"])
    System.cmd("git", ["-C", source, "config", "user.name", "Test"])
    File.write!(Path.join(source, "README.md"), "# Test")
    System.cmd("git", ["-C", source, "add", "."])
    System.cmd("git", ["-C", source, "commit", "-m", "init"])

    bare = Path.join(tmp_dir, "bare.git")
    :ok = RepoOps.clone_bare(source, bare)

    %{bare: bare, tmp_dir: tmp_dir}
  end

  describe "create/3" do
    test "creates worktree from branch", %{bare: bare, tmp_dir: tmp_dir} do
      :ok = Branch.create(bare, "feat/wt", "main")
      wt_path = Path.join(tmp_dir, "wt-1")
      assert :ok = Worktree.create(bare, wt_path, "feat/wt")
      assert File.exists?(Path.join(wt_path, "README.md"))
    end

    test "creates parent directories", %{bare: bare, tmp_dir: tmp_dir} do
      :ok = Branch.create(bare, "feat/deep", "main")
      wt_path = Path.join([tmp_dir, "nested", "deep", "wt"])
      assert :ok = Worktree.create(bare, wt_path, "feat/deep")
    end
  end

  describe "list/1" do
    test "returns worktree entries", %{bare: bare, tmp_dir: tmp_dir} do
      :ok = Branch.create(bare, "feat/list", "main")
      wt_path = Path.join(tmp_dir, "wt-list")
      :ok = Worktree.create(bare, wt_path, "feat/list")

      assert {:ok, entries} = Worktree.list(bare)
      paths = Enum.map(entries, & &1.path)
      assert wt_path in paths
    end
  end

  describe "remove/2" do
    test "removes worktree", %{bare: bare, tmp_dir: tmp_dir} do
      :ok = Branch.create(bare, "feat/rm", "main")
      wt_path = Path.join(tmp_dir, "wt-rm")
      :ok = Worktree.create(bare, wt_path, "feat/rm")

      assert :ok = Worktree.remove(bare, wt_path)
      refute File.exists?(wt_path)
    end
  end

  describe "prune/1" do
    test "prunes stale worktree references", %{bare: bare} do
      assert :ok = Worktree.prune(bare)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement Worktree**

```elixir
# apps/synapsis_core/lib/synapsis/git/worktree.ex
defmodule Synapsis.Git.Worktree do
  @moduledoc "Git worktree operations on bare repositories."

  alias Synapsis.Git.Runner

  @spec create(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def create(bare_path, worktree_path, branch) do
    File.mkdir_p!(Path.dirname(worktree_path))

    case Runner.run(bare_path, ["worktree", "add", worktree_path, branch]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec remove(String.t(), String.t()) :: :ok | {:error, String.t()}
  def remove(bare_path, worktree_path) do
    case Runner.run(bare_path, ["worktree", "remove", worktree_path, "--force"]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec list(String.t()) :: {:ok, [%{path: String.t(), branch: String.t(), head: String.t()}]} | {:error, String.t()}
  def list(bare_path) do
    case Runner.run(bare_path, ["worktree", "list", "--porcelain"]) do
      {:ok, output} -> {:ok, parse_porcelain(output)}
      {:error, _} = err -> err
    end
  end

  @spec prune(String.t()) :: :ok | {:error, String.t()}
  def prune(bare_path) do
    case Runner.run(bare_path, ["worktree", "prune"]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp parse_porcelain(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.map(&parse_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_entry(entry) do
    lines = String.split(entry, "\n", trim: true)

    result =
      Enum.reduce(lines, %{}, fn line, acc ->
        case String.split(line, " ", parts: 2) do
          ["worktree", path] -> Map.put(acc, :path, path)
          ["HEAD", sha] -> Map.put(acc, :head, sha)
          ["branch", ref] -> Map.put(acc, :branch, String.replace_prefix(ref, "refs/heads/", ""))
          ["detached"] -> Map.put(acc, :branch, "(detached)")
          ["bare"] -> Map.put(acc, :bare, true)
          _ -> acc
        end
      end)

    if Map.has_key?(result, :path), do: result, else: nil
  end
end
```

- [ ] **Step 4: Run tests, verify pass, commit**

```bash
git add apps/synapsis_core/lib/synapsis/git/worktree.ex apps/synapsis_core/test/synapsis/git/worktree_test.exs
git commit -m "feat(core): add Git.Worktree operations"
```

### Task 17: Git.Log, Git.Diff, Git.Status

**Files:**
- Create: `apps/synapsis_core/lib/synapsis/git/log.ex`
- Create: `apps/synapsis_core/lib/synapsis/git/diff.ex`
- Create: `apps/synapsis_core/lib/synapsis/git/status.ex`
- Test: `apps/synapsis_core/test/synapsis/git/query_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# apps/synapsis_core/test/synapsis/git/query_test.exs
defmodule Synapsis.Git.QueryTest do
  use ExUnit.Case, async: true

  alias Synapsis.Git.{Log, Diff, Status, RepoOps, Branch, Worktree}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source")
    File.mkdir_p!(source)
    System.cmd("git", ["init", source])
    System.cmd("git", ["-C", source, "config", "user.email", "test@test.com"])
    System.cmd("git", ["-C", source, "config", "user.name", "Test"])
    File.write!(Path.join(source, "README.md"), "# Test")
    System.cmd("git", ["-C", source, "add", "."])
    System.cmd("git", ["-C", source, "commit", "-m", "initial commit"])

    bare = Path.join(tmp_dir, "bare.git")
    :ok = RepoOps.clone_bare(source, bare)
    :ok = Branch.create(bare, "feat/work", "main")

    wt_path = Path.join(tmp_dir, "wt")
    :ok = Worktree.create(bare, wt_path, "feat/work")

    # Make a change in the worktree
    File.write!(Path.join(wt_path, "new.txt"), "hello")
    System.cmd("git", ["-C", wt_path, "add", "."])
    System.cmd("git", ["-C", wt_path, "config", "user.email", "test@test.com"])
    System.cmd("git", ["-C", wt_path, "config", "user.name", "Test"])
    System.cmd("git", ["-C", wt_path, "commit", "-m", "add new file"])

    # Also add an uncommitted file
    File.write!(Path.join(wt_path, "uncommitted.txt"), "wip")

    %{bare: bare, wt_path: wt_path}
  end

  describe "Log.recent/2" do
    test "returns recent commits", %{wt_path: wt_path} do
      assert {:ok, commits} = Log.recent(wt_path)
      assert length(commits) >= 1
      assert hd(commits).subject == "add new file"
      assert is_binary(hd(commits).hash)
      assert is_binary(hd(commits).author)
    end

    test "respects limit option", %{wt_path: wt_path} do
      assert {:ok, commits} = Log.recent(wt_path, limit: 1)
      assert length(commits) == 1
    end
  end

  describe "Diff.from_base/2" do
    test "returns diff from base branch", %{wt_path: wt_path} do
      assert {:ok, diff_text} = Diff.from_base(wt_path, "main")
      assert String.contains?(diff_text, "new.txt")
    end
  end

  describe "Diff.stat/2" do
    test "returns diff statistics", %{wt_path: wt_path} do
      assert {:ok, stat} = Diff.stat(wt_path, "main")
      assert stat.files_changed >= 1
      assert stat.insertions >= 1
    end
  end

  describe "Status.summary/1" do
    test "returns working tree status", %{wt_path: wt_path} do
      assert {:ok, summary} = Status.summary(wt_path)
      assert summary.untracked >= 1
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement Log, Diff, Status**

```elixir
# apps/synapsis_core/lib/synapsis/git/log.ex
defmodule Synapsis.Git.Log do
  @moduledoc "Git log queries."

  alias Synapsis.Git.Runner

  @spec recent(String.t(), keyword()) ::
          {:ok, [%{hash: String.t(), subject: String.t(), author: String.t(), date: String.t()}]}
          | {:error, String.t()}
  def recent(path, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    branch_args = case Keyword.get(opts, :branch) do
      nil -> []
      b -> [b]
    end

    args = ["log", "--format=%H\t%s\t%an\t%aI", "-n", "#{limit}"] ++ branch_args

    case Runner.run(path, args) do
      {:ok, output} ->
        commits =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case String.split(line, "\t", parts: 4) do
              [hash, subject, author, date] ->
                %{hash: hash, subject: subject, author: author, date: date}
              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, commits}

      {:error, _} = err ->
        err
    end
  end
end
```

```elixir
# apps/synapsis_core/lib/synapsis/git/diff.ex
defmodule Synapsis.Git.Diff do
  @moduledoc "Git diff operations."

  alias Synapsis.Git.Runner

  @spec from_base(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def from_base(worktree_path, base_branch) do
    Runner.run(worktree_path, ["diff", "#{base_branch}...HEAD"])
  end

  @spec stat(String.t(), String.t()) ::
          {:ok, %{files_changed: integer(), insertions: integer(), deletions: integer()}}
          | {:error, String.t()}
  def stat(worktree_path, base_branch) do
    case Runner.run(worktree_path, ["diff", "--numstat", "#{base_branch}...HEAD"]) do
      {:ok, output} ->
        lines = String.split(output, "\n", trim: true)

        {ins, del} =
          Enum.reduce(lines, {0, 0}, fn line, {ins_acc, del_acc} ->
            case String.split(line, "\t", parts: 3) do
              [i, d, _file] ->
                {ins_acc + parse_int(i), del_acc + parse_int(d)}
              _ ->
                {ins_acc, del_acc}
            end
          end)

        {:ok, %{files_changed: length(lines), insertions: ins, deletions: del}}

      {:error, _} = err ->
        err
    end
  end

  defp parse_int("-"), do: 0
  defp parse_int(s), do: String.to_integer(s)
end
```

```elixir
# apps/synapsis_core/lib/synapsis/git/status.ex
defmodule Synapsis.Git.Status do
  @moduledoc "Git working tree status."

  alias Synapsis.Git.Runner

  @spec summary(String.t()) ::
          {:ok, %{staged: integer(), modified: integer(), untracked: integer()}}
          | {:error, String.t()}
  def summary(worktree_path) do
    case Runner.run(worktree_path, ["status", "--porcelain"]) do
      {:ok, output} ->
        lines = String.split(output, "\n", trim: true)

        counts =
          Enum.reduce(lines, %{staged: 0, modified: 0, untracked: 0}, fn line, acc ->
            case String.at(line, 0) do
              "?" -> %{acc | untracked: acc.untracked + 1}
              " " -> %{acc | modified: acc.modified + 1}
              _ ->
                # First char is index status (staged), second is worktree
                case String.at(line, 1) do
                  " " -> %{acc | staged: acc.staged + 1}
                  _ -> %{acc | staged: acc.staged + 1, modified: acc.modified + 1}
                end
            end
          end)

        {:ok, counts}

      {:error, _} = err ->
        err
    end
  end
end
```

- [ ] **Step 4: Run tests, verify pass, commit**

```bash
git add apps/synapsis_core/lib/synapsis/git/log.ex apps/synapsis_core/lib/synapsis/git/diff.ex apps/synapsis_core/lib/synapsis/git/status.ex apps/synapsis_core/test/synapsis/git/query_test.exs
git commit -m "feat(core): add Git.Log, Git.Diff, Git.Status query modules"
```

### Task 18: Phase 2 verification

- [ ] **Step 1: Run all git tests**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix test apps/synapsis_core/test/synapsis/git/ --trace'`
Expected: All pass.

- [ ] **Step 2: Compile + format check**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix compile --warnings-as-errors && mix format --check-formatted'`

---

## Phase 3: Board + DevLog + Workspace

### Task 19: Add yaml_elixir dependency

**Files:**
- Modify: `apps/synapsis_core/mix.exs`

- [ ] **Step 1: Add yaml_elixir to deps**

Add `{:yaml_elixir, "~> 2.11"}` to the `deps` function in `apps/synapsis_core/mix.exs`.

- [ ] **Step 2: Fetch deps**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix deps.get'`

- [ ] **Step 3: Commit**

```bash
git add apps/synapsis_core/mix.exs mix.lock
git commit -m "chore(core): add yaml_elixir dependency"
```

### Task 20: Board module (pure functions)

**Files:**
- Create: `apps/synapsis_core/lib/synapsis/board.ex`
- Test: `apps/synapsis_core/test/synapsis/board_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# apps/synapsis_core/test/synapsis/board_test.exs
defmodule Synapsis.BoardTest do
  use ExUnit.Case, async: true

  alias Synapsis.Board

  @empty_board_yaml """
  version: 1
  columns:
    - id: backlog
      name: Backlog
    - id: ready
      name: Ready
    - id: in_progress
      name: "In Progress"
    - id: review
      name: Review
    - id: done
      name: Done
  cards: []
  """

  describe "parse/1" do
    test "parses valid board YAML" do
      assert {:ok, board} = Board.parse(@empty_board_yaml)
      assert board.version == 1
      assert length(board.columns) == 5
      assert board.cards == []
    end

    test "returns error for invalid YAML" do
      assert {:error, _} = Board.parse("not: [valid: yaml: {")
    end
  end

  describe "serialize/1" do
    test "round-trips through parse and serialize" do
      {:ok, board} = Board.parse(@empty_board_yaml)
      yaml = Board.serialize(board)
      assert {:ok, reparsed} = Board.parse(yaml)
      assert reparsed.version == board.version
      assert length(reparsed.columns) == length(board.columns)
    end
  end

  describe "add_card/2" do
    test "adds a card to the board" do
      {:ok, board} = Board.parse(@empty_board_yaml)
      {:ok, updated} = Board.add_card(board, %{title: "Do thing", description: "Details"})
      assert length(updated.cards) == 1
      card = hd(updated.cards)
      assert card.title == "Do thing"
      assert card.column == "backlog"
      assert is_binary(card.id)
    end
  end

  describe "move_card/3" do
    test "moves card to valid column" do
      {:ok, board} = Board.parse(@empty_board_yaml)
      {:ok, board} = Board.add_card(board, %{title: "Task"})
      card_id = hd(board.cards).id

      assert {:ok, board} = Board.move_card(board, card_id, "ready")
      assert Board.get_card(board, card_id).column == "ready"
    end

    test "rejects invalid transition" do
      {:ok, board} = Board.parse(@empty_board_yaml)
      {:ok, board} = Board.add_card(board, %{title: "Task"})
      card_id = hd(board.cards).id

      # backlog -> review is not a valid transition
      assert {:error, :invalid_transition} = Board.move_card(board, card_id, "review")
    end
  end

  describe "update_card/3" do
    test "updates card fields" do
      {:ok, board} = Board.parse(@empty_board_yaml)
      {:ok, board} = Board.add_card(board, %{title: "Old"})
      card_id = hd(board.cards).id

      assert {:ok, board} = Board.update_card(board, card_id, %{title: "New"})
      assert Board.get_card(board, card_id).title == "New"
    end

    test "returns error for missing card" do
      {:ok, board} = Board.parse(@empty_board_yaml)
      assert {:error, :not_found} = Board.update_card(board, "nonexistent", %{title: "X"})
    end
  end

  describe "remove_card/2" do
    test "removes card" do
      {:ok, board} = Board.parse(@empty_board_yaml)
      {:ok, board} = Board.add_card(board, %{title: "Task"})
      card_id = hd(board.cards).id

      assert {:ok, board} = Board.remove_card(board, card_id)
      assert board.cards == []
    end
  end

  describe "cards_by_column/2" do
    test "filters cards by column" do
      {:ok, board} = Board.parse(@empty_board_yaml)
      {:ok, board} = Board.add_card(board, %{title: "A"})
      {:ok, board} = Board.add_card(board, %{title: "B"})
      card_id = hd(board.cards).id
      {:ok, board} = Board.move_card(board, card_id, "ready")

      assert length(Board.cards_by_column(board, "backlog")) == 1
      assert length(Board.cards_by_column(board, "ready")) == 1
    end
  end

  describe "validate_transition/2" do
    test "backlog -> ready is valid" do
      assert Board.validate_transition("backlog", "ready")
    end

    test "backlog -> done is valid (skip/cancel)" do
      assert Board.validate_transition("backlog", "done")
    end

    test "backlog -> review is invalid" do
      refute Board.validate_transition("backlog", "review")
    end

    test "in_progress -> review is valid" do
      assert Board.validate_transition("in_progress", "review")
    end

    test "done -> anything is invalid" do
      refute Board.validate_transition("done", "backlog")
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement Board module**

```elixir
# apps/synapsis_core/lib/synapsis/board.ex
defmodule Synapsis.Board do
  @moduledoc "Kanban board parse, serialize, and mutation — pure functions over YAML."

  @valid_transitions %{
    "backlog" => ["ready", "done"],
    "ready" => ["in_progress", "backlog"],
    "in_progress" => ["review", "ready", "failed"],
    "review" => ["done", "in_progress"],
    "failed" => ["backlog", "done"]
  }

  @type card :: %{
          id: String.t(),
          title: String.t(),
          description: String.t(),
          column: String.t(),
          repo_id: String.t() | nil,
          branch: String.t() | nil,
          worktree_id: String.t() | nil,
          agent_session_id: String.t() | nil,
          plan_ref: String.t() | nil,
          design_refs: [String.t()],
          priority: integer(),
          labels: [String.t()],
          created_at: String.t(),
          updated_at: String.t()
        }

  @type board :: %{
          version: integer(),
          columns: [%{id: String.t(), name: String.t()}],
          cards: [card()]
        }

  @spec parse(String.t()) :: {:ok, board()} | {:error, term()}
  def parse(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, data} ->
        board = %{
          version: data["version"] || 1,
          columns:
            Enum.map(data["columns"] || [], fn c ->
              %{id: c["id"], name: c["name"]}
            end),
          cards:
            Enum.map(data["cards"] || [], fn c ->
              %{
                id: c["id"],
                title: c["title"] || "",
                description: c["description"] || "",
                column: c["column"] || "backlog",
                repo_id: c["repo_id"],
                branch: c["branch"],
                worktree_id: c["worktree_id"],
                agent_session_id: c["agent_session_id"],
                plan_ref: c["plan_ref"],
                design_refs: c["design_refs"] || [],
                priority: c["priority"] || 0,
                labels: c["labels"] || [],
                created_at: c["created_at"] || "",
                updated_at: c["updated_at"] || ""
              }
            end)
        }

        {:ok, board}

      {:error, _} = err ->
        err
    end
  end

  @spec serialize(board()) :: String.t()
  def serialize(board) do
    data = %{
      "version" => board.version,
      "columns" => Enum.map(board.columns, fn c -> %{"id" => c.id, "name" => c.name} end),
      "cards" =>
        Enum.map(board.cards, fn c ->
          %{
            "id" => c.id,
            "title" => c.title,
            "description" => c.description,
            "column" => c.column,
            "repo_id" => c.repo_id,
            "branch" => c.branch,
            "worktree_id" => c.worktree_id,
            "agent_session_id" => c.agent_session_id,
            "plan_ref" => c.plan_ref,
            "design_refs" => c.design_refs,
            "priority" => c.priority,
            "labels" => c.labels,
            "created_at" => c.created_at,
            "updated_at" => c.updated_at
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()
        end)
    }

    YamlElixir.Sigil.yaml_encode(data)
  rescue
    _ -> Jason.encode!(data, pretty: true)
  end

  @spec add_card(board(), map()) :: {:ok, board()}
  def add_card(board, attrs) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    card = %{
      id: Ecto.UUID.generate(),
      title: Map.get(attrs, :title, ""),
      description: Map.get(attrs, :description, ""),
      column: Map.get(attrs, :column, "backlog"),
      repo_id: Map.get(attrs, :repo_id),
      branch: Map.get(attrs, :branch),
      worktree_id: Map.get(attrs, :worktree_id),
      agent_session_id: Map.get(attrs, :agent_session_id),
      plan_ref: Map.get(attrs, :plan_ref),
      design_refs: Map.get(attrs, :design_refs, []),
      priority: Map.get(attrs, :priority, 0),
      labels: Map.get(attrs, :labels, []),
      created_at: now,
      updated_at: now
    }

    {:ok, %{board | cards: [card | board.cards]}}
  end

  @spec move_card(board(), String.t(), String.t()) :: {:ok, board()} | {:error, :invalid_transition | :not_found}
  def move_card(board, card_id, target_column) do
    case get_card(board, card_id) do
      nil ->
        {:error, :not_found}

      card ->
        if validate_transition(card.column, target_column) do
          now = DateTime.utc_now() |> DateTime.to_iso8601()

          cards =
            Enum.map(board.cards, fn c ->
              if c.id == card_id, do: %{c | column: target_column, updated_at: now}, else: c
            end)

          {:ok, %{board | cards: cards}}
        else
          {:error, :invalid_transition}
        end
    end
  end

  @spec update_card(board(), String.t(), map()) :: {:ok, board()} | {:error, :not_found}
  def update_card(board, card_id, attrs) do
    case get_card(board, card_id) do
      nil ->
        {:error, :not_found}

      _card ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        cards =
          Enum.map(board.cards, fn c ->
            if c.id == card_id do
              attrs
              |> Enum.reduce(c, fn {k, v}, acc -> Map.put(acc, k, v) end)
              |> Map.put(:updated_at, now)
            else
              c
            end
          end)

        {:ok, %{board | cards: cards}}
    end
  end

  @spec remove_card(board(), String.t()) :: {:ok, board()}
  def remove_card(board, card_id) do
    {:ok, %{board | cards: Enum.reject(board.cards, &(&1.id == card_id))}}
  end

  @spec get_card(board(), String.t()) :: card() | nil
  def get_card(board, card_id) do
    Enum.find(board.cards, &(&1.id == card_id))
  end

  @spec cards_by_column(board(), String.t()) :: [card()]
  def cards_by_column(board, column) do
    Enum.filter(board.cards, &(&1.column == column))
  end

  @spec validate_transition(String.t(), String.t()) :: boolean()
  def validate_transition(from, to) do
    to in Map.get(@valid_transitions, from, [])
  end
end
```

- [ ] **Step 4: Run tests, verify pass, commit**

```bash
git add apps/synapsis_core/lib/synapsis/board.ex apps/synapsis_core/test/synapsis/board_test.exs
git commit -m "feat(core): add Board module for kanban YAML operations"
```

### Task 21: DevLog module (pure functions)

**Files:**
- Create: `apps/synapsis_core/lib/synapsis/dev_log.ex`
- Test: `apps/synapsis_core/test/synapsis/dev_log_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# apps/synapsis_core/test/synapsis/dev_log_test.exs
defmodule Synapsis.DevLogTest do
  use ExUnit.Case, async: true

  alias Synapsis.DevLog

  @initial_content "# Dev Log\n"

  describe "append/2" do
    test "appends entry under date heading" do
      entry = %{
        timestamp: ~U[2026-04-04 10:30:00Z],
        category: "progress",
        author: "assistant",
        content: "Implemented board module."
      }

      result = DevLog.append(@initial_content, entry)
      assert String.contains?(result, "2026-04-04")
      assert String.contains?(result, "10:30 — progress [assistant]")
      assert String.contains?(result, "Implemented board module.")
    end

    test "appends under existing date heading" do
      entry1 = %{timestamp: ~U[2026-04-04 10:00:00Z], category: "progress", author: "assistant", content: "First"}
      entry2 = %{timestamp: ~U[2026-04-04 11:00:00Z], category: "decision", author: "user", content: "Second"}

      result =
        @initial_content
        |> DevLog.append(entry1)
        |> DevLog.append(entry2)

      # Only one date heading
      assert length(Regex.scan(~r/## 2026-04-04/, result)) == 1
      assert String.contains?(result, "First")
      assert String.contains?(result, "Second")
    end
  end

  describe "parse/1" do
    test "parses entries from content" do
      content = """
      # Dev Log

      ## 2026-04-04

      ### 10:30 — progress [assistant]
      Did a thing.

      ### 11:00 — decision [user]
      Made a choice.
      """

      entries = DevLog.parse(content)
      assert length(entries) == 2
      assert hd(entries).category == "progress"
      assert List.last(entries).category == "decision"
    end
  end

  describe "recent/2" do
    test "returns last N entries" do
      content = """
      # Dev Log

      ## 2026-04-04

      ### 10:00 — progress [assistant]
      One.

      ### 11:00 — progress [assistant]
      Two.

      ### 12:00 — progress [assistant]
      Three.
      """

      entries = DevLog.recent(content, 2)
      assert length(entries) == 2
      assert hd(entries).content =~ "Two"
    end
  end

  describe "filter/2" do
    test "filters by category" do
      content = """
      # Dev Log

      ## 2026-04-04

      ### 10:00 — progress [assistant]
      One.

      ### 11:00 — decision [user]
      Two.
      """

      entries = DevLog.filter(content, category: "decision")
      assert length(entries) == 1
      assert hd(entries).content =~ "Two"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement DevLog**

```elixir
# apps/synapsis_core/lib/synapsis/dev_log.ex
defmodule Synapsis.DevLog do
  @moduledoc "Append-only dev log parse and append — pure functions over Markdown."

  @type entry :: %{
          timestamp: DateTime.t(),
          category: String.t(),
          author: String.t(),
          content: String.t()
        }

  @valid_categories ~w(decision progress blocker insight error completion user-note)

  @spec append(String.t(), entry()) :: String.t()
  def append(content, entry) do
    date_str = Calendar.strftime(entry.timestamp, "%Y-%m-%d")
    time_str = Calendar.strftime(entry.timestamp, "%H:%M")
    heading = "## #{date_str}"
    entry_text = "### #{time_str} — #{entry.category} [#{entry.author}]\n#{entry.content}\n"

    if String.contains?(content, heading) do
      # Append under existing date heading
      String.replace(content, heading, "#{heading}\n\n#{entry_text}", global: false)
    else
      # Add new date heading at the end
      "#{String.trim_trailing(content)}\n\n#{heading}\n\n#{entry_text}"
    end
  end

  @spec parse(String.t()) :: [entry()]
  def parse(content) do
    # Match entries: ### HH:MM — category [author]\ncontent
    ~r/### (\d{2}:\d{2}) — (\w[\w-]*) \[([^\]]+)\]\n([\s\S]*?)(?=\n### |\n## |\z)/
    |> Regex.scan(content)
    |> Enum.map(fn [_, time, category, author, body] ->
      %{
        timestamp: parse_timestamp(content, time),
        category: category,
        author: author,
        content: String.trim(body)
      }
    end)
  end

  @spec recent(String.t(), pos_integer()) :: [entry()]
  def recent(content, count) do
    content
    |> parse()
    |> Enum.take(-count)
  end

  @spec filter(String.t(), keyword()) :: [entry()]
  def filter(content, opts) do
    entries = parse(content)
    category = Keyword.get(opts, :category)
    author = Keyword.get(opts, :author)

    entries
    |> then(fn es -> if category, do: Enum.filter(es, &(&1.category == category)), else: es end)
    |> then(fn es -> if author, do: Enum.filter(es, &(&1.author == author)), else: es end)
  end

  @doc false
  def valid_categories, do: @valid_categories

  # Find the date heading above this time entry
  defp parse_timestamp(content, time) do
    # Find the nearest ## YYYY-MM-DD before this time
    dates = Regex.scan(~r/## (\d{4}-\d{2}-\d{2})/, content)
    date_str = case dates do
      [] -> "2000-01-01"
      _ -> List.last(dates) |> List.last()
    end

    case DateTime.from_iso8601("#{date_str}T#{time}:00Z") do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
end
```

- [ ] **Step 4: Run tests, verify pass, commit**

```bash
git add apps/synapsis_core/lib/synapsis/dev_log.ex apps/synapsis_core/test/synapsis/dev_log_test.exs
git commit -m "feat(core): add DevLog module for markdown append/parse"
```

### Task 22: PathResolver updates + Workspace seeding

**Files:**
- Modify: `apps/synapsis_workspace/lib/synapsis/workspace/path_resolver.ex`
- Create: `apps/synapsis_workspace/lib/synapsis/workspace/seeding.ex`
- Test: `apps/synapsis_workspace/test/synapsis/workspace/path_resolver_additions_test.exs`
- Test: `apps/synapsis_workspace/test/synapsis/workspace/seeding_test.exs`

- [ ] **Step 1: Write failing tests for PathResolver additions**

```elixir
# apps/synapsis_workspace/test/synapsis/workspace/path_resolver_additions_test.exs
defmodule Synapsis.Workspace.PathResolverAdditionsTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workspace.PathResolver

  describe "derive_kind/1 new patterns" do
    test "board.yaml → :board" do
      assert PathResolver.derive_kind(["board.yaml"]) == :board
    end

    test "plans/** → :plan" do
      assert PathResolver.derive_kind(["plans", "auth-prd.md"]) == :plan
    end

    test "design/** → :design_doc" do
      assert PathResolver.derive_kind(["design", "adr-001.md"]) == :design_doc
    end

    test "logs/devlog.md → :devlog" do
      assert PathResolver.derive_kind(["logs", "devlog.md"]) == :devlog
    end

    test "repos/*/config.yaml → :repo_config" do
      assert PathResolver.derive_kind(["repos", "abc-123", "config.yaml"]) == :repo_config
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Update PathResolver.derive_kind/1**

Add new pattern matches to `derive_kind/1` in `path_resolver.ex`:

```elixir
def derive_kind(segments) do
  case segments do
    ["board.yaml"] -> :board
    ["plans" | _] -> :plan
    ["design" | _] -> :design_doc
    ["logs", "devlog.md"] -> :devlog
    ["repos", _repo_id, "config.yaml"] -> :repo_config
    ["attachments" | _] -> :attachment
    ["handoffs" | _] -> :handoff
    ["scratch" | _] -> :session_scratch
    _ -> :document
  end
end
```

- [ ] **Step 4: Run tests, verify pass**

- [ ] **Step 5: Write Seeding module and test**

```elixir
# apps/synapsis_workspace/lib/synapsis/workspace/seeding.ex
defmodule Synapsis.Workspace.Seeding do
  @moduledoc "Seed conventional workspace documents for a new project."

  alias Synapsis.Workspace

  @default_board """
  version: 1
  columns:
    - id: backlog
      name: Backlog
    - id: ready
      name: Ready
    - id: in_progress
      name: "In Progress"
    - id: review
      name: Review
    - id: done
      name: Done
  cards: []
  """

  @spec seed_project(binary()) :: :ok
  def seed_project(project_id) do
    board_path = "/projects/#{project_id}/board.yaml"
    devlog_path = "/projects/#{project_id}/logs/devlog.md"

    now = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M")
    devlog_content = "# Dev Log\n\n## #{DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d")}\n\n### #{DateTime.utc_now() |> Calendar.strftime("%H:%M")} — progress [system]\nProject created.\n"

    # Idempotent: only write if not exists
    unless workspace_exists?(board_path) do
      Workspace.write(board_path, @default_board, author: "system", content_format: :yaml)
    end

    unless workspace_exists?(devlog_path) do
      Workspace.write(devlog_path, devlog_content, author: "system", content_format: :markdown)
    end

    :ok
  end

  defp workspace_exists?(path) do
    case Workspace.exists?(path) do
      true -> true
      false -> false
    end
  end
end
```

- [ ] **Step 6: Commit**

```bash
git add apps/synapsis_workspace/lib/synapsis/workspace/path_resolver.ex apps/synapsis_workspace/lib/synapsis/workspace/seeding.ex apps/synapsis_workspace/test/synapsis/workspace/path_resolver_additions_test.exs
git commit -m "feat(workspace): add new path kinds and project seeding"
```

### Task 23: Phase 3 verification

- [ ] **Step 1: Run workspace + core tests**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix test apps/synapsis_core apps/synapsis_workspace --trace'`

- [ ] **Step 2: Compile + format**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix compile --warnings-as-errors && mix format --check-formatted'`

---

## Phase 4: Workflow Tools

### Task 24: Add :workflow category + register tools

**Files:**
- Modify: `apps/synapsis_core/lib/synapsis/tool.ex` — add `:workflow` to category type
- Modify: `apps/synapsis_core/lib/synapsis/tool/builtin.ex` — register 12 new tools

- [ ] **Step 1: Add `:workflow` to category type in tool.ex**

In the `@type category` definition, add `| :workflow` to the union.

- [ ] **Step 2: Register tools in builtin.ex**

Add the 12 new tool modules to the registration list in `Synapsis.Tool.Builtin`.

- [ ] **Step 3: Commit**

```bash
git add apps/synapsis_core/lib/synapsis/tool.ex apps/synapsis_core/lib/synapsis/tool/builtin.ex
git commit -m "feat(tool): add :workflow category, register 12 workflow tools"
```

### Task 25: BoardRead + BoardUpdate tools

**Files:**
- Create: `apps/synapsis_core/lib/synapsis/tool/board_read.ex`
- Create: `apps/synapsis_core/lib/synapsis/tool/board_update.ex`
- Test: `apps/synapsis_core/test/synapsis/tool/board_tools_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# apps/synapsis_core/test/synapsis/tool/board_tools_test.exs
defmodule Synapsis.Tool.BoardToolsTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Tool.{BoardRead, BoardUpdate}

  # These tests need a workspace with a board document
  # The context needs a project_id to locate the board
  setup do
    {:ok, project} =
      Synapsis.Projects.create(%{name: "board-test", path: "/tmp/bt", slug: "bt"})

    Synapsis.Workspace.Seeding.seed_project(project.id)
    ctx = %{project_id: project.id, session_id: "test-session"}

    %{ctx: ctx, project: project}
  end

  describe "BoardRead" do
    test "name returns board_read" do
      assert BoardRead.name() == "board_read"
    end

    test "reads empty board", %{ctx: ctx} do
      assert {:ok, result} = BoardRead.execute(%{}, ctx)
      assert is_binary(result)
      assert String.contains?(result, "cards") or String.contains?(result, "[]")
    end
  end

  describe "BoardUpdate" do
    test "creates a card", %{ctx: ctx} do
      input = %{
        "action" => "create_card",
        "card" => %{"title" => "First task", "description" => "Do it"}
      }
      assert {:ok, result} = BoardUpdate.execute(input, ctx)
      assert String.contains?(result, "First task")
    end

    test "moves a card", %{ctx: ctx} do
      # Create first
      {:ok, _} = BoardUpdate.execute(%{
        "action" => "create_card",
        "card" => %{"title" => "Move me"}
      }, ctx)

      # Read to get card_id
      {:ok, board_json} = BoardRead.execute(%{}, ctx)
      # Parse the card_id from the result (JSON)
      {:ok, data} = Jason.decode(board_json)
      card_id = hd(data["cards"])["id"]

      assert {:ok, _} = BoardUpdate.execute(%{
        "action" => "move_card",
        "card_id" => card_id,
        "column" => "ready"
      }, ctx)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement BoardRead**

```elixir
# apps/synapsis_core/lib/synapsis/tool/board_read.ex
defmodule Synapsis.Tool.BoardRead do
  @moduledoc "Read the current kanban board state for the active project."
  use Synapsis.Tool

  @impl true
  def name, do: "board_read"

  @impl true
  def description, do: "Read the current kanban board state for the active project. Returns all columns and cards, or filtered by column, repo, or label."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "column" => %{"type" => "string", "description" => "Filter cards by column"},
        "repo_id" => %{"type" => "string", "description" => "Filter cards by target repo"},
        "label" => %{"type" => "string", "description" => "Filter cards by label"}
      },
      "required" => []
    }
  end

  @impl true
  def category, do: :workflow

  @impl true
  def permission_level, do: :none

  @impl true
  def execute(input, context) do
    project_id = context[:project_id]

    if is_nil(project_id) do
      {:error, "No active project. Select a project first."}
    else
      board_path = "/projects/#{project_id}/board.yaml"

      case Synapsis.Workspace.read(board_path) do
        {:ok, resource} ->
          case Synapsis.Board.parse(resource.content) do
            {:ok, board} ->
              cards = apply_filters(board.cards, input)
              result = %{columns: board.columns, cards: cards}
              {:ok, Jason.encode!(result)}

            {:error, reason} ->
              {:error, "Failed to parse board: #{inspect(reason)}"}
          end

        {:error, :not_found} ->
          {:ok, Jason.encode!(%{columns: [], cards: []})}
      end
    end
  end

  defp apply_filters(cards, input) do
    cards
    |> maybe_filter(:column, input["column"])
    |> maybe_filter(:repo_id, input["repo_id"])
    |> maybe_filter_label(input["label"])
  end

  defp maybe_filter(cards, _field, nil), do: cards
  defp maybe_filter(cards, field, value), do: Enum.filter(cards, &(Map.get(&1, field) == value))

  defp maybe_filter_label(cards, nil), do: cards
  defp maybe_filter_label(cards, label), do: Enum.filter(cards, &(label in (&1.labels || [])))
end
```

- [ ] **Step 4: Implement BoardUpdate**

```elixir
# apps/synapsis_core/lib/synapsis/tool/board_update.ex
defmodule Synapsis.Tool.BoardUpdate do
  @moduledoc "Modify the kanban board: create, move, update, or remove cards."
  use Synapsis.Tool

  @impl true
  def name, do: "board_update"

  @impl true
  def description, do: "Modify the kanban board. Supports: create card, move card, update card fields, remove card."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ["create_card", "move_card", "update_card", "remove_card"]},
        "card" => %{"type" => "object", "description" => "Card fields for create"},
        "card_id" => %{"type" => "string", "description" => "Card ID for move/update/remove"},
        "column" => %{"type" => "string", "description" => "Target column for move"},
        "fields" => %{"type" => "object", "description" => "Fields to update"}
      },
      "required" => ["action"]
    }
  end

  @impl true
  def category, do: :workflow

  @impl true
  def permission_level, do: :none

  @impl true
  def side_effects, do: [:workspace_changed, :board_changed]

  @impl true
  def execute(input, context) do
    project_id = context[:project_id]

    if is_nil(project_id) do
      {:error, "No active project."}
    else
      board_path = "/projects/#{project_id}/board.yaml"

      with {:ok, resource} <- Synapsis.Workspace.read(board_path),
           {:ok, board} <- Synapsis.Board.parse(resource.content),
           {:ok, updated_board} <- dispatch_action(board, input),
           yaml = Synapsis.Board.serialize(updated_board),
           {:ok, _} <- Synapsis.Workspace.write(board_path, yaml, author: "assistant", content_format: :yaml) do
        # Broadcast board change
        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "project:#{project_id}:board",
          {:board_changed, %{action: input["action"]}}
        )

        {:ok, Jason.encode!(%{ok: true, action: input["action"], cards: updated_board.cards})}
      else
        {:error, reason} -> {:error, "Board update failed: #{inspect(reason)}"}
      end
    end
  end

  defp dispatch_action(board, %{"action" => "create_card", "card" => card_attrs}) do
    attrs =
      card_attrs
      |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
      |> Map.new()

    Synapsis.Board.add_card(board, attrs)
  rescue
    ArgumentError -> Synapsis.Board.add_card(board, %{title: card_attrs["title"] || "", description: card_attrs["description"] || ""})
  end

  defp dispatch_action(board, %{"action" => "move_card", "card_id" => id, "column" => col}) do
    Synapsis.Board.move_card(board, id, col)
  end

  defp dispatch_action(board, %{"action" => "update_card", "card_id" => id, "fields" => fields}) do
    attrs =
      fields
      |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
      |> Map.new()

    Synapsis.Board.update_card(board, id, attrs)
  rescue
    ArgumentError -> {:error, "invalid field names"}
  end

  defp dispatch_action(board, %{"action" => "remove_card", "card_id" => id}) do
    Synapsis.Board.remove_card(board, id)
  end

  defp dispatch_action(_board, _), do: {:error, "invalid action or missing parameters"}
end
```

- [ ] **Step 5: Run tests, verify pass, commit**

```bash
git add apps/synapsis_core/lib/synapsis/tool/board_read.ex apps/synapsis_core/lib/synapsis/tool/board_update.ex apps/synapsis_core/test/synapsis/tool/board_tools_test.exs
git commit -m "feat(tool): add board_read and board_update workflow tools"
```

### Task 26: DevlogRead + DevlogWrite tools

**Files:**
- Create: `apps/synapsis_core/lib/synapsis/tool/devlog_read.ex`
- Create: `apps/synapsis_core/lib/synapsis/tool/devlog_write.ex`
- Test: `apps/synapsis_core/test/synapsis/tool/devlog_tools_test.exs`

Implementation follows the same pattern as board tools. Each tool:
- Uses `Synapsis.Tool` behaviour
- Category: `:workflow`, permission: `:none`
- Reads/writes workspace at `/projects/<project_id>/logs/devlog.md`
- DevlogWrite calls `Synapsis.DevLog.append/2`
- DevlogRead calls `Synapsis.DevLog.recent/2` or `filter/2`

- [ ] **Step 1: Write failing tests**
- [ ] **Step 2: Implement DevlogRead and DevlogWrite**
- [ ] **Step 3: Run tests, verify pass, commit**

### Task 27: RepoLink, RepoSync, RepoStatus tools

**Files:**
- Create: `apps/synapsis_core/lib/synapsis/tool/repo_link.ex`
- Create: `apps/synapsis_core/lib/synapsis/tool/repo_sync.ex`
- Create: `apps/synapsis_core/lib/synapsis/tool/repo_status.ex`
- Test: `apps/synapsis_core/test/synapsis/tool/repo_tools_test.exs`

Each tool follows the `Synapsis.Tool` behaviour. Category: `:workflow`, permission: `:none`.

- `repo_link` — calls `Synapsis.Repos.create/2`, `Synapsis.Git.RepoOps.clone_bare/2`, `add_remote/3`
- `repo_sync` — calls `Synapsis.Git.RepoOps.fetch_all/1`
- `repo_status` — calls `Synapsis.Repos.get_with_remotes/1`, `Synapsis.Git.Branch.list/1`, `Synapsis.Git.Log.recent/2`, `Synapsis.Worktrees.list_active_for_repo/1`

- [ ] **Step 1: Write failing tests**
- [ ] **Step 2: Implement all three**
- [ ] **Step 3: Run tests, verify pass, commit**

### Task 28: WorktreeCreate, WorktreeList, WorktreeRemove tools

**Files:**
- Create: `apps/synapsis_core/lib/synapsis/tool/worktree_create.ex`
- Create: `apps/synapsis_core/lib/synapsis/tool/worktree_list.ex`
- Create: `apps/synapsis_core/lib/synapsis/tool/worktree_remove.ex`
- Test: `apps/synapsis_core/test/synapsis/tool/worktree_tools_test.exs`

Each follows the same pattern. Category: `:workflow`, permission: `:none`.

- `worktree_create` — creates branch if needed, creates worktree, creates DB record
- `worktree_list` — queries `Synapsis.Worktrees.list_active_for_repo/1`
- `worktree_remove` — validates status, removes git worktree, updates DB

- [ ] **Step 1: Write failing tests**
- [ ] **Step 2: Implement all three**
- [ ] **Step 3: Run tests, verify pass, commit**

### Task 29: AgentSpawn + AgentStatus tools (stubs)

**Files:**
- Create: `apps/synapsis_core/lib/synapsis/tool/agent_spawn.ex`
- Create: `apps/synapsis_core/lib/synapsis/tool/agent_status.ex`
- Test: `apps/synapsis_core/test/synapsis/tool/agent_tools_test.exs`

Note: These are **stubs** — they implement the tool interface and parameter validation but return `{:error, "not yet implemented"}` for the actual agent spawning logic, which depends on Phase 5 (Agent Architecture). This lets us register them in the tool registry now.

- [ ] **Step 1: Write tests for tool metadata (name, category, parameters)**
- [ ] **Step 2: Implement stubs**
- [ ] **Step 3: Run tests, verify pass, commit**

### Task 30: Phase 4 verification

- [ ] **Step 1: Run full core test suite**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix test apps/synapsis_core --trace'`

- [ ] **Step 2: Verify all 12 tools register**

Run in IEx:
```elixir
devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix run -e "
  Synapsis.Tool.Registry.start_link([])
  tools = Synapsis.Tool.Registry.list_all()
  workflow = Enum.filter(tools, fn t -> t.category == :workflow end)
  IO.puts(\"Workflow tools: #{length(workflow)}\")
  Enum.each(workflow, fn t -> IO.puts(\"  - #{t.name}\") end)
"'
```
Expected: 12 workflow tools listed.

- [ ] **Step 3: Compile + format**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix compile --warnings-as-errors && mix format --check-formatted'`

---

## Phase 5: Agent Architecture

### Task 31: ToolScoping module

**Files:**
- Create: `apps/synapsis_agent/lib/synapsis/agent/tool_scoping.ex`
- Test: `apps/synapsis_agent/test/synapsis/agent/tool_scoping_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# apps/synapsis_agent/test/synapsis/agent/tool_scoping_test.exs
defmodule Synapsis.Agent.ToolScopingTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.ToolScoping

  describe "categories_for_role/1" do
    test "assistant includes workflow tools" do
      cats = ToolScoping.categories_for_role(:assistant)
      assert :workflow in cats
      refute :filesystem in cats
      refute :execution in cats
    end

    test "build includes filesystem but not workflow" do
      cats = ToolScoping.categories_for_role(:build)
      assert :filesystem in cats
      assert :execution in cats
      refute :workflow in cats
    end
  end
end
```

- [ ] **Step 2: Implement ToolScoping**

```elixir
# apps/synapsis_agent/lib/synapsis/agent/tool_scoping.ex
defmodule Synapsis.Agent.ToolScoping do
  @moduledoc "Role-based tool category filtering."

  @assistant_categories [:workflow, :planning, :interaction, :web, :orchestration, :memory, :workspace, :session]
  @build_categories [:filesystem, :search, :execution, :web, :planning]

  @spec categories_for_role(:assistant | :build) :: [atom()]
  def categories_for_role(:assistant), do: @assistant_categories
  def categories_for_role(:build), do: @build_categories
end
```

- [ ] **Step 3: Run tests, verify pass, commit**

```bash
git add apps/synapsis_agent/lib/synapsis/agent/tool_scoping.ex apps/synapsis_agent/test/synapsis/agent/tool_scoping_test.exs
git commit -m "feat(agent): add ToolScoping for role-based tool filtering"
```

### Task 32: ProjectContextBuilder

**Files:**
- Create: `apps/synapsis_agent/lib/synapsis/agent/project_context_builder.ex`
- Test: `apps/synapsis_agent/test/synapsis/agent/project_context_builder_test.exs`

- [ ] **Step 1: Write failing tests**
- [ ] **Step 2: Implement ProjectContextBuilder** — queries project, board summary, repo summaries, devlog tail
- [ ] **Step 3: Run tests, verify pass, commit**

### Task 33: RepoContextBuilder

**Files:**
- Create: `apps/synapsis_agent/lib/synapsis/agent/repo_context_builder.ex`
- Test: `apps/synapsis_agent/test/synapsis/agent/repo_context_builder_test.exs`

- [ ] **Step 1: Write failing tests**
- [ ] **Step 2: Implement RepoContextBuilder** — queries worktree, builds file tree, git log/diff/status
- [ ] **Step 3: Run tests, verify pass, commit**

### Task 34: BuildAgentSupervisor

**Files:**
- Create: `apps/synapsis_agent/lib/synapsis/agent/build_agent_supervisor.ex`

- [ ] **Step 1: Implement BuildAgentSupervisor**

```elixir
# apps/synapsis_agent/lib/synapsis/agent/build_agent_supervisor.ex
defmodule Synapsis.Agent.BuildAgentSupervisor do
  @moduledoc "DynamicSupervisor for ephemeral Build Agent processes."
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_agent(config) do
    spec = {Synapsis.Agent.Agents.BuildAgent, config}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
```

- [ ] **Step 2: Commit**

```bash
git add apps/synapsis_agent/lib/synapsis/agent/build_agent_supervisor.ex
git commit -m "feat(agent): add BuildAgentSupervisor"
```

### Task 35: AssistantAgent and BuildAgent (stubs)

**Files:**
- Create: `apps/synapsis_agent/lib/synapsis/agent/agents/assistant_agent.ex`
- Create: `apps/synapsis_agent/lib/synapsis/agent/agents/build_agent.ex`
- Test: `apps/synapsis_agent/test/synapsis/agent/agents/assistant_agent_test.exs`

These are structural stubs that define the GenServer interface and state shape. Full graph execution integration is beyond this plan's scope — it builds on the existing graph runtime (GR-1 through GR-5 from agent-system-prd, unchanged).

- [ ] **Step 1: Implement AssistantAgent stub** — GenServer with context_mode state, handle_info for notifications
- [ ] **Step 2: Implement BuildAgent stub** — GenServer with init config, temporary restart
- [ ] **Step 3: Write tests for start/stop lifecycle**
- [ ] **Step 4: Commit**

### Task 36: WorktreeCleanup Oban worker

**Files:**
- Create: `apps/synapsis_agent/lib/synapsis/agent/worktree_cleanup.ex`
- Test: `apps/synapsis_agent/test/synapsis/agent/worktree_cleanup_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
# apps/synapsis_agent/test/synapsis/agent/worktree_cleanup_test.exs
defmodule Synapsis.Agent.WorktreeCleanupTest do
  use Synapsis.Agent.DataCase, async: true

  alias Synapsis.Agent.WorktreeCleanup

  test "module implements Oban.Worker" do
    assert function_exported?(WorktreeCleanup, :perform, 1)
  end
end
```

- [ ] **Step 2: Implement WorktreeCleanup**

```elixir
# apps/synapsis_agent/lib/synapsis/agent/worktree_cleanup.ex
defmodule Synapsis.Agent.WorktreeCleanup do
  @moduledoc "Oban worker for periodic worktree garbage collection."
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    stale_completed = Synapsis.Worktrees.stale(24)
    stale_failed = Synapsis.Worktrees.stale(6)
    stale = Enum.uniq_by(stale_completed ++ stale_failed, & &1.id)

    for wt <- stale do
      repo = Synapsis.Repos.get(wt.repo_id)

      if repo do
        case Synapsis.Git.Worktree.remove(repo.bare_path, wt.local_path) do
          :ok ->
            {:ok, wt} = Synapsis.Worktrees.mark_cleaning(wt)
            Synapsis.Worktrees.mark_cleaned(wt)
            Logger.info("worktree_cleaned", worktree_id: wt.id)

          {:error, reason} ->
            Logger.warning("worktree_cleanup_failed", worktree_id: wt.id, reason: reason)
        end

        Synapsis.Git.Worktree.prune(repo.bare_path)
      end
    end

    :ok
  end
end
```

- [ ] **Step 3: Run tests, verify pass, commit**

```bash
git add apps/synapsis_agent/lib/synapsis/agent/worktree_cleanup.ex apps/synapsis_agent/test/synapsis/agent/worktree_cleanup_test.exs
git commit -m "feat(agent): add WorktreeCleanup Oban worker"
```

### Task 37: Phase 5 verification

- [ ] **Step 1: Run full agent test suite**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix test apps/synapsis_agent --trace'`

- [ ] **Step 2: Full umbrella compile + test**

Run: `devenv shell -- bash -c 'cd /home/gao/Workspace/gsmlg-opt/Synapsis && mix compile --warnings-as-errors && mix test && mix format --check-formatted'`

---

## Final Verification

- [ ] **All migrations run cleanly**
- [ ] **`mix compile --warnings-as-errors`** — zero warnings
- [ ] **`mix test`** — all green
- [ ] **`mix format --check-formatted`** — no issues
