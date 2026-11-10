defmodule Synapsis.Web.SearchUnicodeFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Web.Search
  alias Synapsis.Web.Search.Cache

  @reference Path.expand(
               "../../../../synapsis_agent/test/fixtures/openclaw/488631c/search-unicode.json",
               __DIR__
             )

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    if Code.ensure_loaded?(Cache) and is_nil(Process.whereis(Cache)), do: start_supervised!(Cache)
    {:ok, fixture: fixture}
  end

  test "generic Unicode output reserves both URLs before supplementary text and next fields",
       ctx do
    urls = ["https://unicode.example/one", "https://unicode.example/two"]
    remaining = 20_000 - Enum.sum(Enum.map(urls, &byte_size/1))
    title = String.duplicate("🙂", 10_001)
    rows = for url <- urls, do: %{"title" => title, "url" => url, "description" => "Zmore"}
    install(ctx, rows)
    assert {:ok, result} = search(ctx)
    assert Enum.map(result["results"], & &1["url"]) == urls
    [first, second] = result["results"]
    assert first["title"] == String.duplicate("🙂", div(remaining, 2))
    assert first["snippet"] == if(rem(remaining, 2) == 1, do: "Z", else: "")
    assert first["siteName"] == ""
    assert second["title"] == ""
    assert second["snippet"] == ""
    assert second["siteName"] == ""
    assert result["truncated"] == true
    assert utf16_units(first["title"]) + utf16_units(first["snippet"]) == remaining
    assert String.valid?(Jason.encode!(result))
  end

  test "generic combining text can stop between components as the fixed UTF16 budget does", ctx do
    url = "https://unicode.example/combining"
    remaining = 20_000 - byte_size(url)
    title = String.duplicate("e\u0301", 10_001)
    install(ctx, [%{"title" => title, "url" => url, "description" => "Following"}])
    assert {:ok, result} = search(ctx)
    assert [row] = result["results"]

    assert row["title"] ==
             String.duplicate("e\u0301", div(remaining, 2)) <>
               if(rem(remaining, 2) == 1, do: "e", else: "")

    assert row["snippet"] == ""
    assert row["siteName"] == ""
    assert result["truncated"] == true
    assert utf16_units(row["title"]) + byte_size(url) == 20_000
  end

  test "generic ordinary prose trims field edges without changing internal Unicode", ctx do
    install(ctx, [
      %{
        "title" => " \tRésumé 🙂 \n",
        "url" => "https://unicode.example/trim",
        "description" => "\n e\u0301 Z \t"
      }
    ])

    assert {:ok, result} = search(ctx)

    assert [%{"title" => "Résumé 🙂", "snippet" => "e\u0301 Z", "siteName" => "unicode.example"}] =
             result["results"]

    assert Map.get(result, "truncated", false) == false
  end

  test "complete pinned generic normalization matches ordinary Unicode HTTP projections" do
    reference = Jason.decode!(File.read!(@reference))
    assert length(reference["genericCases"]) == 12

    for row <- reference["genericCases"] do
      provider_case = Enum.find(reference["providerCases"], &(&1["id"] == row["providerCaseId"]))

      {payload, arguments, mode, method, path} =
        if provider_case do
          [request] = provider_case["requests"]

          {provider_case["httpPayload"], provider_case["arguments"],
           Map.get(provider_case, "mode", "web"), request["method"], request["path"]}
        else
          results =
            Enum.map(row["providerResult"]["results"], fn item ->
              %{"title" => item["title"], "url" => item["url"], "description" => item["snippet"]}
            end)

          {%{"web" => %{"results" => results}},
           %{"query" => row["query"], "count" => length(results)}, "web", "GET",
           "/proxy/res/v1/web/search"}
        end

      fixture = Gaoxy.Test.open()

      try do
        owner = self()

        Gaoxy.Test.stub(fixture, method, path, fn conn ->
          send(owner, {:unicode_http, row["id"]})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(payload))
        end)

        config = %{
          provider: row["provider"],
          base_url: Gaoxy.Test.url(fixture, "/proxy"),
          api_key: "ordinary-unicode-fixture",
          credential_version: <<1, 2, 3>>,
          timeout_ms: 5_000,
          cache_ttl_ms: 0,
          count: 5,
          mode: mode
        }

        assert {:ok, result} =
                 Search.search(row["query"], search_config: config, arguments: arguments)

        id = row["id"]
        assert_receive {:unicode_http, ^id}
        expected = Map.drop(row["normalizedUnwrappedResult"], ~w(externalContent tookMs))
        assert Map.delete(result, "tookMs") == expected, row["id"]
        assert String.valid?(Jason.encode!(result))
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  defp search(ctx) do
    config = %{
      provider: "brave",
      base_url: Gaoxy.Test.url(ctx.fixture),
      api_key: "ordinary-unicode-fixture",
      credential_version: <<1, 2, 3>>,
      timeout_ms: 5_000,
      cache_ttl_ms: 0,
      count: 10,
      mode: "web"
    }

    Search.search("Unicode sources", search_config: config, arguments: %{"count" => 10})
  end

  defp install(ctx, rows) do
    Gaoxy.Test.stub(ctx.fixture, "GET", "/res/v1/web/search", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"web" => %{"results" => rows}}))
    end)
  end

  defp utf16_units(value),
    do: div(byte_size(:unicode.characters_to_binary(value, :utf8, :utf16)), 2)
end
