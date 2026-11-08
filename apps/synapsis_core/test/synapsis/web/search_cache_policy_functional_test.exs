defmodule Synapsis.Web.SearchCachePolicyFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Web.Search
  alias Synapsis.Web.Search.Cache

  @fixture Path.expand(
             "../../../../synapsis_agent/test/fixtures/openclaw/488631c/search-cache-policy.json",
             __DIR__
           )
  @clock_scale 100

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    counter = start_supervised!({Agent, fn -> [] end})

    if Code.ensure_loaded?(Cache) and is_nil(Process.whereis(Cache)),
      do: start_supervised!(Cache)

    previous = :sys.get_state(Cache)
    :sys.replace_state(Cache, fn _ -> %{entries: %{}, sequence: 0} end)
    on_exit(fn -> :sys.replace_state(Cache, fn _ -> previous end) end)
    {:ok, fixture: fixture, counter: counter}
  end

  test "execution timeout, TTL and overridden default count share ordinary search results", ctx do
    for provider <- ~w(brave tavily firecrawl) do
      install(ctx, provider)
      args = %{"query" => "policy #{provider}", "count" => 2}
      assert {:ok, first} = search(ctx, provider, args)

      assert {:ok, cached} =
               search(ctx, provider, args,
                 timeout_ms: 2_000,
                 cache_ttl_ms: 120_000,
                 count: 9
               )

      assert cached == Map.put(first, "cached", true)

      assert length(requests(ctx)) ==
               Enum.find_index(~w(brave tavily firecrawl), &(&1 == provider)) + 1
    end
  end

  test "Firecrawl per-call timeout preserves one result while raw options remain independent",
       ctx do
    install(ctx, "firecrawl")
    args = %{"query" => "timeout option", "count" => 2, "timeout_seconds" => 1}
    assert {:ok, first} = search(ctx, "firecrawl", args, generic: false)

    assert {:ok, second} =
             search(ctx, "firecrawl", Map.put(args, "timeout_seconds", 2), generic: false)

    assert second == Map.put(first, "cached", true)
    assert [{"firecrawl", body}] = requests(ctx)
    assert body == %{"query" => "timeout option", "limit" => 2}
    assert args["timeout_seconds"] == 1
  end

  test "zero TTL fetches fresh results and leaves the original shared value available", ctx do
    install(ctx, "brave")
    args = %{"query" => "disabled reuse", "count" => 1}
    assert {:ok, original} = search(ctx, "brave", args)
    assert {:ok, live_a} = search(ctx, "brave", args, cache_ttl_ms: 0)
    assert {:ok, live_b} = search(ctx, "brave", args, cache_ttl_ms: 0)
    assert live_a["results"] != original["results"]
    assert live_b["results"] != live_a["results"]
    assert {:ok, cached} = search(ctx, "brave", args)
    assert cached == Map.put(original, "cached", true)
    assert length(requests(ctx)) == 3
  end

  test "current shorter TTL refreshes shared HTTP results for the next longer caller", ctx do
    install(ctx, "tavily")
    args = %{"query" => "short caller", "count" => 1}
    assert {:ok, original} = search(ctx, "tavily", args)
    Process.sleep(250)
    assert {:ok, fresh} = search(ctx, "tavily", args, cache_ttl_ms: 200)
    assert fresh["results"] != original["results"]
    assert {:ok, cached} = search(ctx, "tavily", args)
    assert cached == Map.put(fresh, "cached", true)
    assert length(requests(ctx)) == 2
  end

  test "longer current TTL cannot extend the stored expiry", ctx do
    install(ctx, "brave")
    args = %{"query" => "stored expiry", "count" => 1}
    assert {:ok, original} = search(ctx, "brave", args, cache_ttl_ms: 10)
    Process.sleep(30)
    assert {:ok, fresh} = search(ctx, "brave", args)
    assert fresh["results"] != original["results"]
    assert {:ok, cached} = search(ctx, "brave", args)
    assert cached == Map.put(fresh, "cached", true)
    assert length(requests(ctx)) == 2
  end

  test "a shorter reader reuses no old value without evicting it for a longer reader" do
    assert :ok = Cache.put("caller-age", %{"value" => "original"}, 60_000)
    Process.sleep(10)
    assert :miss = Cache.get("caller-age", 1)
    assert {:ok, %{"value" => "original"}} = Cache.get("caller-age", 60_000)
    assert :miss = Cache.get("caller-age", 0)
    assert {:ok, %{"value" => "original"}} = Cache.get("caller-age")
  end

  test "ordinary updates retain insertion order and prune before full-cache replacement" do
    for index <- 1..100, do: assert(:ok == Cache.put(index, %{"value" => index}, 60_000))
    assert :ok = Cache.put(50, %{"value" => "updated"}, 60_000)
    assert :miss = Cache.get(1)
    assert {:ok, %{"value" => 2}} = Cache.get(2)
    assert {:ok, %{"value" => "updated"}} = Cache.get(50)
    assert :ok = Cache.put(101, %{"value" => 101}, 60_000)
    assert {:ok, %{"value" => 2}} = Cache.get(2)

    for index <- 102..149, do: assert(:ok == Cache.put(index, %{"value" => index}, 60_000))

    assert :miss = Cache.get(49)
    assert {:ok, %{"value" => "updated"}} = Cache.get(50)
    assert :ok = Cache.put(150, %{"value" => 150}, 60_000)
    assert :miss = Cache.get(50)
    assert {:ok, %{"value" => 51}} = Cache.get(51)
  end

  test "ordinary reads expire only their requested key before insertion-order pruning" do
    for index <- 1..100 do
      ttl = if index == 50, do: 10, else: 60_000
      assert :ok = Cache.put(index, %{"value" => index}, ttl)
    end

    Process.sleep(30)
    assert {:ok, %{"value" => 1}} = Cache.get(1)
    assert :ok = Cache.put(101, %{"value" => 101}, 60_000)
    assert :miss = Cache.get(1)
    assert :miss = Cache.get(50)
    assert {:ok, %{"value" => 2}} = Cache.get(2)
  end

  test "generic projection remains distinct from dedicated rich search results", ctx do
    install(ctx, "tavily")
    args = %{"query" => "projection", "count" => 1}
    assert {:ok, generic} = search(ctx, "tavily", args)
    assert {:ok, rich} = search(ctx, "tavily", args, generic: false)
    assert generic["kind"] == "results"
    assert rich["answer"] == "Fixture answer"
    assert length(requests(ctx)) == 2
    assert {:ok, cached} = search(ctx, "tavily", args, timeout_ms: 2_000)
    assert cached == Map.put(generic, "cached", true)
    assert length(requests(ctx)) == 2
  end

  test "complete pinned public callbacks match HTTP and cache policy observations", ctx do
    reference = Jason.decode!(File.read!(@fixture))
    assert length(reference["publicGroups"]) == 8
    assert Enum.sum(Enum.map(reference["publicGroups"], &length(&1["steps"]))) == 36
    install(ctx, "brave", "web")
    install(ctx, "brave", "llm-context")

    for group <- reference["publicGroups"] do
      clear_cache()
      Agent.update(ctx.counter, fn _ -> [] end)

      Enum.reduce(group["steps"], %{}, fn step, writes ->
        rebase_clock(writes, step["elapsedMs"])
        policy = step["policy"]
        count_before = length(requests(ctx))

        assert {:ok, result} =
                 search(ctx, "brave", step["arguments"],
                   mode: group["mode"],
                   cache_ttl_ms: policy["ttlMs"] * @clock_scale,
                   timeout_ms: policy["timeoutMs"],
                   count: policy["defaultCount"]
                 )

        assert result["cached"] == true == step["cached"], group["id"]
        assert length(requests(ctx)) == step["cumulativeRequests"], group["id"]

        if step["request"] do
          assert length(requests(ctx)) == count_before + 1
          assert {"brave", input} = List.last(requests(ctx))
          assert input == step["request"]["query"]
        else
          assert length(requests(ctx)) == count_before
        end

        assert Enum.map(result["results"], & &1["url"]) ==
                 Enum.map(step["result"]["results"], fn row ->
                   index = row["url"] |> String.split("source-") |> List.last()
                   "https://cache.example/#{index}"
                 end)

        if step["cached"] or policy["ttlMs"] == 0 do
          writes
        else
          for {key, entry} <- :sys.get_state(Cache).entries, into: %{} do
            assert entry.expires_at - entry.inserted_at == policy["ttlMs"] * @clock_scale
            {key, {step["elapsedMs"], policy["ttlMs"]}}
          end
        end
      end)
    end
  end

  test "complete pinned cache helpers match value, key order and capacity observations" do
    reference = Jason.decode!(File.read!(@fixture))
    assert length(reference["helperGroups"]) == 7

    for group <- reference["helperGroups"] do
      clear_cache()

      Enum.reduce(group["steps"], %{}, fn step, writes ->
        rebase_clock(writes, step["elapsedMs"])
        key = step["key"]

        writes =
          if step["operation"] == "put" do
            assert :ok = Cache.put(key, step["value"], step["ttlMs"] * @clock_scale)

            if step["ttlMs"] > 0,
              do: Map.put(writes, key, {step["elapsedMs"], step["ttlMs"]}),
              else: writes
          else
            ttl = if is_integer(step["ttlMs"]), do: step["ttlMs"] * @clock_scale, else: :infinity
            expected = if step["result"], do: {:ok, step["result"]["value"]}, else: :miss
            assert Cache.get(key, ttl) == expected, group["id"]
            writes
          end

        entries = :sys.get_state(Cache).entries
        assert map_size(entries) == step["state"]["size"], group["id"]

        assert entries
               |> Enum.sort_by(fn {_, entry} -> entry.sequence end)
               |> Enum.map(&elem(&1, 0)) ==
                 step["state"]["keys"],
               group["id"]

        if target = step["state"]["target"] do
          assert entries[key].value == target["value"]

          assert entries[key].expires_at - entries[key].inserted_at ==
                   (target["expiresAtMs"] - target["insertedAtMs"]) * @clock_scale
        else
          assert entries[key] == nil
        end

        writes
      end)
    end
  end

  # Only the test process rebases stored timestamps. Scaling leaves scheduling
  # room before adjacent reference-clock boundaries; no production clock is replaced.
  defp rebase_clock(writes, elapsed) do
    :sys.replace_state(Cache, fn state ->
      timestamp = System.monotonic_time(:millisecond)

      entries =
        Map.new(state.entries, fn {key, entry} ->
          {inserted, ttl} = Map.fetch!(writes, key)
          start = timestamp - (elapsed - inserted) * @clock_scale
          {key, %{entry | inserted_at: start, expires_at: start + ttl * @clock_scale}}
        end)

      %{state | entries: entries}
    end)
  end

  defp clear_cache, do: :sys.replace_state(Cache, fn _ -> %{entries: %{}, sequence: 0} end)

  defp search(ctx, provider, args, opts \\ []) do
    config = %{
      provider: provider,
      base_url: Gaoxy.Test.url(ctx.fixture),
      api_key: "ordinary-cache-fixture",
      credential_version: <<1, 2, 3>>,
      timeout_ms: Keyword.get(opts, :timeout_ms, 5_000),
      cache_ttl_ms: Keyword.get(opts, :cache_ttl_ms, 60_000),
      count: Keyword.get(opts, :count, 5),
      mode: Keyword.get(opts, :mode, "web")
    }

    Search.search(args["query"],
      search_config: config,
      arguments: args,
      generic: Keyword.get(opts, :generic, true)
    )
  end

  defp requests(ctx), do: Agent.get(ctx.counter, & &1)

  defp install(ctx, provider, mode \\ "web") do
    {method, path} =
      case provider do
        "brave" ->
          {"GET", if(mode == "web", do: "/res/v1/web/search", else: "/res/v1/llm/context")}

        "tavily" ->
          {"POST", "/search"}

        "firecrawl" ->
          {"POST", "/v2/search"}
      end

    Gaoxy.Test.stub(ctx.fixture, method, path, fn conn ->
      {input, conn} =
        if method == "GET" do
          {Plug.Conn.fetch_query_params(conn).query_params, conn}
        else
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          {Jason.decode!(body), conn}
        end

      index =
        Agent.get_and_update(ctx.counter, fn rows ->
          {length(rows) + 1, rows ++ [{provider, input}]}
        end)

      row = %{
        "title" => "Source #{index}",
        "url" => "https://cache.example/#{index}",
        "description" => "Passage #{index}",
        "content" => "Passage #{index}"
      }

      payload =
        case provider do
          "brave" when mode == "llm-context" -> %{"grounding" => %{"generic" => [row]}}
          "brave" -> %{"web" => %{"results" => [row]}}
          "tavily" -> %{"results" => [row], "answer" => "Fixture answer"}
          "firecrawl" -> %{"success" => true, "data" => %{"web" => [row]}}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
