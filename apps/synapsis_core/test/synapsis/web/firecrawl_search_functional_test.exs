defmodule Synapsis.Web.FirecrawlSearchFunctionalTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.Codex.Web

  setup do
    Code.ensure_loaded!(Synapsis.Web.Search)
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "rich callback normalizes optional filters and preserves full ordinary metadata fallbacks",
       ctx do
    owner = self()
    payload = %{"success" => true, "data" => %{"news" => [row()]}}
    install(ctx, payload, owner)

    arguments = %{
      "query" => " rich source ",
      "count" => 12,
      "sources" => [" news ", ""],
      "categories" => [" github "],
      "exclude_domains" => [" excluded.example "],
      "tbs" => " qdr:m ",
      "location" => " 東京 ",
      "country" => " JP ",
      "scrape_results" => true,
      "timeout_seconds" => 5
    }

    assert {:ok, result} = search(ctx, arguments, generic: false)
    assert result["query"] == "rich source"

    assert result["results"] == [
             %{
               "title" => "Fallback title",
               "url" => "https://www.example.org/one",
               "description" => "Fallback summary 雪",
               "content" => "# Full content",
               "siteName" => "example.org",
               "published" => "2026-01-03T04:05:06.789Z"
             }
           ]

    assert_receive {:firecrawl_http, body}

    assert body == %{
             "query" => "rich source",
             "limit" => 12,
             "sources" => ["news"],
             "categories" => ["github"],
             "excludeDomains" => ["excluded.example"],
             "tbs" => "qdr:m",
             "location" => "東京",
             "country" => "JP",
             "scrapeOptions" => %{"formats" => ["markdown"]}
           }
  end

  test "generic callback keeps authored query and defaults while rich canonical options share the cache",
       ctx do
    owner = self()
    install(ctx, %{"data" => [row()]}, owner)
    args = %{"query" => " generic source ", "count" => 1}
    assert {:ok, first} = search(ctx, args)
    assert first["kind"] == "results"
    assert first["query"] == args["query"]

    assert first["results"] == [
             %{
               "title" => "Fallback title",
               "url" => "https://www.example.org/one",
               "snippet" => "Fallback summary 雪",
               "siteName" => "example.org",
               "published" => "2026-01-03T04:05:06.789Z"
             }
           ]

    assert_receive {:firecrawl_http, %{"query" => " generic source ", "limit" => 1}}
    assert {:ok, cached} = search(ctx, args)
    assert cached == Map.put(first, "cached", true)

    assert {:ok, rich} =
             search(ctx, %{"query" => " rich cache ", "sources" => [], "tbs" => "  "},
               generic: false
             )

    assert_receive {:firecrawl_http, %{"query" => "rich cache", "limit" => 5}}

    assert {:ok, rich_cached} =
             search(
               ctx,
               %{"query" => "rich cache", "scrape_results" => false, "timeout_seconds" => 4},
               generic: false
             )

    assert rich_cached == Map.put(rich, "cached", true)
    Gaoxy.Test.verify!(ctx.fixture)
  end

  test "every actual pinned HTTP callback retains the complete portable result through the native Web adapter",
       ctx do
    fixture_path =
      Path.expand(
        "../../../../synapsis_agent/test/fixtures/openclaw/488631c/firecrawl-search.json",
        __DIR__
      )

    reference = fixture_path |> File.read!() |> Jason.decode!()

    vectors =
      for group <- reference["groups"],
          step <- group["steps"],
          is_map(step["request"]),
          do: {group, step}

    assert length(vectors) == 43

    for {group, step} <- vectors do
      fixture = Gaoxy.Test.open()

      try do
        local = %{ctx | fixture: fixture}
        install(local, group["httpPayload"], self())
        request_body = step["request"]["body"]
        # Compare source-effective typed inputs. The native model schema retains
        # integer counts and snake_case keys; the reference raw reader additionally
        # accepts scientific-number strings and camelCase aliases.
        arguments =
          Map.take(request_body, ~w(query sources categories tbs location country))
          |> Map.put("count", request_body["limit"])
          |> maybe_put("include_domains", request_body["includeDomains"])
          |> maybe_put("exclude_domains", request_body["excludeDomains"])
          |> Map.put("scrape_results", is_map(request_body["scrapeOptions"]))

        generic = group["surface"] != "dedicated"

        assert {:ok, actual} =
                 search(local, arguments,
                   generic: generic,
                   provider: group["provider"],
                   cache_ttl_ms: 0
                 )

        expected =
          if generic, do: step["publicPortableResult"], else: step["providerPortableResult"]

        assert Map.delete(actual, "tookMs") == Map.delete(expected, "tookMs"),
               inspect(%{id: group["id"], actual: actual, expected: expected},
                 limit: 40,
                 printable_limit: 2500
               )

        assert_receive {:firecrawl_http, actual_body}
        assert actual_body == request_body, group["id"]
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp row do
    %{
      "url" => "",
      "sourceUrl" => "https://www.example.org/one",
      "title" => "",
      "description" => "",
      "snippet" => "",
      "summary" => "Fallback summary 雪",
      "markdown" => "",
      "content" => "# Full content",
      "publishedDate" => "",
      "metadata" => %{"title" => "Fallback title", "publishedTime" => "2026-01-03T04:05:06.789Z"}
    }
  end

  defp install(ctx, payload, owner) do
    Gaoxy.Test.stub(ctx.fixture, "POST", "/v2/search", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:firecrawl_http, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end

  defp search(ctx, args, opts \\ []) do
    config = %{
      provider: Keyword.get(opts, :provider, "firecrawl"),
      base_url: Gaoxy.Test.url(ctx.fixture, "/unused"),
      api_key: "ordinary-firecrawl",
      credential_version: <<1>>,
      timeout_ms: 5000,
      cache_ttl_ms: Keyword.get(opts, :cache_ttl_ms, 60000),
      count: 5
    }

    Web.search(Synapsis.Web.Search, args["query"],
      search_config: config,
      arguments: args,
      generic: Keyword.get(opts, :generic, true),
      timeout: 5000
    )
  end
end
