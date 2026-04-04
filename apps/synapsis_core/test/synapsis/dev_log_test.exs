defmodule Synapsis.DevLogTest do
  use ExUnit.Case, async: true

  alias Synapsis.DevLog

  defp make_entry(opts \\ []) do
    %{
      timestamp: Keyword.get(opts, :timestamp, ~U[2024-03-15 10:30:00Z]),
      category: Keyword.get(opts, :category, "progress"),
      author: Keyword.get(opts, :author, "assistant"),
      content: Keyword.get(opts, :content, "Made some progress on the task.")
    }
  end

  describe "append/2" do
    test "appends entry to empty content" do
      content = "# Dev Log"
      entry = make_entry()

      result = DevLog.append(content, entry)

      assert String.contains?(result, "## 2024-03-15")
      assert String.contains?(result, "### 10:30 — progress [assistant]")
      assert String.contains?(result, "Made some progress on the task.")
    end

    test "appends under new date heading when date not present" do
      content = """
      # Dev Log

      ## 2024-03-14

      ### 09:00 — progress [assistant]
      Previous day entry.
      """

      entry = make_entry(timestamp: ~U[2024-03-15 11:00:00Z], content: "New day entry.")

      result = DevLog.append(content, entry)

      assert String.contains?(result, "## 2024-03-14")
      assert String.contains?(result, "## 2024-03-15")
      assert String.contains?(result, "New day entry.")
      # Both dates present
      assert Regex.scan(~r/## 2024-03-1[45]/, result) |> length() == 2
    end

    test "appends under existing date heading without creating duplicate heading" do
      content = """
      # Dev Log

      ## 2024-03-15

      ### 09:00 — progress [assistant]
      Morning entry.
      """

      entry = make_entry(timestamp: ~U[2024-03-15 14:00:00Z], content: "Afternoon entry.")

      result = DevLog.append(content, entry)

      # Only one date heading for 2024-03-15
      headings = Regex.scan(~r/## 2024-03-15/, result)
      assert length(headings) == 1

      assert String.contains?(result, "Morning entry.")
      assert String.contains?(result, "Afternoon entry.")
      assert String.contains?(result, "### 14:00 — progress [assistant]")
    end

    test "new entries appear after existing ones for same date" do
      content = """
      # Dev Log

      ## 2024-03-15

      ### 09:00 — progress [assistant]
      Morning entry.
      """

      entry = make_entry(timestamp: ~U[2024-03-15 14:00:00Z], content: "Later entry.")
      result = DevLog.append(content, entry)

      morning_pos = :binary.match(result, "Morning entry.") |> elem(0)
      later_pos = :binary.match(result, "Later entry.") |> elem(0)

      assert morning_pos < later_pos
    end
  end

  describe "parse/1" do
    test "parses entries from markdown content" do
      content = """
      # Dev Log

      ## 2024-03-15

      ### 10:30 — progress [assistant]
      Made some progress.

      ### 14:00 — decision [user]
      Decided to use YAML.
      """

      entries = DevLog.parse(content)

      assert length(entries) == 2

      first = hd(entries)
      assert first.category == "progress"
      assert first.author == "assistant"
      assert String.contains?(first.content, "Made some progress.")

      second = Enum.at(entries, 1)
      assert second.category == "decision"
      assert second.author == "user"
      assert String.contains?(second.content, "Decided to use YAML.")
    end

    test "parses timestamp correctly" do
      content = """
      # Dev Log

      ## 2024-03-15

      ### 10:30 — progress [assistant]
      Content here.
      """

      [entry] = DevLog.parse(content)

      assert entry.timestamp.year == 2024
      assert entry.timestamp.month == 3
      assert entry.timestamp.day == 15
      assert entry.timestamp.hour == 10
      assert entry.timestamp.minute == 30
    end

    test "returns empty list for content with no entries" do
      content = "# Dev Log\n\nNo entries yet."
      assert DevLog.parse(content) == []
    end

    test "parses multiple entries across multiple dates" do
      content = """
      # Dev Log

      ## 2024-03-14

      ### 09:00 — progress [assistant]
      Day 1 entry.

      ## 2024-03-15

      ### 10:00 — completion [assistant]
      Day 2 entry.
      """

      entries = DevLog.parse(content)
      assert length(entries) == 2

      assert Enum.at(entries, 0).category == "progress"
      assert Enum.at(entries, 1).category == "completion"
    end

    test "parses build-agent author" do
      content = """
      # Dev Log

      ## 2024-03-15

      ### 10:00 — progress [build-agent:abc123]
      Agent progress.
      """

      [entry] = DevLog.parse(content)
      assert entry.author == "build-agent:abc123"
    end
  end

  describe "recent/2" do
    test "returns last N entries" do
      content = """
      # Dev Log

      ## 2024-03-15

      ### 09:00 — progress [assistant]
      Entry 1.

      ### 10:00 — progress [assistant]
      Entry 2.

      ### 11:00 — progress [assistant]
      Entry 3.
      """

      recent = DevLog.recent(content, 2)

      assert length(recent) == 2
      assert String.contains?(hd(recent).content, "Entry 2.")
      assert String.contains?(Enum.at(recent, 1).content, "Entry 3.")
    end

    test "returns all entries if count exceeds total" do
      content = """
      # Dev Log

      ## 2024-03-15

      ### 09:00 — progress [assistant]
      Only entry.
      """

      recent = DevLog.recent(content, 100)
      assert length(recent) == 1
    end

    test "returns empty list for empty content" do
      assert DevLog.recent("# Dev Log", 5) == []
    end
  end

  describe "filter/2" do
    setup do
      content = """
      # Dev Log

      ## 2024-03-15

      ### 09:00 — progress [assistant]
      Progress entry.

      ### 10:00 — decision [user]
      Decision entry.

      ### 11:00 — blocker [assistant]
      Blocker entry.

      ### 12:00 — progress [user]
      User progress.
      """

      {:ok, content: content}
    end

    test "filters by category", %{content: content} do
      entries = DevLog.filter(content, category: "progress")
      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.category == "progress"))
    end

    test "filters by author", %{content: content} do
      entries = DevLog.filter(content, author: "user")
      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.author == "user"))
    end

    test "filters by since", %{content: content} do
      since = ~U[2024-03-15 10:30:00Z]
      entries = DevLog.filter(content, since: since)
      # Only entries at 11:00 and 12:00
      assert length(entries) == 2
    end

    test "filters by until", %{content: content} do
      until = ~U[2024-03-15 10:30:00Z]
      entries = DevLog.filter(content, until: until)
      # Only entries at 09:00 and 10:00
      assert length(entries) == 2
    end

    test "combines multiple filters", %{content: content} do
      entries = DevLog.filter(content, category: "progress", author: "user")
      assert length(entries) == 1
      assert hd(entries).author == "user"
      assert hd(entries).category == "progress"
    end

    test "returns empty list when no match", %{content: content} do
      entries = DevLog.filter(content, category: "insight")
      assert entries == []
    end
  end
end
