defmodule Synapsis.Tool.BoardUpdate do
  @moduledoc "Create, move, update, or remove cards on the project kanban board."
  use Synapsis.Tool

  @impl true
  def name, do: "board_update"

  @impl true
  def description,
    do:
      "Mutate the project kanban board. Supported actions: create_card, move_card, update_card, " <>
        "remove_card."

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :workflow

  @impl true
  def side_effects, do: [:workspace_changed, :board_changed]

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["create_card", "move_card", "update_card", "remove_card"],
          "description" => "The board mutation to perform"
        },
        "card" => %{
          "type" => "object",
          "description" =>
            "Card attributes for create_card (title, description, column, labels, priority, etc.)"
        },
        "card_id" => %{
          "type" => "string",
          "description" => "Card ID for move_card, update_card, or remove_card"
        },
        "column" => %{
          "type" => "string",
          "description" => "Target column for move_card"
        },
        "fields" => %{
          "type" => "object",
          "description" => "Fields to update for update_card"
        }
      },
      "required" => ["action"]
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

        with {:ok, board} <- load_board(path),
             {:ok, updated_board, message} <- apply_action(board, input),
             {:ok, _doc} <- persist_board(path, updated_board, project_id) do
          Phoenix.PubSub.broadcast(
            Synapsis.PubSub,
            "project:#{project_id}:board",
            {:board_changed, project_id, input["action"]}
          )

          {:ok, message}
        end
    end
  end

  defp load_board(path) do
    case Synapsis.WorkspaceDocuments.get_by_path(path) do
      nil ->
        default_board = %{
          version: 1,
          columns: [
            %{"id" => "backlog", "name" => "Backlog"},
            %{"id" => "ready", "name" => "Ready"},
            %{"id" => "in_progress", "name" => "In Progress"},
            %{"id" => "review", "name" => "Review"},
            %{"id" => "done", "name" => "Done"}
          ],
          cards: []
        }

        {:ok, default_board}

      doc ->
        content = doc.content_body || ""

        case Synapsis.Board.parse(content) do
          {:ok, board} -> {:ok, board}
          {:error, reason} -> {:error, "Failed to parse board: #{inspect(reason)}"}
        end
    end
  end

  defp apply_action(board, %{"action" => "create_card"} = input) do
    attrs = Map.get(input, "card", %{})

    case Synapsis.Board.add_card(board, attrs) do
      {:ok, updated} ->
        card_id = List.last(updated.cards)["id"]
        {:ok, updated, Jason.encode!(%{action: "created", card_id: card_id})}
    end
  end

  defp apply_action(board, %{"action" => "move_card"} = input) do
    card_id = Map.get(input, "card_id")
    column = Map.get(input, "column")

    case Synapsis.Board.move_card(board, card_id, column) do
      {:ok, updated} ->
        {:ok, updated, Jason.encode!(%{action: "moved", card_id: card_id, column: column})}

      {:error, :not_found} ->
        {:error, "Card #{card_id} not found"}

      {:error, :invalid_transition} ->
        {:error, "Invalid column transition for card #{card_id}"}
    end
  end

  defp apply_action(board, %{"action" => "update_card"} = input) do
    card_id = Map.get(input, "card_id")
    fields = Map.get(input, "fields", %{})

    case Synapsis.Board.update_card(board, card_id, fields) do
      {:ok, updated} ->
        {:ok, updated, Jason.encode!(%{action: "updated", card_id: card_id})}

      {:error, :not_found} ->
        {:error, "Card #{card_id} not found"}
    end
  end

  defp apply_action(board, %{"action" => "remove_card"} = input) do
    card_id = Map.get(input, "card_id")

    case Synapsis.Board.remove_card(board, card_id) do
      {:ok, updated} ->
        {:ok, updated, Jason.encode!(%{action: "removed", card_id: card_id})}
    end
  end

  defp apply_action(_board, %{"action" => action}) do
    {:error, "Unknown action: #{action}"}
  end

  defp persist_board(path, board, project_id) do
    yaml = Synapsis.Board.serialize(board)

    case Synapsis.WorkspaceDocuments.get_by_path(path) do
      nil ->
        %Synapsis.WorkspaceDocument{}
        |> Synapsis.WorkspaceDocument.changeset(%{
          path: path,
          content_body: yaml,
          content_format: :yaml,
          kind: :document,
          project_id: project_id,
          created_by: "system",
          updated_by: "system"
        })
        |> Synapsis.WorkspaceDocuments.insert()

      doc ->
        doc
        |> Synapsis.WorkspaceDocument.changeset(%{
          content_body: yaml,
          updated_by: "system"
        })
        |> Synapsis.WorkspaceDocuments.update()
    end
  end
end
