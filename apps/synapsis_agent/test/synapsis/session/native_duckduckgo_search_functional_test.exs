defmodule Synapsis.Session.NativeDuckDuckGoSearchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Codex.Session, as: NativeSession
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.Web.Search
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::web_search"

  setup %{tmp_dir: root} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    Agent.update(harness.counter, &Map.put(&1, :search_requests, []))
    %{harness: harness}
  end

  test "selected keyless DuckDuckGo defaults reach the actual Worker catalog", %{harness: harness} do
    configure(harness, %{"provider" => "duckduckgo"})
    admitted = assert_admitted(harness)
    install_provider(harness, [])
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Describe available tools")
    initial = request(0)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_receive {:search_descriptors, descriptors, _}, 5000
    descriptor = assert_catalog(descriptors, admitted)

    assert descriptor.backend_context.config == %{
             provider: "duckduckgo",
             credential_id: nil,
             base_url: "https://html.duckduckgo.com/html",
             timeout_ms: 20_000,
             cache_ttl_ms: 900_000,
             count: 5,
             mode: "web",
             region: nil,
             safe_search: "moderate"
           }

    assert initial["tools"] == wire_tools(descriptor)
    assert_wire(initial, [], [])
    assert Enum.filter(parts(harness.session.id), &match?(%ToolUse{}, &1)) == []
    assert Agent.get(harness.counter, & &1.search_requests) == []
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 1
  end

  test "DuckDuckGo results and current-query cache survive ordinary completed Worker replacement",
       %{harness: harness} do
    base = Gaoxy.Test.url(harness.provider.fixture, "/html")

    configure(harness, %{
      "provider" => "duckduckgo",
      "base_url" => " " <> base <> " ",
      "count" => 3,
      "region" => " us-en "
    })

    args = %{"query" => " Ordinary sources 雪🙂 "}
    cached_args = %{"query" => "Ordinary sources 雪🙂", "count" => 5, "region" => " us-en "}
    followup = %{"query" => " Fresh sources 雪🙂 ", "count" => 3, "region" => " de-de "}

    calls = [
      {"duckduckgo-first", @name, args},
      {"duckduckgo-cached", @name, cached_args},
      {"duckduckgo-region", @name, followup}
    ]

    admitted = assert_admitted(harness)
    install_search(harness, :results)

    {descriptor, initial_root, requests, original_parts, uses, results} =
      run_search(harness, admitted, calls)

    assert descriptor.backend_context.config == %{
             provider: "duckduckgo",
             credential_id: nil,
             base_url: base,
             timeout_ms: 20_000,
             cache_ttl_ms: 900_000,
             count: 3,
             mode: "web",
             region: "us-en",
             safe_search: "moderate"
           }

    [first, cached, last] = Enum.map(results, &Jason.decode!(&1.content))
    assert is_integer(first["tookMs"]) and first["tookMs"] >= 0

    assert first == %{
             "kind" => "results",
             "provider" => "duckduckgo",
             "query" => " Ordinary sources 雪🙂 ",
             "count" => 2,
             "tookMs" => first["tookMs"],
             "results" => [
               %{
                 "title" => "First ordinary title 雪",
                 "url" => "https://www.sources.example/one",
                 "snippet" => "First ordinary snippet 🙂.",
                 "siteName" => "www.sources.example"
               },
               %{
                 "title" => "Second ordinary title",
                 "url" => "https://news.example/two",
                 "snippet" => "Second ordinary snippet.",
                 "siteName" => "news.example"
               }
             ]
           }

    assert cached == first |> Map.put("query", "Ordinary sources 雪🙂") |> Map.put("cached", true)
    assert is_integer(last["tookMs"]) and last["tookMs"] >= 0
    assert last == %{first | "query" => " Fresh sources 雪🙂 ", "tookMs" => last["tookMs"]}

    expected_http = [
      expected_request("Ordinary sources 雪🙂", "us-en"),
      expected_request("Fresh sources 雪🙂", "de-de")
    ]

    assert Agent.get(harness.counter, & &1.search_requests) == expected_http
    assert_history(harness.session.id, calls, requests, uses, results)
    assert_replay(harness, descriptor, initial_root, calls, original_parts, uses, results)
    assert Agent.get(harness.counter, & &1.search_requests) == expected_http
  end

  test "DuckDuckGo complete protocol-relative raw data and cache survive ordinary completed Worker replacement",
       %{harness: harness} do
    base = Gaoxy.Test.url(harness.provider.fixture, "/html")
    configure(harness, %{"provider" => "duckduckgo", "base_url" => base})
    args = %{"query" => "ordinary relative source"}
    cached_args = %{"query" => " ordinary relative source "}

    calls = [
      {"duckduckgo-raw-first", @name, args},
      {"duckduckgo-raw-cached", @name, cached_args}
    ]

    admitted = assert_admitted(harness)
    install_search(harness, :raw)

    {descriptor, initial_root, requests, original_parts, uses, results} =
      run_search(harness, admitted, calls)

    assert descriptor.backend_context.config == %{
             provider: "duckduckgo",
             credential_id: nil,
             base_url: base,
             timeout_ms: 20_000,
             cache_ttl_ms: 900_000,
             count: 5,
             mode: "web",
             region: nil,
             safe_search: "moderate"
           }

    [first, cached] = Enum.map(results, &Jason.decode!(&1.content))
    took = get_in(first, ["data", "tookMs"])
    assert is_integer(took) and took >= 0

    assert first == %{
             "kind" => "raw",
             "provider" => "duckduckgo",
             "data" => %{
               "provider" => "duckduckgo",
               "query" => "ordinary relative source",
               "count" => 1,
               "tookMs" => took,
               "results" => [
                 %{
                   "title" => "Relative ordinary source",
                   "url" => "//www.relative.example/guide",
                   "snippet" => "Relative ordinary snippet."
                 }
               ]
             }
           }

    assert cached == %{
             "kind" => "raw",
             "provider" => "duckduckgo",
             "data" => Map.put(first["data"], "cached", true)
           }

    expected_http = [expected_request("ordinary relative source", nil)]
    assert Agent.get(harness.counter, & &1.search_requests) == expected_http
    assert_history(harness.session.id, calls, requests, uses, results)
    assert_replay(harness, descriptor, initial_root, calls, original_parts, uses, results)
    assert Agent.get(harness.counter, & &1.search_requests) == expected_http
  end

  defp configure(harness, search) do
    config = Map.put(harness.agent_config.config, "web_search", search)

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{tools: [@name], config: config})
  end

  defp assert_admitted(harness) do
    session = start_supervised!({NativeSession, owner_pid: self()})

    authority = %{
      caller: "native-duckduckgo-functional",
      run_id: Ecto.UUID.generate(),
      grants: [@name],
      tool_revision: 1,
      tool_revisions: %{@name => 1}
    }

    assert {:ok, binding} = NativeSession.bind(session, authority)
    context = %{agent: %{name: harness.agent_name}}
    identity = %{run_id: authority.run_id, session_id: harness.session.id}
    assert {:ok, [bundle]} = Search.bundles(context, identity, authority, [@name], binding)
    assert {:ok, %{status: :confirmed}} = NativeSession.close(session)
    bundle
  end

  defp assert_catalog(descriptors, admitted) do
    assert Map.keys(descriptors) == [@name]
    descriptor = descriptors[@name]
    assert descriptor.backend == Search
    assert descriptor.schema == admitted.registry.tools[@name].schema
    assert descriptor.description == admitted.registry.tools[@name].description

    assert descriptor.description ==
             "Search the web using DuckDuckGo. Returns titles, URLs, and snippets with no API key required."

    assert descriptor.schema == %{
             "type" => "object",
             "properties" => %{
               "query" => %{"type" => "string", "description" => "Search query string."},
               "count" => %{
                 "type" => "integer",
                 "description" => "Number of results to return (1-10).",
                 "minimum" => 1,
                 "maximum" => 10
               },
               "region" => %{
                 "type" => "string",
                 "description" =>
                   "Optional DuckDuckGo region code such as us-en, uk-en, or de-de."
               },
               "safeSearch" => %{
                 "type" => "string",
                 "description" => "SafeSearch level: strict, moderate, or off."
               }
             },
             "required" => ["query"],
             "additionalProperties" => false
           }

    for group <- reference()["groups"] do
      assert descriptor.description == group["descriptor"]["description"], group["id"]

      # Native admission requires query; the source schema already uses integer count.
      assert descriptor.schema ==
               Map.put(group["descriptor"]["parameters"], "required", ["query"]),
             group["id"]
    end

    descriptor
  end

  defp run_search(harness, admitted, calls) do
    install_provider(harness, calls)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Search DuckDuckGo")
    requests = for index <- 0..length(calls), do: request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_receive {:search_descriptors, descriptors, initial_root}, 5000
    descriptor = assert_catalog(descriptors, admitted)
    for req <- requests, do: assert(req["tools"] == wire_tools(descriptor))
    original_parts = parts(harness.session.id)
    uses = Enum.filter(original_parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(original_parts, &match?(%ToolResult{}, &1))
    {descriptor, initial_root, requests, original_parts, uses, results}
  end

  defp assert_history(id, calls, requests, uses, results) do
    assert uses ==
             Enum.map(calls, fn {call_id, name, input} ->
               %ToolUse{tool_use_id: call_id, tool: name, input: input, status: :pending}
             end)

    assert Enum.map(results, & &1.tool_use_id) == Enum.map(calls, &elem(&1, 0))
    assert Enum.all?(results, &(&1.is_error == false))

    for result <- results do
      public = Jason.decode!(result.content)

      assert result.projection == %{
               "version" => 1,
               "result" => Map.merge(public, %{"content" => result.content, "is_error" => false})
             }
    end

    for {req, count} <- Enum.with_index(requests),
        do: assert_wire(req, Enum.take(calls, count), Enum.take(results, count))

    for part <- uses ++ results do
      assert {:ok, dump} = Synapsis.Part.dump(part)

      expected_dump =
        case part do
          %ToolUse{} ->
            %{
              "type" => "tool_use",
              "tool" => part.tool,
              "tool_use_id" => part.tool_use_id,
              "input" => part.input,
              "status" => "pending"
            }

          %ToolResult{} ->
            %{
              "type" => "tool_result",
              "tool_use_id" => part.tool_use_id,
              "content" => part.content,
              "projection" => part.projection,
              "is_error" => false
            }
        end

      assert dump == expected_dump
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert_durable(id, uses, results)
  end

  defp assert_replay(harness, descriptor, initial_root, calls, original_parts, uses, results) do
    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    {_, worker_data} = :sys.get_state(old_worker)
    runtime = :sys.get_state(worker_data.runtime_pid)
    assert is_pid(initial_root)
    refute Process.alive?(initial_root)
    assert runtime.root == nil
    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5000
    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute old_worker == new_worker
    assert :ok = Worker.send_message(harness.session.id, "Recall DuckDuckGo searches")
    replay = request(length(calls) + 1)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_receive {:search_replay_root, replay_root}, 5000
    assert is_pid(replay_root)
    refute Process.alive?(replay_root)
    {_, replay_worker_data} = :sys.get_state(new_worker)
    assert :sys.get_state(replay_worker_data.runtime_pid).root == nil
    assert replay["tools"] == wire_tools(descriptor)
    assert_wire(replay, calls, results)

    assert parts(harness.session.id) ==
             original_parts ++
               [%Text{content: "Recall DuckDuckGo searches"}, %Text{content: "Searches complete"}]

    assert_durable(harness.session.id, uses, results)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == length(calls) + 2
  end

  defp install_search(harness, branch) do
    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/html", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      observed = %{
        "method" => conn.method,
        "path" => conn.request_path,
        "query" => URI.decode_query(conn.query_string),
        "headers" => Map.take(Map.new(conn.req_headers), ["user-agent"]),
        "body" => body
      }

      Agent.update(harness.counter, &%{&1 | search_requests: &1.search_requests ++ [observed]})

      html =
        case branch do
          :results ->
            """
            <div><a class="result__a" href="https://www.sources.example/one"> First ordinary title 雪 </a><a class="result__snippet" href="https://www.sources.example/one"> First ordinary snippet 🙂. </a></div>
            <div><a href="https://news.example/two" class="result__a">Second ordinary title</a><a href="https://news.example/two" class="result__snippet">Second ordinary snippet.</a></div>
            """

          :raw ->
            """
            <div><a class="result__a" href="//www.relative.example/guide"> Relative ordinary source </a><a class="result__snippet" href="//www.relative.example/guide"> Relative ordinary snippet. </a></div>
            """
        end

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, html)
    end)
  end

  defp expected_request(query, region) do
    query =
      if region,
        do: %{"q" => query, "kl" => region, "kp" => "-1"},
        else: %{"q" => query, "kp" => "-1"}

    %{
      "method" => "GET",
      "path" => "/html",
      "query" => query,
      "headers" => %{
        "user-agent" =>
          "synapsis-duckduckgo/#{Application.spec(:synapsis_provider, :vsn)} (+https://github.com/gsmlg-opt/Synapsis)"
      },
      "body" => ""
    }
  end

  defp install_provider(harness, calls) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [req]}}
        end)

      send(owner, {:search_request, index, req})

      if index == 0 or index == length(calls) + 1 do
        [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
        {_, data} = :sys.get_state(worker)
        runtime = :sys.get_state(data.runtime_pid)

        if index == 0 do
          send(
            owner,
            {:search_descriptors, :sys.get_state(runtime.root).catalog.registry.tools,
             runtime.root}
          )
        else
          send(owner, {:search_replay_root, runtime.root})
        end
      end

      completed = Enum.count(req["messages"], &(&1["role"] == "tool"))

      chunks =
        case Enum.at(calls, completed) do
          {id, name, args} ->
            [
              DeterministicProvider.tool_call_chunk(ToolName.encode(name), id, args),
              DeterministicProvider.finish_chunk("tool_calls")
            ]

          nil ->
            [
              DeterministicProvider.text_chunk("Searches complete"),
              DeterministicProvider.finish_chunk("stop")
            ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)
  end

  defp wire_tools(descriptor) do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => ToolName.encode(@name),
          "description" => descriptor.description,
          "parameters" => descriptor.schema
        }
      }
    ]
  end

  defp request(index) do
    assert_receive {:search_request, ^index, request}, 15_000
    request
  end

  defp parts(id),
    do: for(message <- Synapsis.Message.list_by_session(id), part <- message.parts, do: part)

  defp assert_wire(req, calls, results) do
    uses = for message <- req["messages"], call <- List.wrap(message["tool_calls"]), do: call

    assert Enum.map(uses, fn call ->
             update_in(call, ["function", "arguments"], &Jason.decode!/1)
           end) ==
             Enum.map(calls, fn {id, name, input} ->
               %{
                 "id" => id,
                 "type" => "function",
                 "function" => %{"name" => ToolName.encode(name), "arguments" => input}
               }
             end)

    actual = for message <- req["messages"], message["role"] == "tool", do: message

    assert actual ==
             Enum.map(
               results,
               &%{"role" => "tool", "tool_call_id" => &1.tool_use_id, "content" => &1.content}
             )
  end

  defp assert_durable(id, uses, results) do
    assert {:ok, turns} = Store.list_turns(id)
    assert turns != []

    for {turn, index} <- Enum.with_index(turns),
        do: assert(Store.get_turn(id, index) == {:ok, turn})

    raw = for turn <- turns, part <- turn.parts, do: part

    assert Enum.map(Enum.filter(raw, &(&1[:type] == "tool_use")), &{&1.id, &1.name, &1.input}) ==
             Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input})

    assert Enum.map(
             Enum.filter(raw, &(&1[:type] == "tool_result")),
             &{&1.tool_use_id, &1.content, &1.projection, &1.is_error}
           ) ==
             Enum.map(results, &{&1.tool_use_id, &1.content, &1.projection, false})
  end

  defp reference do
    Path.expand("../../fixtures/openclaw/488631c/duckduckgo-search.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
  end
end
