defmodule Synapsis.Workspace.Projection do
  @moduledoc """
  Projects domain records as virtual workspace resources.

  Workspace paths are agent-owned:

    * `/shared/skills/:name/SKILL.md`
    * `/shared/memory/:category/:key.md`
    * `/agents/:agent/memory/:category/:key.md`
    * `/agents/:agent/sessions/:session_id/todo.md`
    * `/agents/:agent/sessions/:session_id/memory/:category/:key.md`
  """

  alias Synapsis.Workspace.Resource
  alias Synapsis.WorkspaceDocuments

  @spec project_skill(struct()) :: Resource.t()
  def project_skill(%{} = skill) do
    %Resource{
      id: skill.id,
      path: "/shared/skills/#{skill.name}/SKILL.md",
      kind: :skill,
      content: build_skill_content(skill),
      content_format: :markdown,
      metadata: %{
        "scope" => skill.scope,
        "tool_allowlist" => skill.tool_allowlist,
        "config_overrides" => skill.config_overrides,
        "is_builtin" => skill.is_builtin
      },
      visibility: :global_shared,
      lifecycle: :shared,
      version: 1,
      created_by: nil,
      updated_by: nil,
      created_at: skill.inserted_at,
      updated_at: skill.updated_at
    }
  end

  @spec project_memory(struct()) :: Resource.t()
  def project_memory(%{} = entry) do
    %Resource{
      id: entry.id,
      path: memory_path(entry),
      kind: :memory,
      content: build_memory_content(entry),
      content_format: :markdown,
      metadata: build_memory_metadata(entry),
      visibility: memory_visibility(entry),
      lifecycle: :shared,
      version: 1,
      created_by: nil,
      updated_by: nil,
      created_at: entry.inserted_at,
      updated_at: entry.updated_at
    }
  end

  @spec project_todo(struct()) :: Resource.t()
  def project_todo(%{} = todo) do
    agent_id = resolve_todo_agent_id(todo)
    session_id = todo.session_id

    %Resource{
      id: todo.id,
      path: todo_path(agent_id, session_id),
      kind: :todo,
      content: build_todo_content(todo),
      content_format: :markdown,
      metadata: %{
        "agent_id" => agent_id,
        "session_id" => session_id,
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

  @spec list_projected(String.t(), keyword()) :: [Resource.t()]
  def list_projected(path_prefix, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    kind_filter = Keyword.get(opts, :kind)

    path_prefix
    |> path_segments()
    |> dispatch_list(limit)
    |> maybe_filter_kind(kind_filter)
  end

  @spec find_projected(String.t()) :: {:ok, Resource.t()} | {:error, :not_found}
  def find_projected(path) do
    path
    |> path_segments()
    |> dispatch_find()
  end

  defp dispatch_list(["shared", "skills" | _], limit), do: list_skills(:global, nil, limit)
  defp dispatch_list(["shared", "memory" | _], limit), do: list_memory(:shared, nil, limit)
  defp dispatch_list(["agents", agent_id, "memory" | _], limit), do: list_memory(:agent, agent_id, limit)

  defp dispatch_list(["agents", agent_id, "sessions", session_id | _], _limit),
    do: list_todos_for_session(agent_id, session_id)

  defp dispatch_list(["agents", agent_id, "sessions"], limit),
    do: list_todos_for_agent(agent_id, limit)

  defp dispatch_list(_segments, _limit), do: []

  defp dispatch_find(["shared", "skills", name, "SKILL.md"]),
    do: find_skill(:global, nil, name)

  defp dispatch_find(["shared", "memory", _category, key_with_ext]) do
    find_memory(:shared, nil, strip_md_ext(key_with_ext))
  end

  defp dispatch_find(["agents", agent_id, "memory", _category, key_with_ext]) do
    find_memory(:agent, agent_id, strip_md_ext(key_with_ext))
  end

  defp dispatch_find(["agents", agent_id, "sessions", session_id, "todo.md"]) do
    find_todo(agent_id, session_id)
  end

  defp dispatch_find(_segments), do: {:error, :not_found}

  defp list_skills(scope, agent_id, limit) do
    if Code.ensure_loaded?(Synapsis.Skill) do
      scope
      |> to_string()
      |> WorkspaceDocuments.list_skills(agent_id, limit)
      |> Enum.map(&project_skill/1)
    else
      []
    end
  end

  defp find_skill(scope, agent_id, name) do
    if Code.ensure_loaded?(Synapsis.Skill) do
      case WorkspaceDocuments.find_skill(to_string(scope), agent_id, name) do
        nil -> {:error, :not_found}
        skill -> {:ok, project_skill(skill)}
      end
    else
      {:error, :not_found}
    end
  end

  defp list_memory(scope, scope_id, limit) do
    if Code.ensure_loaded?(Synapsis.SemanticMemory) do
      scope
      |> to_string()
      |> WorkspaceDocuments.list_semantic_memories(scope_id, limit)
      |> Enum.map(&project_memory/1)
    else
      []
    end
  end

  defp find_memory(scope, scope_id, key) do
    if Code.ensure_loaded?(Synapsis.SemanticMemory) do
      case WorkspaceDocuments.find_semantic_memory(to_string(scope), scope_id, key) do
        nil -> {:error, :not_found}
        entry -> {:ok, project_memory(entry)}
      end
    else
      {:error, :not_found}
    end
  end

  defp list_todos_for_session(agent_id, session_id) do
    if Code.ensure_loaded?(Synapsis.SessionTodo) do
      case WorkspaceDocuments.list_todos_for_session(session_id) do
        [] -> []
        todos -> [build_todo_resource(agent_id, session_id, todos)]
      end
    else
      []
    end
  end

  defp list_todos_for_agent(agent_id, limit) do
    if Code.ensure_loaded?(Synapsis.SessionTodo) and Code.ensure_loaded?(Synapsis.Session) do
      agent_id
      |> WorkspaceDocuments.list_todos_for_agent(limit)
      |> Enum.map(fn {session_id, todos} -> build_todo_resource(agent_id, session_id, todos) end)
      |> Enum.take(limit)
    else
      []
    end
  end

  defp find_todo(agent_id, session_id) do
    if Code.ensure_loaded?(Synapsis.SessionTodo) do
      case WorkspaceDocuments.list_todos_for_session(session_id) do
        [] -> {:error, :not_found}
        todos -> {:ok, build_todo_resource(agent_id, session_id, todos)}
      end
    else
      {:error, :not_found}
    end
  end

  defp memory_path(%{scope: "shared", id: id} = entry),
    do: "/shared/memory/#{memory_category(entry)}/#{id}.md"

  defp memory_path(%{scope: "agent", scope_id: agent_id, id: id} = entry),
    do: "/agents/#{agent_id}/memory/#{memory_category(entry)}/#{id}.md"

  defp memory_path(%{id: id} = entry),
    do: "/shared/memory/#{memory_category(entry)}/#{id}.md"

  defp todo_path(agent_id, session_id), do: "/agents/#{agent_id}/sessions/#{session_id}/todo.md"

  defp memory_visibility(%{scope: "shared"}), do: :global_shared
  defp memory_visibility(%{scope: "agent"}), do: :agent_shared
  defp memory_visibility(_), do: :private

  defp build_memory_content(%{title: title, summary: summary, detail: detail}) do
    detail =
      case detail do
        map when is_map(map) and map_size(map) > 0 -> "\n\n```json\n#{JSON.encode!(map)}\n```"
        _ -> ""
      end

    "# #{title}\n\n#{summary}#{detail}"
  end

  defp build_memory_content(%{content: content}), do: content

  defp build_memory_metadata(%{metadata: metadata}) when is_map(metadata), do: metadata

  defp build_memory_metadata(entry) do
    %{
      "scope" => Map.get(entry, :scope),
      "scope_id" => Map.get(entry, :scope_id),
      "kind" => Map.get(entry, :kind),
      "title" => Map.get(entry, :title),
      "tags" => Map.get(entry, :tags, []),
      "importance" => Map.get(entry, :importance),
      "confidence" => Map.get(entry, :confidence),
      "source" => Map.get(entry, :source)
    }
  end

  defp build_skill_content(skill) do
    parts = ["# #{skill.name}"]
    parts = maybe_append(parts, skill.description)
    parts = maybe_append_section(parts, "System Prompt", skill.system_prompt_fragment)

    if skill.tool_allowlist != [] do
      parts ++ ["\n## Tool Allowlist\n\n#{Enum.join(skill.tool_allowlist, ", ")}"]
    else
      parts
    end
    |> Enum.join("\n")
  end

  defp maybe_append(parts, nil), do: parts
  defp maybe_append(parts, ""), do: parts
  defp maybe_append(parts, content), do: parts ++ ["\n#{content}"]

  defp maybe_append_section(parts, _title, nil), do: parts
  defp maybe_append_section(parts, _title, ""), do: parts
  defp maybe_append_section(parts, title, content), do: parts ++ ["\n## #{title}\n\n#{content}"]

  defp build_todo_resource(agent_id, session_id, todos) do
    content =
      todos
      |> Enum.sort_by(& &1.sort_order)
      |> Enum.map(&build_todo_content/1)
      |> Enum.join("\n")

    latest = Enum.max_by(todos, & &1.updated_at, DateTime)
    oldest = Enum.min_by(todos, & &1.inserted_at, DateTime)

    %Resource{
      id: session_id,
      path: todo_path(agent_id, session_id),
      kind: :todo,
      content: content,
      content_format: :markdown,
      metadata: %{"agent_id" => agent_id, "session_id" => session_id, "count" => length(todos)},
      visibility: :private,
      lifecycle: :scratch,
      version: 1,
      created_by: nil,
      updated_by: nil,
      created_at: oldest.inserted_at,
      updated_at: latest.updated_at
    }
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

  defp resolve_todo_agent_id(%{session: %{agent: agent}}) when is_binary(agent), do: agent
  defp resolve_todo_agent_id(%{agent_id: agent_id}) when is_binary(agent_id), do: agent_id
  defp resolve_todo_agent_id(%{session_id: session_id}), do: resolve_session_agent_id(session_id)
  defp resolve_todo_agent_id(_), do: "unknown"

  defp resolve_session_agent_id(session_id) do
    if Code.ensure_loaded?(Synapsis.Session) do
      WorkspaceDocuments.get_session_agent_id(session_id) || "unknown"
    else
      "unknown"
    end
  end

  defp memory_category(%{metadata: %{"category" => category}}) when is_binary(category),
    do: category

  defp memory_category(%{kind: kind}) when is_binary(kind), do: kind

  defp memory_category(_entry), do: "general"

  defp path_segments(path) do
    path
    |> String.trim_leading("/")
    |> String.split("/", trim: true)
  end

  defp maybe_filter_kind(results, nil), do: results
  defp maybe_filter_kind(results, kind), do: Enum.filter(results, &(&1.kind == kind))

  defp strip_md_ext(filename) do
    case String.split(filename, ".", parts: 2) do
      [base, "md"] -> base
      _ -> filename
    end
  end
end
