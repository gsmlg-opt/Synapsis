defmodule Synapsis.Provider.OllamaSearchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Provider.WebSearch
  alias Synapsis.Provider.WebSearch.Ollama

  @groups ~w(search-default operator-query unicode-query explicit-count numeric-count-token
    configured-count-ignored configured-timeout-ignored endpoint-plugin-prefix endpoint-model-base-url
    endpoint-model-baseURL endpoint-model-base-url-precedence endpoint-plugin-precedence
    direct-hosted direct-hosted-prefix ordered-metadata sparse-results successful-empty
    successful-missing-results same-query-repeated count-sequence endpoint-prefix-ending-v1)

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "base preparation removes trailing slashes then a trailing v1 while preserving prefixes",
       ctx do
    for {input, expected} <- [
          {nil, "http://127.0.0.1:11434"},
          {"http://127.0.0.1:11434///", "http://127.0.0.1:11434"},
          {"http://127.0.0.1:11434/v1/", "http://127.0.0.1:11434"},
          {"http://ordinary.example/prefix/V1///", "http://ordinary.example/prefix"},
          {"http://ordinary.example/proxy/v1/v1///", "http://ordinary.example/proxy/v1"},
          {"https://ollama.com/prefix/v1/", "https://ollama.com/prefix"}
        ] do
      assert Ollama.endpoint(input) == {:ok, expected}

      assert {:ok, prepared} =
               config(ctx) |> Map.put(:base_url, input) |> WebSearch.prepare_config()

      assert prepared.base_url == expected
      assert WebSearch.prepare_config(prepared) == {:ok, prepared}
    end
  end

  test "direct hosted requests use the hosted route through the pure request builder", ctx do
    for base <- [
          "https://ollama.com",
          "https://OLLAMA.COM/ordinary/v1/",
          "https://ollama.com:443/ordinary/V1///"
        ] do
      selected = %{config(ctx) | base_url: base, api_key: "ordinary-ollama-fixture"}
      assert {:ok, prepared} = WebSearch.prepare_config(selected)

      assert {:ok, args} =
               Ollama.prepare(prepared, %{"query" => " hosted fixture 雪 ", "count" => 2})

      assert {:ok, :post, url, headers, body} = Ollama.request(prepared, args)

      assert url == prepared.base_url <> "/api/web_search"
      assert Map.new(headers)["authorization"] == "Bearer ordinary-ollama-fixture"
      assert Map.new(headers)["content-type"] == "application/json"
      assert body == %{"query" => "hosted fixture 雪", "max_results" => 2}
    end
  end

  test "local POST trims private query and returns the complete ordered provider map", ctx do
    stub(ctx, payload())
    original = %{"query" => " ordinary Ollama 雪🙂 ", "count" => 2}

    selected = %{config(ctx) | timeout_ms: 5000, api_key: "ordinary-ollama-fixture"}
    assert {:ok, result} = WebSearch.search(selected, original)
    assert_receive {:ollama_http, "/ordinary/api/experimental/web_search", body, headers}
    assert body == %{"query" => "ordinary Ollama 雪🙂", "max_results" => 2}
    assert Map.new(headers)["content-type"] == "application/json"
    assert Map.new(headers)["authorization"] == "Bearer ordinary-ollama-fixture"

    assert Map.delete(result, "tookMs") == %{
             "provider" => "ollama",
             "query" => "ordinary Ollama 雪🙂",
             "count" => 2,
             "results" => rows()
           }

    assert is_integer(result["tookMs"])
    assert result["tookMs"] >= 0
    assert original == %{"query" => " ordinary Ollama 雪🙂 ", "count" => 2}
  end

  test "source default count ignores config and explicit positive numeric tokens select results",
       ctx do
    payload = %{
      "results" =>
        for(
          index <- 1..6,
          do: %{"title" => "Source #{index}", "url" => "https://source.example/#{index}"}
        )
    }

    stub(ctx, payload)

    for {configured, extra, count} <- [
          {2, %{}, 5},
          {3, %{}, 5},
          {3.5, %{}, 5},
          {"3", %{}, 5},
          {3, %{"count" => 2}, 2},
          {3, %{"count" => "2e0"}, 2},
          {3, %{"count" => " 3.0 "}, 3}
        ] do
      input = Map.put(extra, "query", " ordinary count ")
      selected = %{config(ctx) | count: configured}
      assert {:ok, prepared} = WebSearch.prepare(selected, input)
      assert prepared == %{"query" => "ordinary count", "count" => count}
      assert {:ok, result} = WebSearch.search(selected, input)
      assert_receive {:ollama_http, "/ordinary/api/experimental/web_search", body, _}
      assert body == %{"query" => "ordinary count", "max_results" => count}

      assert Map.delete(result, "tookMs") == %{
               "provider" => "ollama",
               "query" => "ordinary count",
               "count" => count,
               "results" =>
                 for(
                   index <- 1..count,
                   do: %{
                     "title" => "Source #{index}",
                     "url" => "https://source.example/#{index}",
                     "snippet" => "",
                     "siteName" => "source.example"
                   }
                 )
             }
    end
  end

  test "successful empty and sparse payloads retain the provider shape", ctx do
    for {payload, expected} <- [
          {%{"results" => []}, []},
          {%{}, []},
          {%{"results" => [%{"url" => " https://SPARSE.EXAMPLE/story "}]},
           [
             %{
               "title" => "",
               "url" => "https://SPARSE.EXAMPLE/story",
               "snippet" => "",
               "siteName" => "sparse.example"
             }
           ]}
        ] do
      fixture = Gaoxy.Test.open()

      try do
        local = %{ctx | fixture: fixture}
        stub(local, payload)
        args = %{"query" => " sparse ordinary source ", "count" => 2}

        assert Ollama.result(config(local), args, payload) ==
                 {:ok, %{"count" => length(expected), "results" => expected}}

        assert {:ok, result} = WebSearch.search(config(local), args)
        assert_receive {:ollama_http, "/ordinary/api/experimental/web_search", _, _}

        assert Map.delete(result, "tookMs") == %{
                 "provider" => "ollama",
                 "query" => "sparse ordinary source",
                 "count" => length(expected),
                 "results" => expected
               }
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  test "provider repeats ordinary queries without a source cache", ctx do
    stub(ctx, payload())
    args = %{"query" => " repeated Ollama source ", "count" => 2}

    for _ <- 1..2 do
      assert {:ok, result} = WebSearch.search(config(ctx), args)
      assert_receive {:ollama_http, "/ordinary/api/experimental/web_search", body, _}
      assert body == %{"query" => "repeated Ollama source", "max_results" => 2}

      assert Map.delete(result, "tookMs") == %{
               "provider" => "ollama",
               "query" => "repeated Ollama source",
               "count" => 2,
               "results" => rows()
             }
    end
  end

  test "every pinned local callback matches its entire portable provider result", ctx do
    reference = reference()
    assert Enum.map(reference["groups"], & &1["id"]) == @groups
    assert length(for(group <- reference["groups"], step <- group["steps"], do: step)) == 24

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
        stub(local, group["httpPayload"], uri.path)

        selected =
          config(local)
          |> Map.put(:base_url, Gaoxy.Test.url(fixture, prefix <> "/V1///"))
          |> Map.put(:count, Map.get(step["setup"]["searchConfig"], "maxResults", 5))

        assert {:ok, actual} = WebSearch.search(selected, step["arguments"])

        assert Map.delete(actual, "tookMs") ==
                 Map.delete(step["providerPortableResult"], "tookMs"),
               group["id"]

        assert is_integer(actual["tookMs"])
        assert actual["tookMs"] >= 0
        assert_receive {:ollama_http, path, body, _}
        assert path == uri.path, group["id"]
        assert body == step["request"]["body"], group["id"]
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  test "pinned hosted callbacks match pure request and result builders", ctx do
    callbacks =
      for group <- reference()["groups"],
          group["id"] in ["direct-hosted", "direct-hosted-prefix"],
          step <- group["steps"],
          do: {group, step}

    assert length(callbacks) == 2

    for {group, step} <- callbacks do
      source_request = step["request"]

      selected = %{
        config(ctx)
        | base_url: String.replace_suffix(source_request["url"], "/api/web_search", "/v1/"),
          api_key: "fixture-ollama-key"
      }

      assert {:ok, selected} = WebSearch.prepare_config(selected)
      assert {:ok, args} = WebSearch.prepare(selected, step["arguments"])
      assert {:ok, :post, url, headers, body} = Ollama.request(selected, args)
      assert url == source_request["url"], group["id"]
      assert body == source_request["body"], group["id"]

      for {name, value} <- source_request["headers"] do
        assert Map.new(headers)[String.downcase(name)] == value, group["id"]
      end

      assert {:ok, result} = Ollama.result(selected, args, group["httpPayload"])

      assert Map.merge(result, %{"provider" => "ollama", "query" => args["query"]}) ==
               Map.delete(step["providerPortableResult"], "tookMs"),
             group["id"]
    end
  end

  defp reference do
    Path.expand(
      "../../../../synapsis_agent/test/fixtures/openclaw/488631c/ollama-search.json",
      __DIR__
    )
    |> File.read!()
    |> Jason.decode!()
  end

  defp config(ctx),
    do: %{
      provider: "ollama",
      base_url: Gaoxy.Test.url(ctx.fixture, "/ordinary/v1/"),
      api_key: nil,
      timeout_ms: 15_000,
      count: 5,
      mode: "web"
    }

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
        "url" => "https://WWW.SOURCE.EXAMPLE:443/ordinary path?q=hello world#section",
        "snippet" => "First passage 🙂",
        "siteName" => "www.source.example"
      },
      %{
        "title" => "Second source",
        "url" => "http://NEWS.EXAMPLE:80/story",
        "snippet" => "Second passage 雪",
        "siteName" => "news.example"
      }
    ]
  end

  defp stub(ctx, payload, path \\ "/ordinary/api/experimental/web_search") do
    owner = self()

    Gaoxy.Test.stub(ctx.fixture, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:ollama_http, conn.request_path, Jason.decode!(body), conn.req_headers})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
