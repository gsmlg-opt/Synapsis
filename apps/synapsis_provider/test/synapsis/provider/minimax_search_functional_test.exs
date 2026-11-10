defmodule Synapsis.Provider.MiniMaxSearchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Provider.WebSearch

  @groups ~w(search-default operator-query unicode-query configured-count configured-count-string
    explicit-count numeric-count-token configured-timeout endpoint-explicit-cn endpoint-explicit-global
    endpoint-model-global endpoint-model-cn endpoint-portal-cn ordered-metadata sparse-results
    successful-empty successful-missing-organic successful-status-zero same-cache-reuse empty-cache-reuse
    count-cache-identity)

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "ordinary POST sends only the private trimmed query", ctx do
    stub(ctx, %{"organic" => []})
    arguments = %{"query" => " ordinary MiniMax search 雪🙂 ", "count" => 2}

    assert {:ok, result} = WebSearch.search(config(ctx), arguments)
    assert_receive {:minimax_http, path, body, headers}
    assert path == "/v1/coding_plan/search"
    assert body == %{"q" => "ordinary MiniMax search 雪🙂"}
    assert Map.new(headers)["accept"] == "application/json"
    assert Map.new(headers)["content-type"] == "application/json"

    assert Map.delete(result, "tookMs") == %{
             "provider" => "minimax",
             "query" => "ordinary MiniMax search 雪🙂",
             "count" => 0,
             "results" => []
           }

    assert is_integer(result["tookMs"])
    assert result["tookMs"] >= 0
    assert arguments == %{"query" => " ordinary MiniMax search 雪🙂 ", "count" => 2}
  end

  test "ordered results preserve raw title link snippet date and related query whitespace", ctx do
    stub(ctx, %{
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
      "related_searches" => [
        %{"query" => " Related source 雪 "},
        %{"query" => "  "},
        %{"query" => "Related news 🙂"},
        %{"query" => ""},
        %{}
      ],
      "base_resp" => %{"status_code" => 0, "status_msg" => "success"}
    })

    assert {:ok, result} =
             WebSearch.search(config(ctx), %{"query" => "source metadata", "count" => 2})

    assert Map.delete(result, "tookMs") == %{
             "provider" => "minimax",
             "query" => "source metadata",
             "count" => 2,
             "results" => [
               %{
                 "title" => " First source 雪 ",
                 "url" => " https://WWW.SOURCE.EXAMPLE:443/ordinary path?q=hello world#section ",
                 "description" => " First passage 🙂 ",
                 "published" => " 2026-11-01 ",
                 "siteName" => "www.source.example"
               },
               %{
                 "title" => " Second source ",
                 "url" => "http://NEWS.EXAMPLE:80/story",
                 "description" => " Second passage ",
                 "published" => "2026-11-02",
                 "siteName" => "news.example"
               }
             ],
             "relatedSearches" => [" Related source 雪 ", "  ", "Related news 🙂"]
           }
  end

  test "configured counts and explicit numeric tokens slice locally without changing the body",
       ctx do
    organic =
      for index <- 1..7 do
        %{"title" => "Source #{index}", "link" => "https://source.example/#{index}"}
      end

    stub(ctx, %{"organic" => organic})

    for {configured, extra, expected} <- [
          {5, %{}, 5},
          {3, %{}, 3},
          {3.9, %{}, 3},
          {"3", %{}, 5},
          {3, %{"count" => 2}, 2},
          {3, %{"count" => "2e0"}, 2}
        ] do
      arguments = Map.put(extra, "query", " ordinary count ")
      assert {:ok, result} = WebSearch.search(%{config(ctx) | count: configured}, arguments)
      assert_receive {:minimax_http, "/v1/coding_plan/search", body, _}
      assert body == %{"q" => "ordinary count"}

      assert Map.delete(result, "tookMs") == %{
               "provider" => "minimax",
               "query" => "ordinary count",
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

  test "explicit region chooses its default origin and trusted synthetic origins keep the fixed route",
       ctx do
    for {extra, base} <- [
          {%{}, "https://api.minimax.io/v1/coding_plan/search"},
          {%{region: "global"}, "https://api.minimax.io/v1/coding_plan/search"},
          {%{region: "cn"}, "https://api.minimaxi.com/v1/coding_plan/search"},
          {%{base_url: nil, region: "cn"}, "https://api.minimaxi.com/v1/coding_plan/search"}
        ] do
      assert {:ok, prepared} =
               config(ctx)
               |> Map.delete(:base_url)
               |> Map.merge(extra)
               |> WebSearch.prepare_config()

      assert prepared.base_url == base
    end

    stub(ctx, %{"organic" => []})

    for region <- ["global", "cn"],
        suffix <- ["/", "///", "/ordinary/prefix?view=source#section"] do
      local =
        config(ctx)
        |> Map.put(:base_url, Gaoxy.Test.url(ctx.fixture, suffix))
        |> Map.put(:region, region)

      assert {:ok, result} = WebSearch.search(local, %{"query" => "synthetic origin"})
      assert_receive {:minimax_http, "/v1/coding_plan/search", body, _}
      assert body == %{"q" => "synthetic origin"}
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

    assert length(callbacks) == 22

    for {group, step} <- callbacks do
      fixture = Gaoxy.Test.open()

      try do
        local = %{ctx | fixture: fixture}
        stub(local, group["httpPayload"])
        outer = step["setup"]["searchConfig"]

        region =
          if URI.parse(step["request"]["url"]).host == "api.minimaxi.com",
            do: "cn",
            else: "global"

        local_config =
          config(local)
          |> Map.put(:region, region)
          |> Map.put(:count, Map.get(outer, "maxResults", 5))
          |> Map.put(:timeout_ms, Map.get(outer, "timeoutSeconds", 30) * 1000)

        assert {:ok, actual} = WebSearch.search(local_config, step["arguments"])

        assert Map.delete(actual, "tookMs") ==
                 Map.delete(step["providerPortableResult"], "tookMs"),
               group["id"]

        assert is_integer(actual["tookMs"])
        assert actual["tookMs"] >= 0
        assert_receive {:minimax_http, path, body, _}
        assert path == "/v1/coding_plan/search", group["id"]
        assert body == step["request"]["body"], group["id"]
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

  defp config(ctx),
    do: %{
      provider: "minimax",
      base_url: Gaoxy.Test.url(ctx.fixture, "/"),
      api_key: "ordinary-minimax-fixture",
      timeout_ms: 5000,
      count: 5,
      mode: "web"
    }

  defp stub(ctx, payload) do
    owner = self()

    Gaoxy.Test.stub(ctx.fixture, "POST", "/v1/coding_plan/search", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:minimax_http, conn.request_path, Jason.decode!(body), conn.req_headers})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
