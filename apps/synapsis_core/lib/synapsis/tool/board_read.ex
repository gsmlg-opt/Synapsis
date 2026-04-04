defmodule Synapsis.Tool.BoardRead do
  @moduledoc "Read the project kanban board, optionally filtered by column, repo, or label."
  use Synapsis.Tool

  @impl true
  def name, do: "board_read"

  @impl true
  def description,
    do:
      "Read the project kanban board. Optionally filter by column, repo_id, or label. " <>
        "Returns cards as JSON."

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :workflow

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "column" => %{
          "type" => "string",
          "description" => "Filter cards by column (e.g. backlog, ready, in_progress, review, done)"
        },
        "repo_id" => %{
          "type" => "string",
          "description" => "Filter cards associated with a specific repo"
        },
        "label" => %{
          "type" => "string",
          "description" => "Filter cards that have this label"
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
        path = "/projects/#{project_id}/board.yaml"

        case Synapsis.WorkspaceDocuments.get_by_path(path) do
          nil ->
            {:ok, Jason.encode!(%{version: 1, columns: default_columns(), cards: []})}

          doc ->
            content = doc.content_body || ""

            case Synapsis.Board.parse(content) do
              {:ok, board} ->
                cards = filter_cards(board.cards, input)

                result = %{
                  version: board.version,
                  columns: board.columns,
                  cards: cards
                }

                {:ok, Jason.encode!(result)}

              {:error, reason} ->
                {:error, "Failed to parse board: #{inspect(reason)}"}
            end
        end
    end
  end

  defp filter_cards(cards, input) do
    cards
    |> maybe_filter_column(Map.get(input, "column"))
    |> maybe_filter_repo(Map.get(input, "repo_id"))
    |> maybe_filter_label(Map.get(input, "label"))
  end

  defp maybe_filter_column(cards, nil), do: cards

  defp maybe_filter_column(cards, column) do
    Enum.filter(cards, fn card ->
      (card["column"] || card[:column]) == column
    end)
  end

  defp maybe_filter_repo(cards, nil), do: cards

  defp maybe_filter_repo(cards, repo_id) do
    Enum.filter(cards, fn card ->
      (card["repo_id"] || card[:repo_id]) == repo_id
    end)
  end

  defp maybe_filter_label(cards, nil), do: cards

  defp maybe_filter_label(cards, label) do
    Enum.filter(cards, fn card ->
      labels = card["labels"] || card[:labels] || []
      label in labels
    end)
  end

  defp default_columns do
    [
      %{"id" => "backlog", "name" => "Backlog"},
      %{"id" => "ready", "name" => "Ready"},
      %{"id" => "in_progress", "name" => "In Progress"},
      %{"id" => "review", "name" => "Review"},
      %{"id" => "done", "name" => "Done"}
    ]
  end
end
