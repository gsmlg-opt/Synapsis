defmodule Synapsis.Web.KimiSearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.Web
  alias Synapsis.Web.Search.Cache

  @groups ~w(search-default operator-query unicode-query configured-count configured-count-string
    explicit-count numeric-count-token configured-timeout endpoint-model-ai endpoint-model-cn
    endpoint-explicit-cn endpoint-custom endpoint-trailing-slashes ordered-metadata sparse-results
    successful-empty same-cache-reuse empty-cache-reuse)

  setup do
    Code.ensure_loaded!(Synapsis.Web.Search)
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    counter = start_supervised!({Agent, fn -> [] end})
    if is_nil(Process.whereis(Cache)), do: start_supervised!(Cache)
    {:ok, fixture: fixture, counter: counter}
  end

  test "generic Kimi output preserves the authored query and complete ordered normalized rows",
       ctx do
    install(ctx, payload())
    args = %{"query" => " Kimi source metadata 雪🙂 ", "count" => 2}
    assert {:ok, result} = search(ctx, args)

    assert Map.delete(result, "tookMs") == %{
             "kind" => "results",
             "provider" => "kimi",
             "query" => args["query"],
             "count" => 2,
             "results" => rows()
           }

    assert is_integer(result["tookMs"])
    assert result["tookMs"] >= 0

    assert requests(ctx) == [
             {"/v1/tools/search", %{"text_query" => String.trim(args["query"]), "limit" => 2}}
           ]
  end

  test "equivalent private queries reuse cache while each public query remains authored", ctx do
    install(ctx, payload())
    raw = %{"query" => " cached Kimi 雪🙂 "}

    assert {:ok, first} = search(ctx, raw)
    assert {:ok, cached} = search(ctx, %{"query" => "cached Kimi 雪🙂", "count" => 5})

    assert cached ==
             first |> Map.put("query", "cached Kimi 雪🙂") |> Map.put("cached", true)

    assert {:ok, repeated} = search(ctx, raw)
    assert repeated == Map.put(first, "cached", true)

    assert requests(ctx) == [
             {"/v1/tools/search", %{"text_query" => "cached Kimi 雪🙂", "limit" => 5}}
           ]
  end

  test "successful empty results are cached and preserve each authored public query", ctx do
    install(ctx, %{"search_results" => []})
    args = %{"query" => " empty Kimi result "}
    assert {:ok, first} = search(ctx, args)

    assert Map.delete(first, "tookMs") == %{
             "kind" => "results",
             "provider" => "kimi",
             "query" => args["query"],
             "count" => 0,
             "results" => []
           }

    assert {:ok, cached} = search(ctx, %{"query" => "empty Kimi result", "count" => 5})
    assert cached == first |> Map.put("query", "empty Kimi result") |> Map.put("cached", true)

    assert requests(ctx) == [
             {"/v1/tools/search", %{"text_query" => "empty Kimi result", "limit" => 5}}
           ]
  end

  test "sparse successful rows keep empty title and snippet in the public result", ctx do
    install(ctx, %{"search_results" => [%{"url" => " https://SPARSE.EXAMPLE:443/story "}]})
    args = %{"query" => " sparse ordinary source "}
    assert {:ok, result} = search(ctx, args)

    assert Map.delete(result, "tookMs") == %{
             "kind" => "results",
             "provider" => "kimi",
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

  test "positive Unicode operators and configured counts reach the private request unchanged",
       ctx do
    install(ctx, %{"search_results" => []})

    query =
      ~s(雪🙂 "语言模型" site:example.org -site:archive.example lang:zh after:2026-01-01 before:2026-11-01)

    for {label, opts, extra, count} <- [
          {"default", [], %{}, 5},
          {"configured", [count: 3], %{}, 3},
          {"configured-string", [count: "3"], %{}, 5},
          {"explicit", [count: 3], %{"count" => 2}, 2},
          {"numeric-token", [], %{"count" => "2e0"}, 2}
        ] do
      authored = " " <> query <> " " <> label <> " "
      assert {:ok, result} = search(ctx, Map.put(extra, "query", authored), opts)

      assert Map.delete(result, "tookMs") == %{
               "kind" => "results",
               "provider" => "kimi",
               "query" => authored,
               "count" => 0,
               "results" => []
             }

      assert List.last(requests(ctx)) ==
               {"/v1/tools/search", %{"text_query" => String.trim(authored), "limit" => count}}
    end

    assert length(requests(ctx)) == 5
  end

  test "every pinned HTTP callback matches the complete portable generic public result", ctx do
    reference = reference()
    assert Enum.map(reference["groups"], & &1["id"]) == @groups

    callbacks =
      for group <- reference["groups"],
          step <- group["steps"],
          is_map(step["request"]),
          do: {group, step}

    assert length(callbacks) == 18

    for {group, step} <- callbacks do
      fixture = Gaoxy.Test.open()

      try do
        local = %{ctx | fixture: fixture}
        path = URI.parse(step["request"]["url"]).path
        prefix = String.replace_suffix(path, "/tools/search", "")
        install(local, group["httpPayload"], path)
        outer = step["setup"]["searchConfig"]

        assert {:ok, actual} =
                 search(local, step["arguments"],
                   base_url: Gaoxy.Test.url(fixture, prefix),
                   count: Map.get(outer, "maxResults", 5),
                   timeout_ms: Map.get(outer, "timeoutSeconds", 30) * 1000,
                   cache_ttl_ms: 0
                 )

        assert Map.delete(actual, "tookMs") ==
                 Map.delete(step["publicPortableResult"], "tookMs"),
               group["id"]

        assert is_integer(actual["tookMs"])
        assert actual["tookMs"] >= 0
        assert List.last(requests(ctx)) == {path, step["request"]["body"]}, group["id"]
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  defp reference do
    Path.expand(
      "../../../../synapsis_agent/test/fixtures/openclaw/488631c/kimi-search.json",
      __DIR__
    )
    |> File.read!()
    |> Jason.decode!()
  end

  defp payload do
    %{
      "search_results" => [
        %{
          "title" => " First source 雪 ",
          "url" => " https://WWW.SOURCE.EXAMPLE:443/ordinary path?q=hello world#section ",
          "snippet" => " First passage 🙂 ",
          "date" => " 2026-11-01 ",
          "site_name" => "Supplied source label"
        },
        %{
          "title" => " Second source ",
          "url" => "http://NEWS.EXAMPLE:80/story",
          "snippet" => " Second passage ",
          "date" => "2026-11-02",
          "site_name" => "Supplied news label"
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
        "published" => "2026-11-01",
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
      provider: "kimi",
      base_url: Keyword.get(opts, :base_url, Gaoxy.Test.url(ctx.fixture, "/v1")),
      api_key: "ordinary-kimi-fixture",
      credential_version: <<1>>,
      timeout_ms: Keyword.get(opts, :timeout_ms, 5000),
      cache_ttl_ms: Keyword.get(opts, :cache_ttl_ms, 60_000),
      count: Keyword.get(opts, :count, 5),
      mode: "web"
    }

    Web.search(Synapsis.Web.Search, args["query"], search_config: config, arguments: args)
  end

  defp requests(ctx), do: Agent.get(ctx.counter, & &1)

  defp install(ctx, payload, path \\ "/v1/tools/search") do
    Gaoxy.Test.stub(ctx.fixture, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(ctx.counter, &(&1 ++ [{conn.request_path, Jason.decode!(body)}]))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
