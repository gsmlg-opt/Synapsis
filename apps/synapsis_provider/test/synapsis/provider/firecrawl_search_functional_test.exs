defmodule Synapsis.Provider.FirecrawlSearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.WebSearch

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "normal search options are privately normalized before the v2 request", ctx do
    stub(ctx, %{"success" => true, "data" => []})

    arguments = %{
      "query" => " ordinary query ",
      "count" => 6,
      "sources" => [" web ", "", " news ", " "],
      "categories" => [" research ", ""],
      "include_domains" => [" example.org ", ""],
      "tbs" => " qdr:w ",
      "location" => " Berlin, Germany ",
      "country" => " DE ",
      "scrape_results" => true
    }

    assert {:ok, result} = WebSearch.search(config(ctx), arguments)
    assert_receive {:http, body, headers, ""}

    assert body == %{
             "query" => " ordinary query ",
             "limit" => 6,
             "sources" => ["web", "news"],
             "categories" => ["research"],
             "includeDomains" => ["example.org"],
             "tbs" => "qdr:w",
             "location" => "Berlin, Germany",
             "country" => "DE",
             "scrapeOptions" => %{"formats" => ["markdown"]}
           }

    assert Map.new(headers)["accept"] == "application/json"
    assert Map.new(headers)["content-type"] == "application/json"
    assert result["query"] == " ordinary query "
    assert result["provider"] == "firecrawl"
    assert arguments["sources"] == [" web ", "", " news ", " "]
    assert arguments["tbs"] == " qdr:w "
  end

  test "empty optional values are omitted and excluded domains retain ordinary order", ctx do
    stub(ctx, %{"data" => []})

    assert {:ok, _} =
             WebSearch.search(config(ctx), %{
               "query" => "minimal",
               "sources" => ["", " "],
               "categories" => [],
               "include_domains" => [""],
               "exclude_domains" => [],
               "tbs" => " ",
               "location" => "",
               "country" => " ",
               "scrape_results" => false
             })

    assert_receive {:http, %{"query" => "minimal", "limit" => 5} = body, _, ""}
    assert map_size(body) == 2

    assert {:ok, _} =
             WebSearch.search(config(ctx), %{
               "query" => "exclude",
               "exclude_domains" => [" example.org ", "", " example.net "]
             })

    assert_receive {:http, body, _, ""}

    assert body == %{
             "query" => "exclude",
             "limit" => 5,
             "excludeDomains" => ["example.org", "example.net"]
           }
  end

  test "configured keyful and free search counts reach the same endpoint format", ctx do
    stub(ctx, %{"results" => [%{"url" => "https://www.example.org/page"}]})

    for {provider, api_key} <- [{"firecrawl", "ordinary-fixture"}, {"firecrawl-free", nil}] do
      provider_config = %{config(ctx) | provider: provider, api_key: api_key, count: 3}

      assert {:ok, result} = WebSearch.search(provider_config, %{"query" => "configured"})
      assert_receive {:http, %{"query" => "configured", "limit" => 3}, _, ""}
      assert result["provider"] == provider
      assert result["count"] == 1
      assert [%{"siteName" => "example.org"}] = result["results"]
    end
  end

  test "empty string fields fall through the complete ordered result alternatives", ctx do
    timestamp = "2026-10-28T01:02:03.123+08:00"

    stub(ctx, %{
      "data" => [
        %{
          "url" => "",
          "sourceURL" => "https://www.example.org/first",
          "sourceUrl" => "https://unused.example/first",
          "title" => "",
          "description" => "",
          "snippet" => "",
          "summary" => "Summary first",
          "markdown" => "",
          "content" => "",
          "text" => "Text first",
          "publishedDate" => "",
          "published" => "",
          "metadata" => %{
            "title" => "Metadata first",
            "publishedTime" => "",
            "publishedDate" => timestamp
          }
        },
        %{
          "url" => "",
          "sourceURL" => "",
          "sourceUrl" => "http://www.example.net/second?query=ordinary",
          "title" => " Second ",
          "description" => "",
          "snippet" => "Snippet second",
          "markdown" => "",
          "content" => "Content second",
          "publishedDate" => timestamp
        },
        %{
          "url" => "",
          "sourceURL" => "",
          "sourceUrl" => "",
          "metadata" => %{
            "sourceURL" => "https://www.example.com/third",
            "title" => "Metadata third",
            "publishedTime" => timestamp
          },
          "description" => "Description third",
          "markdown" => "Markdown third"
        },
        %{
          "url" => "https://www.example.edu/fourth",
          "title" => "Fourth",
          "published" => timestamp
        }
      ]
    })

    assert {:ok, result} =
             WebSearch.search(config(ctx), %{"query" => "fallbacks", "scrape_results" => true})

    assert result["results"] == [
             %{
               "title" => "Metadata first",
               "url" => "https://www.example.org/first",
               "description" => "Summary first",
               "content" => "Text first",
               "published" => timestamp,
               "siteName" => "example.org"
             },
             %{
               "title" => " Second ",
               "url" => "http://www.example.net/second?query=ordinary",
               "description" => "Snippet second",
               "content" => "Content second",
               "published" => timestamp,
               "siteName" => "example.net"
             },
             %{
               "title" => "Metadata third",
               "url" => "https://www.example.com/third",
               "description" => "Description third",
               "content" => "Markdown third",
               "published" => timestamp,
               "siteName" => "example.com"
             },
             %{
               "title" => "Fourth",
               "url" => "https://www.example.edu/fourth",
               "description" => "",
               "published" => timestamp,
               "siteName" => "example.edu"
             }
           ]

    assert result["count"] == 4
  end

  test "every published envelope shape preserves provider row order" do
    first = %{"title" => "First", "url" => "https://example.org/first"}
    second = %{"title" => "Second", "url" => "https://example.org/second"}
    third = %{"title" => "Third", "url" => "https://example.org/third"}
    rows = [first, second, third]

    for payload <- [
          %{"data" => rows},
          %{"results" => rows},
          %{"data" => %{"results" => rows}},
          %{"data" => %{"data" => rows}},
          %{"data" => %{"web" => [first], "news" => [second], "images" => [third]}},
          %{"data" => %{"web" => [], "news" => rows, "images" => []}},
          %{"web" => %{"results" => rows}}
        ] do
      fixture = Gaoxy.Test.open()

      try do
        ctx = %{fixture: fixture}
        stub(ctx, payload)
        assert {:ok, result} = WebSearch.search(config(ctx), %{"query" => "envelope"})
        assert result["count"] == 3
        assert Enum.map(result["results"], & &1["title"]) == ["First", "Second", "Third"]
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  test "the first array envelope wins even when empty" do
    rows = [%{"title" => "Later", "url" => "https://example.org/later"}]

    for payload <- [
          %{"data" => [], "results" => rows},
          %{"results" => [], "data" => %{"results" => rows}},
          %{"data" => %{"results" => [], "data" => rows}},
          %{"data" => %{"data" => [], "web" => rows}},
          %{"data" => %{"web" => []}, "web" => %{"results" => rows}}
        ] do
      fixture = Gaoxy.Test.open()

      try do
        ctx = %{fixture: fixture}
        stub(ctx, payload)
        assert {:ok, result} = WebSearch.search(config(ctx), %{"query" => "empty envelope"})
        assert result["results"] == []
        assert result["count"] == 0
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  test "one hundred ordered records and the configured count remain available", ctx do
    rows =
      for index <- 1..101,
          do: %{"title" => "Source #{index}", "url" => "https://example.org/#{index}"}

    stub(ctx, %{"data" => rows})

    assert {:ok, result} =
             WebSearch.search(%{config(ctx) | count: 100}, %{"query" => "hundred"})

    assert_receive {:http, %{"query" => "hundred", "limit" => 100}, _, ""}
    assert result["count"] == 100
    assert Enum.map(result["results"], & &1["title"]) == Enum.map(1..100, &"Source #{&1}")
  end

  defp config(ctx),
    do: %{
      provider: "firecrawl",
      base_url: Gaoxy.Test.url(ctx.fixture, "/old/base?discard=yes#old-fragment"),
      api_key: "ordinary-fixture",
      timeout_ms: 5000,
      count: 5,
      mode: "web"
    }

  defp stub(ctx, payload) do
    owner = self()

    Gaoxy.Test.stub(ctx.fixture, "POST", "/v2/search", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:http, Jason.decode!(body), conn.req_headers, conn.query_string})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
