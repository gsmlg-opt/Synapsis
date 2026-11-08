defmodule Synapsis.Web.DuckDuckGoSearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.Web
  alias Synapsis.Web.Search.Cache

  setup do
    Code.ensure_loaded!(Synapsis.Web.Search)
    if is_nil(Process.whereis(Cache)), do: start_supervised!(Cache)
    counter = start_supervised!({Agent, fn -> [] end})
    {:ok, counter: counter}
  end

  test "all 48 pinned Web callbacks match complete generic maps, 34 GETs and 14 cache hits",
       ctx do
    reference = reference()
    assert length(reference["groups"]) == 26
    assert length(for group <- reference["groups"], step <- group["steps"], do: step) == 48

    assert length(
             for group <- reference["groups"], step <- group["steps"], step["cacheHit"], do: step
           ) == 14

    for group <- reference["groups"] do
      fixture = Gaoxy.Test.open()
      group_start = length(requests(ctx))

      try do
        install(fixture, ctx.counter, group)

        Enum.reduce(group["steps"], [], fn step, previous ->
          selected = config(fixture, group, step)
          before_count = length(requests(ctx))
          assert {:ok, actual} = search(selected, step["arguments"])

          expected = observed_timing(step["genericPortableResult"], actual)
          assert actual == expected, group["id"]

          if step["cacheHit"] do
            assert Enum.any?(previous, fn earlier ->
                     actual == cached_result(earlier, step["arguments"]["query"])
                   end),
                   group["id"]
          end

          assert Enum.drop(requests(ctx), before_count) ==
                   Enum.map(step["requests"], &expected_request(group, &1)),
                 group["id"]

          assert length(requests(ctx)) - group_start == step["cumulativeRequests"], group["id"]

          cached =
            if actual["kind"] == "raw",
              do: get_in(actual, ["data", "cached"]) == true,
              else: actual["cached"] == true

          assert cached == step["cacheHit"], group["id"]
          assert step["arguments"] == step["argumentsAfter"]
          assert step["setup"] == step["setupAfter"]
          previous ++ [actual]
        end)
      after
        Gaoxy.Test.close(fixture)
      end
    end

    assert length(requests(ctx)) == 34
  end

  test "effective count and region share cache while zero TTL preserves the earlier payload",
       ctx do
    fixture = Gaoxy.Test.open()

    try do
      source = Enum.find(reference()["groups"], &(&1["id"] == "search-default"))
      original_html = hd(source["httpPayloads"])

      fresh_html =
        "<a class=\"result__a\" href=\"https://fresh.example/one\">Fresh bypass title</a>" <>
          "<a class=\"result__snippet\">Fresh bypass snippet.</a>"

      group = %{
        source
        | "id" => "ordinary-effective-identity",
          "httpPayloads" => [original_html, original_html, fresh_html]
      }

      install(fixture, ctx.counter, group)
      step = hd(group["steps"])
      selected = %{config(fixture, group, step) | count: 3, region: " us-en "}
      args = %{"query" => " ordinary effective identity "}

      expected =
        step["genericPortableResult"] |> Map.put("query", args["query"]) |> Map.delete("tookMs")

      assert {:ok, first} = search(selected, args)
      assert Map.delete(first, "tookMs") == expected

      equivalent = %{
        selected
        | base_url: " " <> selected.base_url <> " ",
          region: "de-de",
          count: 2,
          mode: "llm-context",
          timeout_ms: 9_000,
          cache_ttl_ms: 60_000
      }

      explicit = %{
        "query" => "ordinary effective identity",
        "count" => 5,
        "region" => " us-en "
      }

      assert {:ok, cached} = search(equivalent, explicit)
      assert cached == cached_result(first, explicit["query"])
      assert length(requests(ctx)) == 1

      assert {:ok, declared_count} = search(%{selected | count: 2}, args)
      assert declared_count == cached_result(first, args["query"])
      assert length(requests(ctx)) == 1

      model_args = Map.put(args, "count", 3)
      assert {:ok, three} = search(selected, model_args)
      assert Map.delete(three, "tookMs") == expected
      assert length(requests(ctx)) == 2
      assert {:ok, explicit_three} = search(%{selected | count: 4}, model_args)
      assert explicit_three == cached_result(three, args["query"])
      assert length(requests(ctx)) == 2

      fresh = %{
        "kind" => "results",
        "provider" => "duckduckgo",
        "query" => args["query"],
        "count" => 1,
        "results" => [
          %{
            "title" => "Fresh bypass title",
            "url" => "https://fresh.example/one",
            "snippet" => "Fresh bypass snippet.",
            "siteName" => "fresh.example"
          }
        ]
      }

      assert {:ok, bypassed} = search(%{selected | cache_ttl_ms: 0}, args)
      assert Map.delete(bypassed, "tookMs") == fresh
      assert length(requests(ctx)) == 3
      assert {:ok, returning} = search(selected, args)
      assert returning == cached_result(first, args["query"])
      assert length(requests(ctx)) == 3

      first_endpoint = %{selected | base_url: selected.base_url <> "?old=one"}
      second_endpoint = %{selected | base_url: selected.base_url <> "?old=two"}
      assert {:ok, endpoint_one} = search(first_endpoint, args)
      assert Map.delete(endpoint_one, "tookMs") == fresh
      assert {:ok, endpoint_two} = search(second_endpoint, args)
      assert Map.delete(endpoint_two, "tookMs") == fresh
      assert length(requests(ctx)) == 5
      assert {:ok, endpoint_cached} = search(first_endpoint, args)
      assert endpoint_cached == cached_result(endpoint_one, args["query"])
      assert length(requests(ctx)) == 5

      wire = %{
        "method" => "GET",
        "path" => local_path(group),
        "query_string" => "q=ordinary+effective+identity&kl=us-en&kp=-1",
        "query" => %{"q" => "ordinary effective identity", "kl" => "us-en", "kp" => "-1"},
        "headers" => %{"user-agent" => user_agent()},
        "body" => ""
      }

      assert requests(ctx) == List.duplicate(wire, 5)
    after
      Gaoxy.Test.close(fixture)
    end
  end

  defp observed_timing(%{"kind" => "raw"} = expected, actual) do
    timing = get_in(actual, ["data", "tookMs"])
    assert is_integer(timing) and timing >= 0
    put_in(expected, ["data", "tookMs"], timing)
  end

  defp observed_timing(expected, actual) do
    assert is_integer(actual["tookMs"]) and actual["tookMs"] >= 0
    Map.put(expected, "tookMs", actual["tookMs"])
  end

  defp cached_result(%{"kind" => "raw"} = earlier, _query) do
    Map.update!(earlier, "data", &Map.put(&1, "cached", true))
  end

  defp cached_result(earlier, query) do
    earlier |> Map.put("cached", true) |> Map.put("query", query)
  end

  defp search(config, args) do
    Web.search(Synapsis.Web.Search, args["query"], search_config: config, arguments: args)
  end

  defp config(fixture, group, step) do
    options =
      get_in(step, ["setup", "config", "plugins", "entries", "duckduckgo", "config", "webSearch"])

    search = get_in(step, ["setup", "config", "tools", "web", "search"])

    %{
      provider: "duckduckgo",
      base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/") <> local_path(group),
      api_key: nil,
      credential_id: nil,
      credential_version: nil,
      region: options["region"],
      safe_search: nil,
      timeout_ms: 20_000,
      cache_ttl_ms: round(Map.get(search, "cacheTtlMinutes", 15) * 60_000),
      count: Map.get(search, "maxResults", 5),
      mode: "web"
    }
  end

  defp install(fixture, counter, group) do
    initial_count = Agent.get(counter, &length/1)

    Gaoxy.Test.stub(fixture, "GET", local_path(group), fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      observed = %{
        "method" => conn.method,
        "path" => conn.request_path,
        "query_string" => conn.query_string,
        "query" => URI.decode_query(conn.query_string),
        "headers" => conn.req_headers |> Map.new() |> Map.take(["user-agent"]),
        "body" => body
      }

      index = Agent.get_and_update(counter, &{length(&1) - initial_count, &1 ++ [observed]})
      html = Enum.at(group["httpPayloads"], min(index, length(group["httpPayloads"]) - 1))

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, html)
    end)
  end

  defp expected_request(group, source) do
    %{
      "method" => source["method"],
      "path" => local_path(group),
      "query_string" => URI.parse(source["url"]).query,
      "query" => source["query"],
      "headers" => %{"user-agent" => user_agent()},
      "body" => ""
    }
  end

  defp user_agent do
    "synapsis-duckduckgo/#{Application.spec(:synapsis_provider, :vsn)} (+https://github.com/gsmlg-opt/Synapsis)"
  end

  defp local_path(group), do: "/duckduckgo/" <> group["id"] <> "/html"
  defp requests(ctx), do: Agent.get(ctx.counter, & &1)

  defp reference do
    Path.expand(
      "../../../../synapsis_agent/test/fixtures/openclaw/488631c/duckduckgo-search.json",
      __DIR__
    )
    |> File.read!()
    |> Jason.decode!()
  end
end
