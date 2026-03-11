defmodule Synapsis.Tool.ToolSearch do
  @moduledoc "Search for available tools by keyword. Activates matching deferred tools."
  use Synapsis.Tool

  @impl true
  def name, do: "tool_search"

  @impl true
  def description,
    do: "Search for tools by keyword. Discovers and activates deferred/plugin tools."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "Search keyword(s)"},
        "limit" => %{"type" => "integer", "description" => "Max results (default: 5)"}
      },
      "required" => ["query"]
    }
  end

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :orchestration

  @impl true
  def execute(input, _context) do
    query = input["query"] |> String.downcase()
    limit = input["limit"] || 5

    # Get all tools including deferred
    all_tools = Synapsis.Tool.Registry.list_for_llm(include_deferred: true)

    # Score and filter by query relevance
    matches =
      all_tools
      |> Enum.map(fn tool ->
        score = relevance_score(tool, query)
        {tool, score}
      end)
      |> Enum.filter(fn {_tool, score} -> score > 0 end)
      |> Enum.sort_by(fn {_tool, score} -> -score end)
      |> Enum.take(limit)
      |> Enum.map(fn {tool, _score} -> tool end)

    # Activate matched deferred tools
    Enum.each(matches, fn tool ->
      Synapsis.Tool.Registry.mark_loaded(tool.name)
    end)

    if Enum.empty?(matches) do
      {:ok, "No tools found matching \"#{input["query"]}\""}
    else
      result =
        Enum.map(matches, fn tool ->
          %{
            "name" => tool.name,
            "description" => tool.description
          }
        end)

      {:ok, Jason.encode!(result)}
    end
  end

  defp relevance_score(tool, query) do
    name_lower = String.downcase(tool.name)
    desc_lower = String.downcase(tool.description)
    query_words = String.split(query)

    name_score = if String.contains?(name_lower, query), do: 10, else: 0

    word_score =
      Enum.reduce(query_words, 0, fn word, acc ->
        cond do
          String.contains?(name_lower, word) -> acc + 5
          String.contains?(desc_lower, word) -> acc + 2
          true -> acc
        end
      end)

    name_score + word_score
  end
end
