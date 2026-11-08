defmodule Synapsis.Provider.GeminiSearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.WebSearch
  alias Synapsis.Provider.WebSearch.Gemini

  test "all 39 pinned POSTs match the pure deterministic builder and actual raw provider output" do
    reference = reference()

    callbacks =
      for group <- reference["groups"], step <- group["steps"], step["request"], do: {group, step}

    assert length(reference["groups"]) == 36
    assert length(callbacks) == 39

    for {group, step} <- callbacks do
      source = step["request"]
      selected = config(step)
      assert {:ok, prepared} = WebSearch.prepare_config(selected)
      assert {:ok, args} = Gemini.prepare(prepared, step["arguments"])
      assert {:ok, :post, url, headers, body} = Gemini.request(prepared, args, clock(step))
      assert url == source["url"], group["id"]
      assert body == source["body"], group["id"]
      # The source client header is explicitly a fixture attribution policy.
      assert Map.new(headers) == Map.delete(source["headers"], "x-goog-api-client"), group["id"]
      assert args["query"] == String.trim(step["arguments"]["query"])
      refute Map.has_key?(args, "count")
      assert {:ok, raw} = Gemini.result(prepared, args, group["httpPayload"])
      expected = raw_expected(group, step)
      assert Map.merge(raw, %{"provider" => "gemini", "query" => args["query"]}) == expected

      fixture = Gaoxy.Test.open()

      try do
        owner = self()

        Gaoxy.Test.stub(fixture, "POST", source["path"], fn conn ->
          {:ok, encoded, conn} = Plug.Conn.read_body(conn)

          send(
            owner,
            {:gemini_post, conn.method, conn.request_path, Jason.decode!(encoded),
             conn.req_headers}
          )

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(group["httpPayload"]))
        end)

        base_path = URI.parse(prepared.base_url).path || ""

        local_base =
          if base_path == "",
            do: String.trim_trailing(Gaoxy.Test.url(fixture), "/"),
            else: Gaoxy.Test.url(fixture, base_path)

        local = %{prepared | base_url: local_base}
        local = Map.put(local, :request_time, clock(step))
        assert {:ok, actual} = WebSearch.search(local, step["arguments"])
        assert Map.delete(actual, "tookMs") == expected, group["id"]
        assert is_integer(actual["tookMs"]) and actual["tookMs"] >= 0
        assert_receive {:gemini_post, "POST", path, actual_body, actual_headers}, 5000
        assert path == source["path"], group["id"]
        assert actual_body == source["body"], group["id"]
        expected_headers = Map.delete(source["headers"], "x-goog-api-client")
        assert Map.take(Map.new(actual_headers), Map.keys(expected_headers)) == expected_headers
        assert step["arguments"] == step["argumentsAfter"]
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  test "endpoint preparation is canonical and idempotent for ordinary explicit roots" do
    for {input, expected} <- [
          {nil, "https://generativelanguage.googleapis.com/v1beta"},
          {"https://generativelanguage.googleapis.com/",
           "https://generativelanguage.googleapis.com/v1beta"},
          {" https://generativelanguage.googleapis.com/v1beta/// ",
           "https://generativelanguage.googleapis.com/v1beta"},
          {"https://proxy.example/", "https://proxy.example"},
          {"https://proxy.example/gemini/v1beta///", "https://proxy.example/gemini/v1beta"}
        ] do
      assert Gemini.endpoint(input) == {:ok, expected}
      step = hd(hd(reference()["groups"])["steps"])
      assert {:ok, prepared} = WebSearch.prepare_config(Map.put(config(step), :base_url, input))
      assert prepared.base_url == expected
      assert WebSearch.prepare_config(prepared) == {:ok, prepared}
    end
  end

  test "an ordinary month end uses next month midnight as its exclusive before bound" do
    step = hd(hd(reference()["groups"])["steps"])
    assert {:ok, selected} = WebSearch.prepare_config(config(step))

    assert {:ok, args} =
             Gemini.prepare(selected, %{"query" => " month end ", "date_before" => "2026-10-31"})

    assert {:ok, :post, _, _, body} = Gemini.request(selected, args, ~U[2026-11-07 12:13:14.789Z])

    assert body == %{
             "contents" => [%{"parts" => [%{"text" => "month end"}]}],
             "tools" => [
               %{
                 "google_search" => %{
                   "timeRangeFilter" => %{
                     "startTime" => "1970-01-01T00:00:00Z",
                     "endTime" => "2026-11-01T00:00:00Z"
                   }
                 }
               }
             ]
           }
  end

  defp config(step) do
    setup = step["setup"]
    options = get_in(setup, ["config", "plugins", "entries", "google", "config", "webSearch"])
    model_base = get_in(setup, ["config", "models", "providers", "google", "baseUrl"])

    %{
      provider: "gemini",
      base_url:
        options["baseUrl"] || model_base || "https://generativelanguage.googleapis.com/v1beta",
      model: options["model"] || "gemini-3.6-flash",
      headers: options["headers"] || %{},
      api_key: "fixture-gemini-key",
      timeout_ms: Map.get(setup["searchConfig"], "timeoutSeconds", 30) * 1000,
      count: setup["searchConfig"]["maxResults"],
      mode: "web"
    }
  end

  defp raw_expected(group, step) do
    # Portable fixture citations have already resolved. Recover the raw domain
    # URLs from the HTTP payload, independently of that resolved result.
    candidate = hd(group["httpPayload"]["candidates"])
    chunks = get_in(candidate, ["groundingMetadata", "groundingChunks"]) || []

    citations =
      Enum.map(chunks, fn %{"web" => web} ->
        web |> Map.take(["title"]) |> Map.put("url", web["uri"])
      end)

    step["providerPortableResult"]
    |> Map.delete("tookMs")
    |> Map.put("citations", citations)
  end

  defp clock(step) do
    {:ok, clock, 0} = DateTime.from_iso8601(step["clock"])
    clock
  end

  defp reference do
    Path.expand(
      "../../../../synapsis_agent/test/fixtures/openclaw/488631c/gemini-search.json",
      __DIR__
    )
    |> File.read!()
    |> Jason.decode!()
  end
end
