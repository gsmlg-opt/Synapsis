defmodule Synapsis.Web.TavilySearchFunctionalTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.Codex.Web

  setup do
    Code.ensure_loaded!(Synapsis.Web.Search)
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "dedicated readers normalize ordinary filters and cache the effective request", ctx do
    install(ctx)

    args = %{
      "query" => " rich Tavily ",
      "search_depth" => " advanced ",
      "topic" => " news ",
      "time_range" => " week ",
      "include_domains" => [" example.org ", ""],
      "exclude_domains" => [],
      "include_answer" => true
    }

    assert {:ok, first} = search(ctx, args, generic: false)

    assert Map.drop(first, ["tookMs"]) == %{
             "provider" => "tavily",
             "query" => "rich Tavily",
             "count" => 1,
             "answer" => "Ordinary answer 雪",
             "results" => [row()]
           }

    assert_receive {:tavily_http, %{"query" => "rich Tavily"} = body}

    assert body == %{
             "query" => "rich Tavily",
             "max_results" => 5,
             "search_depth" => "advanced",
             "topic" => "news",
             "time_range" => "week",
             "include_domains" => ["example.org"],
             "include_answer" => true
           }

    effective = %{
      "query" => "rich Tavily",
      "search_depth" => "advanced",
      "topic" => "news",
      "time_range" => "week",
      "include_domains" => ["example.org"],
      "include_answer" => true
    }

    assert {:ok, cached} = search(ctx, effective, generic: false)
    assert cached == Map.put(first, "cached", true)
    Gaoxy.Test.verify!(ctx.fixture)
  end

  test "generic retains authored query while dedicated false answer is omitted from HTTP", ctx do
    install(ctx)
    args = %{"query" => " generic Tavily ", "count" => 1}
    assert {:ok, first} = search(ctx, args)
    assert first["query"] == args["query"]
    assert first["kind"] == "results"
    assert first["results"] == [Map.drop(row(), ["score"])]
    assert_receive {:tavily_http, %{"query" => " generic Tavily ", "max_results" => 1}}
    assert {:ok, cached} = search(ctx, args)
    assert cached == Map.put(first, "cached", true)

    assert {:ok, dedicated} =
             search(ctx, %{"query" => "false Tavily", "include_answer" => false}, generic: false)

    assert dedicated["answer"] == "Ordinary answer 雪"
    assert_receive {:tavily_http, %{"query" => "false Tavily", "max_results" => 5} = body}
    assert body == %{"query" => "false Tavily", "max_results" => 5}
  end

  test "dedicated omitted and false answer options share the callback's effective cache identity",
       ctx do
    install(ctx)
    args = %{"query" => "answer cache"}
    assert {:ok, first} = search(ctx, args, generic: false)
    assert_receive {:tavily_http, %{"query" => "answer cache", "max_results" => 5}}
    assert {:ok, cached} = search(ctx, Map.put(args, "include_answer", false), generic: false)
    assert cached == Map.put(first, "cached", true)
  end

  test "all actual pinned HTTP callbacks preserve exact request bodies and complete portable output",
       ctx do
    reference =
      Path.expand(
        "../../../../synapsis_agent/test/fixtures/openclaw/488631c/tavily-search.json",
        __DIR__
      )
      |> File.read!()
      |> Jason.decode!()

    vectors =
      for group <- reference["groups"],
          step <- group["steps"],
          is_map(step["request"]),
          do: {group, step}

    assert length(vectors) == 46

    for {group, step} <- vectors do
      fixture = Gaoxy.Test.open()

      try do
        local = %{ctx | fixture: fixture}
        request = step["request"]
        endpoint = URI.parse(request["url"])
        owner = self()

        Gaoxy.Test.stub(fixture, "POST", endpoint.path, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(owner, {:tavily_oracle_http, conn.query_string, Jason.decode!(body)})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(group["httpPayload"]))
        end)

        # Compare source-effective typed arguments. The reference raw reader also
        # accepts scientific numeric strings and names its rich count max_results;
        # native input remains integer count, with its existing selected schemas.
        arguments =
          request["body"]
          |> Map.delete("max_results")
          |> Map.put("count", request["body"]["max_results"])

        prefix = String.replace_suffix(endpoint.path, "/search", "")
        base = Gaoxy.Test.url(fixture, if(prefix == "", do: "/", else: prefix))

        base_url =
          URI.to_string(%{URI.parse(base) | query: endpoint.query, fragment: endpoint.fragment})

        generic = group["surface"] == "generic"

        assert {:ok, actual} =
                 search(local, arguments, generic: generic, base_url: base_url, cache_ttl_ms: 0)

        expected =
          if generic, do: step["publicPortableResult"], else: step["providerPortableResult"]

        assert Map.delete(actual, "tookMs") == Map.delete(expected, "tookMs"),
               inspect(%{id: group["id"], actual: actual, expected: expected},
                 limit: 40,
                 printable_limit: 3000
               )

        assert_receive {:tavily_oracle_http, query, body}
        assert query == (endpoint.query || ""), group["id"]
        assert body == request["body"], group["id"]
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  defp row do
    %{
      "title" => "Ordinary news",
      "url" => "https://www.example.org/news",
      "snippet" => "News passage 雪",
      "score" => 0.95,
      "published" => "2026-01-03T04:05:06.000Z"
    }
  end

  defp install(ctx) do
    owner = self()

    Gaoxy.Test.stub(ctx.fixture, "POST", "/proxy/search", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:tavily_http, Jason.decode!(body)})

      payload = %{
        "results" => [
          %{
            "title" => "Ordinary news",
            "url" => "https://www.example.org/news",
            "content" => "News passage 雪",
            "score" => 0.95,
            "published_date" => "Sat, 03 Jan 2026 04:05:06 GMT"
          }
        ],
        "answer" => "Ordinary answer 雪"
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end

  defp search(ctx, args, opts \\ []) do
    config = %{
      provider: "tavily",
      base_url: Keyword.get(opts, :base_url, Gaoxy.Test.url(ctx.fixture, "/proxy/")),
      api_key: "ordinary-tavily",
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
