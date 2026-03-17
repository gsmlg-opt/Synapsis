defmodule Synapsis.Workspace.Tools.WorkspaceSearch do
  @moduledoc "Full-text search across workspace documents."
  use Synapsis.Tool

  @impl true
  def name, do: "workspace_search"

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :workspace

  @impl true
  def description do
    "Search workspace documents using full-text search. Finds plans, todos, notes, and other artifacts matching a query. Supports scoping to global, project, or session."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "Search query (supports natural language)"
        },
        "scope" => %{
          "type" => "string",
          "enum" => ["global", "project", "session"],
          "description" => "Limit search scope"
        },
        "project_id" => %{
          "type" => "string",
          "description" => "Filter by project ID"
        },
        "kind" => %{
          "type" => "string",
          "enum" => ["document", "attachment", "handoff", "session_scratch"],
          "description" => "Filter by document kind"
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Max results (default: 20)"
        }
      },
      "required" => ["query"]
    }
  end

  @impl true
  def execute(input, _context) do
    query = input["query"]

    opts =
      []
      |> maybe_add(:scope, parse_scope(input["scope"]))
      |> maybe_add(:project_id, input["project_id"])
      |> maybe_add(:kind, parse_kind(input["kind"]))
      |> maybe_add(:limit, input["limit"])

    case Synapsis.Workspace.search(query, opts) do
      {:ok, resources} ->
        results =
          Enum.map(resources, fn r ->
            %{
              id: r.id,
              path: r.path,
              kind: r.kind,
              content_preview: String.slice(r.content || "", 0, 200),
              version: r.version,
              updated_at: r.updated_at
            }
          end)

        {:ok, Jason.encode!(results)}
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: [{key, value} | opts]

  defp parse_scope("global"), do: :global
  defp parse_scope("project"), do: :project
  defp parse_scope("session"), do: :session
  defp parse_scope(_), do: nil

  defp parse_kind("document"), do: :document
  defp parse_kind("attachment"), do: :attachment
  defp parse_kind("handoff"), do: :handoff
  defp parse_kind("session_scratch"), do: :session_scratch
  defp parse_kind(_), do: nil
end
