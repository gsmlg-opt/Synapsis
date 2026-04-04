defmodule Synapsis.Board do
  @moduledoc """
  Pure functions for parsing, serializing, and mutating kanban board YAML documents.

  All functions are side-effect free — they take data in and return data out.
  """

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

  # Valid column transitions
  @transitions %{
    "backlog" => ["ready", "done"],
    "ready" => ["in_progress", "backlog"],
    "in_progress" => ["review", "ready", "failed"],
    "review" => ["done", "in_progress"],
    "failed" => ["backlog", "done"],
    "done" => []
  }

  @doc """
  Parse a YAML string into a board struct.

  Returns `{:ok, board}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, board()} | {:error, term()}
  def parse(yaml) when is_binary(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, data} ->
        board = normalize_board(data)
        {:ok, board}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Serialize a board struct back to a YAML string.
  """
  @spec serialize(board()) :: String.t()
  def serialize(board) do
    columns_yaml =
      board.columns
      |> Enum.map(fn col ->
        "  - id: #{col["id"] || col[:id]}\n    name: #{col["name"] || col[:name]}"
      end)
      |> Enum.join("\n")

    cards_yaml =
      if Enum.empty?(board.cards) do
        "cards: []"
      else
        cards_str =
          board.cards
          |> Enum.map(&card_to_yaml/1)
          |> Enum.join("\n")

        "cards:\n#{cards_str}"
      end

    """
    version: #{board.version}
    columns:
    #{columns_yaml}
    #{cards_yaml}
    """
    |> String.trim_trailing()
  end

  @doc """
  Add a card to the board with generated UUID id, default column "backlog", and timestamps.

  Returns `{:ok, updated_board}`.
  """
  @spec add_card(board(), map()) :: {:ok, board()}
  def add_card(board, attrs) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    card =
      %{
        "id" => Ecto.UUID.generate(),
        "title" => "",
        "description" => "",
        "column" => "backlog",
        "repo_id" => nil,
        "branch" => nil,
        "worktree_id" => nil,
        "agent_session_id" => nil,
        "plan_ref" => nil,
        "design_refs" => [],
        "priority" => 0,
        "labels" => [],
        "created_at" => now,
        "updated_at" => now
      }
      |> Map.merge(stringify_keys(attrs))

    updated_board = %{board | cards: board.cards ++ [card]}
    {:ok, updated_board}
  end

  @doc """
  Move a card to a target column, validating the transition.

  Returns `{:ok, board}` or `{:error, :invalid_transition | :not_found}`.
  """
  @spec move_card(board(), String.t(), String.t()) ::
          {:ok, board()} | {:error, :invalid_transition | :not_found}
  def move_card(board, card_id, target_column) do
    case find_card_index(board, card_id) do
      nil ->
        {:error, :not_found}

      index ->
        card = Enum.at(board.cards, index)
        from = card["column"] || card[:column]

        if validate_transition(from, target_column) do
          now = DateTime.utc_now() |> DateTime.to_iso8601()
          updated_card = Map.merge(card, %{"column" => target_column, "updated_at" => now})
          updated_cards = List.replace_at(board.cards, index, updated_card)
          {:ok, %{board | cards: updated_cards}}
        else
          {:error, :invalid_transition}
        end
    end
  end

  @doc """
  Update card fields by id.

  Returns `{:ok, board}` or `{:error, :not_found}`.
  """
  @spec update_card(board(), String.t(), map()) :: {:ok, board()} | {:error, :not_found}
  def update_card(board, card_id, attrs) do
    case find_card_index(board, card_id) do
      nil ->
        {:error, :not_found}

      index ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()
        card = Enum.at(board.cards, index)
        updated_card = Map.merge(card, stringify_keys(attrs)) |> Map.put("updated_at", now)
        updated_cards = List.replace_at(board.cards, index, updated_card)
        {:ok, %{board | cards: updated_cards}}
    end
  end

  @doc """
  Remove a card from the board.

  Returns `{:ok, board}`.
  """
  @spec remove_card(board(), String.t()) :: {:ok, board()}
  def remove_card(board, card_id) do
    updated_cards = Enum.reject(board.cards, &(get_id(&1) == card_id))
    {:ok, %{board | cards: updated_cards}}
  end

  @doc """
  Find a card by id.

  Returns the card map or nil.
  """
  @spec get_card(board(), String.t()) :: card() | nil
  def get_card(board, card_id) do
    Enum.find(board.cards, &(get_id(&1) == card_id))
  end

  @doc """
  Filter cards by column.
  """
  @spec cards_by_column(board(), String.t()) :: [card()]
  def cards_by_column(board, column) do
    Enum.filter(board.cards, fn card ->
      (card["column"] || card[:column]) == column
    end)
  end

  @doc """
  Check if a column transition is valid.

  Returns boolean.
  """
  @spec validate_transition(String.t(), String.t()) :: boolean()
  def validate_transition(from, to) do
    allowed = Map.get(@transitions, from, [])
    to in allowed
  end

  # Private helpers

  defp normalize_board(data) when is_map(data) do
    %{
      version: data["version"] || 1,
      columns: normalize_columns(data["columns"] || []),
      cards: normalize_cards(data["cards"] || [])
    }
  end

  defp normalize_columns(columns) when is_list(columns) do
    Enum.map(columns, fn col ->
      %{"id" => col["id"] || col[:id], "name" => col["name"] || col[:name]}
    end)
  end

  defp normalize_cards(cards) when is_list(cards) do
    Enum.map(cards, fn card ->
      %{
        "id" => card["id"] || card[:id] || Ecto.UUID.generate(),
        "title" => card["title"] || card[:title] || "",
        "description" => card["description"] || card[:description] || "",
        "column" => card["column"] || card[:column] || "backlog",
        "repo_id" => card["repo_id"] || card[:repo_id],
        "branch" => card["branch"] || card[:branch],
        "worktree_id" => card["worktree_id"] || card[:worktree_id],
        "agent_session_id" => card["agent_session_id"] || card[:agent_session_id],
        "plan_ref" => card["plan_ref"] || card[:plan_ref],
        "design_refs" => card["design_refs"] || card[:design_refs] || [],
        "priority" => card["priority"] || card[:priority] || 0,
        "labels" => card["labels"] || card[:labels] || [],
        "created_at" => card["created_at"] || card[:created_at] || DateTime.utc_now() |> DateTime.to_iso8601(),
        "updated_at" => card["updated_at"] || card[:updated_at] || DateTime.utc_now() |> DateTime.to_iso8601()
      }
    end)
  end

  defp find_card_index(board, card_id) do
    Enum.find_index(board.cards, &(get_id(&1) == card_id))
  end

  defp get_id(card), do: card["id"] || card[:id]

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp card_to_yaml(card) do
    id = card["id"] || card[:id] || ""
    title = card["title"] || card[:title] || ""
    description = card["description"] || card[:description] || ""
    column = card["column"] || card[:column] || "backlog"
    priority = card["priority"] || card[:priority] || 0
    labels = card["labels"] || card[:labels] || []
    design_refs = card["design_refs"] || card[:design_refs] || []
    created_at = card["created_at"] || card[:created_at] || ""
    updated_at = card["updated_at"] || card[:updated_at] || ""

    optional_fields =
      [
        {"repo_id", card["repo_id"] || card[:repo_id]},
        {"branch", card["branch"] || card[:branch]},
        {"worktree_id", card["worktree_id"] || card[:worktree_id]},
        {"agent_session_id", card["agent_session_id"] || card[:agent_session_id]},
        {"plan_ref", card["plan_ref"] || card[:plan_ref]}
      ]
      |> Enum.filter(fn {_, v} -> v != nil end)
      |> Enum.map(fn {k, v} -> "    #{k}: #{v}" end)
      |> Enum.join("\n")

    labels_yaml =
      if Enum.empty?(labels) do
        "    labels: []"
      else
        items = labels |> Enum.map(&"      - #{&1}") |> Enum.join("\n")
        "    labels:\n#{items}"
      end

    design_refs_yaml =
      if Enum.empty?(design_refs) do
        "    design_refs: []"
      else
        items = design_refs |> Enum.map(&"      - #{&1}") |> Enum.join("\n")
        "    design_refs:\n#{items}"
      end

    base = """
      - id: #{id}
        title: "#{String.replace(title, ~s("), ~s(\\\"))}"
        description: "#{String.replace(description, ~s("), ~s(\\\"))}"
        column: #{column}
        priority: #{priority}
    """

    [
      String.trim_trailing(base),
      if(optional_fields != "", do: optional_fields, else: nil),
      "    " <> String.trim_leading(labels_yaml),
      "    " <> String.trim_leading(design_refs_yaml),
      "    created_at: #{created_at}",
      "    updated_at: #{updated_at}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n")
  end
end
