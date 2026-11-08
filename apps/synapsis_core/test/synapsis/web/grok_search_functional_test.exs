defmodule Synapsis.Web.GrokSearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.Web
  alias Synapsis.Web.Search.Cache

  setup do
    Code.ensure_loaded!(Synapsis.Web.Search)
    if is_nil(Process.whereis(Cache)), do: start_supervised!(Cache)
    counter = start_supervised!({Agent, fn -> [] end})
    {:ok, counter: counter}
  end

  test "all 59 pinned native Web callbacks retain complete generic maps and exactly 11 cache hits",
       ctx do
    reference = reference()
    assert length(reference["groups"]) == 41
    assert length(for group <- reference["groups"], step <- group["steps"], do: step) == 59

    assert length(
             for group <- reference["groups"], step <- group["steps"], step["cacheHit"], do: step
           ) == 11

    for group <- reference["groups"] do
      fixture = Gaoxy.Test.open()

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

          if source = step["request"] do
            assert length(requests(ctx)) == before_count + 1, group["id"]

            assert List.last(requests(ctx)) ==
                     {local_path(group, source["path"]), source["body"], source["headers"]},
                   group["id"]
          else
            assert length(requests(ctx)) == before_count, group["id"]
            assert actual["cached"] == true
          end

          assert step["arguments"] == step["argumentsAfter"]
          assert step["setup"] == step["setupAfter"]
        end
      after
        Gaoxy.Test.close(fixture)
      end
    end

    assert length(requests(ctx)) == 48
  end

  test "ordinary count, timeout, TTL and mode changes reuse canonical model and base identity",
       ctx do
    fixture = Gaoxy.Test.open()

    try do
      group = Enum.find(reference()["groups"], &(&1["id"] == "search-default"))
      install(fixture, ctx.counter, group)
      selected = config(fixture, group, hd(group["steps"]))
      args = %{"query" => " ordinary policy identity ", "count" => 2}
      assert {:ok, first} = search(selected, args)

      assert Map.delete(first, "tookMs") == %{
               "kind" => "answer",
               "provider" => "grok",
               "query" => args["query"],
               "content" => "Ordinary web answer.",
               "citations" => [%{"url" => "https://source.example/one"}]
             }

      equivalent = %{
        selected
        | base_url: " " <> selected.base_url <> "/// ",
          model: " grok-4.7-latest ",
          mode: "llm-context",
          timeout_ms: 15_000,
          count: 3,
          cache_ttl_ms: 60_000
      }

      assert {:ok, cached} =
               search(equivalent, %{"query" => "ordinary policy identity", "count" => " 4 "})

      assert cached ==
               first |> Map.put("query", "ordinary policy identity") |> Map.put("cached", true)

      assert length(requests(ctx)) == 1

      assert {:ok, bypassed} = search(%{selected | cache_ttl_ms: 0}, args)
      assert Map.delete(bypassed, "tookMs") == Map.delete(first, "tookMs")
      assert length(requests(ctx)) == 2
      assert {:ok, returning} = search(selected, args)
      assert returning == Map.put(first, "cached", true)
      assert length(requests(ctx)) == 2
    after
      Gaoxy.Test.close(fixture)
    end
  end

  defp search(config, args) do
    Web.search(Synapsis.Web.Search, args["query"], search_config: config, arguments: args)
  end

  defp config(fixture, group, step) do
    options =
      get_in(step, ["setup", "config", "plugins", "entries", "xai", "config", "webSearch"])

    search = step["setup"]["searchConfig"]
    base = options["baseUrl"] || "https://api.x.ai/v1"

    base_path =
      base |> String.trim() |> String.trim_trailing("/") |> URI.parse() |> Map.get(:path)

    %{
      provider: "grok",
      base_url: Gaoxy.Test.url(fixture, local_path(group, base_path || "")),
      api_key: "fixture-grok-key",
      model: options["model"],
      inline_citations: Map.get(options, "inlineCitations", false),
      timeout_ms: Map.get(search, "timeoutSeconds", 60) * 1000,
      cache_ttl_ms: round(Map.get(search, "cacheTtlMinutes", 15) * 60_000),
      count: Map.get(search, "maxResults", 5),
      mode: "web"
    }
  end

  defp install(fixture, counter, group) do
    sources = for step <- group["steps"], source = step["request"], do: source

    for source <- Enum.uniq_by(sources, & &1["path"]) do
      path = local_path(group, source["path"])

      Gaoxy.Test.stub(fixture, "POST", path, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        headers = conn.req_headers |> Map.new() |> Map.take(Map.keys(source["headers"]))
        Agent.update(counter, &(&1 ++ [{path, Jason.decode!(body), headers}]))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(group["httpPayload"]))
      end)
    end
  end

  defp local_path(group, path), do: "/grok/" <> group["id"] <> path
  defp requests(ctx), do: Agent.get(ctx.counter, & &1)

  defp reference do
    Path.expand(
      "../../../../synapsis_agent/test/fixtures/openclaw/488631c/grok-search.json",
      __DIR__
    )
    |> File.read!()
    |> Jason.decode!()
  end
end
