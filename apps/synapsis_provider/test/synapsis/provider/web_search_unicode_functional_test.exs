defmodule Synapsis.Provider.WebSearchUnicodeFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.WebSearch
  alias Synapsis.Provider.WebSearch.TextBudget

  @reference Path.expand(
               "../../../../synapsis_agent/test/fixtures/openclaw/488631c/search-unicode.json",
               __DIR__
             )

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "Tavily leaves a spare UTF16 unit after a supplementary boundary for its next field",
       ctx do
    prefix = String.duplicate("a", 19_999)

    install(ctx, "POST", "/search", %{
      "results" => [
        %{
          "title" => prefix <> "🙂tail",
          "url" => "https://unicode.example/tavily",
          "content" => "Zmore"
        }
      ],
      "answer" => "Answer"
    })

    assert {:ok, result} = search(ctx, "tavily")
    assert [%{"title" => ^prefix, "snippet" => "Z"}] = result["results"]
    assert result["answer"] == ""
    assert result["truncated"] == true
    assert String.valid?(Jason.encode!(result))
  end

  test "Tavily shared content counts combining codepoints without grapheme normalization", ctx do
    title = String.duplicate("e\u0301", 10_001)

    install(ctx, "POST", "/search", %{
      "results" => [
        %{"title" => title, "url" => "https://unicode.example/combining", "content" => "More"}
      ]
    })

    assert {:ok, result} = search(ctx, "tavily")
    assert [%{"title" => retained, "snippet" => ""}] = result["results"]
    assert retained == String.duplicate("e\u0301", 10_000)
    assert result["truncated"] == true
  end

  test "Firecrawl charges supplementary title before description and scraped content", ctx do
    prefix = String.duplicate("🙂", 9_999) <> "x"

    install(ctx, "POST", "/v2/search", %{
      "success" => true,
      "data" => %{
        "web" => [
          %{
            "title" => prefix <> "🙂tail",
            "url" => "https://unicode.example/firecrawl",
            "description" => "Dmore",
            "markdown" => "# More"
          }
        ]
      }
    })

    assert {:ok, result} = search(ctx, "firecrawl", %{"scrape_results" => true})
    assert [%{"title" => ^prefix, "description" => "D", "content" => ""}] = result["results"]
    assert result["truncated"] == true
    assert String.valid?(Jason.encode!(result))
  end

  test "Brave web passes its complete ordinary text to the generic output owner", ctx do
    title = String.duplicate("界", 20_001)
    description = "Later ordinary passage"

    install(ctx, "GET", "/res/v1/web/search", %{
      "web" => %{
        "results" => [
          %{
            "title" => title,
            "url" => "https://unicode.example/brave",
            "description" => description
          }
        ]
      }
    })

    assert {:ok, result} = search(ctx, "brave")
    assert [%{"title" => ^title, "description" => ^description}] = result["results"]
    assert Map.get(result, "truncated", false) == false
  end

  test "Brave LLM preserves full title and every ordinary snippet before generic projection",
       ctx do
    title = String.duplicate("界", 20_001)
    snippets = [String.duplicate("🙂", 10_001), "Second passage"]

    install(ctx, "GET", "/res/v1/llm/context", %{
      "grounding" => %{
        "generic" => [
          %{"title" => title, "url" => "https://unicode.example/context", "snippets" => snippets}
        ]
      }
    })

    assert {:ok, result} = search(ctx, "brave", %{}, mode: "llm-context")
    assert [%{"title" => ^title, "snippets" => ^snippets}] = result["results"]
    assert Map.get(result, "truncated", false) == false
  end

  test "original UTF16 prefix helper observations match complete scalar prefixes" do
    reference = Jason.decode!(File.read!(@reference))
    assert length(reference["prefixCases"]) == 8

    for row <- reference["prefixCases"] do
      assert TextBudget.take(row["value"], row["maxUnits"]) == {row["text"], row["usedUnits"]}
      assert TextBudget.units(row["text"]) == row["usedUnits"]
      assert row["text"] != row["value"] == row["truncated"]
      assert String.valid?(row["text"])
    end
  end

  test "complete pinned provider search clients match ordinary Unicode HTTP results" do
    reference = Jason.decode!(File.read!(@reference))
    assert length(reference["providerCases"]) == 7

    for row <- reference["providerCases"] do
      fixture = Gaoxy.Test.open()

      try do
        assert [request] = row["requests"]
        owner = self()

        Gaoxy.Test.stub(fixture, request["method"], request["path"], fn conn ->
          {body, conn} =
            if request["method"] == "GET" do
              {nil, conn}
            else
              {:ok, body, conn} = Plug.Conn.read_body(conn)
              {Jason.decode!(body), conn}
            end

          send(owner, {:unicode_request, row["id"], URI.decode_query(conn.query_string), body})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(row["httpPayload"]))
        end)

        config = %{
          provider: row["provider"],
          base_url: Gaoxy.Test.url(fixture, "/proxy"),
          api_key: "ordinary-unicode-fixture",
          timeout_ms: 5_000,
          count: 5,
          mode: Map.get(row, "mode", "web")
        }

        assert {:ok, result} = WebSearch.search(config, row["arguments"])
        id = row["id"]
        assert_receive {:unicode_request, ^id, query, body}
        assert query == request["query"]
        assert body == request["body"]
        expected = Map.drop(row["resultContentUnframed"], ~w(externalContent tookMs))
        assert Map.delete(result, "tookMs") == expected, row["id"]
        assert String.valid?(Jason.encode!(result))
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  defp search(ctx, provider, arguments \\ %{}, opts \\ []) do
    config = %{
      provider: provider,
      base_url: Gaoxy.Test.url(ctx.fixture),
      api_key: "ordinary-unicode-fixture",
      timeout_ms: 5_000,
      count: 2,
      mode: Keyword.get(opts, :mode, "web")
    }

    WebSearch.search(config, Map.merge(%{"query" => "Unicode sources", "count" => 2}, arguments))
  end

  defp install(ctx, method, path, payload) do
    Gaoxy.Test.stub(ctx.fixture, method, path, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
