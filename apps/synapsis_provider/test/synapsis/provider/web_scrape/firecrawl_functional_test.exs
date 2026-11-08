defmodule Synapsis.Provider.WebScrape.FirecrawlFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.WebScrape.Firecrawl
  alias Synapsis.Provider.WebSearch.TextBudget

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "default preparation keeps local mode and budgets outside the exact wire body" do
    assert {:ok, prepared} = Firecrawl.prepare(%{}, %{"url" => " https://source.example/a "})

    assert prepared == %{
             body: %{
               "url" => "https://source.example/a",
               "formats" => ["markdown"],
               "onlyMainContent" => true,
               "timeout" => 60_000,
               "maxAge" => 172_800_000,
               "proxy" => "auto",
               "storeInCache" => true
             },
             timeout_ms: 60_000,
             extract_mode: "markdown",
             max_chars: 50_000
           }
  end

  test "literal false and zero options override configured defaults and timeout follows seconds" do
    config = %{timeout_ms: 17_999, only_main_content: true, max_age_ms: 99, max_chars_cap: 80_000}

    args = %{
      "url" => "https://source.example/a",
      "extractMode" => " text ",
      "maxChars" => 70_000,
      "onlyMainContent" => false,
      "maxAgeMs" => 0,
      "proxy" => " stealth ",
      "storeInCache" => false,
      "timeoutSeconds" => 3
    }

    assert {:ok, prepared} = Firecrawl.prepare(config, args)
    assert prepared.extract_mode == "text"
    assert prepared.max_chars == 70_000
    assert prepared.timeout_ms == 3_000

    assert prepared.body == %{
             "url" => args["url"],
             "formats" => ["markdown"],
             "onlyMainContent" => false,
             "timeout" => 3_000,
             "maxAge" => 0,
             "proxy" => "stealth",
             "storeInCache" => false
           }

    assert {:ok, defaults} =
             Firecrawl.prepare(%{config | only_main_content: false, max_age_ms: 0}, %{
               "url" => args["url"]
             })

    assert defaults.timeout_ms == 17_000
    assert defaults.body["onlyMainContent"] == false
    assert defaults.body["maxAge"] == 0
    assert defaults.max_chars == 50_000
    assert {:ok, capped} = Firecrawl.prepare(%{max_chars_cap: 100}, args)
    assert capped.max_chars == 100
    assert {:ok, clamped} = Firecrawl.prepare(%{}, Map.put(args, "timeoutSeconds", 2_147_999))
    assert clamped.timeout_ms == 2_147_000_000
  end

  test "POST replaces endpoint path and clears query and fragment with portable metadata",
       context do
    owner = self()

    stub(context, fn conn, body ->
      send(owner, {:request, conn.method, conn.request_path, conn.query_string, body})

      %{
        "success" => true,
        "warning" => "  warning\n",
        "data" => %{
          "markdown" => "  # Body\n",
          "content" => "ignored",
          "url" => "https://fallback.example/page",
          "statusCode" => 201,
          "metadata" => %{
            "statusCode" => "206.9",
            "title" => " Title \n",
            "sourceURL" => "https://FINAL.example:443/page?q=1#part"
          },
          "html" => "ignored",
          "links" => ["ignored"]
        }
      }
    end)

    assert {:ok, result} =
             Firecrawl.scrape(config(context, "/proxy/nested?route=ordinary#fragment"), %{
               "url" => " https://source.example/a "
             })

    assert_receive {:request, "POST", "/v2/scrape", "", body}

    assert body == %{
             "url" => "https://source.example/a",
             "formats" => ["markdown"],
             "onlyMainContent" => true,
             "timeout" => 10_000,
             "maxAge" => 172_800_000,
             "proxy" => "auto",
             "storeInCache" => true
           }

    assert result == %{
             "url" => "https://source.example/a",
             "finalUrl" => "https://final.example/page?q=1#part",
             "status" => 206,
             "title" => " Title \n",
             "extractor" => "firecrawl",
             "extractMode" => "markdown",
             "truncated" => false,
             "rawLength" => 9,
             "length" => 9,
             "text" => "  # Body\n",
             "warning" => "  warning\n"
           }
  end

  test "fallback content preserves HTML and optional status and URL fields", context do
    stub(context, fn _, _ ->
      %{
        "data" => %{
          "markdown" => "",
          "content" => " <h1>Literal</h1> ",
          "url" => "https://fallback.example",
          "statusCode" => "203",
          "title" => "ignored"
        }
      }
    end)

    args = %{"url" => "https://source.example/a"}
    assert {:ok, result} = Firecrawl.scrape(config(context), args)

    assert result ==
             portable(args["url"], " <h1>Literal</h1> ")
             |> Map.merge(%{"finalUrl" => "https://fallback.example", "status" => 203})
  end

  test "whitespace-only Markdown is ordinary content and remains unchanged", context do
    args = %{"url" => "https://source.example/a"}
    stub(context, fn _, _ -> %{"data" => %{"markdown" => " \t\n"}} end)
    assert {:ok, whitespace} = Firecrawl.scrape(config(context), args)
    assert whitespace == portable(args["url"], " \t\n")
  end

  test "Unicode body budgets preserve scalars and metadata shares title-first 4000 units",
       context do
    title = String.duplicate("a", 3_999) <> "😀"

    stub(context, fn _, _ ->
      %{
        "data" => %{"markdown" => "界😀étail", "metadata" => %{"title" => title}},
        "warning" => "😀later"
      }
    end)

    assert {:ok, result} =
             Firecrawl.scrape(config(context), %{
               "url" => "https://source.example/a",
               "maxChars" => 4
             })

    assert result["text"] == "界😀e"
    assert result["length"] == 4
    assert result["rawLength"] == 9
    assert result["title"] == String.duplicate("a", 3_999)
    assert result["warning"] == ""
    assert result["truncated"] == true
    assert TextBudget.units(result["title"]) == 3_999
  end

  test "text mode converts prose but preserves fenced code, NULs and line boundaries", context do
    markdown =
      " # Heading\r\n\n- [label](https://example.com)  and `inline` ![alt](image.png)\n\n```elixir\n  # literal  \n\t- [link](url)\n```\n2. Last\n\n\nEnd\0literal"

    expected =
      "# Heading\n\nlabel and inline\n\n  # literal  \n\t- [link](url)\n\nLast\n\nEnd\0literal"

    stub(context, fn _, body ->
      assert body["formats"] == ["markdown"]
      %{"data" => %{"markdown" => markdown}}
    end)

    assert {:ok, result} =
             Firecrawl.scrape(config(context), %{
               "url" => "https://source.example/a",
               "extractMode" => "text"
             })

    assert result == portable("https://source.example/a", expected, "text")
  end

  test "text headings and lists recognize CR and Unicode line boundaries", context do
    markdown =
      "# first\r## second\u2028- third\u2029+ fourth\r1. fifth\u2028# sixth\u2029* seventh"

    expected = "firstsecond\u2028third\u2029fourthfifth\u2028sixth\u2029seventh"
    stub(context, fn _, _ -> %{"data" => %{"markdown" => markdown}} end)

    assert {:ok, result} =
             Firecrawl.scrape(config(context), %{
               "url" => "https://source.example/a",
               "extractMode" => "text"
             })

    assert result == portable("https://source.example/a", expected, "text")
  end

  test "text numbered lists strip ASCII digits and preserve ordinary Unicode digit prefixes",
       context do
    markdown = "١. Arabic\n１. Fullwidth\n1. ASCII\n١٢. Kept"
    expected = "١. Arabic\n１. Fullwidth\nASCII\n١٢. Kept"
    stub(context, fn _, _ -> %{"data" => %{"markdown" => markdown}} end)

    assert {:ok, result} =
             Firecrawl.scrape(config(context), %{
               "url" => "https://source.example/a",
               "extractMode" => "text"
             })

    assert result == portable("https://source.example/a", expected, "text")
  end

  test "source numeric tokens retain scientific trailing decimal points", context do
    args = %{
      "url" => "https://source.example/a",
      "maxChars" => "1.e2",
      "timeoutSeconds" => "3.e0"
    }

    stub(context, fn _, body ->
      assert body["timeout"] == 3_000

      %{
        "data" => %{
          "markdown" => String.duplicate("x", 101),
          "metadata" => %{"statusCode" => "2.e2"}
        }
      }
    end)

    assert {:ok, prepared} = Firecrawl.prepare(config(context), args)
    assert prepared.max_chars == 100
    assert prepared.timeout_ms == 3_000
    assert {:ok, result} = Firecrawl.scrape(config(context), args)

    assert result ==
             portable(args["url"], String.duplicate("x", 100))
             |> Map.merge(%{"status" => 200, "rawLength" => 101, "truncated" => true})
  end

  test "raw JSON responses above sixteen MiB are read before the local body budget", context do
    raw = String.duplicate("x", 16 * 1024 * 1024 + 1)
    stub(context, fn _, _ -> %{"data" => %{"markdown" => raw}} end)

    assert {:ok, result} =
             Firecrawl.scrape(config(context), %{
               "url" => "https://source.example/a",
               "maxChars" => 100
             })

    assert result["text"] == String.duplicate("x", 100)
    assert result["rawLength"] == byte_size(raw)
    assert result["length"] == 100
    assert result["truncated"] == true
  end

  test "whole pinned source successful groups replay exact HTTP and full portable maps" do
    fixture_path =
      Path.expand(
        "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/firecrawl-scrape.json",
        __DIR__
      )

    capture = fixture_path |> File.read!() |> Jason.decode!()
    assert capture["pin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    groups = capture["groups"]
    assert length(groups) >= 19

    for group <- groups, step <- group["steps"] do
      fixture = Gaoxy.Test.open()
      owner = self()
      id = group["id"]
      request = step["request"]
      source_config = group["config"]

      fetch =
        get_in(source_config, ["plugins", "entries", "firecrawl", "config", "webFetch"]) || %{}

      cfg = %{
        api_key: "ordinary-fixture-key",
        base_url: Gaoxy.Test.url(fixture) <> "/discard?ordinary=1#fragment",
        timeout_ms: Map.get(fetch, "timeoutSeconds", 60) * 1_000,
        only_main_content: Map.get(fetch, "onlyMainContent", true),
        max_age_ms: Map.get(fetch, "maxAgeMs", 172_800_000),
        max_chars_cap: get_in(source_config, ["tools", "web", "fetch", "maxCharsCap"]) || 50_000
      }

      try do
        Gaoxy.Test.stub(fixture, "POST", "/v2/scrape", fn conn ->
          {:ok, body, _} = Plug.Conn.read_body(conn)

          send(
            owner,
            {:oracle_http, id, conn.method, conn.request_path, conn.query_string,
             Map.new(conn.req_headers), Jason.decode!(body)}
          )

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(group["httpPayload"]))
        end)

        assert {:ok, prepared} = Firecrawl.prepare(cfg, step["arguments"])
        assert prepared.body == request["body"], id
        assert prepared.timeout_ms == request["timeoutSeconds"] * 1_000, id
        assert {:ok, actual} = Firecrawl.scrape(cfg, step["arguments"])
        assert actual == step["resultPortable"], id
        assert_receive {:oracle_http, ^id, method, path, query, headers, body}
        assert method == request["method"], id
        assert path == request["path"], id
        assert query == (URI.parse(request["url"]).query || ""), id
        assert body == request["body"], id

        expected_headers =
          request["headers"]
          |> Enum.map(fn {key, value} -> {String.downcase(key), value} end)
          |> Map.new()
          |> Map.delete("authorization")

        assert Map.take(headers, Map.keys(expected_headers)) == expected_headers, id
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  defp portable(url, text, mode \\ "markdown") do
    %{
      "url" => url,
      "finalUrl" => url,
      "extractor" => "firecrawl",
      "extractMode" => mode,
      "truncated" => false,
      "rawLength" => TextBudget.units(text),
      "length" => TextBudget.units(text),
      "text" => text
    }
  end

  defp config(context, suffix \\ ""),
    do: %{
      api_key: "ordinary-fixture-key",
      base_url: String.trim_trailing(Gaoxy.Test.url(context.fixture), "/") <> suffix,
      timeout_ms: 10_000
    }

  defp stub(context, response) do
    Gaoxy.Test.stub(context.fixture, "POST", "/v2/scrape", fn conn ->
      {:ok, body, _} = Plug.Conn.read_body(conn)
      payload = response.(conn, Jason.decode!(body))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
