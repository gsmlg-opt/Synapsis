defmodule Synapsis.Provider.ParallelSearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.WebSearch

  @groups ~w(search-default normalized-pair unicode-pair optional-context configured-count
    configured-count-fraction configured-count-string explicit-count numeric-count-token
    configured-timeout endpoint-origin endpoint-prefix endpoint-full endpoint-schemeless
    endpoint-query endpoint-trailing endpoint-full-trailing endpoint-fragment ordered-metadata
    cli-query-fallback cli-query-with-objective query-with-pair successful-empty
    successful-empty-minimal same-cache-generated-session same-cache-supplied-session
    empty-cache-reuse count-cache-identity objective-cache-identity queries-cache-identity
    query-order-cache-identity session-cache-identity client-model-cache-identity endpoint-cache-identity)

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "paid POST privately normalizes objective queries and supplied options with complete raw results",
       ctx do
    stub(ctx, payload())

    arguments = %{
      "objective" => " Compare ordinary sources 雪🙂 ",
      "search_queries" => [" first source 雪 ", "first source 雪", " ", " second source 🙂 "],
      "count" => 2,
      "session_id" => " supplied-session ",
      "client_model" => " gpt-6-astra "
    }

    assert {:ok, result} = WebSearch.search(config(ctx), arguments)
    assert_receive {:parallel_http, "/v1/search", "", body, headers}

    assert body == %{
             "objective" => "Compare ordinary sources 雪🙂",
             "search_queries" => ["first source 雪", "second source 🙂"],
             "advanced_settings" => %{"max_results" => 2},
             "session_id" => "supplied-session",
             "client_model" => "gpt-6-astra"
           }

    assert Map.new(headers)["accept"] == "application/json"
    assert Map.new(headers)["content-type"] == "application/json"
    assert Map.new(headers)["x-api-key"] == "ordinary-parallel-fixture"
    assert Map.new(headers)["user-agent"] == "synapsis-parallel/1"

    assert Map.delete(result, "tookMs") == %{
             "provider" => "parallel",
             "objective" => "Compare ordinary sources 雪🙂",
             "searchQueries" => ["first source 雪", "second source 🙂"],
             "count" => 2,
             "results" => rows(),
             "searchId" => "search-ordinary",
             "sessionId" => "supplied-session",
             "warnings" => [%{"code" => "source_notice", "detail" => " Ordinary notice 雪 "}],
             "usage" => [%{"name" => "search", "count" => 1}]
           }

    assert is_integer(result["tookMs"])
    assert result["tookMs"] >= 0

    assert arguments == %{
             "objective" => " Compare ordinary sources 雪🙂 ",
             "search_queries" => [" first source 雪 ", "first source 雪", " ", " second source 🙂 "],
             "count" => 2,
             "session_id" => " supplied-session ",
             "client_model" => " gpt-6-astra "
           }
  end

  test "positive integer tokens and configured numeric floors select and slice ordered results",
       ctx do
    results =
      for index <- 1..7 do
        %{"title" => "Source #{index}", "url" => "https://source.example/#{index}"}
      end

    stub(ctx, %{"results" => results})

    for {configured, extra, expected} <- [
          {5, %{}, 5},
          {3.9, %{}, 3},
          {"3", %{}, 5},
          {4, %{"count" => 2}, 2},
          {4, %{"count" => "2e0"}, 2},
          {4, %{"count" => " 3.0 "}, 3}
        ] do
      args =
        Map.merge(
          %{"objective" => " Find sources ", "search_queries" => [" ordinary sources "]},
          extra
        )

      assert {:ok, result} = WebSearch.search(%{config(ctx) | count: configured}, args)
      assert_receive {:parallel_http, "/v1/search", "", body, _}

      assert body == %{
               "objective" => "Find sources",
               "search_queries" => ["ordinary sources"],
               "advanced_settings" => %{"max_results" => expected}
             }

      assert Map.delete(result, "tookMs") == %{
               "provider" => "parallel",
               "objective" => "Find sources",
               "searchQueries" => ["ordinary sources"],
               "count" => expected,
               "results" =>
                 for(
                   index <- 1..expected,
                   do: %{
                     "title" => "Source #{index}",
                     "url" => "https://source.example/#{index}",
                     "description" => "",
                     "siteName" => "source.example"
                   }
                 )
             }
    end
  end

  test "default and configured endpoints preserve origin prefix and query with idempotent preparation",
       ctx do
    for {input, expected} <- [
          {nil, "https://api.parallel.ai/v1/search"},
          {"https://API.PARALLEL.EXAMPLE:443/", "https://api.parallel.example/v1/search"},
          {"parallel.example/ordinary/", "https://parallel.example/ordinary/v1/search"},
          {"https://parallel.example/ordinary///?view=source#section",
           "https://parallel.example/ordinary/v1/search?view=source"},
          {"https://parallel.example/ordinary/v1/search/?view=source#section",
           "https://parallel.example/ordinary/v1/search?view=source"}
        ] do
      assert {:ok, prepared} =
               config(ctx) |> Map.put(:base_url, input) |> WebSearch.prepare_config()

      assert prepared.base_url == expected
      assert WebSearch.prepare_config(prepared) == {:ok, prepared}
    end

    assert {:ok, default} = config(ctx) |> Map.delete(:base_url) |> WebSearch.prepare_config()
    assert default.base_url == "https://api.parallel.ai/v1/search"
  end

  test "synthetic prefix endpoint sends its query once and keeps the supplied session and model",
       ctx do
    stub(ctx, %{"results" => []}, "/ordinary/v1/search")

    config = %{
      config(ctx)
      | base_url: Gaoxy.Test.url(ctx.fixture, "/ordinary/v1/search/?view=source#section")
    }

    args = %{
      "objective" => " Follow up ordinary research ",
      "search_queries" => [" ordinary follow up "],
      "session_id" => "supplied-followup-session",
      "client_model" => "claude-opus-4-7"
    }

    assert {:ok, result} = WebSearch.search(config, args)
    assert_receive {:parallel_http, "/ordinary/v1/search", "view=source", body, _}

    assert body == %{
             "objective" => "Follow up ordinary research",
             "search_queries" => ["ordinary follow up"],
             "advanced_settings" => %{"max_results" => 5},
             "session_id" => "supplied-followup-session",
             "client_model" => "claude-opus-4-7"
           }

    assert Map.delete(result, "tookMs") == %{
             "provider" => "parallel",
             "objective" => "Follow up ordinary research",
             "searchQueries" => ["ordinary follow up"],
             "count" => 0,
             "results" => []
           }
  end

  test "CLI query fallback is private and explicit search queries take precedence", ctx do
    stub(ctx, %{"results" => []})

    for {args, queries} <- [
          {%{"query" => " CLI ordinary 雪🙂 "}, ["CLI ordinary 雪🙂"]},
          {%{"query" => " CLI anchor ", "search_queries" => [" explicit keyword query "]},
           ["explicit keyword query"]}
        ] do
      assert {:ok, result} = WebSearch.search(config(ctx), args)
      assert_receive {:parallel_http, "/v1/search", "", body, _}
      assert body == %{"search_queries" => queries, "advanced_settings" => %{"max_results" => 5}}

      assert Map.delete(result, "tookMs") == %{
               "provider" => "parallel",
               "searchQueries" => queries,
               "count" => 0,
               "results" => []
             }
    end
  end

  test "successful sparse rows and empty metadata retain the portable provider shape", ctx do
    stub(ctx, %{
      "results" => [%{"url" => "https://SPARSE.EXAMPLE/story"}],
      "warnings" => [],
      "usage" => []
    })

    assert {:ok, result} =
             WebSearch.search(config(ctx), %{"search_queries" => ["sparse ordinary source"]})

    assert Map.delete(result, "tookMs") == %{
             "provider" => "parallel",
             "searchQueries" => ["sparse ordinary source"],
             "count" => 1,
             "results" => [
               %{
                 "title" => "",
                 "url" => "https://SPARSE.EXAMPLE/story",
                 "description" => "",
                 "siteName" => "sparse.example"
               }
             ]
           }
  end

  test "every pinned paid HTTP callback matches its complete portable provider map", ctx do
    reference = reference()
    assert Enum.map(reference["groups"], & &1["id"]) == @groups

    callbacks =
      for group <- reference["groups"],
          step <- group["steps"],
          is_map(step["request"]),
          do: {group, step}

    assert length(callbacks) == 41

    for {group, step} <- callbacks do
      fixture = Gaoxy.Test.open()

      try do
        local = %{ctx | fixture: fixture}
        request = step["request"]
        uri = URI.parse(request["url"])
        stub(local, group["httpPayload"], uri.path)
        outer = step["setup"]["searchConfig"]
        endpoint = uri.path <> if(uri.query, do: "?" <> uri.query, else: "")

        local_config =
          config(local)
          |> Map.put(:base_url, Gaoxy.Test.url(fixture, endpoint))
          |> Map.put(
            :api_key,
            get_in(step, [
              "setup",
              "config",
              "plugins",
              "entries",
              "parallel",
              "config",
              "webSearch",
              "apiKey"
            ])
          )
          |> Map.put(:count, Map.get(outer, "maxResults", 5))
          |> Map.put(:timeout_ms, Map.get(outer, "timeoutSeconds", 30) * 1000)

        assert {:ok, actual} = WebSearch.search(local_config, step["arguments"])

        assert Map.delete(actual, "tookMs") ==
                 Map.delete(step["providerPortableResult"], "tookMs"),
               group["id"]

        assert is_integer(actual["tookMs"])
        assert actual["tookMs"] >= 0
        assert_receive {:parallel_http, path, query, body, headers}
        assert path == request["path"], group["id"]
        assert URI.decode_query(query) == request["query"], group["id"]
        assert body == request["body"], group["id"]
        assert Map.new(headers)["accept"] == request["headers"]["Accept"]
        assert Map.new(headers)["content-type"] == request["headers"]["Content-Type"]
        assert Map.new(headers)["x-api-key"] == request["headers"]["x-api-key"]
        assert Map.new(headers)["user-agent"] == "synapsis-parallel/1"
        assert request["headers"]["User-Agent"] == reference["pluginFixture"]["userAgent"]
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  defp reference do
    Path.expand(
      "../../../../synapsis_agent/test/fixtures/openclaw/488631c/parallel-search.json",
      __DIR__
    )
    |> File.read!()
    |> Jason.decode!()
  end

  defp config(ctx),
    do: %{
      provider: "parallel",
      base_url: Gaoxy.Test.url(ctx.fixture, "/"),
      api_key: "ordinary-parallel-fixture",
      timeout_ms: 5000,
      count: 5,
      mode: "web"
    }

  defp payload,
    do: %{
      "search_id" => "search-ordinary",
      "session_id" => "supplied-session",
      "warnings" => [%{"code" => "source_notice", "detail" => " Ordinary notice 雪 "}],
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

  defp stub(ctx, payload, path \\ "/v1/search") do
    owner = self()

    Gaoxy.Test.stub(ctx.fixture, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        owner,
        {:parallel_http, conn.request_path, conn.query_string, Jason.decode!(body),
         conn.req_headers}
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
