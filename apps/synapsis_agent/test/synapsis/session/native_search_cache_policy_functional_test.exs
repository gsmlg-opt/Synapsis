defmodule Synapsis.Session.NativeSearchCachePolicyFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.Web.Search
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::firecrawl_search"

  test "native search timeout options share result cache while raw calls survive durable replay",
       %{tmp_dir: root} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    {:ok, credential} =
      Synapsis.Credentials.create(%{
        name: harness.agent_name <> " cache policy",
        key: "fixture-cache-policy-key"
      })

    on_exit(fn -> Synapsis.Credentials.delete(credential.id) end)
    Agent.update(harness.counter, &Map.put(&1, :search_requests, []))
    install_search(harness)

    config =
      Map.put(harness.agent_config.config, "firecrawl_search", %{
        "credential_id" => credential.id,
        "base_url" => Gaoxy.Test.url(harness.provider.fixture),
        "timeout_ms" => 5_000,
        "cache_ttl_ms" => 900_000
      })

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{tools: [@name], config: config})

    calls = calls()
    install_provider(harness, calls)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Search with ordinary timeout options")
    requests = for index <- 0..3, do: request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_receive {:search_descriptors, descriptors}, 5_000
    assert [tool] = hd(requests)["tools"]
    assert ToolName.decode(tool["function"]["name"]) == @name
    assert descriptors[@name].backend == Search
    assert tool["function"]["parameters"] == descriptors[@name].schema

    original = parts(harness.session.id)
    uses = Enum.filter(original, &match?(%ToolUse{}, &1))
    results = Enum.filter(original, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input}) == calls
    assert Enum.map(results, & &1.tool_use_id) == Enum.map(calls, &elem(&1, 0))
    assert Enum.all?(results, &(&1.is_error == false))
    [first, longer_timeout, original_timeout] = Enum.map(results, &Jason.decode!(&1.content))

    assert Map.keys(first) |> Enum.sort() == ~w(count provider query results tookMs)
    assert first["provider"] == "firecrawl"
    assert first["query"] == "native policy search"
    assert first["count"] == 1
    assert is_integer(first["tookMs"]) and first["tookMs"] >= 0

    assert first["results"] == [
             %{
               "title" => "Policy source 1",
               "url" => "https://cache-policy.example/document-1",
               "description" => "Ordinary cached passage",
               "content" => "# Cached document 1",
               "siteName" => "cache-policy.example"
             }
           ]

    assert longer_timeout == Map.put(first, "cached", true)
    assert original_timeout == longer_timeout

    for {req, count} <- Enum.with_index(requests),
        do: assert_wire(req, Enum.take(calls, count), Enum.take(results, count))

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
    assert :ok = Worker.send_message(harness.session.id, "Recall searches with timeout options")
    replay = request(4)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_wire(replay, calls, results)

    assert parts(harness.session.id) ==
             original ++
               [
                 %Text{content: "Recall searches with timeout options"},
                 %Text{content: "Searches complete"}
               ]

    assert_durable(harness.session.id, uses, results)
    assert_search_effects(harness)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 5
  end

  defp calls do
    arguments = %{
      "query" => "  native policy search  ",
      "count" => 1,
      "sources" => ["web"],
      "scrape_results" => true
    }

    for {id, timeout} <- [
          {"search-timeout-first", 1},
          {"search-timeout-longer", 2},
          {"search-timeout-original", 1}
        ],
        do: {id, @name, Map.put(arguments, "timeout_seconds", timeout)}
  end

  defp install_search(harness) do
    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v2/search", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      input = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.search_requests) + 1,
           %{state | search_requests: state.search_requests ++ [input]}}
        end)

      payload = %{
        "success" => true,
        "data" => %{
          "web" => [
            %{
              "title" => "Policy source #{index}",
              "url" => "https://cache-policy.example/document-#{index}",
              "description" => "Ordinary cached passage",
              "markdown" => "# Cached document #{index}"
            }
          ]
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
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
    assert Agent.get(harness.counter, & &1.search_requests) == [
             %{
               "query" => "native policy search",
               "limit" => 1,
               "sources" => ["web"],
               "scrapeOptions" => %{"formats" => ["markdown"]}
             }
           ]
  end
end
