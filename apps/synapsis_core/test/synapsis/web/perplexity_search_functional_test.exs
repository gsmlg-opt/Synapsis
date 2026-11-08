defmodule Synapsis.Web.PerplexitySearchFunctionalTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.Codex.Web
  alias Synapsis.Provider.WebSearch.TextBudget
  alias Synapsis.Web.Search.Cache

  setup do
    Code.ensure_loaded!(Synapsis.Web.Search)
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    counter = start_supervised!({Agent, fn -> [] end})
    if is_nil(Process.whereis(Cache)), do: start_supervised!(Cache)
    {:ok, fixture: fixture, counter: counter}
  end

  test "native public search retains options and separates Search count, mode and configured model",
       ctx do
    install(ctx, "search_api", %{
      "results" => [
        %{"title" => "Source", "url" => "https://example.org/source", "snippet" => "Passage"}
      ]
    })

    install(ctx, "chat_completions", %{"choices" => [%{"message" => %{"content" => "Answer"}}]})

    raw = %{
      "query" => " cache search ",
      "language" => " EN ",
      "freshness" => " PW ",
      "count" => 2
    }

    assert {:ok, first} = search(ctx, raw)
    assert first["kind"] == "results"
    assert first["query"] == raw["query"]

    assert {:ok, cached} =
             search(ctx, %{
               raw
               | "query" => "cache search",
                 "language" => "EN",
                 "freshness" => "week"
             })

    assert cached == first |> Map.put("query", "cache search") |> Map.put("cached", true)
    assert length(requests(ctx)) == 1

    assert {"/proxy/search",
            %{"search_language_filter" => ["EN"], "search_recency_filter" => "week"}} =
             {elem(hd(requests(ctx)), 0),
              Map.take(
                elem(hd(requests(ctx)), 1),
                ~w(search_language_filter search_recency_filter)
              )}

    assert {:ok, _} = search(ctx, Map.put(raw, "count", 3))
    assert {:ok, _} = search(ctx, raw, model: "perplexity/sonar")

    assert {:ok, answer} =
             search(ctx, Map.take(raw, ~w(query count freshness)), mode: "chat_completions")

    assert answer["kind"] == "answer"
    assert length(requests(ctx)) == 4
  end

  test "Sonar ignores count for caching while TTL zero bypasses and preserves the prior entry",
       ctx do
    install(ctx, "chat_completions", %{
      "choices" => [%{"message" => %{"content" => "Answer"}}],
      "citations" => ["https://b.example/", "https://a.example/"]
    })

    raw = %{"query" => "unused count", "count" => 1}
    assert {:ok, original} = search(ctx, raw, mode: "chat_completions")
    assert {:ok, cached} = search(ctx, Map.put(raw, "count", 9), mode: "chat_completions")
    assert cached == Map.put(original, "cached", true)

    for _ <- 1..2,
        do: assert({:ok, _} = search(ctx, raw, mode: "chat_completions", cache_ttl_ms: 0))

    assert {:ok, cached} = search(ctx, raw, mode: "chat_completions")
    assert cached == Map.put(original, "cached", true)
    assert length(requests(ctx)) == 3

    assert original["citations"] == [
             %{"url" => "https://b.example/"},
             %{"url" => "https://a.example/"}
           ]

    assert Map.keys(original) |> Enum.sort() == ~w(citations content kind provider query tookMs)
  end

  test "answer URLs reserve UTF16 units before complete-scalar body prefixes", ctx do
    urls = ["https://b.example/", "https://a.example/"]
    left = 20_000 - Enum.sum(Enum.map(urls, &TextBudget.units/1))
    prefix = String.duplicate("🙂", div(left, 2)) <> if(rem(left, 2) == 1, do: "x", else: "")

    install(ctx, "chat_completions", %{
      "choices" => [%{"message" => %{"content" => "  " <> prefix <> "🙂tail  "}}],
      "citations" => urls
    })

    assert {:ok, answer} = search(ctx, %{"query" => "bounded answer"}, mode: "chat_completions")
    assert answer["content"] == prefix
    assert answer["truncated"] == true

    assert TextBudget.units(answer["content"]) +
             Enum.sum(Enum.map(answer["citations"], &TextBudget.units(&1["url"]))) == 20_000
  end

  test "answer citation scan retains first twenty canonical URLs in source order", ctx do
    urls = for index <- 1..21, do: "https://EXAMPLE.org:443/source-#{index}"

    install(ctx, "chat_completions", %{
      "choices" => [%{"message" => %{"content" => "Answer"}}],
      "citations" => urls
    })

    assert {:ok, answer} = search(ctx, %{"query" => "many citations"}, mode: "chat_completions")

    assert Enum.map(answer["citations"], & &1["url"]) ==
             for(index <- 1..20, do: "https://example.org/source-#{index}")

    assert answer["truncated"] == true
  end

  test "pinned public callbacks retain source fields, cache identity and raw caller query", ctx do
    reference = reference()
    assert length(reference["groups"]) == 25
    assert Enum.sum(Enum.map(reference["groups"], &length(&1["steps"]))) == 54

    for group <- reference["groups"] do
      offset = length(requests(ctx))
      install(ctx, group["mode"], group["httpPayload"], "/" <> group["id"])

      for step <- group["steps"] do
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

        model =
          case String.trim(options["model"] || "") do
            "" -> "perplexity/sonar-pro"
            value -> value
          end

        outer = step["setup"]["searchConfig"]
        ttl = round(outer["cacheTtlMinutes"] * 60_000)
        if ttl == 1, do: Process.sleep(3)

        assert {:ok, result} =
                 search(ctx, step["arguments"],
                   mode: group["mode"],
                   model: model,
                   count: outer["maxResults"],
                   cache_ttl_ms: ttl,
                   base_path: "/" <> group["id"],
                   timeout_ms: Map.get(outer, "timeoutSeconds", 30) * 1000
                 )

        assert Map.drop(result, ["tookMs"]) ==
                 Map.drop(step["publicUnwrappedResult"], ~w(externalContent tookMs)),
               group["id"]

        assert length(requests(ctx)) == offset + step["cumulativeRequests"], group["id"]

        if request = step["request"] do
          {_, actual} = List.last(requests(ctx))

          expected =
            if group["mode"] == "chat_completions",
              do: Map.put(request["body"], "model", model),
              else: request["body"]

          assert actual == expected, group["id"]
        end

        assert step["arguments"] == step["argumentsAfter"]
      end
    end
  end

  test "actual Sonar HTTP matches pinned full UTF16 body normalization without native persistence",
       ctx do
    cases =
      reference()["normalizerCases"]
      |> Enum.filter(
        &(&1["id"] in ~w(answer-body-emoji answer-body-combining answer-body-zwj answer-citation-limit answer-empty-citations answer-short-unicode))
      )

    assert length(cases) == 6

    for row <- cases do
      provider = row["providerResult"]

      payload = %{
        "choices" => [%{"message" => %{"content" => provider["content"]}}],
        "citations" => provider["citations"]
      }

      prefix = "/" <> row["id"]
      install(ctx, "chat_completions", payload, prefix)

      assert {:ok, result} =
               search(ctx, %{"query" => row["query"]},
                 mode: "chat_completions",
                 base_path: prefix
               )

      assert Map.drop(result, ["tookMs"]) ==
               Map.drop(row["publicUnwrappedResult"], ~w(externalContent tookMs)),
             row["id"]
    end
  end

  test "successful callback normalization reserves the full budget for citation URLs", ctx do
    row =
      Enum.find(reference()["normalizerCases"], &(&1["id"] == "answer-citations-exhaust-body"))

    assert row
    provider = row["providerResult"]

    install(ctx, "chat_completions", %{
      "choices" => [%{"message" => %{"content" => provider["content"]}}],
      "citations" => provider["citations"]
    })

    config = %{
      provider: "perplexity",
      base_url: Gaoxy.Test.url(ctx.fixture, "/proxy"),
      api_key: "ordinary-perplexity-fixture",
      timeout_ms: 5000,
      cache_ttl_ms: 0,
      count: 5,
      mode: "chat_completions",
      model: "perplexity/sonar-pro"
    }

    # This checks the Core callback; the dedicated native citation-budget
    # functional test covers admission, persistence and fresh Worker replay.
    assert {:ok, result} =
             Synapsis.Web.Search.search(row["query"],
               search_config: config,
               arguments: %{"query" => row["query"]}
             )

    assert result["content"] == ""
    assert length(result["citations"]) == 20
    assert Enum.sum(Enum.map(result["citations"], &TextBudget.units(&1["url"]))) == 20_000

    assert Map.drop(result, ["tookMs"]) ==
             Map.drop(row["publicUnwrappedResult"], ~w(externalContent tookMs))
  end

  defp reference do
    path =
      Path.expand(
        "../../../../synapsis_agent/test/fixtures/openclaw/488631c/perplexity-search.json",
        __DIR__
      )

    Jason.decode!(File.read!(path))
  end

  defp search(ctx, args, opts \\ []) do
    config = %{
      provider: "perplexity",
      base_url: Gaoxy.Test.url(ctx.fixture, Keyword.get(opts, :base_path, "/proxy")),
      api_key: "ordinary-perplexity-fixture",
      credential_version: <<1>>,
      timeout_ms: Keyword.get(opts, :timeout_ms, 5000),
      cache_ttl_ms: Keyword.get(opts, :cache_ttl_ms, 60_000),
      count: Keyword.get(opts, :count, 5),
      mode: Keyword.get(opts, :mode, "search_api"),
      model: Keyword.get(opts, :model, "perplexity/sonar-pro")
    }

    Web.search(Synapsis.Web.Search, args["query"], search_config: config, arguments: args)
  end

  defp requests(ctx), do: Agent.get(ctx.counter, & &1)

  defp install(ctx, mode, payload, prefix \\ "/proxy") do
    path = prefix <> if(mode == "search_api", do: "/search", else: "/chat/completions")

    Gaoxy.Test.stub(ctx.fixture, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(ctx.counter, &(&1 ++ [{path, Jason.decode!(body)}]))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
