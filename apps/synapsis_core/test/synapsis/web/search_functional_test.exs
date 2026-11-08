defmodule Synapsis.Web.SearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Web.Search
  alias Synapsis.Web.Search.Cache

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    counter = start_supervised!({Agent, fn -> [] end})

    if Code.ensure_loaded?(Cache) and is_nil(Process.whereis(Cache)),
      do: start_supervised!(Cache)

    {:ok, fixture: fixture, counter: counter}
  end

  test "Brave web preserves ordinary filters, dates and ordered source metadata", context do
    owner = self()

    stub(context, "GET", "/proxy/res/v1/web/search", fn request ->
      send(owner, {:brave_query, request})

      %{
        "web" => %{
          "results" => [
            %{
              "title" => "First",
              "url" => "https://one.example/article",
              "description" => "First snippet",
              "page_age" => "2026-10-20"
            },
            %{
              "title" => "Second",
              "url" => "https://two.example/article",
              "description" => "Second snippet"
            }
          ]
        }
      }
    end)

    arguments = %{
      "query" => "ordinary source search",
      "count" => 2,
      "country" => "US",
      "search_lang" => "en",
      "ui_lang" => "en-US",
      "date_after" => "2026-10-01",
      "date_before" => "2026-10-21"
    }

    assert {:ok, result} =
             search(context, "brave", arguments, base_path: "/proxy")

    assert_receive {:brave_query, query}

    assert query == %{
             "q" => arguments["query"],
             "count" => "2",
             "country" => "US",
             "search_lang" => "en",
             "ui_lang" => "en-US",
             "freshness" => "2026-10-01to2026-10-21"
           }

    assert result["kind"] == "results"
    assert result["provider"] == "brave"
    assert result["count"] == 2

    assert result["results"] == [
             %{
               "title" => "First",
               "url" => "https://one.example/article",
               "snippet" => "First snippet",
               "published" => "2026-10-20",
               "siteName" => "one.example"
             },
             %{
               "title" => "Second",
               "url" => "https://two.example/article",
               "snippet" => "Second snippet",
               "siteName" => "two.example"
             }
           ]
  end

  test "Brave LLM context selects the distinct endpoint and first snippet", context do
    owner = self()

    stub(context, "GET", "/res/v1/llm/context", fn query ->
      send(owner, {:llm_query, query})

      %{
        "grounding" => %{
          "generic" => [
            %{
              "title" => "Context",
              "url" => "https://source.example/context",
              "snippets" => ["First passage", "Second passage"]
            }
          ]
        },
        "sources" => %{
          "https://source.example/context" => %{
            "age" => [nil, "2026-10-15", nil, "2026-10-15T12:00:00Z"]
          }
        }
      }
    end)

    assert {:ok, result} =
             search(
               context,
               "brave",
               %{
                 "query" => "context search",
                 "count" => 1,
                 "freshness" => "pw",
                 "search_lang" => "en"
               },
               mode: "llm-context"
             )

    assert_receive {:llm_query,
                    %{"q" => "context search", "freshness" => "pw", "search_lang" => "en"}}

    assert result["results"] == [
             %{
               "title" => "Context",
               "url" => "https://source.example/context",
               "snippet" => "First passage",
               "published" => "2026-10-15T12:00:00Z",
               "siteName" => "source.example"
             }
           ]

    assert Map.keys(result) |> Enum.sort() ==
             ~w(count kind provider query results tookMs)
  end

  test "Tavily dedicated options retain twenty scores and answer while generic output closes at ten",
       context do
    owner = self()

    rows =
      for index <- 1..20 do
        %{
          "title" => "Tavily #{index}",
          "url" => "https://tavily.example/#{index}",
          "content" => "Passage #{index}",
          "score" => index / 20,
          "published_date" => "2026-10-19"
        }
      end

    stub(context, "POST", "/proxy/search", fn body ->
      send(owner, {:tavily_body, body})
      %{"results" => rows, "answer" => "A cited answer"}
    end)

    args = %{
      "query" => "Tavily ordinary",
      "count" => 20,
      "search_depth" => "advanced",
      "topic" => "news",
      "include_answer" => true,
      "time_range" => "week",
      "include_domains" => ["tavily.example"]
    }

    assert {:ok, rich} = search(context, "tavily", args, generic: false, base_path: "/proxy")
    assert_receive {:tavily_body, body}

    assert Map.take(body, Map.keys(args) -- ["count"]) == Map.delete(args, "count")
    assert body["max_results"] == 20
    assert rich["count"] == 20
    assert rich["answer"] == "A cited answer"
    assert Enum.map(rich["results"], & &1["score"]) == Enum.map(1..20, &(&1 / 20))
    assert Enum.map(rich["results"], & &1["snippet"]) == Enum.map(1..20, &"Passage #{&1}")

    assert {:ok, generic} = search(context, "tavily", args, base_path: "/proxy")
    assert generic["kind"] == "results"
    assert generic["count"] == 10
    assert generic["truncated"] == true

    assert Enum.map(generic["results"], & &1["url"]) ==
             Enum.map(1..10, &"https://tavily.example/#{&1}")

    assert Enum.all?(
             generic["results"],
             &(Map.keys(&1) |> Enum.sort() == ~w(published snippet title url))
           )

    refute Map.has_key?(generic, "answer")
  end

  test "Firecrawl search preserves its rich source envelopes, one hundred rows and scraped Markdown",
       context do
    owner = self()

    rows =
      for index <- 1..100 do
        %{
          "title" => "Firecrawl #{index}",
          "url" => "https://www.firecrawl.example/#{index}",
          "description" => "Summary #{index}",
          "markdown" => "# Document #{index}",
          "publishedDate" => "2026-10-18"
        }
      end

    envelopes = [
      %{"data" => Enum.take(rows, 2)},
      %{"results" => Enum.take(rows, 2)},
      %{"data" => %{"results" => Enum.take(rows, 2)}},
      %{"data" => %{"data" => Enum.take(rows, 2)}},
      %{"data" => %{"web" => [hd(rows)], "news" => [Enum.at(rows, 1)], "images" => []}},
      %{"web" => %{"results" => Enum.take(rows, 2)}}
    ]

    by_query =
      envelopes
      |> Enum.with_index()
      |> Map.new(fn {envelope, index} -> {"envelope #{index}", envelope} end)

    stub(context, "POST", "/v2/search", fn body ->
      send(owner, {:firecrawl_body, body})

      if body["query"] == "Firecrawl ordinary",
        do: %{"success" => true, "data" => %{"web" => rows}},
        else: Map.fetch!(by_query, body["query"])
    end)

    args = %{
      "query" => "Firecrawl ordinary",
      "count" => 100,
      "sources" => ["web"],
      "categories" => ["research"],
      "include_domains" => ["firecrawl.example"],
      "tbs" => "qdr:w",
      "location" => "Berlin",
      "country" => "DE",
      "scrape_results" => true
    }

    assert {:ok, rich} =
             search(context, "firecrawl", args, generic: false, base_path: "/discarded")

    assert_receive {:firecrawl_body, body}

    assert body == %{
             "query" => args["query"],
             "limit" => 100,
             "sources" => ["web"],
             "categories" => ["research"],
             "includeDomains" => ["firecrawl.example"],
             "tbs" => "qdr:w",
             "location" => "Berlin",
             "country" => "DE",
             "scrapeOptions" => %{"formats" => ["markdown"]}
           }

    assert rich["count"] == 100
    assert Enum.map(rich["results"], & &1["content"]) == Enum.map(1..100, &"# Document #{&1}")
    assert Enum.all?(rich["results"], &(&1["siteName"] == "firecrawl.example"))

    for {_envelope, index} <- Enum.with_index(envelopes) do
      assert {:ok, result} =
               search(context, "firecrawl", %{"query" => "envelope #{index}", "count" => 2})

      assert Enum.map(result["results"], & &1["url"]) ==
               ["https://www.firecrawl.example/1", "https://www.firecrawl.example/2"]
    end
  end

  test "successful repeat and option-specific search cache preserve duration and expire normally",
       context do
    stub(context, "POST", "/search", fn _ ->
      %{
        "results" => [
          %{"title" => "Cached", "url" => "https://cache.example", "content" => "Body"}
        ]
      }
    end)

    args = %{"query" => "ordinary cached query", "count" => 1}
    assert {:ok, first} = search(context, "tavily", args)
    assert {:ok, second} = search(context, "tavily", args)
    assert second == Map.put(first, "cached", true)
    assert length(Agent.get(context.counter, & &1)) == 1

    assert {:ok, _} = search(context, "tavily", Map.put(args, "count", 2))
    assert length(Agent.get(context.counter, & &1)) == 2

    expiring = Map.put(args, "query", "short ordinary cache")
    assert {:ok, _} = search(context, "tavily", expiring, cache_ttl_ms: 30)
    Process.sleep(40)
    assert {:ok, after_expiry} = search(context, "tavily", expiring, cache_ttl_ms: 30)
    refute Map.has_key?(after_expiry, "cached")
    assert length(Agent.get(context.counter, & &1)) == 4
  end

  test "successful searches with caching disabled preserve all one hundred shared entries",
       context do
    entries =
      for index <- 1..100 do
        result = %{
          "kind" => "results",
          "provider" => "tavily",
          "query" => "Stored ordinary search #{index}",
          "count" => 1,
          "results" => [
            %{
              "title" => "Stored source #{index}",
              "url" => "https://stored.example/#{index}",
              "snippet" => "Stored passage #{index}"
            }
          ],
          "tookMs" => index
        }

        key = make_ref()
        assert :ok = Cache.put(key, result, 900_000)
        {key, result}
      end

    for {key, result} <- entries, do: assert(Cache.get(key) == {:ok, result})

    stub(context, "POST", "/search", fn _ ->
      %{
        "results" => [
          %{
            "title" => "Live source",
            "url" => "https://live.example",
            "content" => "Live passage"
          }
        ]
      }
    end)

    args = %{"query" => "Ordinary search without cache", "count" => 1}
    assert {:ok, first} = search(context, "tavily", args, cache_ttl_ms: 0)
    assert {:ok, second} = search(context, "tavily", args, cache_ttl_ms: 0)
    assert first["count"] == 1
    assert second["results"] == first["results"]
    assert length(Agent.get(context.counter, & &1)) == 2

    for {key, result} <- entries, do: assert(Cache.get(key) == {:ok, result})
  end

  test "generic output reserves all source URLs before its shared twenty-thousand character budget",
       context do
    rows =
      for index <- 1..10 do
        %{
          "title" => "Source #{index}",
          "url" => "https://budget.example/#{index}",
          "content" => String.duplicate("text ", 1_000)
        }
      end

    stub(context, "POST", "/search", fn _ -> %{"results" => rows} end)

    assert {:ok, result} =
             search(context, "tavily", %{"query" => "ordinary content budget", "count" => 10})

    assert result["truncated"] == true

    assert Enum.map(result["results"], & &1["url"]) ==
             Enum.map(1..10, &"https://budget.example/#{&1}")

    assert result["results"]
           |> Enum.flat_map(&Map.values/1)
           |> Enum.map(&String.length/1)
           |> Enum.sum() <= 20_000
  end

  defp search(context, provider, arguments, opts \\ []) do
    base_url =
      case Keyword.get(opts, :base_path) do
        nil -> Gaoxy.Test.url(context.fixture)
        path -> Gaoxy.Test.url(context.fixture, path)
      end

    config = %{
      provider: provider,
      base_url: base_url,
      api_key: "ordinary-fixture-key",
      credential_version: <<1, 2, 3>>,
      timeout_ms: 5_000,
      cache_ttl_ms: Keyword.get(opts, :cache_ttl_ms, 900_000),
      count: 5,
      mode: Keyword.get(opts, :mode, "web")
    }

    Search.search(arguments["query"],
      search_config: config,
      arguments: arguments,
      generic: Keyword.get(opts, :generic, true),
      timeout: 5_000,
      result_limit: 1_000_000
    )
  end

  defp stub(context, method, path, response) do
    Gaoxy.Test.stub(context.fixture, method, path, fn conn ->
      request =
        if method == "GET" do
          Plug.Conn.fetch_query_params(conn).query_params
        else
          {:ok, body, _conn} = Plug.Conn.read_body(conn)
          Jason.decode!(body)
        end

      Agent.update(context.counter, &[{method, path, request} | &1])
      payload = response.(request)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
