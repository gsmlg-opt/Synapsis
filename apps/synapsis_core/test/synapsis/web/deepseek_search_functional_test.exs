defmodule Synapsis.Web.DeepSeekSearchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Codex.Web
  alias Synapsis.Web.Search.Cache

  setup do
    Code.ensure_loaded!(Synapsis.Web.Search)
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    counter = start_supervised!({Agent, fn -> [] end})
    if is_nil(Process.whereis(Cache)), do: start_supervised!(Cache)
    {:ok, fixture: fixture, counter: counter}
  end

  test "generic DeepSeek output preserves authored query and complete ordered normalized rows",
       ctx do
    install(ctx, payload())
    args = %{"query" => " DeepSeek source metadata ", "count" => 2}

    assert {:ok, result} = search(ctx, args)

    assert Map.delete(result, "tookMs") == %{
             "kind" => "results",
             "provider" => "deepseek",
             "query" => args["query"],
             "count" => 2,
             "results" => rows()
           }

    assert is_integer(result["tookMs"])
    assert result["tookMs"] >= 0

    assert requests(ctx) == [
             %{"query" => "DeepSeek source metadata", "count" => 2, "need_content" => false}
           ]
  end

  test "equivalent private queries share cache while each public query remains authored", ctx do
    install(ctx, payload())
    raw = %{"query" => " cached DeepSeek 雪🙂 "}

    assert {:ok, first} = search(ctx, raw)
    assert {:ok, cached} = search(ctx, %{"query" => "cached DeepSeek 雪🙂", "count" => 5})

    assert cached ==
             first |> Map.put("query", "cached DeepSeek 雪🙂") |> Map.put("cached", true)

    assert {:ok, repeated} = search(ctx, raw)
    assert repeated == Map.put(first, "cached", true)

    assert requests(ctx) == [
             %{"query" => "cached DeepSeek 雪🙂", "count" => 5, "need_content" => false}
           ]
  end

  test "default configured and explicit counts support successful empty Unicode searches", ctx do
    install(ctx, %{"results" => []})
    query = ~s(雪🙂 "语言模型" site:example.org lang:zh after:2026-01-01)

    for {label, opts, extra, count} <- [
          {"default", [], %{}, 5},
          {"configured", [count: 3], %{}, 3},
          {"explicit", [count: 3], %{"count" => 2}, 2}
        ] do
      authored = query <> " " <> label
      assert {:ok, result} = search(ctx, Map.put(extra, "query", authored), opts)

      assert Map.delete(result, "tookMs") == %{
               "kind" => "results",
               "provider" => "deepseek",
               "query" => authored,
               "count" => 0,
               "results" => []
             }

      assert List.last(requests(ctx)) == %{
               "query" => authored,
               "count" => count,
               "need_content" => false
             }
    end

    assert length(requests(ctx)) == 3
  end

  test "every pinned HTTP callback matches the complete portable generic public result", ctx do
    reference =
      Path.expand(
        "../../../../synapsis_agent/test/fixtures/openclaw/488631c/deepseek-search.json",
        __DIR__
      )
      |> File.read!()
      |> Jason.decode!()

    callbacks =
      for group <- reference["groups"],
          step <- group["steps"],
          is_map(step["request"]),
          do: {group, step}

    assert length(callbacks) == 10

    for {group, step} <- callbacks do
      fixture = Gaoxy.Test.open()

      try do
        local = %{ctx | fixture: fixture}
        install(local, group["httpPayload"])
        outer = step["setup"]["searchConfig"]

        assert {:ok, actual} =
                 search(local, step["arguments"],
                   count: Map.get(outer, "maxResults", 5),
                   timeout_ms: Map.get(outer, "timeoutSeconds", 30) * 1000,
                   cache_ttl_ms: 0
                 )

        assert Map.delete(actual, "tookMs") ==
                 Map.delete(step["publicPortableResult"], "tookMs"),
               group["id"]

        assert List.last(requests(ctx)) == step["request"]["body"], group["id"]
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  defp payload do
    %{
      "results" => [
        %{
          "title" => " First source 雪 ",
          "url" => " https://SOURCE.EXAMPLE:443/ordinary path?q=hello world#section ",
          "summary" => " Model summary 雪 ",
          "snippet" => "Short passage",
          "date" => " 2026-11-01T01:02:03Z ",
          "site_name" => " Source Example "
        },
        %{
          "title" => " Second source ",
          "url" => "http://NEWS.EXAMPLE:80/story",
          "summary" => " ",
          "snippet" => " Fallback passage 🙂 ",
          "date" => " 2026-11-02 ",
          "site_name" => " News Example "
        }
      ]
    }
  end

  defp rows do
    [
      %{
        "title" => "First source 雪",
        "url" => "https://source.example/ordinary%20path?q=hello%20world#section",
        "snippet" => "Model summary 雪",
        "published" => "2026-11-01T01:02:03Z",
        "siteName" => "Source Example"
      },
      %{
        "title" => "Second source",
        "url" => "http://news.example/story",
        "snippet" => "Fallback passage 🙂",
        "published" => "2026-11-02",
        "siteName" => "News Example"
      }
    ]
  end

  defp search(ctx, args, opts \\ []) do
    config = %{
      provider: "deepseek",
      base_url: Gaoxy.Test.url(ctx.fixture, "/"),
      api_key: "ordinary-deepseek-fixture",
      credential_version: <<1>>,
      timeout_ms: Keyword.get(opts, :timeout_ms, 5000),
      cache_ttl_ms: Keyword.get(opts, :cache_ttl_ms, 60_000),
      count: Keyword.get(opts, :count, 5),
      mode: "web"
    }

    Web.search(Synapsis.Web.Search, args["query"], search_config: config, arguments: args)
  end

  defp requests(ctx), do: Agent.get(ctx.counter, & &1)

  defp install(ctx, payload) do
    Gaoxy.Test.stub(ctx.fixture, "POST", "/v1/tools/search", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(ctx.counter, &(&1 ++ [Jason.decode!(body)]))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
