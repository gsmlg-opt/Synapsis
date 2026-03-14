defmodule Synapsis.Workspace.Projection do
  @moduledoc """
  Projects domain schemas (skills, memory entries, session todos) into
  uniform workspace Resource structs for browsing via the workspace API.

  Domain schemas are not replicated — this module queries them at read time
  and returns transient Resource structs with paths derived from domain fields.

  All database access is delegated to named functions in `Synapsis.WorkspaceDocuments`.

  ## Path conventions

    - Global skill     → `/shared/skills/:name/SKILL.md`
    - Project skill    → `/projects/:project_id/skills/:name/SKILL.md`
    - Memory entry     → `/projects/:project_id/memory/:category/:key.md`
                         (global scope) `/shared/memory/:category/:key.md`
    - Session todo     → `/projects/:project_id/sessions/:session_id/todo.md`

  ## Graceful degradation

  All functions check whether the required schema modules are loaded before
  querying. When a schema is not available (e.g. during early bootstrap or in
  isolated tests), the functions return empty lists or `:error` rather than
  raising.
  """

  alias Synapsis.WorkspaceDocuments
  alias Synapsis.Workspace.Resource

  # ---------------------------------------------------------------------------
  # Skill projection
  # ---------------------------------------------------------------------------

  @doc """
  Project a `Synapsis.Skill` struct into a `Resource`.

  ## Examples

      iex> Projection.project_skill(%Synapsis.Skill{scope: "global", name: "elixir-patterns", ...})
      %Resource{path: "/shared/skills/elixir-patterns/SKILL.md", kind: :skill, ...}
  """
  @spec project_skill(struct()) :: Resource.t()
  def project_skill(%{} = skill) do
    path = skill_path(skill)

    content = build_skill_content(skill)

    %Resource{
      id: skill.id,
      path: path,
      kind: :skill,
      content: content,
      content_format: :markdown,
      metadata: %{
        "scope" => skill.scope,
        "project_id" => skill.project_id,
        "tool_allowlist" => skill.tool_allowlist,
        "config_overrides" => skill.config_overrides,
        "is_builtin" => skill.is_builtin
      },
      visibility: skill_visibility(skill),
      lifecycle: :shared,
      version: 1,
      created_by: nil,
      updated_by: nil,
      created_at: skill.inserted_at,
      updated_at: skill.updated_at
    }
  end

  # ---------------------------------------------------------------------------
  # Memory entry projection
  # ---------------------------------------------------------------------------

  @doc """
  Project a `Synapsis.MemoryEntry` struct into a `Resource`.

  The `category` segment of the path is derived from `metadata["category"]`
  when present, falling back to `"general"`.

  ## Examples

      iex> Projection.project_memory(%Synapsis.MemoryEntry{scope: "project", scope_id: "abc", key: "auth-patterns", ...})
      %Resource{path: "/projects/abc/memory/semantic/auth-patterns.md", kind: :memory, ...}
  """
  @spec project_memory(struct()) :: Resource.t()
  def project_memory(%{} = entry) do
    path = memory_path(entry)

    %Resource{
      id: entry.id,
      path: path,
      kind: :memory,
      content: entry.content,
      content_format: :markdown,
      metadata: entry.metadata || %{},
      visibility: memory_visibility(entry),
      lifecycle: :shared,
      version: 1,
      created_by: nil,
      updated_by: nil,
      created_at: entry.inserted_at,
      updated_at: entry.updated_at
    }
  end

  # ---------------------------------------------------------------------------
  # Session todo projection
  # ---------------------------------------------------------------------------

  @doc """
  Project a `Synapsis.SessionTodo` struct (preloaded with its session's
  project_id) into a Resource.

  All todos for a single session are aggregated by `list_projected/2` and
  `find_projected/1` — this function projects a single todo item for cases
  where the caller already has a struct with `:session` preloaded or has
  separately resolved the project_id.

  The `project_id` must be provided via the `:project_id` key in the struct
  (virtual field) or through a preloaded `:session` association.
  """
  @spec project_todo(struct()) :: Resource.t()
  def project_todo(%{} = todo) do
    project_id = resolve_todo_project_id(todo)
    session_id = todo.session_id
    path = todo_path(project_id, session_id)

    content = build_todo_content(todo)

    %Resource{
      id: todo.id,
      path: path,
      kind: :todo,
      content: content,
      content_format: :markdown,
      metadata: %{
        "session_id" => session_id,
        "project_id" => project_id,
        "todo_id" => todo.todo_id,
        "status" => to_string(todo.status),
        "sort_order" => todo.sort_order
      },
      visibility: :private,
      lifecycle: :scratch,
      version: 1,
      created_by: nil,
      updated_by: nil,
      created_at: todo.inserted_at,
      updated_at: todo.updated_at
    }
  end

  # ---------------------------------------------------------------------------
  # list_projected/2
  # ---------------------------------------------------------------------------

  @doc """
  Query domain contexts for resources matching the given path prefix and opts,
  returning projected Resources.

  Dispatches based on the path prefix pattern:

    - `/shared/skills/**`                           → global skills
    - `/projects/:id/skills/**`                     → project skills
    - `/shared/memory/**`                           → global memory entries
    - `/projects/:id/memory/**`                     → project memory entries
    - `/projects/:id/sessions/:sid/todo.md`         → session todos
    - `/projects/:id/sessions/**`                   → all todos for sessions in project

  Returns `[]` when the domain schema is not available.

  ## Options

    - `:limit` - max results, default 100
    - `:kind`  - filter to `:skill`, `:memory`, or `:todo`
  """
  @spec list_projected(String.t(), keyword()) :: [Resource.t()]
  def list_projected(path_prefix, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    kind_filter = Keyword.get(opts, :kind)

    segments =
      path_prefix
      |> String.trim_leading("/")
      |> String.split("/", trim: true)

    results = dispatch_list(segments, limit)

    if kind_filter do
      Enum.filter(results, fn r -> r.kind == kind_filter end)
    else
      results
    end
  end

  # ---------------------------------------------------------------------------
  # find_projected/1
  # ---------------------------------------------------------------------------

  @doc """
  Given a path, checks whether it matches a domain schema pattern and returns
  the projected Resource if found.

  Resolution patterns (in order):

    1. `/shared/skills/:name/SKILL.md`                     → skill (global)
    2. `/projects/:pid/skills/:name/SKILL.md`              → skill (project)
    3. `/shared/memory/:category/:key.md`                  → memory entry (global)
    4. `/projects/:pid/memory/:category/:key.md`           → memory entry (project)
    5. `/projects/:pid/sessions/:sid/todo.md`              → todo aggregation

  Returns `{:ok, Resource.t()}` or `{:error, :not_found}`.
  """
  @spec find_projected(String.t()) :: {:ok, Resource.t()} | {:error, :not_found}
  def find_projected(path) do
    segments =
      path
      |> String.trim_leading("/")
      |> String.split("/", trim: true)

    dispatch_find(segments)
  end

  # ---------------------------------------------------------------------------
  # Private — list dispatch
  # ---------------------------------------------------------------------------

  defp dispatch_list(["shared", "skills" | _], limit) do
    list_skills(:global, nil, limit)
  end

  defp dispatch_list(["projects", project_id, "skills" | _], limit) do
    list_skills(:project, project_id, limit)
  end

  defp dispatch_list(["shared", "memory" | _], limit) do
    list_memory(:global, nil, limit)
  end

  defp dispatch_list(["projects", project_id, "memory" | _], limit) do
    list_memory(:project, project_id, limit)
  end

  defp dispatch_list(["projects", project_id, "sessions", session_id | _], limit) do
    list_todos_for_session(project_id, session_id, limit)
  end

  defp dispatch_list(["projects", project_id, "sessions"], limit) do
    list_todos_for_project(project_id, limit)
  end

  defp dispatch_list(_segments, _limit), do: []

  # ---------------------------------------------------------------------------
  # Private — find dispatch
  # ---------------------------------------------------------------------------

  defp dispatch_find(["shared", "skills", name, "SKILL.md"]) do
    find_skill(:global, nil, name)
  end

  defp dispatch_find(["projects", project_id, "skills", name, "SKILL.md"]) do
    find_skill(:project, project_id, name)
  end

  defp dispatch_find(["shared", "memory", _category, key_with_ext]) do
    key = strip_md_ext(key_with_ext)
    find_memory(:global, nil, key)
  end

  defp dispatch_find(["projects", project_id, "memory", _category, key_with_ext]) do
    key = strip_md_ext(key_with_ext)
    find_memory(:project, project_id, key)
  end

  defp dispatch_find(["projects", project_id, "sessions", session_id, "todo.md"]) do
    find_todo(project_id, session_id)
  end

  defp dispatch_find(_segments), do: {:error, :not_found}

  # ---------------------------------------------------------------------------
  # Private — skills queries (delegated to WorkspaceDocuments)
  # ---------------------------------------------------------------------------

  defp list_skills(scope, project_id, limit) do
    if Code.ensure_loaded?(Synapsis.Skill) do
      scope
      |> to_string()
      |> WorkspaceDocuments.list_skills(project_id, limit)
      |> Enum.map(&project_skill/1)
    else
      []
    end
  end

  defp find_skill(scope, project_id, name) do
    if Code.ensure_loaded?(Synapsis.Skill) do
      case WorkspaceDocuments.find_skill(to_string(scope), project_id, name) do
        nil -> {:error, :not_found}
        skill -> {:ok, project_skill(skill)}
      end
    else
      {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — memory queries (delegated to WorkspaceDocuments)
  # ---------------------------------------------------------------------------

  defp list_memory(scope, scope_id, limit) do
    if Code.ensure_loaded?(Synapsis.MemoryEntry) do
      scope
      |> to_string()
      |> WorkspaceDocuments.list_memory_entries(scope_id, limit)
      |> Enum.map(&project_memory/1)
    else
      []
    end
  end

  defp find_memory(scope, scope_id, key) do
    if Code.ensure_loaded?(Synapsis.MemoryEntry) do
      case WorkspaceDocuments.find_memory_entry(to_string(scope), scope_id, key) do
        nil -> {:error, :not_found}
        entry -> {:ok, project_memory(entry)}
      end
    else
      {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — todo queries (delegated to WorkspaceDocuments)
  # ---------------------------------------------------------------------------

  defp list_todos_for_session(project_id, session_id, _limit) do
    if Code.ensure_loaded?(Synapsis.SessionTodo) do
      case WorkspaceDocuments.list_todos_for_session(session_id) do
        [] -> []
        todos -> [build_todo_resource(project_id, session_id, todos)]
      end
    else
      []
    end
  end

  defp list_todos_for_project(project_id, limit) do
    if Code.ensure_loaded?(Synapsis.SessionTodo) and Code.ensure_loaded?(Synapsis.Session) do
      project_id
      |> WorkspaceDocuments.list_session_ids_for_project(limit)
      |> Enum.flat_map(fn sid ->
        list_todos_for_session(project_id, sid, limit)
      end)
      |> Enum.take(limit)
    else
      []
    end
  end

  defp find_todo(project_id, session_id) do
    if Code.ensure_loaded?(Synapsis.SessionTodo) do
      case WorkspaceDocuments.list_todos_for_session(session_id) do
        [] -> {:error, :not_found}
        items -> {:ok, build_todo_resource(project_id, session_id, items)}
      end
    else
      {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — path builders
  # ---------------------------------------------------------------------------

  defp skill_path(%{scope: "global", name: name}),
    do: "/shared/skills/#{name}/SKILL.md"

  defp skill_path(%{scope: "project", project_id: project_id, name: name}),
    do: "/projects/#{project_id}/skills/#{name}/SKILL.md"

  defp memory_path(%{scope: "global", key: key} = entry) do
    category = memory_category(entry)
    "/shared/memory/#{category}/#{key}.md"
  end

  defp memory_path(%{scope: "project", scope_id: scope_id, key: key} = entry) do
    category = memory_category(entry)
    "/projects/#{scope_id}/memory/#{category}/#{key}.md"
  end

  defp memory_path(%{scope: "session", scope_id: scope_id, key: key} = entry) do
    # Session-scoped memory is surfaced under the session path
    category = memory_category(entry)
    project_id = resolve_session_project_id(scope_id)
    "/projects/#{project_id}/sessions/#{scope_id}/memory/#{category}/#{key}.md"
  end

  defp todo_path(project_id, session_id),
    do: "/projects/#{project_id}/sessions/#{session_id}/todo.md"

  defp memory_category(%{metadata: %{"category" => category}}) when is_binary(category),
    do: category

  defp memory_category(_entry), do: "general"

  # ---------------------------------------------------------------------------
  # Private — visibility helpers
  # ---------------------------------------------------------------------------

  defp skill_visibility(%{scope: "global"}), do: :global_shared
  defp skill_visibility(%{scope: "project"}), do: :project_shared
  defp skill_visibility(_), do: :private

  defp memory_visibility(%{scope: "global"}), do: :global_shared
  defp memory_visibility(%{scope: "project"}), do: :project_shared
  defp memory_visibility(_), do: :private

  # ---------------------------------------------------------------------------
  # Private — content builders
  # ---------------------------------------------------------------------------

  defp build_skill_content(skill) do
    parts = ["# #{skill.name}"]

    parts =
      if skill.description && skill.description != "",
        do: parts ++ ["\n#{skill.description}"],
        else: parts

    parts =
      if skill.system_prompt_fragment && skill.system_prompt_fragment != "",
        do: parts ++ ["\n## System Prompt\n\n#{skill.system_prompt_fragment}"],
        else: parts

    parts =
      if skill.tool_allowlist != [] do
        tools = Enum.join(skill.tool_allowlist, ", ")
        parts ++ ["\n## Tool Allowlist\n\n#{tools}"]
      else
        parts
      end

    Enum.join(parts, "\n")
  end

  defp build_todo_content(todo) do
    status_mark =
      case todo.status do
        :completed -> "[x]"
        :in_progress -> "[-]"
        _ -> "[ ]"
      end

    "- #{status_mark} #{todo.content}"
  end

  # ---------------------------------------------------------------------------
  # Private — aggregated todo resource for a session
  # ---------------------------------------------------------------------------

  # When a session has multiple todos, they are projected together as a single
  # `todo.md` file with all items rendered as a markdown checklist. The resource
  # id is set to the session_id since there is no single backing row.
  defp build_todo_resource(project_id, session_id, todos) do
    path = todo_path(project_id, session_id)

    content =
      todos
      |> Enum.sort_by(& &1.sort_order)
      |> Enum.map(&build_todo_content/1)
      |> Enum.join("\n")

    latest = Enum.max_by(todos, & &1.updated_at, DateTime)
    oldest = Enum.min_by(todos, & &1.inserted_at, DateTime)

    %Resource{
      id: session_id,
      path: path,
      kind: :todo,
      content: content,
      content_format: :markdown,
      metadata: %{
        "session_id" => session_id,
        "project_id" => project_id,
        "count" => length(todos)
      },
      visibility: :private,
      lifecycle: :scratch,
      version: 1,
      created_by: nil,
      updated_by: nil,
      created_at: oldest.inserted_at,
      updated_at: latest.updated_at
    }
  end

  defp strip_md_ext(filename) do
    case String.split(filename, ".", parts: 2) do
      [base, "md"] -> base
      _ -> filename
    end
  end

  # ---------------------------------------------------------------------------
  # Private — resolve project_id from todo/session structs
  # ---------------------------------------------------------------------------

  defp resolve_todo_project_id(%{session: %{project_id: pid}}) when is_binary(pid), do: pid
  defp resolve_todo_project_id(%{project_id: pid}) when is_binary(pid), do: pid
  defp resolve_todo_project_id(_), do: "unknown"

  defp resolve_session_project_id(session_id) do
    if Code.ensure_loaded?(Synapsis.Session) do
      WorkspaceDocuments.get_session_project_id(session_id) || "unknown"
    else
      "unknown"
    end
  end
end
