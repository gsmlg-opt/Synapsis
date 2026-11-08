defmodule Synapsis.Web.GeminiSearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.Web
  alias Synapsis.Web.Search.Cache

  setup do
    Code.ensure_loaded!(Synapsis.Web.Search)
    if is_nil(Process.whereis(Cache)), do: start_supervised!(Cache)
    counter = start_supervised!({Agent, fn -> %{posts: [], heads: []} end})
    {:ok, counter: counter}
  end

  test "every pinned generic callback uses real HEAD resolution before projection and cache",
       ctx do
    reference = reference()
    assert length(reference["groups"]) == 36
    assert Enum.sum(Enum.map(reference["groups"], &length(&1["steps"]))) == 47

    assert Enum.count(
             for(group <- reference["groups"], step <- group["steps"], do: step),
             & &1["cacheHit"]
           ) == 8

    for group <- reference["groups"] do
      fixture = Gaoxy.Test.open()

      try do
        local = Map.merge(ctx, %{fixture: fixture, group: group})
        offset = Agent.get(ctx.counter, & &1)
        install(local)

        for step <- group["steps"] do
          config = config(local, step)
          {:ok, now, 0} = DateTime.from_iso8601(step["clock"])
          assert {:ok, actual} = search(local, config, step["arguments"], request_time: now)

          assert Map.delete(actual, "tookMs") ==
                   Map.delete(step["genericPortableResult"], "tookMs"),
                 group["id"]

          assert is_integer(actual["tookMs"]) and actual["tookMs"] >= 0
          state = Agent.get(ctx.counter, & &1)
          posts = Enum.drop(state.posts, length(offset.posts))
          heads = Enum.drop(state.heads, length(offset.heads))
          assert length(posts) == step["cumulativeRequests"], group["id"]

          expected_posts =
            group["steps"]
            |> Enum.take_while(&(&1 != step))
            |> Kernel.++([step])
            |> Enum.filter(& &1["request"])
            |> Enum.map(fn item ->
              source = item["request"]

              {local_path(group, source["path"]), source["body"],
               Map.delete(source["headers"], "x-goog-api-client")}
            end)

          assert posts == expected_posts, group["id"]

          expected_heads =
            group["steps"]
            |> Enum.take_while(&(&1 != step))
            |> Kernel.++([step])
            |> Enum.flat_map(& &1["headRequests"])
            |> Enum.flat_map(fn head ->
              if head["url"] == head["finalUrl"],
                do: [head["url"]],
                else: [head["url"], head["finalUrl"]]
            end)

          # Citation requests run concurrently; only arrival order is unordered.
          assert Enum.frequencies(heads) == Enum.frequencies(expected_heads), group["id"]
          assert step["arguments"] == step["argumentsAfter"]
        end
      after
        Gaoxy.Test.close(fixture)
      end
    end

    assert length(Agent.get(ctx.counter, & &1.posts)) == 39
  end

  test "ordinary canonical roots, ignored count and normalized declared policy retain cache identity",
       ctx do
    group = hd(reference()["groups"])
    fixture = Gaoxy.Test.open()

    try do
      local =
        Map.merge(ctx, %{fixture: fixture, group: %{group | "id" => "host-policy-identity"}})

      install(local)
      step = hd(group["steps"])
      selected = config(local, step)
      args = %{"query" => " ordinary host policy ", "count" => 2}
      assert {:ok, first} = search(local, selected, args, request_time: ~U[2026-10-27 12:00:00Z])

      equivalent = %{
        selected
        | base_url: selected.base_url <> "///",
          count: 4,
          mode: "llm-context",
          timeout_ms: 9000
      }

      assert {:ok, cached} =
               search(local, equivalent, %{"query" => "ordinary host policy", "count" => 4},
                 request_time: ~U[2026-11-07 12:00:00Z]
               )

      assert cached ==
               first |> Map.put("query", "ordinary host policy") |> Map.put("cached", true)

      another_policy =
        Map.update!(selected, :citation_allowed_hosts, &Enum.sort(["ordinary.example" | &1]))

      assert {:ok, distinct} = search(local, another_policy, args)
      assert Map.delete(distinct, "tookMs") == Map.delete(first, "tookMs")
      assert {:ok, returning} = search(local, selected, args)
      assert returning == Map.put(first, "cached", true)
      assert length(Agent.get(ctx.counter, & &1.posts)) == 2

      assert Enum.frequencies(Agent.get(ctx.counter, & &1.heads)) == %{
               "https://source.example/ordinary" => 2,
               "https://source.example/second" => 2
             }
    after
      Gaoxy.Test.close(fixture)
    end
  end

  defp search(ctx, config, args, opts \\ []) do
    routing = fn uri, timeout ->
      local = Gaoxy.Test.url(ctx.fixture, head_path(ctx.group, URI.to_string(uri))) |> URI.parse()
      Synapsis.Web.Transport.head(local, timeout)
    end

    Web.search(
      Synapsis.Web.Search,
      args["query"],
      Keyword.merge([search_config: config, arguments: args, citation_transport: routing], opts)
    )
  end

  defp config(ctx, step) do
    options =
      get_in(step, ["setup", "config", "plugins", "entries", "google", "config", "webSearch"])

    model_base = get_in(step, ["setup", "config", "models", "providers", "google", "baseUrl"])
    base = options["baseUrl"] || model_base || "https://generativelanguage.googleapis.com/v1beta"
    base = String.trim(base) |> String.trim_trailing("/")

    base =
      if base == "https://generativelanguage.googleapis.com", do: base <> "/v1beta", else: base

    base_path = URI.parse(base).path || ""

    hosts =
      for step <- ctx.group["steps"],
          head <- step["headRequests"],
          url <- [head["url"], head["finalUrl"]],
          do: URI.parse(url).host

    %{
      provider: "gemini",
      base_url: Gaoxy.Test.url(ctx.fixture, local_path(ctx.group, base_path)),
      api_key: "fixture-gemini-key",
      model: options["model"] || "gemini-3.6-flash",
      headers: options["headers"] || %{},
      timeout_ms: Map.get(step["setup"]["searchConfig"], "timeoutSeconds", 30) * 1000,
      cache_ttl_ms: round(step["setup"]["searchConfig"]["cacheTtlMinutes"] * 60_000),
      count: step["setup"]["searchConfig"]["maxResults"],
      mode: "web",
      citation_allowed_hosts: Enum.sort(Enum.uniq(hosts)),
      citation_policy: :declared_hosts_v1
    }
  end

  defp install(ctx) do
    sources = for step <- ctx.group["steps"], source = step["request"], do: source

    for source <- Enum.uniq_by(sources, & &1["path"]) do
      path = local_path(ctx.group, source["path"])

      Gaoxy.Test.stub(ctx.fixture, "POST", path, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        names =
          ~w(content-type x-goog-api-key) ++
            Enum.map(Map.keys(source["headers"]), &String.downcase/1)

        headers = conn.req_headers |> Map.new() |> Map.take(names -- ["x-goog-api-client"])

        Agent.update(
          ctx.counter,
          &%{&1 | posts: &1.posts ++ [{path, Jason.decode!(body), headers}]}
        )

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(ctx.group["httpPayload"]))
      end)
    end

    heads = for step <- ctx.group["steps"], head <- step["headRequests"], do: head
    sources = for head <- heads, url <- [head["url"], head["finalUrl"]], do: url

    for url <- Enum.uniq(sources) do
      target = Map.get(ctx.group["redirectMap"], url, url)

      Gaoxy.Test.stub(ctx.fixture, "HEAD", head_path(ctx.group, url), fn conn ->
        Agent.update(ctx.counter, &%{&1 | heads: &1.heads ++ [url]})

        if target == url,
          do: Plug.Conn.resp(conn, 200, ""),
          else: conn |> Plug.Conn.put_resp_header("location", target) |> Plug.Conn.resp(302, "")
      end)
    end
  end

  defp local_path(group, path), do: "/gemini/" <> group["id"] <> path

  defp head_path(group, url),
    do: "/heads/" <> group["id"] <> "/" <> Base.url_encode64(url, padding: false)

  defp reference do
    Path.expand(
      "../../../../synapsis_agent/test/fixtures/openclaw/488631c/gemini-search.json",
      __DIR__
    )
    |> File.read!()
    |> Jason.decode!()
  end
end
