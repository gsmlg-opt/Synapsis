defmodule Synapsis.Web.XSearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Web.XSearch
  alias Synapsis.Web.XSearch.Cache

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    counter = start_supervised!({Agent, fn -> [] end})
    if Code.ensure_loaded?(Cache) and is_nil(Process.whereis(Cache)), do: start_supervised!(Cache)
    {:ok, fixture: fixture, counter: counter}
  end

  test "normalized ordinary repeats reuse the independent X-search cache", context do
    stub(context)
    config = config(context)

    assert {:ok, first} =
             XSearch.search(config, %{
               "query" => " ordinary query ",
               "allowed_x_handles" => [" Alpha "]
             })

    assert {:ok, second} =
             XSearch.search(%{config | timeout_ms: 7_000}, %{
               "query" => "ordinary query",
               "allowed_x_handles" => ["Alpha"]
             })

    assert second == Map.put(first, "cached", true)
    assert first["content"] == "ordinary answer"
    assert Agent.get(context.counter, &length/1) == 1
  end

  test "ordinary source options and model variants select distinct entries", context do
    stub(context)
    arguments = %{"query" => "ordinary query"}

    variants = [
      arguments,
      Map.put(arguments, "allowed_x_handles", ["Alpha", "Beta"]),
      Map.put(arguments, "allowed_x_handles", ["Beta", "Alpha"]),
      Map.put(arguments, "excluded_x_handles", ["Alpha"]),
      Map.put(arguments, "from_date", "2024-02-29"),
      Map.put(arguments, "to_date", "2024-03-01"),
      Map.put(arguments, "enable_image_understanding", true),
      Map.put(arguments, "enable_video_understanding", true)
    ]

    for args <- variants do
      assert {:ok, first} = XSearch.search(config(context), args)
      assert {:ok, repeated} = XSearch.search(config(context), args)
      assert repeated == Map.put(first, "cached", true)
    end

    for extra <- [%{model: "grok-4.3"}, %{inline_citations: true}, %{max_turns: 3}] do
      config = Map.merge(config(context), extra)
      assert {:ok, first} = XSearch.search(config, arguments)
      assert {:ok, repeated} = XSearch.search(config, arguments)
      assert repeated == Map.put(first, "cached", true)
    end

    assert Agent.get(context.counter, &length/1) == length(variants) + 3
  end

  test "explicit zero TTL performs ordinary repeated provider requests", context do
    stub(context)
    config = Map.put(config(context), :cache_ttl_ms, 0)
    assert {:ok, first} = XSearch.search(config, %{"query" => "ordinary query"})
    assert {:ok, second} = XSearch.search(config, %{"query" => "ordinary query"})
    assert Map.delete(first, "tookMs") == Map.delete(second, "tookMs")
    assert Agent.get(context.counter, &length/1) == 2
  end

  test "shorter caller TTL limits reuse without deleting the existing entry" do
    key = make_ref()
    value = %{"ordinary" => true}
    assert :ok = Cache.put(key, value, 900_000)
    assert Cache.get(key, 0) == :miss
    assert Cache.get(key, 900_000) == {:ok, value}
  end

  test "X-search capacity is independent of existing search and extraction entries", context do
    search = for _ <- 1..100, do: {make_ref(), %{"ordinary" => true}}
    extract = for _ <- 1..100, do: {make_ref(), %{"ordinary" => true}}

    for {key, value} <- search,
        do: assert(:ok = Synapsis.Web.Search.Cache.put(key, value, 900_000))

    for {key, value} <- extract, do: assert(:ok = Synapsis.Web.Extract.Cache.put(key, value))
    stub(context)
    assert {:ok, _} = XSearch.search(config(context), %{"query" => "ordinary query"})
    for {key, value} <- search, do: assert(Synapsis.Web.Search.Cache.get(key) == {:ok, value})
    for {key, value} <- extract, do: assert(Synapsis.Web.Extract.Cache.get(key) == {:ok, value})
  end

  defp config(context),
    do: %{
      api_key: "ordinary-fixture-key",
      base_url: Gaoxy.Test.url(context.fixture, "/v1"),
      timeout_ms: 5_000,
      credential_id: "fixture",
      credential_version: "1",
      cache_ttl_ms: 900_000
    }

  defp stub(context) do
    Gaoxy.Test.stub(context.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(context.counter, &[Jason.decode!(body) | &1])

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"output_text" => "ordinary answer"}))
    end)
  end
end
