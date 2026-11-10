defmodule Synapsis.Web.ParallelSearchFunctionalTest do
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

  test "generic Parallel adds only kind while preserving full normalized provider result and raw input",
       ctx do
    install(ctx)
    raw = arguments()
    assert {:ok, result} = search(ctx, raw)
    assert Map.delete(result, "tookMs") == expected("Compare ordinary sources 雪🙂")
    assert is_integer(result["tookMs"])
    assert result["tookMs"] >= 0
    assert requests(ctx) == [{"/v1/search", "", body()}]
    assert raw == arguments()

    assert {:ok, direct} = search(ctx, raw, generic: false)

    assert Map.delete(direct, "tookMs") ==
             Map.delete(expected("Compare ordinary sources 雪🙂"), "kind")

    assert requests(ctx) == [{"/v1/search", "", body()}, {"/v1/search", "", body()}]

    assert {:ok, keywords} = search(ctx, Map.delete(raw, "objective"))

    assert Map.delete(keywords, "tookMs") ==
             Map.delete(expected("Compare ordinary sources 雪🙂"), "objective")

    assert requests(ctx) == [
             {"/v1/search", "", body()},
             {"/v1/search", "", body()},
             {"/v1/search", "", Map.delete(body(), "objective")}
           ]
  end

  test "normalized equivalent inputs share cache without inheriting generated response session ids",
       ctx do
    install(ctx)
    assert {:ok, first} = search(ctx, arguments())
    assert Map.delete(first, "tookMs") == expected("Compare ordinary sources 雪🙂")

    equivalent = %{
      "objective" => "Compare ordinary sources 雪🙂",
      "search_queries" => ["first source 雪", "second source 🙂"],
      "count" => "2e0",
      "client_model" => "gpt-6-astra"
    }

    assert {:ok, cached} = search(ctx, equivalent)
    assert cached == first |> Map.delete("sessionId") |> Map.put("cached", true)
    assert {:ok, repeated} = search(ctx, arguments())
    assert repeated == cached
    assert requests(ctx) == [{"/v1/search", "", body()}]
    assert equivalent["search_queries"] == ["first source 雪", "second source 🙂"]
  end

  test "supplied session ids remain cached and follow-up objective queries and model form identities",
       ctx do
    install(ctx)
    raw = Map.put(arguments(), "session_id", " generated-session ")
    assert {:ok, first} = search(ctx, raw)
    assert Map.delete(first, "tookMs") == expected("Compare ordinary sources 雪🙂")
    assert {:ok, cached} = search(ctx, Map.put(raw, "session_id", "generated-session"))
    assert cached == Map.put(first, "cached", true)

    followup = %{
      "objective" => " Follow up ordinary findings ",
      "search_queries" => [" fresh ordinary evidence "],
      "count" => 2,
      "session_id" => "generated-session",
      "client_model" => "claude-opus-4-7"
    }

    assert {:ok, second} = search(ctx, followup)

    assert Map.delete(second, "tookMs") ==
             expected("Follow up ordinary findings")
             |> Map.put("searchQueries", ["fresh ordinary evidence"])

    assert {:ok, followup_cached} = search(ctx, followup)
    assert followup_cached == Map.put(second, "cached", true)

    assert requests(ctx) == [
             {"/v1/search", "", Map.put(body(), "session_id", "generated-session")},
             {"/v1/search", "",
              %{
                "objective" => "Follow up ordinary findings",
                "search_queries" => ["fresh ordinary evidence"],
                "advanced_settings" => %{"max_results" => 2},
                "session_id" => "generated-session",
                "client_model" => "claude-opus-4-7"
              }}
           ]
  end

  test "canonical endpoints reuse cache while endpoint query distinguishes requests",
       ctx do
    install(ctx, "/ordinary/v1/search")
    base = Gaoxy.Test.url(ctx.fixture, "/ordinary/?view=one#section")
    canonical = Gaoxy.Test.url(ctx.fixture, "/ordinary/v1/search?view=one")
    assert {:ok, first} = search(ctx, arguments(), base_url: base)
    assert Map.delete(first, "tookMs") == expected("Compare ordinary sources 雪🙂")
    assert {:ok, cached} = search(ctx, arguments(), base_url: canonical)
    assert cached == first |> Map.delete("sessionId") |> Map.put("cached", true)

    assert {:ok, second} =
             search(ctx, arguments(), base_url: Gaoxy.Test.url(ctx.fixture, "/ordinary?view=two"))

    assert Map.delete(second, "tookMs") == expected("Compare ordinary sources 雪🙂")

    assert requests(ctx) == [
             {"/ordinary/v1/search", "view=one", body()},
             {"/ordinary/v1/search", "view=two", body()}
           ]
  end

  test "resolved counts and query-only CLI calls keep their separate normalized cache identities",
       ctx do
    install(ctx)
    raw = Map.delete(arguments(), "count")
    assert {:ok, two} = search(ctx, raw, count: 2.9)
    assert Map.delete(two, "tookMs") == expected("Compare ordinary sources 雪🙂")
    assert {:ok, same} = search(ctx, Map.put(raw, "count", "2.0"))
    assert same == two |> Map.delete("sessionId") |> Map.put("cached", true)
    assert {:ok, one} = search(ctx, Map.put(raw, "count", 1))

    assert Map.delete(one, "tookMs") ==
             expected("Compare ordinary sources 雪🙂")
             |> Map.put("count", 1)
             |> Map.update!("results", &Enum.take(&1, 1))

    cli = %{"query" => " CLI ordinary source ", "count" => 2}
    assert {:ok, cli_result} = search(ctx, cli)

    assert Map.delete(cli_result, "tookMs") ==
             expected("Compare ordinary sources 雪🙂")
             |> Map.delete("objective")
             |> Map.put("searchQueries", ["CLI ordinary source"])

    assert {:ok, cli_cached} = search(ctx, %{cli | "query" => "CLI ordinary source"})
    assert cli_cached == cli_result |> Map.delete("sessionId") |> Map.put("cached", true)

    assert requests(ctx) == [
             {"/v1/search", "", body()},
             {"/v1/search", "", put_in(body(), ["advanced_settings", "max_results"], 1)},
             {"/v1/search", "",
              %{
                "search_queries" => ["CLI ordinary source"],
                "advanced_settings" => %{"max_results" => 2}
              }}
           ]
  end

  defp arguments,
    do: %{
      "objective" => " Compare ordinary sources 雪🙂 ",
      "search_queries" => [" first source 雪 ", "first source 雪", " ", " second source 🙂 "],
      "count" => 2,
      "client_model" => " gpt-6-astra "
    }

  defp body,
    do: %{
      "objective" => "Compare ordinary sources 雪🙂",
      "search_queries" => ["first source 雪", "second source 🙂"],
      "advanced_settings" => %{"max_results" => 2},
      "client_model" => "gpt-6-astra"
    }

  defp expected(objective),
    do: %{
      "kind" => "results",
      "provider" => "parallel",
      "objective" => objective,
      "searchQueries" => ["first source 雪", "second source 🙂"],
      "count" => 2,
      "results" => rows(),
      "searchId" => "search-ordinary",
      "sessionId" => "generated-session",
      "warnings" => [%{"code" => "notice", "detail" => " Ordinary source notice "}],
      "usage" => [%{"name" => "search", "count" => 1}]
    }

  defp rows,
    do: [
      %{
        "title" => " First source 雪 ",
        "url" => "https://WWW.SOURCE.EXAMPLE:443/path?q=ordinary#part",
        "description" => " First passage 雪 \n\n Second passage 🙂 ",
        "siteName" => "www.source.example",
        "published" => " 2026-11-01 ",
        "excerpts" => [" First passage 雪 ", " Second passage 🙂 "]
      },
      %{
        "title" => " Second source ",
        "url" => "http://NEWS.EXAMPLE:80/story",
        "description" => " Follow-up passage ",
        "siteName" => "news.example",
        "published" => "2026-11-02",
        "excerpts" => [" Follow-up passage "]
      }
    ]

  defp search(ctx, args, opts \\ []) do
    config = %{
      provider: "parallel",
      base_url: Keyword.get(opts, :base_url, Gaoxy.Test.url(ctx.fixture, "/")),
      api_key: "ordinary-parallel-fixture",
      credential_version: <<1>>,
      timeout_ms: 5000,
      cache_ttl_ms: 60_000,
      count: Keyword.get(opts, :count, 5),
      mode: "web"
    }

    anchor = args["objective"] || args["query"] || Enum.join(args["search_queries"], " ")

    Web.search(Synapsis.Web.Search, anchor,
      search_config: config,
      arguments: args,
      generic: Keyword.get(opts, :generic, true)
    )
  end

  defp requests(ctx), do: Agent.get(ctx.counter, & &1)

  defp install(ctx, path \\ "/v1/search") do
    payload = %{
      "search_id" => "search-ordinary",
      "session_id" => "generated-session",
      "warnings" => [%{"code" => "notice", "detail" => " Ordinary source notice "}],
      "usage" => [%{"name" => "search", "count" => 1}],
      "results" => [
        %{
          "title" => " First source 雪 ",
          "url" => "https://WWW.SOURCE.EXAMPLE:443/path?q=ordinary#part",
          "publish_date" => " 2026-11-01 ",
          "excerpts" => [" First passage 雪 ", " Second passage 🙂 "]
        },
        %{
          "title" => " Second source ",
          "url" => "http://NEWS.EXAMPLE:80/story",
          "publish_date" => "2026-11-02",
          "excerpts" => [" Follow-up passage "]
        }
      ]
    }

    Gaoxy.Test.stub(ctx.fixture, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      Agent.update(
        ctx.counter,
        &(&1 ++ [{conn.request_path, conn.query_string, Jason.decode!(body)}])
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
