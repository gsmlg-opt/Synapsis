defmodule Synapsis.Web.ExaSearchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional
  alias Backplane.AgentRuntime.Codex.Web
  alias Synapsis.Provider.WebSearch.TextBudget
  alias Synapsis.Web.Search.Cache

  setup do
    Code.ensure_loaded!(Synapsis.Web.Search)
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    counter = start_supervised!({Agent, fn -> [] end})
    if is_nil(Process.whereis(Cache)), do: start_supervised!(Cache)
    {:ok, fixture: fixture, counter: counter}
  end

  test "native Exa callback forwards rich options and normalizes a hundred results into ten ordered rows",
       ctx do
    payload = %{
      "results" =>
        for(
          index <- 1..100,
          do: %{
            "title" => " Source #{index} ",
            "url" => "https://www.example.org/#{index}",
            "highlights" => [" Passage #{index} ", " 次の行 "],
            "summary" => "Summary",
            "highlightScores" => [0.9, 0],
            "publishedDate" => "2026-01-02"
          }
        )
    }

    install(ctx, payload)

    args = %{
      "query" => " Exa full options ",
      "count" => 100,
      "type" => "deep",
      "date_after" => " 2026-01-01 ",
      "date_before" => "2026-02-03",
      "contents" => %{
        "highlights" => %{
          "maxCharacters" => 40,
          "query" => " raw ",
          "numSentences" => 2,
          "highlightsPerUrl" => 3
        },
        "text" => false,
        "summary" => true
      }
    }

    assert {:ok, result} = search(ctx, args)
    assert result["query"] == args["query"]
    assert result["kind"] == "results"
    assert result["provider"] == "exa"
    assert result["count"] == 10
    assert result["truncated"] == true

    assert Enum.map(result["results"], & &1["title"]) ==
             for(index <- 1..10, do: "Source #{index}")

    assert Enum.map(result["results"], & &1["snippet"]) ==
             for(index <- 1..10, do: "Passage #{index}\n次の行")

    assert Enum.all?(
             result["results"],
             &(&1["siteName"] == "www.example.org" and &1["published"] == "2026-01-02")
           )

    assert [
             %{
               "query" => "Exa full options",
               "numResults" => 100,
               "type" => "deep",
               "contents" => contents,
               "startPublishedDate" => "2026-01-01",
               "endPublishedDate" => "2026-02-03"
             }
           ] = requests(ctx)

    assert contents == args["contents"]
  end

  test "canonical defaults share cache and keep current raw query while timeout and caller TTL preserve prior entries",
       ctx do
    install(ctx, %{
      "results" => [
        %{"title" => "Title", "url" => "https://example.org/", "summary" => "Summary"}
      ]
    })

    raw = %{"query" => " canonical Exa "}
    assert {:ok, original} = search(ctx, raw)

    assert {:ok, cached} =
             search(ctx, %{"query" => "canonical Exa", "type" => "auto", "contents" => %{}},
               timeout_ms: 7000
             )

    assert cached == original |> Map.put("query", "canonical Exa") |> Map.put("cached", true)

    assert requests(ctx) == [
             %{
               "query" => "canonical Exa",
               "numResults" => 5,
               "type" => "auto",
               "contents" => %{"highlights" => true}
             }
           ]

    for _ <- 1..2, do: assert({:ok, _} = search(ctx, raw, cache_ttl_ms: 0))
    assert {:ok, retained} = search(ctx, raw)
    assert retained == Map.put(original, "cached", true)
    assert length(requests(ctx)) == 3
    assert {:ok, _} = search(ctx, Map.put(raw, "type", "neural"))
    assert {:ok, _} = search(ctx, Map.put(raw, "contents", %{"text" => true}))
    assert {:ok, _} = search(ctx, Map.put(raw, "count", 6))
    assert length(requests(ctx)) == 6
  end

  test "generic UTF16 budget reserves every retained URL before complete-scalar text", ctx do
    url = "https://example.org/ordinary"

    install(ctx, %{
      "results" => [
        %{
          "title" => String.duplicate("🙂", 10_001),
          "url" => url,
          "highlights" => ["Full source passage"],
          "publishedDate" => "2026-01-02"
        }
      ]
    })

    assert {:ok, result} = search(ctx, %{"query" => "Exa UTF16"})
    [row] = result["results"]
    assert row["url"] == url
    assert row["title"] == String.duplicate("🙂", div(20_000 - TextBudget.units(url), 2))
    assert result["truncated"] == true

    assert Enum.sum(
             for key <- ~w(title url snippet siteName), do: TextBudget.units(row[key] || "")
           ) <= 20_000
  end

  test "every pinned HTTP-bearing Exa callback matches the complete generic public result", ctx do
    reference =
      Path.expand(
        "../../../../synapsis_agent/test/fixtures/openclaw/488631c/exa-search.json",
        __DIR__
      )
      |> File.read!()
      |> Jason.decode!()

    callbacks =
      for group <- reference["groups"],
          {step, index} <- Enum.with_index(group["steps"]),
          is_map(step["request"]),
          do: {group, step, index}

    assert length(callbacks) == 55

    for {group, step, index} <- callbacks do
      prefix = "/reference/" <> group["id"] <> "/" <> Integer.to_string(index)
      install(ctx, group["httpPayload"], prefix)
      outer = step["setup"]["searchConfig"]

      assert {:ok, actual} =
               search(ctx, step["arguments"],
                 base_path: prefix,
                 count: outer["maxResults"],
                 cache_ttl_ms: 0,
                 timeout_ms: Map.get(outer, "timeoutSeconds", 30) * 1000
               )

      assert Map.delete(actual, "tookMs") == Map.delete(step["publicPortableResult"], "tookMs"),
             group["id"]
    end
  end

  defp search(ctx, args, opts \\ []) do
    config = %{
      provider: "exa",
      base_url: Gaoxy.Test.url(ctx.fixture, Keyword.get(opts, :base_path, "/proxy")),
      api_key: "ordinary-exa-fixture",
      credential_version: <<1>>,
      timeout_ms: Keyword.get(opts, :timeout_ms, 5000),
      cache_ttl_ms: Keyword.get(opts, :cache_ttl_ms, 60_000),
      count: Keyword.get(opts, :count, 5),
      mode: "web"
    }

    Web.search(Synapsis.Web.Search, args["query"], search_config: config, arguments: args)
  end

  defp requests(ctx), do: Agent.get(ctx.counter, & &1)

  defp install(ctx, payload, prefix \\ "/proxy") do
    Gaoxy.Test.stub(ctx.fixture, "POST", prefix <> "/search", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(ctx.counter, &(&1 ++ [Jason.decode!(body)]))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
