defmodule Synapsis.Provider.XSearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.XSearch
  alias Synapsis.Provider.WebSearch.TextBudget

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "default preparation requests the configured xAI Responses X-search tool" do
    assert {:ok, prepared} = XSearch.prepare(%{}, %{"query" => "  exact post  "})
    assert prepared.endpoint == "https://api.x.ai/v1/responses"
    assert prepared.timeout_ms == 30_000
    assert prepared.inline_citations == false
    assert prepared.query == "exact post"
    assert prepared.model == "grok-4.7"

    assert prepared.body == %{
             "model" => "grok-4.7",
             "input" => [%{"role" => "user", "content" => "exact post"}],
             "tools" => [%{"type" => "x_search"}],
             "store" => false,
             "reasoning" => %{"effort" => "low"}
           }
  end

  test "ordinary handles, dates and understanding flags retain the reference wire names" do
    config = %{
      model: " grok-4.3-latest ",
      base_url: " https://proxy.example/v1/// ",
      max_turns: 4
    }

    args = %{
      "query" => " Find this thread ",
      "allowed_x_handles" => [" Alpha ", "Beta", "Alpha"],
      "from_date" => " 2024-02-29 ",
      "to_date" => "2024-03-03",
      "enable_image_understanding" => true,
      "enable_video_understanding" => true
    }

    assert {:ok, prepared} = XSearch.prepare(config, args)
    assert prepared.endpoint == "https://proxy.example/v1/responses"
    assert prepared.body["model"] == "grok-4.3"
    assert prepared.body["reasoning"] == %{"effort" => "none"}
    assert prepared.body["max_turns"] == 4

    assert prepared.body["tools"] == [
             %{
               "type" => "x_search",
               "allowed_x_handles" => ["Alpha", "Beta", "Alpha"],
               "from_date" => "2024-02-29",
               "to_date" => "2024-03-03",
               "enable_image_understanding" => true,
               "enable_video_understanding" => true
             }
           ]
  end

  test "ordinary model aliases and forward releases preserve reasoning defaults" do
    for {requested, model, effort} <- [
          {"grok-4.7-latest", "grok-4.7", "low"},
          {"grok-4.6", "grok-4.6", "low"},
          {"grok-4.3", "grok-4.3", "none"},
          {"grok-4.5-latest", "grok-4.5", nil},
          {"grok-build-latest", "grok-4.5", nil},
          {"grok-code-fast", "grok-build-0.1", nil},
          {"grok-4.20", "grok-4.20", nil},
          {"grok-4.8-0115", "grok-4.8-0115", "low"},
          {"grok-5", "grok-5", "low"},
          {"grok-4-fast-reasoning", "grok-4-fast", nil}
        ] do
      assert {:ok, prepared} = XSearch.prepare(%{model: requested}, %{"query" => "post"})
      assert prepared.model == model
      assert prepared.body["model"] == model
      assert prepared.body["reasoning"] == if(effort, do: %{"effort" => effort}, else: nil)
    end
  end

  test "successful POST concatenates adjacent output blocks and preserves portable filter fields",
       context do
    owner = self()

    stub(context, fn conn, body ->
      send(owner, {:wire, conn.method, conn.request_path, conn.query_string, body})

      %{
        "output" => [
          %{"type" => "message", "content" => [%{"type" => "output_text", "text" => " A"}]},
          %{"type" => "output_text", "text" => "B\n"}
        ],
        "output_text" => "unused fallback",
        "citations" => [
          "https://X.example:443/one",
          "https://x.example/one",
          "https://two.example"
        ]
      }
    end)

    args = %{
      "query" => "  exact post  ",
      "excluded_x_handles" => [" noise "],
      "from_date" => "2024-02-29",
      "enable_image_understanding" => false,
      "enable_video_understanding" => true
    }

    assert {:ok, prepared} = XSearch.prepare(config(context), args)
    assert {:ok, result} = XSearch.search(config(context), prepared)
    assert_receive {:wire, "POST", "/v1/responses", "", body}
    assert body == prepared.body
    assert is_integer(result["tookMs"]) and result["tookMs"] >= 0

    assert Map.delete(result, "tookMs") == %{
             "query" => "exact post",
             "provider" => "xai",
             "model" => "grok-4.7",
             "content" => " AB\n",
             "citations" => ["https://x.example/one", "https://two.example"],
             "excludedXHandles" => ["noise"],
             "fromDate" => "2024-02-29",
             "enableVideoUnderstanding" => true
           }
  end

  test "annotation citations retain block order when top-level citations are absent", context do
    stub(context, fn _, _ ->
      %{
        "output" => [
          message("First", [citation("https://one.example/a"), citation("https://two.example/b")]),
          message("Second", [
            citation("https://one.example/a"),
            citation("https://three.example/c")
          ])
        ]
      }
    end)

    assert {:ok, result} = search(context, %{"query" => "ordinary"})
    assert result["content"] == "FirstSecond"

    assert result["citations"] == [
             "https://one.example/a",
             "https://two.example/b",
             "https://three.example/c"
           ]
  end

  test "top-level citations take precedence and inline citations keep exact UTF16 offsets",
       context do
    stub(context, fn _, _ ->
      %{
        "output" => [message("A😀BC", [citation("https://annotation.example/a")])],
        "citations" => ["https://top.example/a"],
        "inline_citations" => [
          %{
            "start_index" => 1,
            "end_index" => 3,
            "url" => "https://X.example:443/a",
            "title" => "unused"
          },
          %{"start_index" => 5, "end_index" => 5, "url" => "https://end.example"}
        ]
      }
    end)

    assert {:ok, result} = search(context, %{"query" => "ordinary"}, %{inline_citations: true})
    assert result["content"] == "A😀BC"
    assert result["citations"] == ["https://top.example/a"]

    assert result["inlineCitations"] == [
             %{"start_index" => 1, "end_index" => 3, "url" => "https://x.example/a"},
             %{"start_index" => 5, "end_index" => 5, "url" => "https://end.example"}
           ]
  end

  test "top-level output text fallback retains whitespace and enabled empty inline list",
       context do
    stub(context, fn _, _ -> %{"output_text" => " \t\n", "inline_citations" => []} end)
    assert {:ok, result} = search(context, %{"query" => "ordinary"}, %{inline_citations: true})
    assert result["content"] == " \t\n"
    assert result["citations"] == []
    assert result["inlineCitations"] == []
  end

  test "twenty citation and inline slots retain their original order", context do
    urls = for i <- 1..23, do: "https://posts.example/#{i}"

    stub(context, fn _, _ ->
      %{
        "output_text" => "answer",
        "citations" => urls,
        "inline_citations" =>
          for(url <- urls, do: %{"url" => url, "start_index" => 0, "end_index" => 6})
      }
    end)

    assert {:ok, result} = search(context, %{"query" => "ordinary"}, %{inline_citations: true})
    assert result["citations"] == Enum.take(urls, 20)
    assert Enum.map(result["inlineCitations"], & &1["url"]) == Enum.take(urls, 20)
  end

  test "Unicode budget retains a contiguous scalar prefix across output blocks", context do
    first = String.duplicate("a", 19_999)

    stub(context, fn _, _ ->
      %{
        "output" => [
          message(first),
          message("😀tail"),
          message("later", [citation("https://later.example/a")])
        ]
      }
    end)

    assert {:ok, result} = search(context, %{"query" => "ordinary"})
    assert result["content"] == first
    assert TextBudget.units(result["content"]) == 19_999
    assert result["truncated"] == true
    assert result["citations"] == []
  end

  test "top-level text fallback shares the same twenty-thousand UTF16 budget", context do
    stub(context, fn _, _ -> %{"output_text" => String.duplicate("😀", 10_001)} end)
    assert {:ok, result} = search(context, %{"query" => "ordinary"})
    assert result["content"] == String.duplicate("😀", 10_000)
    assert result["truncated"] == true
  end

  test "ordinary requests and entire portable maps match actual fixed-source callbacks" do
    fixture_path =
      Path.expand(
        "../../../../synapsis_agent/test/fixtures/openclaw/488631c/x-search.json",
        __DIR__
      )

    capture = fixture_path |> File.read!() |> Jason.decode!()
    assert capture["pin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"

    callbacks =
      for group <- capture["groups"],
          {step, index} <- Enum.with_index(group["steps"]),
          not is_nil(step["request"]),
          do: {group, step, index}

    assert length(callbacks) >= 120

    for {group, step, index} <- callbacks do
      source_config = get_in(step, ["config", "plugins", "entries", "xai", "config"])
      x_search = source_config["xSearch"] || %{}
      web_search = source_config["webSearch"] || %{}

      config = %{
        api_key: "ordinary-source-fixture-key",
        base_url: x_search["baseUrl"] || web_search["baseUrl"] || "https://api.x.ai/v1",
        model: x_search["model"] || "grok-4.7",
        timeout_ms: (x_search["timeoutSeconds"] || 30) * 1_000,
        inline_citations: x_search["inlineCitations"] === true,
        max_turns: x_search["maxTurns"]
      }

      assert {:ok, prepared} = XSearch.prepare(config, step["arguments"])
      assert prepared.endpoint == step["request"]["url"], group["id"]
      assert prepared.timeout_ms == step["request"]["timeoutSeconds"] * 1_000, group["id"]
      assert prepared.body == step["request"]["body"], group["id"]

      fixture = Gaoxy.Test.open()

      try do
        path = URI.parse(prepared.endpoint).path
        owner = self()
        id = {group["id"], index}

        Gaoxy.Test.stub(fixture, "POST", path, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(owner, {:source_wire, id, conn.method, conn.request_path, Jason.decode!(body)})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(group["httpPayload"]))
        end)

        local = %{prepared | endpoint: Gaoxy.Test.url(fixture, path)}
        assert {:ok, actual} = XSearch.search(config, local)
        assert_receive {:source_wire, ^id, "POST", ^path, wire}
        assert wire == step["request"]["body"], inspect(id)
        assert is_integer(actual["tookMs"]) and actual["tookMs"] >= 0

        assert Map.put(actual, "tookMs", step["resultPortable"]["tookMs"]) ==
                 step["resultPortable"],
               inspect(id)
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  defp config(context),
    do: %{
      api_key: "ordinary-fixture-key",
      base_url: Gaoxy.Test.url(context.fixture, "/v1/"),
      timeout_ms: 5_000
    }

  defp search(context, arguments, extra \\ %{}) do
    config = Map.merge(config(context), extra)

    with {:ok, prepared} <- XSearch.prepare(config, arguments),
         do: XSearch.search(config, prepared)
  end

  defp stub(context, response) do
    Gaoxy.Test.stub(context.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = response.(conn, Jason.decode!(body))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end

  defp message(text, annotations \\ []),
    do: %{
      "type" => "message",
      "content" => [%{"type" => "output_text", "text" => text, "annotations" => annotations}]
    }

  defp citation(url), do: %{"type" => "url_citation", "url" => url}
end
