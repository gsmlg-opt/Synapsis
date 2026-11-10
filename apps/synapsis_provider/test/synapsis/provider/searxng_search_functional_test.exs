defmodule Synapsis.Provider.SearxngSearchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Provider.WebSearch
  alias Synapsis.Provider.WebSearch.Searxng

  test "all 43 pinned HTTP callbacks match 44 complete GET requests and raw provider maps" do
    reference = reference()

    callbacks =
      for group <- reference["groups"], step <- group["steps"], step["request"], do: {group, step}

    assert length(reference["groups"]) == 32
    assert length(callbacks) == 43
    assert Enum.sum(for {_, step} <- callbacks, do: length(step["requests"])) == 44

    for {group, step} <- callbacks do
      selected = config(step)
      root = selected.base_url |> String.trim() |> String.trim_trailing("/")
      assert Searxng.endpoint(selected.base_url) == {:ok, root}
      assert {:ok, prepared} = Searxng.prepare_config(selected)
      assert prepared.base_url == root
      assert Searxng.prepare_config(prepared) == {:ok, prepared}
      assert WebSearch.prepare_config(selected) == {:ok, prepared}
      assert {:ok, args} = Searxng.prepare(prepared, step["arguments"])
      assert WebSearch.prepare(prepared, step["arguments"]) == {:ok, args}

      expected_args =
        step["request"]["query"]
        |> Map.delete("format")
        |> Map.delete("q")
        |> Map.put("query", step["request"]["query"]["q"])
        |> Map.put("count", effective_count(step, selected))

      assert args == expected_args, group["id"]
      assert selected.timeout_ms == step["request"]["timeoutSeconds"] * 1000

      for source <- step["requests"] do
        request_args =
          if source == step["request"],
            do: args,
            else: Map.put(args, "categories", source["query"]["categories"])

        assert {:ok, method, url, headers, body} = Searxng.request(prepared, request_args)
        uri = URI.parse(url)

        assert %{
                 "method" => method |> Atom.to_string() |> String.upcase(),
                 "url" => url,
                 "path" => uri.path,
                 "query_string" => uri.query,
                 "query" => URI.decode_query(uri.query),
                 "headers" => Map.new(headers),
                 "body" => body
               } == pure_request(source),
               group["id"]
      end

      assert {:ok, raw} = Searxng.result(prepared, args, List.last(group["httpPayloads"]))
      expected = Map.delete(step["providerPortableResult"], "tookMs")
      assert Map.merge(raw, %{"provider" => "searxng", "query" => args["query"]}) == expected

      fixture = Gaoxy.Test.open()
      counter = start_supervised!({Agent, fn -> [] end}, id: make_ref())

      try do
        for source <- Enum.uniq_by(step["requests"], & &1["path"]) do
          Gaoxy.Test.stub(fixture, "GET", source["path"], fn conn ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)

            observed = %{
              "method" => conn.method,
              "path" => conn.request_path,
              "query_string" => conn.query_string,
              "query" => URI.decode_query(conn.query_string),
              "headers" => conn.req_headers |> Map.new() |> Map.take(Map.keys(source["headers"])),
              "body" => body
            }

            index = Agent.get_and_update(counter, &{length(&1), &1 ++ [observed]})

            payload =
              Enum.at(group["httpPayloads"], min(index, length(group["httpPayloads"]) - 1))

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(200, Jason.encode!(payload))
          end)
        end

        uri = URI.parse(prepared.base_url)
        origin = String.trim_trailing(Gaoxy.Test.url(fixture), "/")
        local_base = origin <> (uri.path || "") <> if(uri.query, do: "?" <> uri.query, else: "")

        assert {:ok, actual} =
                 WebSearch.search(%{prepared | base_url: local_base}, step["arguments"])

        assert Map.delete(actual, "tookMs") == expected, group["id"]
        assert is_integer(actual["tookMs"]) and actual["tookMs"] >= 0

        expected_requests =
          for source <- step["requests"] do
            source |> pure_request() |> Map.delete("url") |> Map.put("body", "")
          end

        assert Agent.get(counter, & &1) == expected_requests, group["id"]
        assert step["arguments"] == step["argumentsAfter"]
        assert step["setup"] == step["setupAfter"]
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  test "ordinary configured count and optional defaults yield to explicit model values" do
    step = hd(hd(reference()["groups"])["steps"])
    selected = %{config(step) | count: 2, categories: " news,science ", language: " de "}
    assert {:ok, prepared} = Searxng.prepare_config(selected)

    assert Searxng.prepare(prepared, %{
             "query" => " ordinary defaults ",
             "categories" => " ",
             "language" => " "
           }) ==
             {:ok,
              %{
                "query" => "ordinary defaults",
                "count" => 2,
                "categories" => "news,science",
                "language" => "de"
              }}

    assert Searxng.prepare(prepared, %{
             "query" => " ordinary override ",
             "count" => 3,
             "categories" => " science,news ",
             "language" => " fr "
           }) ==
             {:ok,
              %{
                "query" => "ordinary override",
                "count" => 3,
                "categories" => "science,news",
                "language" => "fr"
              }}
  end

  defp pure_request(source) do
    %{
      "method" => source["method"],
      "url" => source["url"],
      "path" => source["path"],
      "query_string" => URI.parse(source["url"]).query,
      "query" => source["query"],
      "headers" => source["headers"],
      "body" => nil
    }
  end

  defp effective_count(step, config) do
    case Map.get(step["arguments"], "count", config.count) do
      count when is_binary(count) -> count |> String.trim() |> String.to_integer()
      count -> count
    end
  end

  defp config(step) do
    options =
      get_in(step, ["setup", "config", "plugins", "entries", "searxng", "config", "webSearch"])

    search = get_in(step, ["setup", "config", "tools", "web", "search"])

    %{
      provider: "searxng",
      base_url: options["baseUrl"],
      api_key: nil,
      credential_id: nil,
      categories: options["categories"],
      language: options["language"],
      timeout_ms: Map.get(search, "timeoutSeconds", 20) * 1000,
      count: Map.get(search, "maxResults", 5),
      mode: "web"
    }
  end

  defp reference do
    Path.expand(
      "../../../../synapsis_agent/test/fixtures/openclaw/488631c/searxng-search.json",
      __DIR__
    )
    |> File.read!()
    |> Jason.decode!()
  end
end
