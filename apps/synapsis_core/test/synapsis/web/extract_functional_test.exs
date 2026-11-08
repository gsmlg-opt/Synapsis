defmodule Synapsis.Web.ExtractFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Web.Extract
  alias Synapsis.Web.Extract.Cache

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    counter = start_supervised!({Agent, fn -> [] end})
    if Code.ensure_loaded?(Cache) and is_nil(Process.whereis(Cache)), do: start_supervised!(Cache)
    {:ok, fixture: fixture, counter: counter}
  end

  test "ordinary normalized repeats reuse extraction independently of search TTL and timeout",
       context do
    stub(context)
    config = config(context) |> Map.put(:cache_ttl_ms, 0)

    args = %{
      "urls" => [" https://one.example/a ", "https://two.example/b"],
      "query" => " ordinary query ",
      "include_images" => false
    }

    assert {:ok, first} = Extract.extract(config, args)

    assert {:ok, second} =
             Extract.extract(%{config | timeout_ms: 7_000}, %{
               args
               | "urls" => ["https://one.example/a", "https://two.example/b"],
                 "query" => "ordinary query"
             })

    assert second == Map.put(first, "cached", true)
    assert Agent.get(context.counter, &length/1) == 1

    assert first["results"] == [
             %{
               "url" => "https://one.example/a",
               "rawContent" => "  ordinary extraction\n",
               "content" => "",
               "images" => []
             }
           ]
  end

  test "ordinary option changes and ordered URL arrays select different extraction entries",
       context do
    stub(context)

    args = %{
      "urls" => ["https://one.example/a", "https://two.example/b"],
      "query" => "ordinary query"
    }

    variants = [
      args,
      Map.put(args, "extract_depth", "basic"),
      Map.put(args, "extract_depth", "advanced"),
      Map.put(args, "chunks_per_source", 1),
      Map.put(args, "chunks_per_source", 5),
      Map.put(args, "include_images", true),
      Map.put(args, "query", "another query"),
      Map.put(args, "urls", Enum.reverse(args["urls"])),
      Map.put(args, "urls", args["urls"] ++ [hd(args["urls"])])
    ]

    for variant <- variants do
      assert {:ok, result} = Extract.extract(config(context), variant)
      assert Map.keys(result) |> Enum.sort() == ~w(count provider results tookMs)
      assert {:ok, cached} = Extract.extract(config(context), variant)
      assert cached == Map.put(result, "cached", true)
    end

    assert Agent.get(context.counter, &length/1) == length(variants)
  end

  test "extraction entries do not consume the search cache capacity", context do
    search_entries = for _ <- 1..100, do: {make_ref(), %{"ordinary" => true}}

    for {key, value} <- search_entries,
        do: assert(:ok = Synapsis.Web.Search.Cache.put(key, value, 900_000))

    stub(context)
    assert {:ok, _} = Extract.extract(config(context), %{"urls" => ["https://one.example/a"]})

    for {key, value} <- search_entries,
        do: assert(Synapsis.Web.Search.Cache.get(key) == {:ok, value})
  end

  defp config(context) do
    %{
      api_key: "ordinary-fixture-key",
      base_url: Gaoxy.Test.url(context.fixture),
      timeout_ms: 5_000,
      credential_id: "fixture",
      credential_version: "1"
    }
  end

  defp stub(context) do
    Gaoxy.Test.stub(context.fixture, "POST", "/extract", fn conn ->
      {:ok, body, _} = Plug.Conn.read_body(conn)
      Agent.update(context.counter, &[Jason.decode!(body) | &1])

      payload = %{
        "results" => [
          %{
            "url" => "https://one.example/a",
            "raw_content" => "  ordinary extraction\n",
            "content" => "",
            "images" => []
          }
        ]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
