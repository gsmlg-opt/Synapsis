defmodule Synapsis.Tool.DevlogRead do
  @moduledoc "Read recent entries from the project dev log."
  use Synapsis.Tool

  @impl true
  def name, do: "devlog_read"

  @impl true
  def description,
    do:
      "Read entries from the project dev log at /projects/<id>/logs/devlog.md. " <>
        "Supports filtering by count, category, and since (ISO datetime)."

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :workflow

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "count" => %{
          "type" => "integer",
          "description" => "Maximum number of recent entries to return (default 20)"
        },
        "category" => %{
          "type" => "string",
          "description" =>
            "Filter by category (decision, progress, blocker, insight, error, completion, user-note)"
        },
        "since" => %{
          "type" => "string",
          "description" => "ISO 8601 datetime — only return entries after this timestamp"
        }
      },
      "required" => []
    }
  end

  @impl true
  def execute(input, context) do
    project_id = Map.get(context, :project_id)

    case project_id do
      nil ->
        {:error, "project_id is required in context"}

      project_id ->
        path = "/projects/#{project_id}/logs/devlog.md"
        count = Map.get(input, "count", 20)
        category = Map.get(input, "category")
        since_str = Map.get(input, "since")

        content =
          case Synapsis.WorkspaceDocuments.get_by_path(path) do
            nil -> "# Dev Log\n"
            doc -> doc.content_body || "# Dev Log\n"
          end

        entries = fetch_entries(content, count, category, since_str)

        serialized =
          Enum.map(entries, fn e ->
            %{
              timestamp: DateTime.to_iso8601(e.timestamp),
              category: e.category,
              author: e.author,
              content: e.content
            }
          end)

        {:ok, Jason.encode!(serialized)}
    end
  end

  defp fetch_entries(content, count, nil, nil) do
    Synapsis.DevLog.recent(content, count)
  end

  defp fetch_entries(content, count, category, nil) when not is_nil(category) do
    content
    |> Synapsis.DevLog.filter(category: category)
    |> Enum.take(-count)
  end

  defp fetch_entries(content, count, nil, since_str) when not is_nil(since_str) do
    case DateTime.from_iso8601(since_str) do
      {:ok, since, _} ->
        content
        |> Synapsis.DevLog.filter(since: since)
        |> Enum.take(-count)

      _ ->
        Synapsis.DevLog.recent(content, count)
    end
  end

  defp fetch_entries(content, count, category, since_str) do
    since_opt =
      case DateTime.from_iso8601(since_str) do
        {:ok, since, _} -> [since: since]
        _ -> []
      end

    category_opt = if category, do: [category: category], else: []

    content
    |> Synapsis.DevLog.filter(category_opt ++ since_opt)
    |> Enum.take(-count)
  end
end
