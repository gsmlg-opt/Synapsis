defmodule Synapsis.Web.PerplexitySearchFunctionalTest do
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

  test "native public search retains options and separates Search count",
       ctx do
    install(ctx, %{
      "results" => [
        %{"title" => "Source", "url" => "https://example.org/source", "snippet" => "Passage"}
      ]
    })

    raw = %{
      "query" => " cache search ",
      "language" => " EN ",
      "freshness" => " PW ",
      "count" => 2
    }

    assert {:ok, first} = search(ctx, raw)
    assert first["kind"] == "results"
    assert first["query"] == raw["query"]

    assert {:ok, cached} =
             search(ctx, %{
               raw
               | "query" => "cache search",
                 "language" => "EN",
                 "freshness" => "week"
             })

    assert cached == first |> Map.put("query", "cache search") |> Map.put("cached", true)
    assert length(requests(ctx)) == 1

    assert {"/proxy/search",
            %{"search_language_filter" => ["EN"], "search_recency_filter" => "week"}} =
             {elem(hd(requests(ctx)), 0),
              Map.take(
                elem(hd(requests(ctx)), 1),
                ~w(search_language_filter search_recency_filter)
              )}

    assert {:ok, _} = search(ctx, Map.put(raw, "count", 3))
    assert length(requests(ctx)) == 2
  end

  test "pinned public callbacks retain source fields, cache identity and raw caller query", ctx do
    reference = reference()
    assert length(reference["groups"]) == 25
    assert Enum.sum(Enum.map(reference["groups"], &length(&1["steps"]))) == 54

    for group <- reference["groups"], group["mode"] == "search_api" do
      offset = length(requests(ctx))
      install(ctx, group["httpPayload"], "/" <> group["id"])

      for step <- group["steps"] do
        outer = step["setup"]["searchConfig"]
        ttl = round(outer["cacheTtlMinutes"] * 60_000)
        if ttl == 1, do: Process.sleep(3)

        assert {:ok, result} =
                 search(ctx, step["arguments"],
                   count: outer["maxResults"],
                   cache_ttl_ms: ttl,
                   base_path: "/" <> group["id"],
                   timeout_ms: Map.get(outer, "timeoutSeconds", 30) * 1000
                 )

        assert Map.drop(result, ["tookMs"]) ==
                 Map.drop(step["publicUnwrappedResult"], ~w(externalContent tookMs)),
               group["id"]

        assert length(requests(ctx)) == offset + step["cumulativeRequests"], group["id"]

        if request = step["request"] do
          {_, actual} = List.last(requests(ctx))

          assert actual == request["body"], group["id"]
        end

        assert step["arguments"] == step["argumentsAfter"]
      end
    end
  end

  defp reference do
    path =
      Path.expand(
        "../../../../synapsis_agent/test/fixtures/openclaw/488631c/perplexity-search.json",
        __DIR__
      )

    Jason.decode!(File.read!(path))
  end

  defp search(ctx, args, opts \\ []) do
    config = %{
      provider: "perplexity",
      base_url: Gaoxy.Test.url(ctx.fixture, Keyword.get(opts, :base_path, "/proxy")),
      api_key: "ordinary-perplexity-fixture",
      credential_version: <<1>>,
      timeout_ms: Keyword.get(opts, :timeout_ms, 5000),
      cache_ttl_ms: Keyword.get(opts, :cache_ttl_ms, 60_000),
      count: Keyword.get(opts, :count, 5),
      mode: "search_api"
    }

    Web.search(Synapsis.Web.Search, args["query"], search_config: config, arguments: args)
  end

  defp requests(ctx), do: Agent.get(ctx.counter, & &1)

  defp install(ctx, payload, prefix \\ "/proxy") do
    path = prefix <> "/search"

    Gaoxy.Test.stub(ctx.fixture, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(ctx.counter, &(&1 ++ [{path, Jason.decode!(body)}]))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
