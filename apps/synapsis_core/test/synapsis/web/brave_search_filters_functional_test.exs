defmodule Synapsis.Web.BraveSearchFiltersFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Web.Search
  alias Synapsis.Web.Search.Cache

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    requests = start_supervised!({Agent, fn -> [] end})

    if Code.ensure_loaded?(Cache) and is_nil(Process.whereis(Cache)),
      do: start_supervised!(Cache)

    for path <- ["/res/v1/web/search", "/res/v1/llm/context"] do
      Gaoxy.Test.stub(fixture, "GET", path, fn conn ->
        query = Plug.Conn.fetch_query_params(conn).query_params
        Agent.update(requests, &(&1 ++ [{path, query}]))

        row = %{
          "title" => "Ordinary source",
          "url" => "https://source.example/article",
          "description" => "Ordinary passage",
          "snippets" => ["Ordinary passage"]
        }

        payload = %{"web" => %{"results" => [row]}, "grounding" => %{"generic" => [row]}}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(payload))
      end)
    end

    {:ok, fixture: fixture, requests: requests}
  end

  test "country, language aliases and UI locale use canonical request values", context do
    vectors = [
      {%{"country" => " us ", "language" => " EN ", "ui_lang" => " EN-us "},
       %{"country" => "US", "search_lang" => "en", "ui_lang" => "en-US"}},
      {%{"country" => " all ", "search_lang" => " EN-GB "},
       %{"country" => "ALL", "search_lang" => "en-gb"}},
      {%{"country" => "zz", "search_lang" => "ja"}, %{"country" => "ALL", "search_lang" => "jp"}},
      {%{"search_lang" => "ZH"}, %{"search_lang" => "zh-hans"}},
      {%{"search_lang" => "zh-CN"}, %{"search_lang" => "zh-hans"}},
      {%{"search_lang" => "zh-SG"}, %{"search_lang" => "zh-hans"}},
      {%{"search_lang" => "zh-HK"}, %{"search_lang" => "zh-hant"}},
      {%{"search_lang" => "ZH-tw"}, %{"search_lang" => "zh-hant"}},
      {%{"search_lang" => "PT-BR", "ui_lang" => "pt-br"},
       %{"search_lang" => "pt-br", "ui_lang" => "pt-BR"}}
    ]

    for {{arguments, expected}, index} <- Enum.with_index(vectors) do
      query = "ordinary locale #{index}"
      assert {:ok, result} = search(context, Map.put(arguments, "query", query))
      assert result["count"] == 1

      assert List.last(requests(context)) ==
               {"/res/v1/web/search", Map.merge(%{"q" => query, "count" => "2"}, expected)}
    end
  end

  test "explicit search language takes precedence and swapped locale fields recover", context do
    vectors = [
      {%{"language" => "fr", "search_lang" => " DE "}, %{"search_lang" => "de"}},
      {%{"language" => " JA ", "search_lang" => ""}, %{"search_lang" => "jp"}},
      {%{"search_lang" => "EN-us", "ui_lang" => "ja"},
       %{"search_lang" => "jp", "ui_lang" => "en-US"}},
      {%{"search_lang" => "en-gb", "ui_lang" => "pt-BR"},
       %{"search_lang" => "pt-br", "ui_lang" => "en-GB"}},
      {%{"language" => "fr-ca", "ui_lang" => "FR"},
       %{"search_lang" => "fr", "ui_lang" => "fr-CA"}}
    ]

    for {{arguments, expected}, index} <- Enum.with_index(vectors) do
      query = "ordinary precedence #{index}"
      assert {:ok, _} = search(context, Map.put(arguments, "query", query))

      assert List.last(requests(context)) ==
               {"/res/v1/web/search", Map.merge(%{"q" => query, "count" => "2"}, expected)}
    end
  end

  test "all freshness names and shortcuts become Brave request values", context do
    vectors = [
      {" day ", "pd"},
      {"WEEK", "pw"},
      {"Month", "pm"},
      {"year", "py"},
      {" PD ", "pd"},
      {"PW", "pw"},
      {"Pm", "pm"},
      {"py", "py"},
      {" 2026-01-02to2026-02-03 ", "2026-01-02to2026-02-03"}
    ]

    for {{freshness, expected}, index} <- Enum.with_index(vectors) do
      query = "ordinary freshness #{index}"
      assert {:ok, _} = search(context, %{"query" => query, "freshness" => freshness})

      assert List.last(requests(context)) ==
               {"/res/v1/web/search", %{"q" => query, "count" => "2", "freshness" => expected}}
    end
  end

  test "ISO and slash date bounds and web before-only become ISO request ranges", context do
    vectors = [
      {%{"date_after" => " 2026-01-02 ", "date_before" => "2026-02-03"},
       "2026-01-02to2026-02-03"},
      {%{"date_after" => "1/2/2026", "date_before" => "02/03/2026"}, "2026-01-02to2026-02-03"},
      {%{"date_after" => "2026-01-02", "date_before" => "1/2/2026"}, "2026-01-02to2026-01-02"},
      {%{"date_before" => "2/3/2026"}, "1970-01-01to2026-02-03"}
    ]

    for {{arguments, expected}, index} <- Enum.with_index(vectors) do
      query = "ordinary date bounds #{index}"
      assert {:ok, _} = search(context, Map.put(arguments, "query", query))

      assert List.last(requests(context)) ==
               {"/res/v1/web/search", %{"q" => query, "count" => "2", "freshness" => expected}}
    end
  end

  test "LLM context normalizes bounded dates and after-only derives the current UTC day",
       context do
    today = Date.utc_today()
    after_date = today |> Date.add(-7) |> Date.to_iso8601()
    before_date = Date.to_iso8601(today)

    assert {:ok, _} =
             search(
               context,
               %{
                 "query" => "ordinary LLM bounds",
                 "language" => "JA",
                 "country" => " jp ",
                 "date_after" => "1/2/2026",
                 "date_before" => "2026-02-03"
               },
               mode: "llm-context"
             )

    assert List.last(requests(context)) ==
             {"/res/v1/llm/context",
              %{
                "q" => "ordinary LLM bounds",
                "country" => "JP",
                "search_lang" => "jp",
                "freshness" => "2026-01-02to2026-02-03"
              }}

    arguments = %{"query" => "ordinary LLM after only", "date_after" => after_date}
    assert {:ok, first} = search(context, arguments, mode: "llm-context")

    assert List.last(requests(context)) ==
             {"/res/v1/llm/context",
              %{"q" => arguments["query"], "freshness" => "#{after_date}to#{before_date}"}}

    assert {:ok, cached} =
             search(context, Map.put(arguments, "date_before", before_date), mode: "llm-context")

    assert cached == Map.put(first, "cached", true)
    assert length(requests(context)) == 2
  end

  test "canonical equivalents share one cached HTTP result and distinct options request again",
       context do
    arguments = %{
      "query" => " ordinary equivalent search ",
      "country" => "us",
      "language" => "JA",
      "ui_lang" => "EN-us",
      "freshness" => " week "
    }

    assert {:ok, first} = search(context, arguments)

    canonical = %{
      "query" => "ordinary equivalent search",
      "country" => "US",
      "search_lang" => "jp",
      "ui_lang" => "en-US",
      "freshness" => "pw"
    }

    assert {:ok, cached} = search(context, canonical)
    assert cached == Map.put(first, "cached", true)
    assert length(requests(context)) == 1

    for changed <- [
          Map.put(canonical, "country", "CA"),
          Map.put(canonical, "search_lang", "fr"),
          Map.put(canonical, "ui_lang", "fr-CA"),
          Map.put(canonical, "freshness", "pm"),
          Map.put(canonical, "count", 3)
        ] do
      assert {:ok, result} = search(context, changed)
      assert result["count"] == 1
    end

    assert length(requests(context)) == 6
  end

  test "canonical slash dates and omitted empty locale values share cached requests", context do
    arguments = %{
      "query" => "ordinary equivalent dates",
      "date_after" => "1/2/2026",
      "date_before" => "2/3/2026",
      "country" => "",
      "language" => "",
      "search_lang" => "",
      "ui_lang" => ""
    }

    assert {:ok, first} = search(context, arguments)

    assert {:ok, cached} =
             search(context, %{
               "query" => arguments["query"],
               "date_after" => "2026-01-02",
               "date_before" => "2026-02-03"
             })

    assert cached == Map.put(first, "cached", true)
    assert length(requests(context)) == 1
  end

  test "web after-only requests current UTC end while its cache key retains the omitted bound",
       context do
    today = Date.utc_today()
    after_date = today |> Date.add(-7) |> Date.to_iso8601()
    before_date = Date.to_iso8601(today)
    arguments = %{"query" => "ordinary web after only", "date_after" => after_date}

    assert {:ok, first} = search(context, arguments)
    assert {:ok, cached} = search(context, arguments)
    assert cached == Map.put(first, "cached", true)
    assert {:ok, _} = search(context, Map.put(arguments, "date_before", before_date))

    expected =
      {"/res/v1/web/search",
       %{
         "q" => arguments["query"],
         "count" => "2",
         "freshness" => "#{after_date}to#{before_date}"
       }}

    assert requests(context) == [expected, expected]
  end

  test "recorded public Brave callbacks match ordinary HTTP requests and cache observations",
       context do
    fixture_path =
      Path.expand(
        "../../../../synapsis_agent/test/fixtures/openclaw/488631c/brave-search-filters.json",
        __DIR__
      )

    groups =
      fixture_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("groups")
      |> Enum.reject(&String.ends_with?(&1["id"], "utc-rollover"))

    assert length(groups) == 21
    assert Enum.sum(Enum.map(groups, &length(&1["steps"]))) == 56

    for group <- groups do
      offset = length(requests(context))
      suffix = " [reference:#{group["id"]}]"

      for step <- group["steps"] do
        # Isolate group cache keys while preserving the raw query's surrounding whitespace.
        arguments =
          Map.update!(step["arguments"], "query", fn raw ->
            query = String.trim(raw)
            String.replace(raw, query, query <> suffix, global: false)
          end)

        before_step = length(requests(context))

        assert {:ok, result} =
                 search(context, arguments, mode: group["mode"], default_count: 5)

        assert Map.get(result, "cached", false) == step["cached"],
               "cache observation for #{group["id"]} #{inspect(step["arguments"])}"

        expected =
          case step["request"] do
            nil -> []
            request -> [reference_request(request, step["arguments"], suffix)]
          end

        assert Enum.drop(requests(context), before_step) == expected,
               "HTTP observation for #{group["id"]} #{inspect(step["arguments"])}"

        assert length(requests(context)) == offset + step["cumulativeRequests"]
      end
    end
  end

  defp reference_request(request, arguments, suffix) do
    assert request["method"] == "GET"
    query = Map.update!(request["query"], "q", &(&1 <> suffix))

    query =
      if is_binary(arguments["date_after"]) and String.trim(arguments["date_after"]) != "" and
           arguments["date_before"] in [nil, ""] and arguments["freshness"] in [nil, ""] do
        # Only the captured implicit end day follows the ordinary production UTC clock.
        Map.update!(query, "freshness", fn range ->
          [first, _captured_day] = String.split(range, "to", parts: 2)
          first <> "to" <> Date.to_iso8601(Date.utc_today())
        end)
      else
        query
      end

    {String.replace_prefix(request["path"], "/proxy", ""), query}
  end

  defp search(context, arguments, opts \\ []) do
    config = %{
      provider: "brave",
      base_url: Gaoxy.Test.url(context.fixture),
      api_key: "ordinary-fixture-key",
      credential_version: <<1, 2, 3>>,
      timeout_ms: 5_000,
      cache_ttl_ms: 900_000,
      count: Keyword.get(opts, :default_count, 2),
      mode: Keyword.get(opts, :mode, "web")
    }

    Search.search(arguments["query"],
      search_config: config,
      arguments: arguments,
      generic: true,
      timeout: 5_000,
      result_limit: 1_000_000
    )
  end

  defp requests(context), do: Agent.get(context.requests, & &1)
end
