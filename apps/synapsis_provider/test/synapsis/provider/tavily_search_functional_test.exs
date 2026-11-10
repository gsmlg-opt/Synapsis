defmodule Synapsis.Provider.TavilySearchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Provider.WebSearch

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "default search preserves the supplied query and reverse proxy query", ctx do
    stub(ctx, %{"results" => []})

    assert {:ok, result} = WebSearch.search(config(ctx), %{"query" => " authored query "})
    assert_receive {:http, body, headers, "ordinary=yes"}
    assert body == %{"query" => " authored query ", "max_results" => 5}
    assert Map.new(headers)["accept"] == "application/json"
    assert Map.new(headers)["content-type"] == "application/json"
    assert Map.new(headers)["x-client-source"] == "openclaw"

    assert Map.delete(result, "tookMs") == %{
             "query" => " authored query ",
             "provider" => "tavily",
             "count" => 0,
             "results" => []
           }
  end

  test "dedicated optional strings and ordered domain lists are privately normalized", ctx do
    stub(ctx, %{"results" => []})

    arguments = %{
      "query" => "options",
      "count" => 7,
      "search_depth" => " advanced ",
      "topic" => " news ",
      "time_range" => " week ",
      "include_answer" => true,
      "include_domains" => [" example.org ", "", " example.net ", " "],
      "exclude_domains" => [" excluded.example ", ""]
    }

    assert {:ok, _} = WebSearch.search(config(ctx), arguments)
    assert_receive {:http, body, _, _}

    assert body == %{
             "query" => "options",
             "max_results" => 7,
             "search_depth" => "advanced",
             "topic" => "news",
             "time_range" => "week",
             "include_answer" => true,
             "include_domains" => ["example.org", "example.net"],
             "exclude_domains" => ["excluded.example"]
           }

    assert arguments["include_domains"] == [" example.org ", "", " example.net ", " "]
    assert arguments["search_depth"] == " advanced "
  end

  test "blank optional fields and false answer requests are omitted from the wire", ctx do
    stub(ctx, %{"results" => []})

    for options <- [
          %{},
          %{
            "search_depth" => " ",
            "topic" => "",
            "time_range" => " ",
            "include_answer" => false,
            "include_domains" => ["", " "],
            "exclude_domains" => []
          }
        ] do
      assert {:ok, _} = WebSearch.search(config(ctx), Map.put(options, "query", "minimal"))
      assert_receive {:http, body, _, _}
      assert body == %{"query" => "minimal", "max_results" => 5}
    end
  end

  test "ordinary URL normalization and complete ISO and GMT dates preserve ordered metadata",
       ctx do
    timestamp = "2026-10-28T01:02:03.123+08:00"

    stub(ctx, %{
      "results" => [
        %{
          "title" => " First ",
          "url" => "https://SOURCE.EXAMPLE:443/ordinary path?q=hello world#section",
          "content" => " First snippet ",
          "score" => 0.95,
          "published_date" => timestamp
        },
        %{
          "title" => "News",
          "url" => "http://news.example:80/story",
          "content" => "News snippet",
          "score" => 0,
          "published_date" => "Wed, 28 Oct 2026 01:02:03 GMT"
        },
        %{"url" => "https://example.org"}
      ],
      "answer" => " Ordinary answer "
    })

    assert {:ok, result} = WebSearch.search(config(ctx), %{"query" => "metadata"})

    assert result["results"] == [
             %{
               "title" => " First ",
               "url" => "https://source.example/ordinary%20path?q=hello%20world#section",
               "snippet" => " First snippet ",
               "score" => 0.95,
               "published" => timestamp
             },
             %{
               "title" => "News",
               "url" => "http://news.example/story",
               "snippet" => "News snippet",
               "score" => 0,
               "published" => "2026-10-28T01:02:03.000Z"
             },
             %{"title" => "", "url" => "https://example.org", "snippet" => ""}
           ]

    assert result["answer"] == " Ordinary answer "
    assert result["count"] == 3
    refute Map.has_key?(result, "truncated")
  end

  test "configured twenty result limit preserves order and records a longer ordinary page", ctx do
    rows =
      for index <- 1..21 do
        %{
          "title" => "Source #{index}",
          "url" => "https://example.org/#{index}",
          "content" => "Snippet #{index}",
          "score" => index / 100
        }
      end

    stub(ctx, %{"results" => rows, "answer" => "Answer"})

    assert {:ok, result} =
             WebSearch.search(%{config(ctx) | count: 20}, %{"query" => "twenty"})

    assert_receive {:http, %{"query" => "twenty", "max_results" => 20}, _, _}
    assert result["count"] == 20
    assert Enum.map(result["results"], & &1["title"]) == Enum.map(1..20, &"Source #{&1}")
    assert Enum.map(result["results"], & &1["score"]) == Enum.map(1..20, &(&1 / 100))
    assert result["answer"] == "Answer"
    assert result["truncated"] == true
  end

  test "the shared UTF16 budget charges each title and snippet before the answer", ctx do
    title = String.duplicate("🙂", 5_000)
    snippet = String.duplicate("雪", 9_998)

    stub(ctx, %{
      "results" => [
        %{"title" => title, "url" => "https://example.org/first", "content" => snippet},
        %{"title" => "AB", "url" => "https://example.org/second", "content" => "Later snippet"}
      ],
      "answer" => "Later answer"
    })

    assert {:ok, result} = WebSearch.search(config(ctx), %{"query" => "budget"})

    assert [
             %{"title" => ^title, "snippet" => ^snippet},
             %{"title" => "AB", "snippet" => ""}
           ] = result["results"]

    assert result["answer"] == ""
    assert result["truncated"] == true
  end

  defp config(ctx),
    do: %{
      provider: "tavily",
      base_url: Gaoxy.Test.url(ctx.fixture, "/proxy/?ordinary=yes#section"),
      api_key: "ordinary-tavily-fixture",
      timeout_ms: 5000,
      count: 5,
      mode: "web"
    }

  defp stub(ctx, payload) do
    owner = self()

    Gaoxy.Test.stub(ctx.fixture, "POST", "/proxy/search", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:http, Jason.decode!(body), conn.req_headers, conn.query_string})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
