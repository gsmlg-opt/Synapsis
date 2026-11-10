defmodule Synapsis.Provider.ExaSearchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Provider.WebSearch
  alias Synapsis.Provider.WebSearch.Exa

  @reference Path.expand(
               "../../../../synapsis_agent/test/fixtures/openclaw/488631c/exa-search.json",
               __DIR__
             )

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "default Exa POST uses its actual host integration header and privately trimmed query",
       ctx do
    stub(ctx, "/proxy/search", %{
      "results" => [
        %{
          "title" => " Original title ",
          "url" => "https://www.example.org/first",
          "highlights" => [" First passage ", "Second passage", "First passage"],
          "summary" => " Summary ",
          "highlightScores" => [0.8, 0, -0.2],
          "publishedDate" => "2026-10-28T01:02:03Z"
        }
      ]
    })

    raw = %{"query" => " ordinary search "}
    assert {:ok, result} = WebSearch.search(config(ctx), raw)
    assert_receive {:http, body, headers, query}

    assert body == %{
             "query" => "ordinary search",
             "numResults" => 5,
             "type" => "auto",
             "contents" => %{"highlights" => true}
           }

    assert Map.new(headers)["x-api-key"] == "ordinary-exa-fixture"
    assert Map.new(headers)["x-exa-integration"] == "synapsis"
    assert Map.new(headers)["accept"] == "application/json"
    assert Map.new(headers)["content-type"] == "application/json"
    assert query == ""

    assert Map.delete(result, "tookMs") == %{
             "query" => "ordinary search",
             "provider" => "exa",
             "count" => 1,
             "results" => [
               %{
                 "title" => " Original title ",
                 "url" => "https://www.example.org/first",
                 "description" => "First passage\nSecond passage\nFirst passage",
                 "summary" => "Summary",
                 "highlightScores" => [0.8, 0, -0.2],
                 "published" => "2026-10-28T01:02:03Z",
                 "siteName" => "www.example.org"
               }
             ]
           }

    assert raw == %{"query" => " ordinary search "}
  end

  test "all six Exa modes and positive numeric count tokens are sent exactly", ctx do
    stub(ctx, "/proxy/search", %{"results" => []})

    for type <- ~w(auto neural fast deep deep-reasoning instant) do
      assert {:ok, result} =
               WebSearch.search(config(ctx), %{
                 "query" => type,
                 "type" => type,
                 "count" => " 2e0 "
               })

      assert_receive {:http, body, _, _}

      assert body == %{
               "query" => type,
               "type" => type,
               "numResults" => 2,
               "contents" => %{"highlights" => true}
             }

      assert result["count"] == 0
    end
  end

  test "configured count and one hundred results retain ordered provider records before public normalization",
       ctx do
    rows =
      for index <- 1..101,
          do: %{"title" => "Source #{index}", "url" => "https://exa.example/#{index}"}

    stub(ctx, "/proxy/search", %{"results" => rows})

    assert {:ok, result} = WebSearch.search(%{config(ctx) | count: 100}, %{"query" => "hundred"})
    assert_receive {:http, %{"numResults" => 100}, _, _}
    assert result["count"] == 100
    assert Enum.map(result["results"], & &1["title"]) == Enum.map(1..100, &"Source #{&1}")

    assert {:ok, _} = WebSearch.search(%{config(ctx) | count: 3}, %{"query" => "configured"})
    assert_receive {:http, %{"numResults" => 3}, _, _}
  end

  test "contents booleans, complete objects and empty defaults preserve literal query fields",
       ctx do
    stub(ctx, "/proxy/search", %{"results" => []})

    for contents <- [
          %{"highlights" => false, "text" => true, "summary" => false},
          %{
            "text" => %{"maxCharacters" => 1200},
            "highlights" => %{
              "maxCharacters" => 300,
              "query" => " exact highlights query ",
              "numSentences" => 2,
              "highlightsPerUrl" => 3
            },
            "summary" => %{"query" => " exact summary query "}
          },
          %{"text" => %{}, "highlights" => %{}, "summary" => %{}},
          %{}
        ] do
      args = %{"query" => "contents", "contents" => contents}
      assert {:ok, _} = WebSearch.search(config(ctx), args)
      assert_receive {:http, body, _, _}
      assert body["contents"] == if(contents == %{}, do: %{"highlights" => true}, else: contents)
      assert args["contents"] == contents
    end
  end

  test "date bounds use the complete shared ISO and slash date normalization", ctx do
    stub(ctx, "/proxy/search", %{"results" => []})

    for {dates, expected} <- [
          {%{"date_after" => " 1/2/2026 ", "date_before" => "2026-02-03"},
           %{"startPublishedDate" => "2026-01-02", "endPublishedDate" => "2026-02-03"}},
          {%{"date_after" => "2026-01-02"}, %{"startPublishedDate" => "2026-01-02"}},
          {%{"date_before" => "2/3/2026"}, %{"endPublishedDate" => "2026-02-03"}},
          {%{"date_after" => "2026-01-02", "date_before" => "2026-01-02"},
           %{"startPublishedDate" => "2026-01-02", "endPublishedDate" => "2026-01-02"}}
        ] do
      assert {:ok, _} = WebSearch.search(config(ctx), Map.put(dates, "query", "dates"))
      assert_receive {:http, body, _, _}

      assert body ==
               Map.merge(
                 %{
                   "query" => "dates",
                   "numResults" => 5,
                   "type" => "auto",
                   "contents" => %{"highlights" => true}
                 },
                 expected
               )
    end
  end

  test "freshness modes emit request-time UTC instants", ctx do
    stub(ctx, "/proxy/search", %{"results" => []})

    for freshness <- ~w(day week month year) do
      before = DateTime.utc_now()

      assert {:ok, _} =
               WebSearch.search(config(ctx), %{
                 "query" => "freshness",
                 "freshness" => " #{String.upcase(freshness)} "
               })

      after_request = DateTime.utc_now()
      assert_receive {:http, body, _, _}
      assert {:ok, sent, 0} = DateTime.from_iso8601(body["startPublishedDate"])
      assert DateTime.compare(sent, Exa.freshness_start(freshness, before)) in [:eq, :gt]
      assert DateTime.compare(sent, Exa.freshness_start(freshness, after_request)) in [:eq, :lt]
      assert body["contents"] == %{"highlights" => true}
    end
  end

  test "UTC calendar freshness clamps previous months and preserves JavaScript leap-year rollover" do
    for {freshness, instant, expected} <- [
          {"month", "2026-03-31T12:34:56.789Z", "2026-02-28T12:34:56.789Z"},
          {"month", "2024-03-31T12:34:56.789Z", "2024-02-29T12:34:56.789Z"},
          {"month", "2025-01-31T12:34:56.789Z", "2024-12-31T12:34:56.789Z"},
          {"year", "2024-02-29T12:34:56.789Z", "2023-03-01T12:34:56.789Z"},
          {"day", "2024-03-01T12:34:56.789Z", "2024-02-29T12:34:56.789Z"},
          {"week", "2026-01-03T12:34:56.789Z", "2025-12-27T12:34:56.789Z"}
        ] do
      assert {:ok, datetime, 0} = DateTime.from_iso8601(instant)
      assert DateTime.to_iso8601(Exa.freshness_start(freshness, datetime)) == expected
    end
  end

  test "description fallbacks and full ordinary Unicode reach the generic projection owner",
       ctx do
    long = String.duplicate("界🙂", 10_001)

    stub(ctx, "/proxy/search", %{
      "results" => [
        %{"title" => long, "url" => "https://exa.example/highlights", "highlights" => [long]},
        %{"title" => "Summary", "url" => "https://exa.example/summary", "summary" => " Summary "},
        %{"title" => "Text", "url" => "https://exa.example/text", "text" => " Text "},
        %{"url" => "https://exa.example/empty"}
      ]
    })

    assert {:ok, result} = WebSearch.search(config(ctx), %{"query" => "complete"})
    assert_receive {:http, _, _, _}
    assert Enum.map(result["results"], & &1["description"]) == [long, "Summary", "Text", ""]
    assert hd(result["results"])["title"] == long
    assert List.last(result["results"])["title"] == ""
    assert Map.get(result, "truncated", false) == false
  end

  test "configured endpoint canonicalization preserves query and avoids duplicate search suffix",
       ctx do
    stub(ctx, "/proxy/search", %{"results" => []})

    for suffix <- ["/proxy/?ordinary=yes#fragment", "/proxy/search///?ordinary=yes#fragment"] do
      assert {:ok, _} =
               WebSearch.search(
                 %{config(ctx) | base_url: " " <> Gaoxy.Test.url(ctx.fixture, suffix) <> " "},
                 %{
                   "query" => "endpoint"
                 }
               )

      assert_receive {:http, _, _, "ordinary=yes"}
    end

    assert {:ok, "https://exa.example/proxy/search?ordinary=yes"} =
             Exa.endpoint(" exa.example/proxy///?ordinary=yes#fragment ")

    assert {:ok, "https://proxy.example/exa/search?ordinary=yes"} =
             Exa.endpoint(" HTTPS://PROXY.example:443/exa///?ordinary=yes#fragment ")
  end

  test "every pinned HTTP-bearing Exa callback preserves endpoint, body, headers and full provider map",
       ctx do
    reference = @reference |> File.read!() |> Jason.decode!()

    callbacks =
      for group <- reference["groups"],
          {step, index} <- Enum.with_index(group["steps"]),
          is_map(step["request"]),
          do: {group, step, index}

    assert length(callbacks) == 55

    for {group, step, index} <- callbacks do
      request = step["request"]
      search_config = step["setup"]["searchConfig"]

      provider_config =
        get_in(step, ["setup", "config", "plugins", "entries", "exa", "config", "webSearch"])

      raw_config = %{
        provider: "exa",
        api_key: provider_config["apiKey"],
        base_url: provider_config["baseUrl"],
        count: search_config["maxResults"],
        timeout_ms: Map.get(search_config, "timeoutSeconds", 30) * 1000,
        mode: "web"
      }

      assert {:ok, trusted} = WebSearch.prepare_config(raw_config)
      assert trusted.base_url == request["url"], group["id"]
      assert trusted.timeout_ms == request["timeoutSeconds"] * 1000, group["id"]
      assert {:ok, arguments} = WebSearch.prepare(trusted, step["arguments"])
      assert {:ok, :post, url, headers, body} = Exa.request(trusted, arguments)
      assert url == request["url"], group["id"]
      assert request["method"] == "POST"
      assert_exa_body(body, arguments, step)

      expected_headers =
        request["headers"]
        |> Map.new(fn {key, value} -> {String.downcase(key), value} end)
        |> Map.put("x-exa-integration", "synapsis")

      assert Map.new(headers) == expected_headers, group["id"]
      uri = URI.parse(url)
      prefix = "/oracle/" <> group["id"] <> "/" <> Integer.to_string(index)
      path = prefix <> uri.path

      local_url =
        Gaoxy.Test.url(ctx.fixture, path) <> if(uri.query, do: "?" <> uri.query, else: "")

      stub(ctx, path, group["httpPayload"])
      before_request = DateTime.utc_now()
      assert {:ok, actual} = WebSearch.search(%{trusted | base_url: local_url}, step["arguments"])
      after_request = DateTime.utc_now()
      assert_receive {:http, actual_body, actual_headers, actual_query}
      assert actual_query == (uri.query || ""), group["id"]

      assert Map.take(Map.new(actual_headers), Map.keys(expected_headers)) == expected_headers,
             group["id"]

      assert_exa_body(actual_body, arguments, step)

      if freshness = arguments["freshness"] do
        assert {:ok, sent, 0} = DateTime.from_iso8601(actual_body["startPublishedDate"])

        assert DateTime.compare(sent, Exa.freshness_start(freshness, before_request)) in [
                 :eq,
                 :gt
               ]

        assert DateTime.compare(sent, Exa.freshness_start(freshness, after_request)) in [:eq, :lt]
      end

      assert Map.delete(actual, "tookMs") == Map.delete(step["providerPortableResult"], "tookMs"),
             group["id"]

      assert step["arguments"] == step["argumentsAfter"]
    end
  end

  defp assert_exa_body(actual, arguments, step) do
    expected = step["request"]["body"]

    if freshness = arguments["freshness"] do
      assert {:ok, clock, 0} = DateTime.from_iso8601(step["clock"])

      assert DateTime.to_iso8601(Exa.freshness_start(freshness, clock)) ==
               expected["startPublishedDate"]

      assert Map.delete(actual, "startPublishedDate") ==
               Map.delete(expected, "startPublishedDate")
    else
      assert actual == expected
    end
  end

  defp config(ctx),
    do: %{
      provider: "exa",
      base_url: Gaoxy.Test.url(ctx.fixture, "/proxy"),
      api_key: "ordinary-exa-fixture",
      timeout_ms: 5000,
      count: 5,
      mode: "web"
    }

  defp stub(ctx, path, payload) do
    owner = self()

    Gaoxy.Test.stub(ctx.fixture, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:http, Jason.decode!(body), conn.req_headers, conn.query_string})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
