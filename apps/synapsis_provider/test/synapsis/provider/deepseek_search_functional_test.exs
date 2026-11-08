defmodule Synapsis.Provider.DeepSeekSearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.WebSearch

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "default DeepSeek POST sends the private trimmed query and requests summaries", ctx do
    stub(ctx, %{"results" => []})
    args = %{"query" => " ordinary DeepSeek search "}

    assert {:ok, result} = WebSearch.search(config(ctx), args)
    assert_receive {:deepseek_http, body, headers}

    assert body == %{
             "query" => "ordinary DeepSeek search",
             "count" => 5,
             "need_content" => false
           }

    assert Map.new(headers)["accept"] == "application/json"
    assert Map.new(headers)["content-type"] == "application/json"

    assert Map.delete(result, "tookMs") == %{
             "query" => "ordinary DeepSeek search",
             "provider" => "deepseek",
             "count" => 0,
             "results" => []
           }

    assert is_integer(result["tookMs"])
    assert result["tookMs"] >= 0
    assert args == %{"query" => " ordinary DeepSeek search "}
  end

  test "ordered summaries and snippet fallback retain trimmed metadata and ordinary canonical URLs",
       ctx do
    stub(ctx, %{
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
    })

    assert {:ok, result} = WebSearch.search(config(ctx), %{"query" => "source metadata"})

    assert Map.delete(result, "tookMs") == %{
             "query" => "source metadata",
             "provider" => "deepseek",
             "count" => 2,
             "results" => [
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
           }
  end

  test "configured and explicit ordinary counts reach the DeepSeek request", ctx do
    stub(ctx, %{"results" => []})

    assert {:ok, _} = WebSearch.search(%{config(ctx) | count: 3}, %{"query" => "configured"})
    assert_receive {:deepseek_http, configured, _}
    assert configured == %{"query" => "configured", "count" => 3, "need_content" => false}

    assert {:ok, _} =
             WebSearch.search(%{config(ctx) | count: 3}, %{"query" => "explicit", "count" => 2})

    assert_receive {:deepseek_http, explicit, _}
    assert explicit == %{"query" => "explicit", "count" => 2, "need_content" => false}
  end

  test "positive Unicode search operators survive intact and empty results are successful", ctx do
    stub(ctx, %{"results" => []})

    query =
      ~s(雪🙂 "语言模型" site:example.org -site:archive.example lang:zh after:2026-01-01 before:2026-11-01)

    assert {:ok, result} = WebSearch.search(config(ctx), %{"query" => query, "count" => 2})
    assert_receive {:deepseek_http, body, _}
    assert body == %{"query" => query, "count" => 2, "need_content" => false}

    assert Map.delete(result, "tookMs") == %{
             "query" => query,
             "provider" => "deepseek",
             "count" => 0,
             "results" => []
           }
  end

  test "every pinned HTTP callback matches the complete portable provider result", ctx do
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
        stub(local, group["httpPayload"])
        outer = step["setup"]["searchConfig"]

        config =
          config(local)
          |> Map.put(:count, Map.get(outer, "maxResults", 5))
          |> Map.put(:timeout_ms, Map.get(outer, "timeoutSeconds", 30) * 1000)

        assert {:ok, actual} = WebSearch.search(config, step["arguments"])

        assert Map.delete(actual, "tookMs") ==
                 Map.delete(step["providerPortableResult"], "tookMs"),
               group["id"]

        assert_receive {:deepseek_http, body, _}
        assert body == step["request"]["body"], group["id"]
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  defp config(ctx),
    do: %{
      provider: "deepseek",
      base_url: Gaoxy.Test.url(ctx.fixture, "/"),
      api_key: "ordinary-deepseek-fixture",
      timeout_ms: 5000,
      count: 5,
      mode: "web"
    }

  defp stub(ctx, payload) do
    owner = self()

    Gaoxy.Test.stub(ctx.fixture, "POST", "/v1/tools/search", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:deepseek_http, Jason.decode!(body), conn.req_headers})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
