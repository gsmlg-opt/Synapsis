defmodule Synapsis.Provider.DuckDuckGoSearchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Provider.WebSearch
  alias Synapsis.Provider.WebSearch.DuckDuckGo

  test "all 34 pinned HTTP callbacks match complete GET requests and provider maps" do
    reference = reference()

    callbacks =
      for group <- reference["groups"], step <- group["steps"], step["request"], do: {group, step}

    assert length(reference["groups"]) == 26
    assert length(callbacks) == 34
    assert Enum.sum(for {_, step} <- callbacks, do: length(step["requests"])) == 34

    for {group, step} <- callbacks do
      selected = config(step)
      assert DuckDuckGo.endpoint(nil) == {:ok, "https://html.duckduckgo.com/html"}
      assert {:ok, prepared} = DuckDuckGo.prepare_config(selected)
      assert prepared.base_url == "https://html.duckduckgo.com/html"
      assert DuckDuckGo.prepare_config(prepared) == {:ok, prepared}
      assert WebSearch.prepare_config(selected) == {:ok, prepared}
      assert {:ok, args} = DuckDuckGo.prepare(prepared, step["arguments"])
      assert WebSearch.prepare(prepared, step["arguments"]) == {:ok, args}

      expected_args = %{
        "query" => step["request"]["query"]["q"],
        "count" => effective_count(step),
        "safeSearch" => "moderate"
      }

      expected_args =
        if step["request"]["query"]["kl"],
          do: Map.put(expected_args, "region", step["request"]["query"]["kl"]),
          else: expected_args

      assert args == expected_args, group["id"]
      assert selected.timeout_ms == step["request"]["timeoutSeconds"] * 1_000
      assert {:ok, method, url, headers, body} = DuckDuckGo.request(prepared, args)
      uri = URI.parse(url)

      assert %{
               "method" => method |> Atom.to_string() |> String.upcase(),
               "url" => url,
               "path" => uri.path,
               "query_string" => uri.query,
               "query" => URI.decode_query(uri.query),
               "headers" => Map.new(headers),
               "body" => body
             } == pure_request(step["request"]),
             group["id"]

      index = min(step["cumulativeRequests"] - 1, length(group["httpPayloads"]) - 1)
      html = Enum.at(group["httpPayloads"], index)
      assert {:ok, raw} = DuckDuckGo.result(prepared, args, html)
      expected = Map.delete(step["providerPortableResult"], "tookMs")
      assert Map.merge(raw, %{"provider" => "duckduckgo", "query" => args["query"]}) == expected

      fixture = Gaoxy.Test.open()
      counter = start_supervised!({Agent, fn -> [] end}, id: make_ref())

      try do
        source = step["request"]

        Gaoxy.Test.stub(fixture, "GET", source["path"], fn conn ->
          {:ok, request_body, conn} = Plug.Conn.read_body(conn)

          observed = %{
            "method" => conn.method,
            "path" => conn.request_path,
            "query_string" => conn.query_string,
            "query" => URI.decode_query(conn.query_string),
            "headers" => conn.req_headers |> Map.new() |> Map.take(["user-agent"]),
            "body" => request_body
          }

          Agent.update(counter, &(&1 ++ [observed]))

          conn
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.resp(200, html)
        end)

        local_endpoint = String.trim_trailing(Gaoxy.Test.url(fixture), "/") <> source["path"]
        local = %{prepared | base_url: local_endpoint}
        assert DuckDuckGo.endpoint(local_endpoint) == {:ok, local_endpoint}
        assert {:ok, actual} = WebSearch.search(local, step["arguments"])
        assert Map.delete(actual, "tookMs") == expected, group["id"]
        assert is_integer(actual["tookMs"]) and actual["tookMs"] >= 0

        expected_request = source |> pure_request() |> Map.delete("url") |> Map.put("body", "")

        assert Agent.get(counter, & &1) == [expected_request], group["id"]
        assert step["arguments"] == step["argumentsAfter"]
        assert step["setup"] == step["setupAfter"]
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  test "ordinary effective defaults ignore declared count and accept explicit count and region" do
    step = hd(hd(reference()["groups"])["steps"])

    selected = %{
      config(step)
      | base_url: " https://search.example/complete/html?old=one ",
        count: 3,
        region: " us-en ",
        timeout_ms: 9_000
    }

    assert {:ok, prepared} = DuckDuckGo.prepare_config(selected)
    assert prepared.base_url == "https://search.example/complete/html?old=one"
    assert prepared.region == "us-en"
    assert prepared.timeout_ms == 9_000

    assert DuckDuckGo.prepare(prepared, %{"query" => " ordinary defaults ", "region" => " "}) ==
             {:ok,
              %{
                "query" => "ordinary defaults",
                "count" => 5,
                "region" => "us-en",
                "safeSearch" => "moderate"
              }}

    assert DuckDuckGo.prepare(prepared, %{
             "query" => " ordinary override ",
             "count" => 4,
             "region" => " de-de "
           }) ==
             {:ok,
              %{
                "query" => "ordinary override",
                "count" => 4,
                "region" => "de-de",
                "safeSearch" => "moderate"
              }}
  end

  defp pure_request(source) do
    %{
      "method" => source["method"],
      "url" => source["url"],
      "path" => source["path"],
      "query_string" => URI.parse(source["url"]).query,
      "query" => source["query"],
      "headers" => %{"user-agent" => user_agent()},
      "body" => nil
    }
  end

  defp effective_count(step) do
    case Map.get(step["arguments"], "count", 5) do
      count when is_binary(count) -> count |> String.trim() |> String.to_integer()
      count -> count
    end
  end

  defp config(step) do
    options =
      get_in(step, ["setup", "config", "plugins", "entries", "duckduckgo", "config", "webSearch"])

    search = get_in(step, ["setup", "config", "tools", "web", "search"])

    %{
      provider: "duckduckgo",
      base_url: nil,
      api_key: nil,
      credential_id: nil,
      region: options["region"],
      safe_search: nil,
      timeout_ms: 20_000,
      count: Map.get(search, "maxResults", 5),
      mode: "web"
    }
  end

  defp user_agent do
    "synapsis-duckduckgo/#{Application.spec(:synapsis_provider, :vsn)} (+https://github.com/gsmlg-opt/Synapsis)"
  end

  defp reference do
    Path.expand(
      "../../../../synapsis_agent/test/fixtures/openclaw/488631c/duckduckgo-search.json",
      __DIR__
    )
    |> File.read!()
    |> Jason.decode!()
  end
end
