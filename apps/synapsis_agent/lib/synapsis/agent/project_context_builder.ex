defmodule Synapsis.Agent.ProjectContextBuilder do
  @moduledoc "Assembles context for the Assistant when in project mode."

  @type project_context :: %{
          project: %{id: String.t(), name: String.t(), description: String.t() | nil},
          board_summary: %{
            total: integer(),
            by_column: %{String.t() => integer()},
            in_progress: [map()],
            blockers: [map()]
          },
          repos: [
            %{
              id: String.t(),
              name: String.t(),
              default_branch: String.t(),
              active_worktrees: integer()
            }
          ],
          devlog_tail: [map()]
        }

  @spec build(binary()) :: project_context()
  def build(project_id) do
    project = Synapsis.Projects.get(project_id)

    board_summary = build_board_summary(project_id)
    repos = build_repo_summary(project_id)
    devlog_tail = build_devlog_tail(project_id)

    %{
      project: %{
        id: project.id,
        name: project.name,
        description: project.description
      },
      board_summary: board_summary,
      repos: repos,
      devlog_tail: devlog_tail
    }
  end

  defp build_board_summary(project_id) do
    path = "/projects/#{project_id}/board.yaml"

    case Synapsis.WorkspaceDocuments.get_by_path(path) do
      nil ->
        empty_board_summary()

      %{content_body: nil} ->
        empty_board_summary()

      %{content_body: content} ->
        parse_board_content(content)
    end
  rescue
    _ -> empty_board_summary()
  end

  defp parse_board_content(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, data} when is_map(data) ->
        items = Map.get(data, "items", [])
        by_column = Enum.group_by(items, &Map.get(&1, "column", "backlog"))
        by_column_count = Map.new(by_column, fn {col, entries} -> {col, length(entries)} end)

        in_progress =
          Map.get(by_column, "in_progress", []) ++ Map.get(by_column, "doing", [])

        blockers =
          Enum.filter(items, fn item ->
            Map.get(item, "blocked", false) == true
          end)

        %{
          total: length(items),
          by_column: by_column_count,
          in_progress: in_progress,
          blockers: blockers
        }

      _ ->
        empty_board_summary()
    end
  rescue
    _ -> empty_board_summary()
  end

  defp empty_board_summary do
    %{
      total: 0,
      by_column: %{},
      in_progress: [],
      blockers: []
    }
  end

  defp build_repo_summary(project_id) do
    repos = Synapsis.Repos.list_for_project(project_id)

    Enum.map(repos, fn repo ->
      active_worktrees =
        repo.id
        |> Synapsis.Worktrees.list_active_for_repo()
        |> length()

      %{
        id: repo.id,
        name: repo.name,
        default_branch: repo.default_branch,
        active_worktrees: active_worktrees
      }
    end)
  end

  defp build_devlog_tail(project_id) do
    path = "/projects/#{project_id}/devlog.md"

    case Synapsis.WorkspaceDocuments.get_by_path(path) do
      nil ->
        []

      %{content_body: nil} ->
        []

      %{content_body: content} ->
        content
        |> String.split("\n")
        |> Enum.reject(&(String.trim(&1) == ""))
        |> Enum.take(-20)
        |> Enum.map(&%{line: &1})
    end
  rescue
    _ -> []
  end
end
