defmodule Synapsis.Web.OllamaSearchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Codex.Web
  alias Synapsis.Web.Search.Cache

  @groups ~w(search-default operator-query unicode-query explicit-count numeric-count-token
    configured-count-ignored configured-timeout-ignored endpoint-plugin-prefix endpoint-model-base-url
    endpoint-model-baseURL endpoint-model-base-url-precedence endpoint-plugin-precedence
    direct-hosted direct-hosted-prefix ordered-metadata sparse-results successful-empty
    successful-missing-results same-query-repeated count-sequence endpoint-prefix-ending-v1)

  setup do
    Code.ensure_loaded!(Synapsis.Web.Search)
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    counter = start_supervised!({Agent, fn -> [] end})
    if is_nil(Process.whereis(Cache)), do: start_supervised!(Cache)
    {:ok, fixture: fixture, counter: counter}
  end

  test "generic callback retains authored query and canonicalizes the full ordered result", ctx do
    install(ctx, payload())
    args = %{"query" => " Ollama source metadata 雪🙂 ", "count" => 2}
    assert {:ok, result} = search(ctx, args)

    assert Map.delete(result, "tookMs") == %{
             "kind" => "results",
             "provider" => "ollama",
             "query" => args["query"],
             "count" => 2,
             "results" => rows()
           }

    assert is_integer(result["tookMs"])
    assert result["tookMs"] >= 0
    assert requests(ctx) == [%{"query" => "Ollama source metadata 雪🙂", "max_results" => 2}]
  end

  test "host cache reuses trimmed query while each public result uses the current authored query",
       ctx do
    install(ctx, payload())
    raw = %{"query" => " cached Ollama 雪🙂 "}
    assert {:ok, first} = search(ctx, raw, count: 2)
    assert {:ok, cached} = search(ctx, %{"query" => "cached Ollama 雪🙂", "count" => 5}, count: 3)

    assert cached == first |> Map.put("query", "cached Ollama 雪🙂") |> Map.put("cached", true)
    assert {:ok, repeated} = search(ctx, raw, count: 4)
    assert repeated == Map.put(first, "cached", true)
    assert requests(ctx) == [%{"query" => "cached Ollama 雪🙂", "max_results" => 5}]
  end

  test "resolved counts distinguish host cache entries and equivalent numeric tokens reuse them",
       ctx do
    install(ctx, payload())
    args = %{"query" => " Ollama count cache "}
    assert {:ok, two} = search(ctx, Map.put(args, "count", 2))
    assert {:ok, one} = search(ctx, Map.put(args, "count", 1))

    for {result, count} <- [{two, 2}, {one, 1}] do
      assert Map.delete(result, "tookMs") == %{
               "kind" => "results",
               "provider" => "ollama",
               "query" => args["query"],
               "count" => count,
               "results" => Enum.take(rows(), count)
             }
    end

    assert {:ok, cached_two} = search(ctx, Map.put(args, "count", "2e0"))
    assert cached_two == Map.put(two, "cached", true)
    assert {:ok, cached_one} = search(ctx, Map.put(args, "count", " 1.0 "))
    assert cached_one == Map.put(one, "cached", true)

    assert requests(ctx) == [
             %{"query" => "Ollama count cache", "max_results" => 2},
             %{"query" => "Ollama count cache", "max_results" => 1}
           ]
  end

  test "distinct normalized queries keep separate ordinary host cache entries", ctx do
    install(ctx, payload())

    for query <- [" first Ollama topic 雪 ", " second Ollama topic 🙂 "] do
      args = %{"query" => query, "count" => 2}
      assert {:ok, result} = search(ctx, args)

      assert Map.delete(result, "tookMs") == %{
               "kind" => "results",
               "provider" => "ollama",
               "query" => query,
               "count" => 2,
               "results" => rows()
             }

      assert {:ok, cached} = search(ctx, %{"query" => String.trim(query), "count" => 2})
      assert cached == result |> Map.put("query", String.trim(query)) |> Map.put("cached", true)
    end

    assert requests(ctx) == [
             %{"query" => "first Ollama topic 雪", "max_results" => 2},
             %{"query" => "second Ollama topic 🙂", "max_results" => 2}
           ]
  end

  test "successful empty and missing-result responses use the host cache", ctx do
    for {payload, query} <- [
          {%{"results" => []}, " empty Ollama result "},
          {%{}, " missing Ollama results "}
        ] do
      fixture = Gaoxy.Test.open()

      try do
        local = %{ctx | fixture: fixture}
        install(local, payload)
        assert {:ok, first} = search(local, %{"query" => query})

        assert Map.delete(first, "tookMs") == %{
                 "kind" => "results",
                 "provider" => "ollama",
                 "query" => query,
                 "count" => 0,
                 "results" => []
               }

        assert {:ok, cached} = search(local, %{"query" => String.trim(query), "count" => 5})
        assert cached == first |> Map.put("query", String.trim(query)) |> Map.put("cached", true)
      after
        Gaoxy.Test.close(fixture)
      end
    end

    assert requests(ctx) == [
             %{"query" => "empty Ollama result", "max_results" => 5},
             %{"query" => "missing Ollama results", "max_results" => 5}
           ]
  end

  test "canonical base identity and redundant mode reuse the ordinary host cache", ctx do
    install(ctx, payload())
    args = %{"query" => " Ollama canonical cache ", "count" => 2}
    assert {:ok, first} = search(ctx, args)

    assert {:ok, cached} =
             search(ctx, args,
               base_url: Gaoxy.Test.url(ctx.fixture, "/ordinary/V1///"),
               mode: "llm-context",
               timeout_ms: 5000
             )

    assert cached == Map.put(first, "cached", true)
    assert requests(ctx) == [%{"query" => "Ollama canonical cache", "max_results" => 2}]
  end

  test "every pinned local callback matches its entire generic public map", ctx do
    reference = reference()
    assert Enum.map(reference["groups"], & &1["id"]) == @groups

    callbacks =
      for group <- reference["groups"],
          group["id"] not in ["direct-hosted", "direct-hosted-prefix"],
          step <- group["steps"],
          do: {group, step}

    assert length(callbacks) == 22

    for {group, step} <- callbacks do
      fixture = Gaoxy.Test.open()

      try do
        local = %{ctx | fixture: fixture}
        uri = URI.parse(step["request"]["url"])
        prefix = String.replace_suffix(uri.path, "/api/experimental/web_search", "")
        install(local, group["httpPayload"], uri.path)

        assert {:ok, actual} =
                 search(local, step["arguments"],
                   base_url: Gaoxy.Test.url(fixture, prefix <> "/v1/"),
                   count: Map.get(step["setup"]["searchConfig"], "maxResults", 5),
                   cache_ttl_ms: 0
                 )

        assert Map.delete(actual, "tookMs") == Map.delete(step["publicPortableResult"], "tookMs"),
               group["id"]

        assert is_integer(actual["tookMs"])
        assert actual["tookMs"] >= 0
        assert List.last(requests(ctx)) == step["request"]["body"], group["id"]
      after
        Gaoxy.Test.close(fixture)
      end
    end

    assert length(requests(ctx)) == 22
  end

  defp reference do
    Path.expand(
      "../../../../synapsis_agent/test/fixtures/openclaw/488631c/ollama-search.json",
      __DIR__
    )
    |> File.read!()
    |> Jason.decode!()
  end

  defp search(ctx, args, opts \\ []) do
    config = %{
      provider: "ollama",
      base_url: Keyword.get(opts, :base_url, Gaoxy.Test.url(ctx.fixture, "/ordinary/v1/")),
      api_key: nil,
      timeout_ms: Keyword.get(opts, :timeout_ms, 15_000),
      cache_ttl_ms: Keyword.get(opts, :cache_ttl_ms, 60_000),
      count: Keyword.get(opts, :count, 5),
      mode: Keyword.get(opts, :mode, "web")
    }

    Web.search(Synapsis.Web.Search, args["query"], search_config: config, arguments: args)
  end

  defp payload do
    %{
      "results" => [
        %{
          "title" => " First source 雪 ",
          "url" => " https://WWW.SOURCE.EXAMPLE:443/ordinary path?q=hello world#section ",
          "content" => " First passage 🙂 "
        },
        %{
          "title" => " Second source ",
          "url" => "http://NEWS.EXAMPLE:80/story",
          "content" => " Second passage 雪 "
        }
      ]
    }
  end

  defp rows do
    [
      %{
        "title" => "First source 雪",
        "url" => "https://www.source.example/ordinary%20path?q=hello%20world#section",
        "snippet" => "First passage 🙂",
        "siteName" => "www.source.example"
      },
      %{
        "title" => "Second source",
        "url" => "http://news.example/story",
        "snippet" => "Second passage 雪",
        "siteName" => "news.example"
      }
    ]
  end

  defp requests(ctx), do: Agent.get(ctx.counter, & &1)

  defp install(ctx, payload, path \\ "/ordinary/api/experimental/web_search") do
    Gaoxy.Test.stub(ctx.fixture, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(ctx.counter, &(&1 ++ [Jason.decode!(body)]))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
