defmodule Synapsis.Web.MiniMaxSearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.Web
  alias Synapsis.Web.Search.Cache

  @groups ~w(search-default operator-query unicode-query configured-count configured-count-string
    explicit-count numeric-count-token configured-timeout endpoint-explicit-cn endpoint-explicit-global
    endpoint-model-global endpoint-model-cn endpoint-portal-cn ordered-metadata sparse-results
    successful-empty successful-missing-organic successful-status-zero same-cache-reuse empty-cache-reuse
    count-cache-identity)

  setup do
    Code.ensure_loaded!(Synapsis.Web.Search)
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    counter = start_supervised!({Agent, fn -> [] end})
    if is_nil(Process.whereis(Cache)), do: start_supervised!(Cache)
    {:ok, fixture: fixture, counter: counter}
  end

  test "generic output preserves authored query with complete normalized ordered rows", ctx do
    install(ctx, payload())
    args = %{"query" => " MiniMax source metadata 雪🙂 ", "count" => 2}

    assert {:ok, result} = search(ctx, args)

    assert Map.delete(result, "tookMs") == %{
             "kind" => "results",
             "provider" => "minimax",
             "query" => args["query"],
             "count" => 2,
             "results" => rows()
           }

    assert is_integer(result["tookMs"])
    assert result["tookMs"] >= 0
    assert requests(ctx) == [%{"q" => "MiniMax source metadata 雪🙂"}]
  end

  test "equivalent private queries reuse cache while each public query remains authored", ctx do
    install(ctx, payload())
    raw = %{"query" => " cached MiniMax 雪🙂 "}

    assert {:ok, first} = search(ctx, raw)
    assert {:ok, cached} = search(ctx, %{"query" => "cached MiniMax 雪🙂", "count" => 5})
    assert cached == first |> Map.put("query", "cached MiniMax 雪🙂") |> Map.put("cached", true)

    assert {:ok, repeated} = search(ctx, raw)
    assert repeated == Map.put(first, "cached", true)
    assert requests(ctx) == [%{"q" => "cached MiniMax 雪🙂"}]
  end

  test "resolved counts distinguish cache entries while the POST body remains the same", ctx do
    install(ctx, payload())
    raw = %{"query" => " MiniMax count cache "}

    assert {:ok, two} = search(ctx, Map.put(raw, "count", 2))
    assert {:ok, one} = search(ctx, Map.put(raw, "count", 1))

    assert Map.delete(two, "tookMs") == %{
             "kind" => "results",
             "provider" => "minimax",
             "query" => raw["query"],
             "count" => 2,
             "results" => rows()
           }

    assert Map.delete(one, "tookMs") == %{
             "kind" => "results",
             "provider" => "minimax",
             "query" => raw["query"],
             "count" => 1,
             "results" => Enum.take(rows(), 1)
           }

    assert {:ok, cached_two} = search(ctx, Map.put(raw, "count", "2e0"))
    assert cached_two == Map.put(two, "cached", true)
    assert {:ok, cached_one} = search(ctx, raw, count: 1)
    assert cached_one == Map.put(one, "cached", true)
    assert requests(ctx) == [%{"q" => "MiniMax count cache"}, %{"q" => "MiniMax count cache"}]
  end

  test "successful empty results are cached with each authored public query", ctx do
    install(ctx, %{"organic" => []})
    args = %{"query" => " empty MiniMax result "}
    assert {:ok, first} = search(ctx, args)

    assert Map.delete(first, "tookMs") == %{
             "kind" => "results",
             "provider" => "minimax",
             "query" => args["query"],
             "count" => 0,
             "results" => []
           }

    assert {:ok, cached} = search(ctx, %{"query" => "empty MiniMax result", "count" => 5})
    assert cached == first |> Map.put("query", "empty MiniMax result") |> Map.put("cached", true)
    assert requests(ctx) == [%{"q" => "empty MiniMax result"}]
  end

  test "sparse successful rows keep empty title and snippet", ctx do
    install(ctx, %{"organic" => [%{"link" => " https://SPARSE.EXAMPLE:443/story "}]})
    args = %{"query" => " sparse ordinary source "}
    assert {:ok, result} = search(ctx, args)

    assert Map.delete(result, "tookMs") == %{
             "kind" => "results",
             "provider" => "minimax",
             "query" => args["query"],
             "count" => 1,
             "results" => [
               %{
                 "title" => "",
                 "url" => "https://sparse.example/story",
                 "snippet" => "",
                 "siteName" => "sparse.example"
               }
             ]
           }
  end

  test "every pinned HTTP callback matches the complete portable generic public result", ctx do
    reference = reference()
    assert Enum.map(reference["groups"], & &1["id"]) == @groups

    callbacks =
      for group <- reference["groups"],
          step <- group["steps"],
          is_map(step["request"]),
          do: {group, step}

    assert length(callbacks) == 22

    for {group, step} <- callbacks do
      fixture = Gaoxy.Test.open()

      try do
        local = %{ctx | fixture: fixture}
        install(local, group["httpPayload"])
        outer = step["setup"]["searchConfig"]

        region =
          if URI.parse(step["request"]["url"]).host == "api.minimaxi.com",
            do: "cn",
            else: "global"

        assert {:ok, actual} =
                 search(local, step["arguments"],
                   region: region,
                   count: Map.get(outer, "maxResults", 5),
                   timeout_ms: Map.get(outer, "timeoutSeconds", 30) * 1000,
                   cache_ttl_ms: 0
                 )

        assert Map.delete(actual, "tookMs") ==
                 Map.delete(step["publicPortableResult"], "tookMs"),
               group["id"]

        assert is_integer(actual["tookMs"])
        assert actual["tookMs"] >= 0
        assert List.last(requests(ctx)) == step["request"]["body"], group["id"]
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  defp reference do
    Path.expand(
      "../../../../synapsis_agent/test/fixtures/openclaw/488631c/minimax-search.json",
      __DIR__
    )
    |> File.read!()
    |> Jason.decode!()
  end

  defp payload do
    %{
      "organic" => [
        %{
          "title" => " First source 雪 ",
          "link" => " https://WWW.SOURCE.EXAMPLE:443/ordinary path?q=hello world#section ",
          "snippet" => " First passage 🙂 ",
          "date" => " 2026-11-01 ",
          "site_name" => "Supplied source label"
        },
        %{
          "title" => " Second source ",
          "link" => "http://NEWS.EXAMPLE:80/story",
          "snippet" => " Second passage ",
          "date" => "2026-11-02"
        }
      ],
      "related_searches" => [%{"query" => " Related source 雪 "}, %{"query" => "Related news 🙂"}],
      "base_resp" => %{"status_code" => 0, "status_msg" => "success"}
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
        "snippet" => "Second passage",
        "published" => "2026-11-02",
        "siteName" => "news.example"
      }
    ]
  end

  defp search(ctx, args, opts \\ []) do
    config = %{
      provider: "minimax",
      base_url: Gaoxy.Test.url(ctx.fixture, "/"),
      api_key: "ordinary-minimax-fixture",
      credential_version: <<1>>,
      timeout_ms: Keyword.get(opts, :timeout_ms, 5000),
      cache_ttl_ms: Keyword.get(opts, :cache_ttl_ms, 60_000),
      count: Keyword.get(opts, :count, 5),
      mode: "web"
    }

    config =
      if Keyword.has_key?(opts, :region),
        do: Map.put(config, :region, opts[:region]),
        else: config

    Web.search(Synapsis.Web.Search, args["query"], search_config: config, arguments: args)
  end

  defp requests(ctx), do: Agent.get(ctx.counter, & &1)

  defp install(ctx, payload) do
    Gaoxy.Test.stub(ctx.fixture, "POST", "/v1/coding_plan/search", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(ctx.counter, &(&1 ++ [Jason.decode!(body)]))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
