defmodule Synapsis.Provider.PerplexitySearchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional
  alias Synapsis.Provider.WebSearch

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "Search API posts privately prepared filters and retains complete ordered source text",
       ctx do
    title = String.duplicate("界", 20_001)

    payload = %{
      "results" => [
        %{
          "title" => title,
          "url" => "https://www.example.org/article",
          "snippet" => "Passage",
          "date" => "2026-01-02"
        },
        %{"title" => "Later", "url" => "https://example.org/later"}
      ]
    }

    stub(ctx, "/proxy/search", payload)

    raw = %{
      "query" => " ordinary search ",
      "count" => 1,
      "country" => " us ",
      "language" => " EN ",
      "freshness" => " PW ",
      "domain_filter" => [" example.org ", "example.org"],
      "max_tokens" => 1000,
      "max_tokens_per_page" => 200
    }

    assert {:ok, result} = WebSearch.search(config(ctx), raw)
    assert_receive {:http, body, _headers}

    assert body == %{
             "query" => "ordinary search",
             "max_results" => 1,
             "country" => "us",
             "search_language_filter" => ["EN"],
             "search_recency_filter" => "week",
             "search_domain_filter" => ["example.org", "example.org"],
             "max_tokens" => 1000,
             "max_tokens_per_page" => 200
           }

    assert result["results"] == [
             %{
               "title" => title,
               "url" => "https://www.example.org/article",
               "description" => "Passage",
               "published" => "2026-01-02",
               "siteName" => "example.org"
             }
           ]

    assert result["count"] == 1
    assert raw["query"] == " ordinary search "
    assert raw["domain_filter"] == [" example.org ", "example.org"]
  end

  test "Search API supports each ordinary date bound and deny domains", ctx do
    stub(ctx, "/proxy/search", %{"results" => []})

    for {dates, expected} <- [
          {%{"date_after" => " 1/2/2026 ", "date_before" => "2026-02-03"},
           %{"search_after_date_filter" => "1/2/2026", "search_before_date_filter" => "2/3/2026"}},
          {%{"date_after" => "2026-01-02"}, %{"search_after_date_filter" => "1/2/2026"}},
          {%{"date_before" => "2/3/2026"}, %{"search_before_date_filter" => "2/3/2026"}}
        ] do
      assert {:ok, _} =
               WebSearch.search(
                 config(ctx),
                 Map.merge(%{"query" => "dates", "domain_filter" => [" -example.org "]}, dates)
               )

      assert_receive {:http, body, _}

      assert body ==
               Map.merge(
                 %{
                   "query" => "dates",
                   "max_results" => 5,
                   "search_domain_filter" => ["-example.org"]
                 },
                 expected
               )
    end
  end

  test "former Sonar configuration returns an error before HTTP", ctx do
    assert {:error, :unsupported_perplexity_mode} =
             WebSearch.search(config(ctx, "chat_completions"), %{"query" => "unsupported"})
  end

  test "pinned Perplexity callbacks match request formats and ordinary HTTP response contracts",
       ctx do
    path =
      Path.expand(
        "../../../../synapsis_agent/test/fixtures/openclaw/488631c/perplexity-search.json",
        __DIR__
      )

    reference = Formata.JSON.decode!(File.read!(path))
    assert length(reference["groups"]) == 25

    for group <- reference["groups"],
        group["mode"] == "search_api",
        step <- group["steps"],
        step["request"] != nil do
      options =
        get_in(step, [
          "setup",
          "config",
          "plugins",
          "entries",
          "perplexity",
          "config",
          "webSearch"
        ])

      source_base =
        case String.trim(options["baseUrl"] || "") do
          "" -> "https://api.perplexity.ai"
          value -> value
        end

      outer = step["setup"]["searchConfig"]

      trusted = %{
        config(ctx, group["mode"])
        | base_url: source_base,
          count: outer["maxResults"]
      }

      args = Map.put_new(step["arguments"], "count", outer["maxResults"])
      assert {:ok, prepared} = WebSearch.prepare(trusted, args)

      assert {:ok, :post, url, headers, body} =
               Synapsis.Provider.WebSearch.Perplexity.request(trusted, prepared)

      assert url == step["request"]["url"], group["id"]
      assert body == step["request"]["body"], group["id"]

      assert Enum.into(headers, %{})["accept"] == "application/json"

      prefix = "/" <> group["id"] <> "/" <> Integer.to_string(step["cumulativeRequests"])
      local = %{trusted | base_url: Gaoxy.Test.url(ctx.fixture, prefix)}
      path = prefix <> "/search"

      stub(ctx, path, group["httpPayload"])
      assert {:ok, result} = WebSearch.search(local, step["arguments"])
      assert_receive {:http, actual_body, _}

      assert actual_body == body, group["id"]

      assert unframe(result) ==
               Map.drop(step["providerUnwrappedResult"], ~w(externalContent tookMs cached)),
             group["id"]

      assert step["arguments"] == step["argumentsAfter"]
    end
  end

  defp unframe(result) do
    result = Map.drop(result, ~w(tookMs cached))

    result =
      if is_binary(result["content"]),
        do: Map.update!(result, "content", &String.trim/1),
        else: result

    if is_list(result["results"]) do
      Map.update!(result, "results", fn rows ->
        Enum.map(rows, fn row ->
          Enum.reduce(~w(title description), row, fn key, row ->
            if is_binary(row[key]), do: Map.update!(row, key, &String.trim/1), else: row
          end)
        end)
      end)
    else
      result
    end
  end

  defp config(ctx, mode \\ "search_api"),
    do: %{
      provider: "perplexity",
      base_url: Gaoxy.Test.url(ctx.fixture, "/proxy"),
      api_key: "ordinary-perplexity-fixture",
      timeout_ms: 5000,
      count: 5,
      mode: mode,
      model: "perplexity/sonar-pro"
    }

  defp stub(ctx, path, payload) do
    owner = self()

    Gaoxy.Test.stub(ctx.fixture, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:http, Formata.JSON.decode!(body), conn.req_headers})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Formata.JSON.encode!(payload))
    end)
  end
end
