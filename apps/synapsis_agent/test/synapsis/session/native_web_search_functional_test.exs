defmodule Synapsis.Session.NativeWebSearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.{DisplayCatalog, Profiles}
  alias Synapsis.Agent.Tools.Web.Search
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @names ~w(synapsis::web_search synapsis::tavily_search synapsis::firecrawl_search)

  test "selected searches retain provider-specific results, cache and durable effect-free replay",
       %{
         tmp_dir: root
       } do
    assert Enum.all?(@names, &(&1 in Profiles.supported_names()))

    assert Enum.all?(@names, fn name ->
             Enum.any?(DisplayCatalog.list(), &(&1.name == name and &1.category == :web))
           end)

    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    {:ok, credential} =
      Synapsis.Credentials.create(%{
        name: harness.agent_name <> " search",
        key: "fixture-search-key"
      })

    on_exit(fn ->
      try do
        SessionHarness.cleanup!(harness)
      after
        Synapsis.Credentials.delete(credential.id)
      end
    end)

    Agent.update(harness.counter, &Map.put(&1, :search_requests, []))
    install_searches(harness)
    base = harness.provider.fixture |> Gaoxy.Test.url() |> String.trim_trailing("/")
    common = %{"credential_id" => credential.id, "timeout_ms" => 5_000}

    config =
      harness.agent_config.config
      |> Map.put("web_search", Map.merge(common, %{"provider" => "brave", "base_url" => base}))
      |> Map.put("tavily_search", Map.put(common, "base_url", base <> "/tavily"))
      |> Map.put("firecrawl_search", Map.put(common, "base_url", base <> "/ignored"))

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{tools: @names, config: config})

    calls = calls()
    install_provider(harness, calls)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Search the configured fixture services")
    requests = for index <- 0..4, do: request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_receive {:search_descriptors, descriptors}, 5_000
    first = hd(requests)

    assert Enum.sort(Enum.map(first["tools"], &ToolName.decode(&1["function"]["name"]))) ==
             Enum.sort(@names)

    for tool <- first["tools"] do
      name = ToolName.decode(tool["function"]["name"])
      assert descriptors[name].backend == Search
      assert tool["function"]["parameters"] == descriptors[name].schema
    end

    parts = parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input}) == calls
    assert Enum.map(results, & &1.tool_use_id) == Enum.map(calls, &elem(&1, 0))
    assert Enum.all?(results, &(&1.is_error == false))
    [brave, tavily, firecrawl, cached] = Enum.map(results, &Jason.decode!(&1.content))
    assert brave["provider"] == "brave"
    assert brave["query"] == "native search"
    assert Enum.map(brave["results"], & &1["title"]) == ["Runtime", "Contracts"]
    assert tavily["provider"] == "tavily"
    assert tavily["answer"] =~ "Provider-specific answer"
    assert Enum.map(tavily["results"], & &1["score"]) == [0.9, 0.8]
    assert firecrawl["provider"] == "firecrawl"

    assert Enum.map(firecrawl["results"], & &1["url"]) ==
             ["https://example.net/web", "https://example.net/news"]

    assert Enum.map(firecrawl["results"], & &1["content"]) == ["# Web article", "# News article"]
    assert cached["cached"] == true
    assert Map.delete(cached, "cached") == Map.delete(brave, "cached")

    for {req, count} <- Enum.with_index(requests) do
      assert_wire(req, Enum.take(calls, count), Enum.take(results, count))
    end

    for part <- uses ++ results do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert_durable(harness.session.id, uses, results)
    assert_search_effects(harness)
    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5_000
    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute old_worker == new_worker
    assert :ok = Worker.send_message(harness.session.id, "Recall the completed searches")
    replay = request(5)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_wire(replay, calls, results)

    assert parts(harness.session.id) ==
             parts ++
               [
                 %Text{content: "Recall the completed searches"},
                 %Text{content: "Searches complete"}
               ]

    assert_durable(harness.session.id, uses, results)
    assert_search_effects(harness)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 6
  end

  defp calls do
    brave = %{"query" => "native search", "count" => 2, "country" => "US", "search_lang" => "en"}

    [
      {"search-brave", Enum.at(@names, 0), brave},
      {"search-tavily", Enum.at(@names, 1),
       %{
         "query" => "rich search",
         "count" => 2,
         "search_depth" => "advanced",
         "topic" => "news",
         "include_answer" => true,
         "time_range" => "week",
         "include_domains" => ["example.org"]
       }},
      {"search-firecrawl", Enum.at(@names, 2),
       %{
         "query" => "articles",
         "count" => 2,
         "sources" => ["web", "news"],
         "include_domains" => ["example.net"],
         "scrape_results" => true
       }},
      {"search-brave-cache", Enum.at(@names, 0), brave}
    ]
  end

  defp install_searches(harness) do
    fixtures = [
      {"GET", "/res/v1/web/search",
       %{
         "web" => %{
           "results" => [
             %{
               "title" => "Runtime",
               "url" => "https://example.org/runtime",
               "description" => "Native execution"
             },
             %{
               "title" => "Contracts",
               "url" => "https://example.org/contracts",
               "description" => "Public contracts"
             }
           ]
         }
       }},
      {"POST", "/tavily/search",
       %{
         "answer" => "Provider-specific answer",
         "results" => [
           %{
             "title" => "First",
             "url" => "https://example.org/first",
             "content" => "First snippet",
             "score" => 0.9
           },
           %{
             "title" => "Second",
             "url" => "https://example.org/second",
             "content" => "Second snippet",
             "score" => 0.8
           }
         ]
       }},
      {"POST", "/v2/search",
       %{
         "success" => true,
         "data" => %{
           "web" => [
             %{
               "title" => "Web",
               "url" => "https://example.net/web",
               "description" => "Web snippet",
               "markdown" => "# Web article"
             }
           ],
           "news" => [
             %{
               "title" => "News",
               "url" => "https://example.net/news",
               "description" => "News snippet",
               "markdown" => "# News article"
             }
           ]
         }
       }}
    ]

    for {method, path, response} <- fixtures do
      Gaoxy.Test.stub(harness.provider.fixture, method, path, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        input =
          if method == "GET", do: URI.decode_query(conn.query_string), else: Jason.decode!(body)

        Agent.update(
          harness.counter,
          &%{&1 | search_requests: &1.search_requests ++ [{path, input}]}
        )

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)
    end
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

      if index == 0 do
        [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
        {_, data} = :sys.get_state(worker)
        runtime = :sys.get_state(data.runtime_pid)
        send(owner, {:search_descriptors, :sys.get_state(runtime.root).catalog.registry.tools})
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

  defp request(index) do
    assert_receive {:search_request, ^index, request}, 15_000
    request
  end

  defp parts(id),
    do: for(message <- Synapsis.Message.list_by_session(id), part <- message.parts, do: part)

  defp assert_wire(req, calls, results) do
    uses = for message <- req["messages"], call <- List.wrap(message["tool_calls"]), do: call

    assert Enum.map(uses, fn call ->
             {call["id"], ToolName.decode(call["function"]["name"]),
              Jason.decode!(call["function"]["arguments"])}
           end) == calls

    actual = for message <- req["messages"], message["role"] == "tool", do: message

    assert actual ==
             Enum.map(
               results,
               &%{"role" => "tool", "tool_call_id" => &1.tool_use_id, "content" => &1.content}
             )
  end

  defp assert_durable(id, uses, results) do
    assert {:ok, turns} = Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert(Store.get_turn(id, index) == {:ok, turn})

    raw = for turn <- turns, part <- turn.parts, do: part

    assert Enum.map(Enum.filter(raw, &(&1[:type] == "tool_use")), &{&1.id, &1.name, &1.input}) ==
             Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input})

    assert Enum.map(
             Enum.filter(raw, &(&1[:type] == "tool_result")),
             &{&1.tool_use_id, &1.content, &1.projection}
           ) ==
             Enum.map(results, &{&1.tool_use_id, &1.content, &1.projection})
  end

  defp assert_search_effects(harness) do
    assert [{"/res/v1/web/search", brave}, {"/tavily/search", tavily}, {"/v2/search", firecrawl}] =
             Agent.get(harness.counter, & &1.search_requests)

    assert Map.take(brave, ~w(q count country search_lang)) ==
             %{"q" => "native search", "count" => "2", "country" => "US", "search_lang" => "en"}

    assert Map.take(
             tavily,
             ~w(query max_results search_depth topic include_answer time_range include_domains)
           ) ==
             %{
               "query" => "rich search",
               "max_results" => 2,
               "search_depth" => "advanced",
               "topic" => "news",
               "include_answer" => true,
               "time_range" => "week",
               "include_domains" => ["example.org"]
             }

    assert Map.take(firecrawl, ~w(query limit sources includeDomains scrapeOptions)) ==
             %{
               "query" => "articles",
               "limit" => 2,
               "sources" => ["web", "news"],
               "includeDomains" => ["example.net"],
               "scrapeOptions" => %{"formats" => ["markdown"]}
             }
  end
end
