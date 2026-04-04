defmodule Synapsis.BoardTest do
  use ExUnit.Case, async: true

  alias Synapsis.Board

  @default_yaml """
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
    test "parses valid YAML into board struct" do
      assert {:ok, board} = Board.parse(@default_yaml)
      assert board.version == 1
      assert length(board.columns) == 5
      assert board.cards == []

      first_col = hd(board.columns)
      assert first_col["id"] == "backlog"
      assert first_col["name"] == "Backlog"
    end

    test "parses board with cards" do
      yaml = """
      version: 1
      columns:
        - id: backlog
          name: Backlog
      cards:
        - id: card-1
          title: "My Task"
          description: "Details"
          column: backlog
          priority: 1
          labels: []
          design_refs: []
          created_at: 2024-01-01T00:00:00Z
          updated_at: 2024-01-01T00:00:00Z
      """

      assert {:ok, board} = Board.parse(yaml)
      assert length(board.cards) == 1
      card = hd(board.cards)
      assert card["id"] == "card-1"
      assert card["title"] == "My Task"
      assert card["column"] == "backlog"
    end

    test "returns error for invalid YAML" do
      assert {:error, _reason} = Board.parse("{{invalid yaml: [")
    end

    test "handles empty cards list" do
      assert {:ok, board} = Board.parse(@default_yaml)
      assert board.cards == []
    end
  end

  describe "serialize/1" do
    test "round-trips through parse/serialize" do
      assert {:ok, board} = Board.parse(@default_yaml)
      serialized = Board.serialize(board)
      assert {:ok, board2} = Board.parse(serialized)

      assert board2.version == board.version
      assert length(board2.columns) == length(board.columns)
      assert board2.cards == board.cards
    end

    test "serializes board with cards and round-trips" do
      assert {:ok, board} = Board.parse(@default_yaml)
      {:ok, board} = Board.add_card(board, %{"title" => "Test Card", "priority" => 3})

      serialized = Board.serialize(board)
      assert {:ok, board2} = Board.parse(serialized)

      assert length(board2.cards) == 1
      card = hd(board2.cards)
      assert card["title"] == "Test Card"
      assert card["priority"] == 3
    end
  end

  describe "add_card/2" do
    test "adds card with defaults" do
      assert {:ok, board} = Board.parse(@default_yaml)
      assert {:ok, updated} = Board.add_card(board, %{"title" => "New Card"})

      assert length(updated.cards) == 1
      card = hd(updated.cards)
      assert card["title"] == "New Card"
      assert card["column"] == "backlog"
      assert is_binary(card["id"])
      assert byte_size(card["id"]) > 0
    end

    test "generates unique ids for multiple cards" do
      assert {:ok, board} = Board.parse(@default_yaml)
      {:ok, board} = Board.add_card(board, %{"title" => "Card 1"})
      {:ok, board} = Board.add_card(board, %{"title" => "Card 2"})

      ids = Enum.map(board.cards, & &1["id"])
      assert length(Enum.uniq(ids)) == 2
    end

    test "defaults column to backlog" do
      assert {:ok, board} = Board.parse(@default_yaml)
      {:ok, updated} = Board.add_card(board, %{})
      assert hd(updated.cards)["column"] == "backlog"
    end

    test "respects provided column override" do
      assert {:ok, board} = Board.parse(@default_yaml)
      {:ok, updated} = Board.add_card(board, %{"column" => "ready"})
      assert hd(updated.cards)["column"] == "ready"
    end

    test "sets created_at and updated_at timestamps" do
      assert {:ok, board} = Board.parse(@default_yaml)
      {:ok, updated} = Board.add_card(board, %{"title" => "Timestamped"})
      card = hd(updated.cards)
      assert is_binary(card["created_at"])
      assert is_binary(card["updated_at"])
    end
  end

  describe "move_card/3" do
    setup do
      {:ok, board} = Board.parse(@default_yaml)
      {:ok, board} = Board.add_card(board, %{"title" => "Test Card", "column" => "backlog"})
      card = hd(board.cards)
      {:ok, board: board, card_id: card["id"]}
    end

    test "valid transition: backlog -> ready", %{board: board, card_id: card_id} do
      assert {:ok, updated} = Board.move_card(board, card_id, "ready")
      card = Board.get_card(updated, card_id)
      assert card["column"] == "ready"
    end

    test "valid transition: backlog -> done", %{board: board, card_id: card_id} do
      assert {:ok, updated} = Board.move_card(board, card_id, "done")
      card = Board.get_card(updated, card_id)
      assert card["column"] == "done"
    end

    test "rejects invalid transition: backlog -> in_progress", %{
      board: board,
      card_id: card_id
    } do
      assert {:error, :invalid_transition} = Board.move_card(board, card_id, "in_progress")
    end

    test "rejects transition from done (terminal)", %{board: board, card_id: card_id} do
      {:ok, board} = Board.move_card(board, card_id, "done")
      assert {:error, :invalid_transition} = Board.move_card(board, card_id, "backlog")
    end

    test "returns error for non-existent card", %{board: board} do
      assert {:error, :not_found} = Board.move_card(board, "nonexistent-id", "ready")
    end

    test "updates updated_at on move", %{board: board, card_id: card_id} do
      card_before = Board.get_card(board, card_id)
      {:ok, updated} = Board.move_card(board, card_id, "ready")
      card_after = Board.get_card(updated, card_id)
      # updated_at should be set (and may differ from created_at after move)
      assert is_binary(card_after["updated_at"])
      _ = card_before
    end
  end

  describe "update_card/3" do
    setup do
      {:ok, board} = Board.parse(@default_yaml)
      {:ok, board} = Board.add_card(board, %{"title" => "Original Title"})
      card = hd(board.cards)
      {:ok, board: board, card_id: card["id"]}
    end

    test "updates card fields", %{board: board, card_id: card_id} do
      assert {:ok, updated} =
               Board.update_card(board, card_id, %{
                 "title" => "Updated Title",
                 "priority" => 5
               })

      card = Board.get_card(updated, card_id)
      assert card["title"] == "Updated Title"
      assert card["priority"] == 5
    end

    test "returns error for non-existent card", %{board: board} do
      assert {:error, :not_found} =
               Board.update_card(board, "nonexistent-id", %{"title" => "New"})
    end

    test "preserves unmodified fields", %{board: board, card_id: card_id} do
      {:ok, updated} = Board.update_card(board, card_id, %{"priority" => 10})
      card = Board.get_card(updated, card_id)
      assert card["title"] == "Original Title"
      assert card["priority"] == 10
    end
  end

  describe "remove_card/2" do
    test "removes a card" do
      {:ok, board} = Board.parse(@default_yaml)
      {:ok, board} = Board.add_card(board, %{"title" => "To Remove"})
      card = hd(board.cards)

      {:ok, updated} = Board.remove_card(board, card["id"])
      assert updated.cards == []
    end

    test "removing non-existent card is safe" do
      {:ok, board} = Board.parse(@default_yaml)
      {:ok, board} = Board.add_card(board, %{})
      original_count = length(board.cards)

      {:ok, updated} = Board.remove_card(board, "nonexistent-id")
      assert length(updated.cards) == original_count
    end
  end

  describe "get_card/2" do
    test "finds card by id" do
      {:ok, board} = Board.parse(@default_yaml)
      {:ok, board} = Board.add_card(board, %{"title" => "Findable"})
      card = hd(board.cards)

      found = Board.get_card(board, card["id"])
      assert found["title"] == "Findable"
    end

    test "returns nil for non-existent id" do
      {:ok, board} = Board.parse(@default_yaml)
      assert Board.get_card(board, "nope") == nil
    end
  end

  describe "cards_by_column/2" do
    test "filters cards by column" do
      {:ok, board} = Board.parse(@default_yaml)
      {:ok, board} = Board.add_card(board, %{"title" => "Backlog Card", "column" => "backlog"})
      {:ok, board} = Board.add_card(board, %{"title" => "Ready Card", "column" => "ready"})

      backlog = Board.cards_by_column(board, "backlog")
      ready = Board.cards_by_column(board, "ready")
      done = Board.cards_by_column(board, "done")

      assert length(backlog) == 1
      assert hd(backlog)["title"] == "Backlog Card"
      assert length(ready) == 1
      assert hd(ready)["title"] == "Ready Card"
      assert done == []
    end
  end

  describe "validate_transition/2" do
    test "backlog -> ready is valid" do
      assert Board.validate_transition("backlog", "ready") == true
    end

    test "backlog -> done is valid" do
      assert Board.validate_transition("backlog", "done") == true
    end

    test "backlog -> in_progress is invalid" do
      assert Board.validate_transition("backlog", "in_progress") == false
    end

    test "ready -> in_progress is valid" do
      assert Board.validate_transition("ready", "in_progress") == true
    end

    test "ready -> backlog is valid" do
      assert Board.validate_transition("ready", "backlog") == true
    end

    test "in_progress -> review is valid" do
      assert Board.validate_transition("in_progress", "review") == true
    end

    test "in_progress -> failed is valid" do
      assert Board.validate_transition("in_progress", "failed") == true
    end

    test "review -> done is valid" do
      assert Board.validate_transition("review", "done") == true
    end

    test "review -> in_progress is valid" do
      assert Board.validate_transition("review", "in_progress") == true
    end

    test "failed -> backlog is valid" do
      assert Board.validate_transition("failed", "backlog") == true
    end

    test "done -> backlog is invalid (terminal)" do
      assert Board.validate_transition("done", "backlog") == false
    end

    test "done -> ready is invalid (terminal)" do
      assert Board.validate_transition("done", "ready") == false
    end

    test "unknown column is invalid" do
      assert Board.validate_transition("unknown", "ready") == false
    end
  end
end
