defmodule Synapsis.Provider.KimiSearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.WebSearch

  @groups ~w(search-default operator-query unicode-query configured-count configured-count-string
    explicit-count numeric-count-token configured-timeout endpoint-model-ai endpoint-model-cn
    endpoint-explicit-cn endpoint-custom endpoint-trailing-slashes ordered-metadata sparse-results
    successful-empty same-cache-reuse empty-cache-reuse)

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "ordinary POST sends the trimmed private query and default limit", ctx do
    stub(ctx, "/v1/tools/search", %{"search_results" => []})
    arguments = %{"query" => " ordinary Kimi search "}

    assert {:ok, result} = WebSearch.search(config(ctx), arguments)
    assert_receive {:kimi_http, path, body, headers}
    assert path == "/v1/tools/search"
    assert body == %{"text_query" => "ordinary Kimi search", "limit" => 5}
    assert Map.new(headers)["content-type"] == "application/json"

    assert Map.delete(result, "tookMs") == %{
             "query" => "ordinary Kimi search",
             "provider" => "kimi",
             "count" => 0,
             "results" => []
           }

    assert is_integer(result["tookMs"])
    assert result["tookMs"] >= 0
    assert arguments == %{"query" => " ordinary Kimi search "}
  end

  test "ordered rows preserve raw trimmed URLs and descriptions with URL-derived metadata", ctx do
    stub(ctx, "/v1/tools/search", %{
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
          "url" => " http://NEWS.EXAMPLE:80/story ",
          "snippet" => " Second passage ",
          "date" => "2026-11-02",
          "site_name" => "Supplied news label"
        }
      ]
    })

    assert {:ok, result} = WebSearch.search(config(ctx), %{"query" => "source metadata"})

    assert Map.delete(result, "tookMs") == %{
             "query" => "source metadata",
             "provider" => "kimi",
             "count" => 2,
             "results" => [
               %{
                 "title" => "First source 雪",
                 "url" => "https://WWW.SOURCE.EXAMPLE:443/ordinary path?q=hello world#section",
                 "description" => "First passage 🙂",
                 "published" => "2026-11-01",
                 "siteName" => "www.source.example"
               },
               %{
                 "title" => "Second source",
                 "url" => "http://NEWS.EXAMPLE:80/story",
                 "description" => "Second passage",
                 "published" => "2026-11-02",
                 "siteName" => "news.example"
               }
             ]
           }
  end

  test "sparse successful rows retain empty title and description", ctx do
    stub(ctx, "/v1/tools/search", %{
      "search_results" => [%{"url" => " https://sparse.example/story "}]
    })

    assert {:ok, result} = WebSearch.search(config(ctx), %{"query" => "sparse ordinary source"})

    assert Map.delete(result, "tookMs") == %{
             "provider" => "kimi",
             "query" => "sparse ordinary source",
             "count" => 1,
             "results" => [
               %{
                 "title" => "",
                 "url" => "https://sparse.example/story",
                 "description" => "",
                 "siteName" => "sparse.example"
               }
             ]
           }
  end

  test "ordinary configured counts and numeric count tokens select the exact request limit",
       ctx do
    stub(ctx, "/v1/tools/search", %{"search_results" => []})

    for {configured, extra, expected} <- [
          {3, %{}, 3},
          {"3", %{}, 5},
          {3, %{"count" => 2}, 2},
          {3, %{"count" => "2e0"}, 2}
        ] do
      arguments = Map.put(extra, "query", " ordinary count ")
      assert {:ok, result} = WebSearch.search(%{config(ctx) | count: configured}, arguments)
      assert_receive {:kimi_http, "/v1/tools/search", body, _}
      assert body == %{"text_query" => "ordinary count", "limit" => expected}
      assert result["results"] == []
      assert result["count"] == 0
    end
  end

  test "explicit base prefixes and trailing slashes preserve the search route", ctx do
    for path <- ["/v1/tools/search", "/custom/search-api/tools/search"] do
      stub(ctx, path, %{"search_results" => []})
    end

    for {prefix, path} <- [
          {"/v1", "/v1/tools/search"},
          {"/v1///", "/v1/tools/search"},
          {"/custom/search-api/", "/custom/search-api/tools/search"}
        ] do
      local = Map.put(config(ctx), :base_url, Gaoxy.Test.url(ctx.fixture, prefix))
      assert {:ok, result} = WebSearch.search(local, %{"query" => "endpoint prefix"})
      assert_receive {:kimi_http, ^path, body, _}
      assert body == %{"text_query" => "endpoint prefix", "limit" => 5}
      assert result["results"] == []
    end
  end

  test "every pinned HTTP callback matches its complete portable provider result", ctx do
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
        stub(local, path, group["httpPayload"])
        outer = step["setup"]["searchConfig"]

        local_config =
          config(local)
          |> Map.put(:base_url, Gaoxy.Test.url(fixture, prefix))
          |> Map.put(:count, Map.get(outer, "maxResults", 5))
          |> Map.put(:timeout_ms, Map.get(outer, "timeoutSeconds", 30) * 1000)

        assert {:ok, actual} = WebSearch.search(local_config, step["arguments"])

        assert Map.delete(actual, "tookMs") ==
                 Map.delete(step["providerPortableResult"], "tookMs"),
               group["id"]

        assert is_integer(actual["tookMs"])
        assert actual["tookMs"] >= 0
        assert_receive {:kimi_http, actual_path, body, _}
        assert actual_path == path, group["id"]
        assert body == step["request"]["body"], group["id"]
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

  defp config(ctx),
    do: %{
      provider: "kimi",
      base_url: Gaoxy.Test.url(ctx.fixture, "/v1"),
      api_key: "ordinary-kimi-fixture",
      timeout_ms: 5000,
      count: 5,
      mode: "web"
    }

  defp stub(ctx, path, payload) do
    owner = self()

    Gaoxy.Test.stub(ctx.fixture, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:kimi_http, conn.request_path, Jason.decode!(body), conn.req_headers})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
