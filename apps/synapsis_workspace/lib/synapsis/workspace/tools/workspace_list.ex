defmodule Synapsis.Workspace.Tools.WorkspaceList do
  @moduledoc "List workspace documents under a path prefix."
  use Synapsis.Tool

  @impl true
  def name, do: "workspace_list"

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :workspace

  @impl true
  def description do
    "List workspace documents under a path prefix. Shows plans, todos, notes, and other artifacts organized by directory. Supports filtering by kind, depth, and sort order."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" =>
            "Path prefix to list (e.g. /projects/myapp/plans/, /shared/notes/)"
        },
        "depth" => %{
          "type" => "integer",
          "description" => "Max nesting depth (omit for unlimited)"
        },
        "kind" => %{
          "type" => "string",
          "enum" => ["document", "attachment", "handoff", "session_scratch"],
          "description" => "Filter by document kind"
        },
        "sort" => %{
          "type" => "string",
          "enum" => ["path", "recent", "name"],
          "description" => "Sort order (default: path)"
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Max results (default: 100)"
        }
      },
      "required" => ["path"]
    }
  end

  @impl true
  def execute(input, context) do
    path = input["path"]

    agent_ctx = %{
      role: context[:role] || :user,
      project_id: context[:project_id],
      session_id: context[:session_id]
    }

    with :allowed <- Synapsis.Workspace.Permissions.check(agent_ctx, path, :read) do
      opts =
        []
        |> maybe_add(:depth, input["depth"])
        |> maybe_add(:kind, parse_kind(input["kind"]))
        |> maybe_add(:sort, parse_sort(input["sort"]))
        |> maybe_add(:limit, input["limit"])

      case Synapsis.Workspace.list(path, opts) do
        {:ok, resources} ->
          entries =
            Enum.map(resources, fn r ->
              %{
                id: r.id,
                path: r.path,
                kind: r.kind,
                lifecycle: r.lifecycle,
                version: r.version,
                updated_at: r.updated_at
              }
            end)

          {:ok, Jason.encode!(entries)}
      end
    else
      :denied -> {:error, "Permission denied: cannot list #{path}"}
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: [{key, value} | opts]

  defp parse_kind("document"), do: :document
  defp parse_kind("attachment"), do: :attachment
  defp parse_kind("handoff"), do: :handoff
  defp parse_kind("session_scratch"), do: :session_scratch
  defp parse_kind(_), do: nil

  defp parse_sort("recent"), do: :recent
  defp parse_sort("name"), do: :name
  defp parse_sort(_), do: nil
end
