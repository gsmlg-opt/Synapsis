defmodule Synapsis.MCP.ParallelSearchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.MCP.ParallelSearch
  alias Synapsis.Provider.WebSearch

  @groups ~w(search-default normalized-pair unicode-pair optional-context configured-count
    explicit-count configured-timeout structured-content-priority json-text-fallback post-sse
    post-sse-multiline stateless-server negotiated-version keywords-only cli-query-fallback
    cli-query-with-objective query-with-pair ordered-metadata successful-empty successful-empty-minimal
    same-cache-generated-session same-cache-supplied-session empty-cache-reuse count-cache-identity
    objective-cache-identity queries-cache-identity query-order-cache-identity session-cache-identity
    client-model-cache-identity)

  setup do
    fixture = Gaoxy.Test.open()
    ledger = start_supervised!({Agent, fn -> %{posts: [], deletes: []} end})
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture, ledger: ledger}
  end

  test "official one-shot client initializes calls and retires both registered processes", ctx do
    install(ctx)
    assert {:ok, args} = WebSearch.prepare(config(ctx), arguments())
    assert {:ok, result} = ParallelSearch.search(config(ctx), args)
    session = result["sessionId"]
    assert_uuid(session)
    assert Map.delete(result, "tookMs") == expected(session)
    assert is_integer(result["tookMs"])
    assert result["tookMs"] >= 0

    [initialize, initialized, call] = posts(ctx)
    assert initialize.body["method"] == "initialize"
    assert initialize.body["params"]["protocolVersion"] == "2025-06-18"
    assert is_map(initialize.body["params"]["capabilities"])
    assert initialized.body["method"] == "notifications/initialized"
    assert call.body["method"] == "tools/call"
    assert call.body["params"]["name"] == "web_search"

    assert call.body["params"]["arguments"] == %{
             "objective" => "Compare ordinary sources 雪🙂",
             "search_queries" => ["first source 雪", "second source 🙂"],
             "session_id" => session,
             "model_name" => "gpt-6-astra"
           }

    for request <- [initialized, call] do
      assert request.headers["mcp-session-id"] == "ordinary-transport-session"
      assert request.headers["mcp-protocol-version"] == "2025-06-18"
    end

    refute session == "ordinary-transport-session"
    assert_retired(ctx)
  end

  test "ordinary POST SSE returns the complete structured result and retires normally", ctx do
    install(ctx, response_format: "sse")
    assert {:ok, args} = WebSearch.prepare(config(ctx), arguments())
    assert {:ok, result} = ParallelSearch.search(config(ctx), args)
    assert Map.delete(result, "tookMs") == expected(result["sessionId"])

    assert Enum.map(posts(ctx), & &1.body["method"]) ==
             ["initialize", "notifications/initialized", "tools/call"]

    assert_retired(ctx)
  end

  test "structuredContent is authoritative over a different valid JSON text result", ctx do
    install(ctx, tool_content: "structured-priority")
    args = Map.put(arguments(), "session_id", " supplied-search-session ")
    assert {:ok, args} = WebSearch.prepare(config(ctx), args)
    assert {:ok, result} = ParallelSearch.search(config(ctx), args)
    assert Map.delete(result, "tookMs") == expected("supplied-search-session")

    assert List.last(posts(ctx)).body["params"]["arguments"]["session_id"] ==
             "supplied-search-session"

    assert_retired(ctx)
  end

  test "ordinary JSON text content works with stateless transport and negotiated version", ctx do
    install(ctx,
      tool_content: "text",
      transport_session: nil,
      protocol_version: "2025-03-26",
      observe_protocol: true
    )

    assert {:ok, args} = WebSearch.prepare(config(ctx), arguments())
    assert {:ok, result} = ParallelSearch.search(config(ctx), args)
    assert Map.delete(result, "tookMs") == expected(result["sessionId"])
    [_initialize, initialized, call] = posts(ctx)
    assert %{negotiation_status: :ready, negotiated_version: "2025-03-26"} = call.protocol_info
    refute Map.has_key?(initialized.headers, "mcp-protocol-version")
    refute Map.has_key?(call.headers, "mcp-protocol-version")
    assert_retired(ctx)
  end

  test "Core owns normalized cache identity and strips only generated search sessions from cached copies",
       ctx do
    install(ctx)
    search_config = config(ctx)

    opts = [
      search_config: search_config,
      arguments: arguments(),
      generic: true,
      uncached_search: &ParallelSearch.search/2
    ]

    assert {:ok, first} = Synapsis.Web.Search.search("Compare ordinary sources 雪🙂", opts)
    assert_uuid(first["sessionId"])
    assert Map.delete(first, "tookMs") == Map.put(expected(first["sessionId"]), "kind", "results")

    normalized_args = %{
      "objective" => "Compare ordinary sources 雪🙂",
      "search_queries" => ["first source 雪", "second source 🙂"],
      "client_model" => "gpt-6-astra"
    }

    assert {:ok, cached} =
             Synapsis.Web.Search.search(
               "Compare ordinary sources 雪🙂",
               Keyword.put(opts, :arguments, normalized_args)
             )

    assert cached == first |> Map.delete("sessionId") |> Map.put("cached", true)
    assert length(posts(ctx)) == 3

    supplied_args = Map.put(normalized_args, "session_id", " " <> first["sessionId"] <> " ")
    supplied_opts = Keyword.put(opts, :arguments, supplied_args)

    assert {:ok, supplied} =
             Synapsis.Web.Search.search("Compare ordinary sources 雪🙂", supplied_opts)

    assert Map.delete(supplied, "tookMs") ==
             Map.put(expected(first["sessionId"]), "kind", "results")

    assert {:ok, supplied_cached} =
             Synapsis.Web.Search.search("Compare ordinary sources 雪🙂", supplied_opts)

    assert supplied_cached == Map.put(supplied, "cached", true)
    assert length(posts(ctx)) == 6
    assert_retired(ctx)
  end

  test "every pinned ordinary free callback matches actual MCP arguments and the complete provider map",
       ctx do
    reference = reference()
    assert Enum.map(reference["groups"], & &1["id"]) == @groups

    callbacks =
      for group <- reference["groups"],
          step <- group["steps"],
          is_map(step["request"]),
          do: {group, step}

    assert length(callbacks) == 35

    for {group, step} <- callbacks do
      fixture = Gaoxy.Test.open()
      local = %{ctx | fixture: fixture}
      Agent.update(local.ledger, fn _ -> %{posts: [], deletes: []} end)

      try do
        recipe = group["serverRecipe"]
        content = if recipe["toolContent"] == "json-text", do: "text", else: recipe["toolContent"]

        install(local,
          payload: recipe["httpPayload"],
          tool_content: content,
          response_format: recipe["responseFormat"],
          protocol_version: recipe["protocolVersion"],
          transport_session: recipe["transportSessionId"]
        )

        outer = step["setup"]["searchConfig"]

        search_config =
          config(local)
          |> Map.put(:count, Map.get(outer, "maxResults", 5))
          |> Map.put(:timeout_ms, Map.get(outer, "timeoutSeconds", 30) * 1000)

        assert {:ok, args} = WebSearch.prepare(search_config, step["arguments"])
        assert {:ok, actual} = ParallelSearch.search(search_config, args)
        actual_session = actual["sessionId"]

        if is_nil(args["session_id"]),
          do: assert_uuid(actual_session),
          else: assert(actual_session == args["session_id"])

        pinned_session = step["searchSessionId"]

        assert actual |> Map.delete("tookMs") |> Map.put("sessionId", pinned_session) ==
                 Map.delete(step["providerPortableResult"], "tookMs"),
               group["id"]

        assert is_integer(actual["tookMs"])
        assert actual["tookMs"] >= 0

        [initialize, initialized, call] = posts(local)

        assert Enum.map([initialize, initialized, call], & &1.body["method"]) ==
                 ["initialize", "notifications/initialized", "tools/call"]

        assert call.body["params"]["name"] == "web_search"
        assert call.body["params"]["arguments"]["session_id"] == actual_session

        assert Map.put(call.body["params"]["arguments"], "session_id", pinned_session) ==
                 step["request"]["body"]["params"]["arguments"],
               group["id"]

        assert_retired(local)
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  defp reference do
    Path.expand(
      "../../../../synapsis_agent/test/fixtures/openclaw/488631c/parallel-free-search.json",
      __DIR__
    )
    |> File.read!()
    |> Jason.decode!()
  end

  defp config(ctx) do
    %{
      provider: "parallel-free",
      base_url: Gaoxy.Test.url(ctx.fixture, "/mcp"),
      api_key: nil,
      timeout_ms: 5000,
      cache_ttl_ms: 60_000,
      count: 2,
      mode: "web"
    }
  end

  defp arguments do
    %{
      "objective" => " Compare ordinary sources 雪🙂 ",
      "search_queries" => [" first source 雪 ", "first source 雪", " ", " second source 🙂 "],
      "client_model" => " gpt-6-astra "
    }
  end

  defp payload do
    %{
      "search_id" => "ordinary-search",
      "session_id" => "server-payload-session",
      "warnings" => [%{"code" => "source_notice", "detail" => " Ordinary notice 雪 "}],
      "usage" => [%{"name" => "search", "count" => 1}],
      "results" =>
        for(
          index <- 1..3,
          do: %{
            "title" => " Source #{index} 雪 ",
            "url" => "https://SOURCES.EXAMPLE:443/research/#{index}?q=ordinary#part",
            "publish_date" => " 2026-11-0#{index} ",
            "excerpts" => [" Passage #{index} 雪 ", " Context #{index} 🙂 "]
          }
        )
    }
  end

  defp expected(session) do
    %{
      "provider" => "parallel-free",
      "objective" => "Compare ordinary sources 雪🙂",
      "searchQueries" => ["first source 雪", "second source 🙂"],
      "count" => 2,
      "searchId" => "ordinary-search",
      "sessionId" => session,
      "warnings" => payload()["warnings"],
      "usage" => payload()["usage"],
      "results" =>
        for(
          index <- 1..2,
          do: %{
            "title" => " Source #{index} 雪 ",
            "url" => "https://SOURCES.EXAMPLE:443/research/#{index}?q=ordinary#part",
            "description" => " Passage #{index} 雪 \n\n Context #{index} 🙂 ",
            "siteName" => "sources.example",
            "published" => " 2026-11-0#{index} ",
            "excerpts" => [" Passage #{index} 雪 ", " Context #{index} 🙂 "]
          }
        )
    }
  end

  defp install(ctx, opts \\ []) do
    path = Keyword.get(opts, :path, "/mcp")
    payload = Keyword.get(opts, :payload, payload())
    transport_session = Keyword.get(opts, :transport_session, "ordinary-transport-session")
    version = Keyword.get(opts, :protocol_version, "2025-06-18")

    Gaoxy.Test.stub(ctx.fixture, "POST", path, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(raw)
      entries = registry_entries()

      protocol_info =
        if request["method"] == "tools/call" and Keyword.get(opts, :observe_protocol, false) do
          client =
            Enum.find_value(entries, fn
              {{:parallel_free_search, _, :client}, pid} -> pid
              _ -> nil
            end)

          Backplane.McpProtocol.Client.get_protocol_info(client, timeout: 1000)
        end

      entry = %{
        body: request,
        headers: Map.new(conn.req_headers),
        pids: entries,
        path: conn.request_path,
        query: conn.query_string,
        protocol_info: protocol_info
      }

      Agent.update(ctx.ledger, &%{&1 | posts: &1.posts ++ [entry]})

      case request["method"] do
        "initialize" ->
          conn =
            if transport_session,
              do: Plug.Conn.put_resp_header(conn, "mcp-session-id", transport_session),
              else: conn

          reply(
            conn,
            request["id"],
            %{
              "protocolVersion" => version,
              "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => "ordinary-parallel-fixture", "version" => "1"}
            },
            "json"
          )

        "notifications/initialized" ->
          Plug.Conn.resp(conn, 202, "")

        "tools/call" ->
          result =
            case Keyword.get(opts, :tool_content, "structured") do
              "text" ->
                %{"content" => [%{"type" => "text", "text" => Jason.encode!(payload)}]}

              "structured-priority" ->
                %{
                  "structuredContent" => payload,
                  "content" => [%{"type" => "text", "text" => Jason.encode!(%{"results" => []})}]
                }

              "structured" ->
                %{"structuredContent" => payload, "content" => []}
            end

          reply(conn, request["id"], result, Keyword.get(opts, :response_format, "json"))
      end
    end)

    Gaoxy.Test.stub(ctx.fixture, "DELETE", path, fn conn ->
      Agent.update(ctx.ledger, &%{&1 | deletes: &1.deletes ++ [Map.new(conn.req_headers)]})
      Plug.Conn.resp(conn, 204, "")
    end)
  end

  defp reply(conn, id, result, format) do
    envelope = %{"jsonrpc" => "2.0", "id" => id, "result" => result}

    case format do
      "json" ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(envelope))

      "sse" ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, "event: message\ndata: " <> Jason.encode!(envelope) <> "\n\n")

      "sse-multiline" ->
        body =
          envelope
          |> Jason.encode!(pretty: true)
          |> String.split("\n")
          |> Enum.map_join("\n", &("data: " <> &1))

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, "event: message\n" <> body <> "\n\n")
    end
  end

  defp posts(ctx), do: Agent.get(ctx.ledger, & &1.posts)

  defp registry_entries do
    Registry.select(Synapsis.MCP.Registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn
      {{:parallel_free_search, _, role}, pid}
      when role in [:client, :transport] and is_pid(pid) ->
        true

      _ ->
        false
    end)
  end

  defp assert_retired(ctx) do
    entries = ctx |> posts() |> Enum.flat_map(& &1.pids) |> Enum.uniq()
    assert Enum.any?(entries, fn {{_, _, role}, _} -> role == :client end)
    assert Enum.any?(entries, fn {{_, _, role}, _} -> role == :transport end)

    for {key, pid} <- entries do
      refute Process.alive?(pid)
      await_unregistered(key, System.monotonic_time(:millisecond) + 1_000)
    end
  end

  # Registry removes keys in its partition's asynchronous EXIT handler. Process
  # exit is checked immediately above; observe the exact keys until that handler
  # completes without reissuing a search or changing the registry ourselves.
  defp await_unregistered(key, deadline) do
    entries = Registry.lookup(Synapsis.MCP.Registry, key)

    if entries != [] and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(1)
      await_unregistered(key, deadline)
    else
      assert entries == []
    end
  end

  defp assert_uuid(value) do
    assert is_binary(value)

    assert Regex.match?(
             ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/,
             value
           )
  end
end
