defmodule Synapsis.Web.SearxngSearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.Web
  alias Synapsis.Web.Search.Cache

  setup do
    Code.ensure_loaded!(Synapsis.Web.Search)
    if is_nil(Process.whereis(Cache)), do: start_supervised!(Cache)
    counter = start_supervised!({Agent, fn -> [] end})
    {:ok, counter: counter}
  end

  test "all 55 pinned Web callbacks match complete generic maps, 44 GETs and 12 cache hits",
       ctx do
    reference = reference()
    assert length(reference["groups"]) == 32
    assert length(for group <- reference["groups"], step <- group["steps"], do: step) == 55

    assert length(
             for group <- reference["groups"], step <- group["steps"], step["cacheHit"], do: step
           ) == 12

    for group <- reference["groups"] do
      fixture = Gaoxy.Test.open()
      group_start = length(requests(ctx))

      try do
        install(fixture, ctx.counter, group)

        for step <- group["steps"] do
          selected = config(fixture, group, step)
          before_count = length(requests(ctx))
          assert {:ok, actual} = search(selected, step["arguments"])

          assert Map.delete(actual, "tookMs") ==
                   Map.delete(step["genericPortableResult"], "tookMs"),
                 group["id"]

          assert is_integer(actual["tookMs"]) and actual["tookMs"] >= 0

          assert Enum.drop(requests(ctx), before_count) ==
                   Enum.map(step["requests"], &expected_request(group, &1)),
                 group["id"]

          assert length(requests(ctx)) - group_start == step["cumulativeRequests"], group["id"]
          assert Map.get(actual, "cached", false) == step["cacheHit"], group["id"]
          assert step["arguments"] == step["argumentsAfter"]
          assert step["setup"] == step["setupAfter"]
        end
      after
        Gaoxy.Test.close(fixture)
      end
    end

    assert length(requests(ctx)) == 44
  end

  test "effective defaults share cache while discarded configured query retains base identity",
       ctx do
    fixture = Gaoxy.Test.open()

    try do
      source = Enum.find(reference()["groups"], &(&1["id"] == "search-default"))
      original_payload = hd(source["httpPayloads"])

      bypass_payload = %{
        "results" => [
          %{
            "title" => "Fresh bypass title",
            "url" => "https://fresh.example/one",
            "content" => "Fresh bypass snippet."
          }
        ]
      }

      group = %{
        source
        | "id" => "ordinary-effective-policy",
          "httpPayloads" => [original_payload, original_payload, bypass_payload]
      }

      install(fixture, ctx.counter, group)
      step = hd(group["steps"])
      selected = %{config(fixture, group, step) | categories: " news ", language: " en "}
      args = %{"query" => " ordinary effective identity "}

      expected =
        step["genericPortableResult"] |> Map.delete("tookMs") |> Map.put("query", args["query"])

      assert {:ok, first} = search(selected, args)
      assert Map.delete(first, "tookMs") == expected

      equivalent = %{
        selected
        | base_url: " " <> selected.base_url <> "/// ",
          categories: "science",
          language: "de",
          count: 3,
          mode: "llm-context",
          timeout_ms: 9_000,
          cache_ttl_ms: 60_000
      }

      explicit = %{
        "query" => "ordinary effective identity",
        "count" => 5,
        "categories" => " news ",
        "language" => " en "
      }

      assert {:ok, cached} = search(equivalent, explicit)
      assert cached == first |> Map.put("query", explicit["query"]) |> Map.put("cached", true)
      assert length(requests(ctx)) == 1

      configured = %{selected | count: 2}
      assert {:ok, two} = search(configured, args)
      assert Map.delete(two, "tookMs") == expected
      assert length(requests(ctx)) == 2
      assert {:ok, explicit_two} = search(%{selected | count: 4}, Map.put(args, "count", 2))
      assert explicit_two == Map.put(two, "cached", true)
      assert length(requests(ctx)) == 2

      fresh = %{
        "kind" => "results",
        "provider" => "searxng",
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
      assert returning == Map.put(first, "cached", true)
      assert length(requests(ctx)) == 3

      first_base = %{selected | base_url: selected.base_url <> "?old=one"}
      second_base = %{selected | base_url: selected.base_url <> "?old=two"}
      assert {:ok, base_one} = search(first_base, args)
      assert Map.delete(base_one, "tookMs") == fresh
      assert {:ok, base_two} = search(second_base, args)
      assert Map.delete(base_two, "tookMs") == fresh
      assert length(requests(ctx)) == 5
      assert {:ok, base_cached} = search(first_base, args)
      assert base_cached == Map.put(base_one, "cached", true)
      assert length(requests(ctx)) == 5

      wire = %{
        "method" => "GET",
        "path" => local_path(group, "/search"),
        "query_string" => "q=ordinary+effective+identity&format=json&categories=news&language=en",
        "query" => %{
          "q" => "ordinary effective identity",
          "format" => "json",
          "categories" => "news",
          "language" => "en"
        },
        "headers" => %{"accept" => "application/json"},
        "body" => ""
      }

      assert requests(ctx) == List.duplicate(wire, 5)
    after
      Gaoxy.Test.close(fixture)
    end
  end

  defp search(config, args) do
    Web.search(Synapsis.Web.Search, args["query"], search_config: config, arguments: args)
  end

  defp config(fixture, group, step) do
    options =
      get_in(step, ["setup", "config", "plugins", "entries", "searxng", "config", "webSearch"])

    search = get_in(step, ["setup", "config", "tools", "web", "search"])
    uri = options["baseUrl"] |> String.trim() |> String.trim_trailing("/") |> URI.parse()
    origin = String.trim_trailing(Gaoxy.Test.url(fixture), "/")

    base =
      origin <> local_path(group, uri.path || "") <> if(uri.query, do: "?" <> uri.query, else: "")

    %{
      provider: "searxng",
      base_url: base,
      api_key: nil,
      credential_id: nil,
      credential_version: nil,
      categories: options["categories"],
      language: options["language"],
      timeout_ms: Map.get(search, "timeoutSeconds", 20) * 1000,
      cache_ttl_ms: round(Map.get(search, "cacheTtlMinutes", 15) * 60_000),
      count: Map.get(search, "maxResults", 5),
      mode: "web"
    }
  end

  defp install(fixture, counter, group) do
    sources = for step <- group["steps"], source <- step["requests"], do: source
    initial_count = Agent.get(counter, &length/1)

    for source <- Enum.uniq_by(sources, & &1["path"]) do
      path = local_path(group, source["path"])

      Gaoxy.Test.stub(fixture, "GET", path, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        observed = %{
          "method" => conn.method,
          "path" => conn.request_path,
          "query_string" => conn.query_string,
          "query" => URI.decode_query(conn.query_string),
          "headers" => conn.req_headers |> Map.new() |> Map.take(Map.keys(source["headers"])),
          "body" => body
        }

        index = Agent.get_and_update(counter, &{length(&1) - initial_count, &1 ++ [observed]})
        payload = Enum.at(group["httpPayloads"], min(index, length(group["httpPayloads"]) - 1))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(payload))
      end)
    end
  end

  defp expected_request(group, source) do
    %{
      "method" => source["method"],
      "path" => local_path(group, source["path"]),
      "query_string" => URI.parse(source["url"]).query,
      "query" => source["query"],
      "headers" => source["headers"],
      "body" => ""
    }
  end

  defp local_path(group, path), do: "/searxng/" <> group["id"] <> path
  defp requests(ctx), do: Agent.get(ctx.counter, & &1)

  defp reference do
    Path.expand(
      "../../../../synapsis_agent/test/fixtures/openclaw/488631c/searxng-search.json",
      __DIR__
    )
    |> File.read!()
    |> Jason.decode!()
  end
end
