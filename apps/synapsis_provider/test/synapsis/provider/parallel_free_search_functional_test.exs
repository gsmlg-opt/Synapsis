defmodule Synapsis.Provider.ParallelFreeSearchFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.WebSearch
  alias Synapsis.Provider.WebSearch.{Parallel, ParallelFree}

  test "free endpoint defaults to the hosted MCP and preserves a trusted complete override" do
    assert ParallelFree.endpoint(nil) == {:ok, "https://search.parallel.ai/mcp"}

    for endpoint <- [
          "https://proxy.example/custom/mcp?view=ordinary",
          "http://localhost:4657/ordinary/mcp"
        ] do
      assert ParallelFree.endpoint(endpoint) == {:ok, endpoint}

      assert {:ok, config} =
               WebSearch.prepare_config(%{provider: "parallel-free", base_url: endpoint})

      assert config.base_url == endpoint
      assert WebSearch.prepare_config(config) == {:ok, config}
    end

    assert {:ok, config} = WebSearch.prepare_config(%{provider: "parallel-free"})
    assert config.base_url == "https://search.parallel.ai/mcp"
  end

  test "free shared preparation trims deduplicates and retains ordinary session and model inputs" do
    raw = %{
      "objective" => " Compare ordinary sources 雪🙂 ",
      "search_queries" => [" first source 雪 ", "first source 雪", " ", " second source 🙂 "],
      "count" => " 2e0 ",
      "session_id" => " supplied-session ",
      "client_model" => " gpt-6-astra "
    }

    prepared = %{
      "objective" => "Compare ordinary sources 雪🙂",
      "search_queries" => ["first source 雪", "second source 🙂"],
      "count" => 2,
      "session_id" => "supplied-session",
      "client_model" => "gpt-6-astra"
    }

    config = %{provider: "parallel-free", count: 3}
    assert Parallel.prepare(config, raw) == {:ok, prepared}
    assert WebSearch.prepare(config, raw) == {:ok, prepared}
    assert WebSearch.prepare(config, prepared) == {:ok, prepared}
    assert raw["objective"] == " Compare ordinary sources 雪🙂 "
    assert raw["session_id"] == " supplied-session "
  end

  test "MCP arguments use the local search session model_name and keyword objective fallback" do
    config = %{provider: "parallel-free", count: 3}

    assert {:ok, args} =
             WebSearch.prepare(config, %{
               "search_queries" => [" first source ", "second source"],
               "client_model" => " claude-opus-4-7 "
             })

    assert ParallelFree.tool_arguments(args, "local-generated-session") == %{
             "objective" => "first source second source",
             "search_queries" => ["first source", "second source"],
             "session_id" => "local-generated-session",
             "model_name" => "claude-opus-4-7"
           }

    assert {:ok, cli} = WebSearch.prepare(config, %{"query" => " CLI ordinary 雪🙂 "})

    assert ParallelFree.tool_arguments(cli, "local-cli-session") == %{
             "objective" => "CLI ordinary 雪🙂",
             "search_queries" => ["CLI ordinary 雪🙂"],
             "session_id" => "local-cli-session"
           }
  end

  test "structured content takes precedence and JSON text fallback preserves complete raw rows" do
    config = %{provider: "parallel-free", count: 2}

    assert {:ok, args} =
             WebSearch.prepare(config, %{
               "objective" => " Compare sources ",
               "search_queries" => [" ordinary sources "]
             })

    payload = %{
      "search_id" => "ordinary-search",
      "session_id" => "server-payload-session",
      "warnings" => [%{"code" => "source_notice", "detail" => " Ordinary notice 雪 "}],
      "usage" => [%{"name" => "search", "count" => 1}],
      "results" =>
        for(
          index <- 1..3,
          do: %{
            "title" => " Source #{index} 雪 ",
            "url" => "https://SOURCES.EXAMPLE:443/research/#{index}?q=ordinary#part",
            "publish_date" => " 2026-11-0#{index} ",
            "excerpts" => [" Passage #{index} 雪 ", " Context #{index} 🙂 "]
          }
        )
    }

    expected = %{
      "provider" => "parallel-free",
      "objective" => "Compare sources",
      "searchQueries" => ["ordinary sources"],
      "count" => 2,
      "searchId" => "ordinary-search",
      "sessionId" => "local-search-session",
      "warnings" => payload["warnings"],
      "usage" => payload["usage"],
      "results" =>
        for(
          index <- 1..2,
          do: %{
            "title" => " Source #{index} 雪 ",
            "url" => "https://SOURCES.EXAMPLE:443/research/#{index}?q=ordinary#part",
            "description" => " Passage #{index} 雪 \n\n Context #{index} 🙂 ",
            "siteName" => "sources.example",
            "published" => " 2026-11-0#{index} ",
            "excerpts" => [" Passage #{index} 雪 ", " Context #{index} 🙂 "]
          }
        )
    }

    for tool_result <- [
          %{
            "structuredContent" => payload,
            "content" => [%{"type" => "text", "text" => Jason.encode!(%{"results" => []})}]
          },
          %{"content" => [%{"type" => "text", "text" => Jason.encode!(payload)}]}
        ] do
      assert ParallelFree.result(config, args, tool_result, "local-search-session") ==
               {:ok, expected}
    end
  end
end
