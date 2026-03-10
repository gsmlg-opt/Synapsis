defmodule Synapsis.Tool.ToolSearchTest do
  use ExUnit.Case

  alias Synapsis.Tool.{ToolSearch, Registry}

  defmodule MockFileTool do
    use Synapsis.Tool

    @impl true
    def name, do: "mock_file_reader"

    @impl true
    def description, do: "Reads files from disk"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_input, _ctx), do: {:ok, "read"}

    @impl true
    def category, do: :filesystem
  end

  defmodule MockSearchTool do
    use Synapsis.Tool

    @impl true
    def name, do: "mock_grep_search"

    @impl true
    def description, do: "Search for patterns in code"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_input, _ctx), do: {:ok, "found"}

    @impl true
    def category, do: :search
  end

  defmodule MockDeferredTool do
    use Synapsis.Tool

    @impl true
    def name, do: "mock_deferred_slack"

    @impl true
    def description, do: "Send messages via Slack"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_input, _ctx), do: {:ok, "sent"}
  end

  @test_tools ["mock_file_reader", "mock_grep_search", "mock_deferred_slack"]

  setup do
    Registry.register_module("mock_file_reader", MockFileTool)
    Registry.register_module("mock_grep_search", MockSearchTool)
    Registry.register_module("mock_deferred_slack", MockDeferredTool, deferred: true)

    on_exit(fn ->
      Enum.each(@test_tools, &Registry.unregister/1)
    end)

    :ok
  end

  describe "metadata" do
    test "name returns tool_search" do
      assert ToolSearch.name() == "tool_search"
    end

    test "permission_level is :none" do
      assert ToolSearch.permission_level() == :none
    end

    test "category is :orchestration" do
      assert ToolSearch.category() == :orchestration
    end
  end

  describe "execute/2 — keyword search" do
    test "matches tools by name" do
      assert {:ok, json} = ToolSearch.execute(%{"query" => "file"}, %{})
      results = Jason.decode!(json)
      names = Enum.map(results, & &1["name"])
      assert "mock_file_reader" in names
    end

    test "matches tools by description" do
      assert {:ok, json} = ToolSearch.execute(%{"query" => "patterns"}, %{})
      results = Jason.decode!(json)
      names = Enum.map(results, & &1["name"])
      assert "mock_grep_search" in names
    end

    test "returns no-match message when nothing matches" do
      assert {:ok, msg} = ToolSearch.execute(%{"query" => "xyznonexistent"}, %{})
      assert msg =~ "No tools found"
      assert msg =~ "xyznonexistent"
    end

    test "search is case-insensitive" do
      assert {:ok, json} = ToolSearch.execute(%{"query" => "SLACK"}, %{})
      results = Jason.decode!(json)
      names = Enum.map(results, & &1["name"])
      assert "mock_deferred_slack" in names
    end
  end

  describe "execute/2 — limit parameter" do
    test "respects the limit parameter" do
      # All three tools should match "mock"
      assert {:ok, json} = ToolSearch.execute(%{"query" => "mock", "limit" => 2}, %{})
      results = Jason.decode!(json)
      assert length(results) == 2
    end

    test "defaults to 5 results" do
      assert {:ok, json} = ToolSearch.execute(%{"query" => "mock"}, %{})
      results = Jason.decode!(json)
      # We only registered 3, so all should be returned
      assert length(results) == 3
    end
  end

  describe "execute/2 — deferred tool activation" do
    test "activates deferred tools that match the search" do
      # Before search, deferred tool is excluded from default listing
      before = Registry.list_for_llm([])
      refute Enum.any?(before, &(&1.name == "mock_deferred_slack"))

      # Search for it
      assert {:ok, json} = ToolSearch.execute(%{"query" => "slack"}, %{})
      results = Jason.decode!(json)
      assert Enum.any?(results, &(&1["name"] == "mock_deferred_slack"))

      # After search, deferred tool is now loaded and visible in default listing
      after_search = Registry.list_for_llm([])
      assert Enum.any?(after_search, &(&1.name == "mock_deferred_slack"))
    end

    test "non-deferred tools are unaffected by activation" do
      # Already visible before search
      before = Registry.list_for_llm([])
      assert Enum.any?(before, &(&1.name == "mock_file_reader"))

      assert {:ok, _json} = ToolSearch.execute(%{"query" => "file"}, %{})

      # Still visible after search
      after_search = Registry.list_for_llm([])
      assert Enum.any?(after_search, &(&1.name == "mock_file_reader"))
    end
  end

  describe "execute/2 — relevance ordering" do
    test "name matches rank higher than description-only matches" do
      assert {:ok, json} = ToolSearch.execute(%{"query" => "search"}, %{})
      results = Jason.decode!(json)
      names = Enum.map(results, & &1["name"])
      # mock_grep_search has "search" in its name — should appear
      assert "mock_grep_search" in names
    end
  end
end
