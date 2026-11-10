defmodule Synapsis.Session.NativeTavilySearchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.Web.Search
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @generic "synapsis::web_search"
  @rich "synapsis::tavily_search"

  test "selected rich and generic Tavily preserve normal filters, scores, news timestamps and durable completed history",
       %{tmp_dir: root} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    {:ok, credential} =
      Synapsis.Credentials.create(%{
        name: harness.agent_name <> " Tavily",
        key: "ordinary-native-tavily"
      })

    on_exit(fn ->
      try do
        SessionHarness.cleanup!(harness)
      after
        Synapsis.Credentials.delete(credential.id)
      end
    end)

    Agent.update(harness.counter, &Map.put(&1, :search_requests, []))
    install_search(harness)

    cfg = %{
      "provider" => "tavily",
      "credential_id" => credential.id,
      "base_url" => Gaoxy.Test.url(harness.provider.fixture, "/proxy/"),
      "timeout_ms" => 5000,
      "cache_ttl_ms" => 60000,
      "count" => 5
    }

    config =
      harness.agent_config.config
      |> Map.put("web_search", cfg)
      |> Map.put("tavily_search", cfg)

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{
               tools: [@generic, @rich],
               config: config
             })

    rich = %{
      "query" => " native Tavily search ",
      "count" => 20,
      "search_depth" => "advanced",
      "topic" => "news",
      "time_range" => "week",
      "include_domains" => [" example.org ", ""],
      "exclude_domains" => [" excluded.example "],
      "include_answer" => true
    }

    generic = %{"query" => " generic Tavily search ", "count" => 2}

    calls = [
      {"tavily-rich", @rich, rich},
      {"tavily-generic", @generic, generic},
      {"tavily-cached", @rich, rich}
    ]

    install_provider(harness, calls)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Search Tavily")
    requests = for index <- 0..3, do: request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 15000
    assert_receive {:search_descriptors, descriptors, initial_root}, 5000
    assert Enum.sort(Map.keys(descriptors)) == Enum.sort([@generic, @rich])
    assert Enum.all?(Map.values(descriptors), &(&1.backend == Search))

    tools =
      Map.new(
        hd(requests)["tools"],
        &{ToolName.decode(&1["function"]["name"]), &1["function"]["parameters"]}
      )

    assert tools == Map.new(descriptors, fn {name, value} -> {name, value.schema} end)

    assert Enum.sort(Map.keys(descriptors[@rich].schema["properties"])) ==
             ~w(count exclude_domains include_answer include_domains query search_depth time_range topic)

    assert descriptors[@rich].schema["properties"]["count"]["maximum"] == 20
    assert Enum.sort(Map.keys(descriptors[@generic].schema["properties"])) == ~w(count query)
    assert descriptors[@generic].schema["properties"]["count"]["maximum"] == 10
    parts = parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input}) == calls
    assert Enum.all?(results, &(&1.is_error == false))
    [first, generic_result, cached] = Enum.map(results, &Jason.decode!(&1.content))
    assert first["provider"] == "tavily"
    assert first["query"] == "native Tavily search"
    assert first["count"] == 20

    assert Enum.map(first["results"], & &1["title"]) ==
             for(index <- 1..20, do: "Source #{index}")

    assert Enum.map(first["results"], & &1["snippet"]) ==
             for(index <- 1..20, do: "Passage #{index} 雪")

    assert first["answer"] == "Full Tavily answer 雪"
    assert Enum.map(first["results"], & &1["score"]) == for(index <- 1..20, do: index / 20)

    assert Enum.all?(
             first["results"],
             &(&1["published"] == "2026-01-03T04:05:06.000Z")
           )

    assert generic_result["kind"] == "results"
    assert generic_result["query"] == generic["query"]
    assert generic_result["count"] == 2
    assert Enum.map(generic_result["results"], & &1["title"]) == ["Source 1", "Source 2"]
    assert Enum.map(generic_result["results"], & &1["snippet"]) == ["Passage 1 雪", "Passage 2 雪"]
    assert Enum.all?(generic_result["results"], &(&1["published"] == "2026-01-03T04:05:06.000Z"))
    assert cached == Map.put(first, "cached", true)

    for {req, count} <- Enum.with_index(requests),
        do: assert_wire(req, Enum.take(calls, count), Enum.take(results, count))

    for part <- uses ++ results do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert_durable(harness.session.id, uses, results)
    assert_effect(harness)
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
    assert :ok = Worker.send_message(harness.session.id, "Recall searches")
    replay = request(4)
    assert_receive {:run_event, %{type: "session.completed"}}, 15000
    assert_wire(replay, calls, results)

    assert parts(harness.session.id) ==
             parts ++ [%Text{content: "Recall searches"}, %Text{content: "Searches complete"}]

    assert_durable(harness.session.id, uses, results)
    assert_effect(harness)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 5
  end

  defp install_search(harness) do
    payload = %{
      "answer" => "Full Tavily answer 雪",
      "results" =>
        for(
          index <- 1..20,
          do: %{
            "url" => "https://www.example.org/source-#{index}",
            "title" => "Source #{index}",
            "content" => "Passage #{index} 雪",
            "score" => index / 20,
            "published_date" => "Sat, 03 Jan 2026 04:05:06 GMT"
          }
        )
    }

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/proxy/search", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      Agent.update(
        harness.counter,
        &%{&1 | search_requests: &1.search_requests ++ [{conn.query_string, Jason.decode!(body)}]}
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end

  defp assert_effect(harness) do
    assert [{"", rich}, {"", generic}] = Agent.get(harness.counter, & &1.search_requests)

    assert rich == %{
             "query" => "native Tavily search",
             "max_results" => 20,
             "search_depth" => "advanced",
             "topic" => "news",
             "time_range" => "week",
             "include_domains" => ["example.org"],
             "exclude_domains" => ["excluded.example"],
             "include_answer" => true
           }

    assert generic == %{"query" => " generic Tavily search ", "max_results" => 2}
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

        send(
          owner,
          {:search_descriptors, :sys.get_state(runtime.root).catalog.registry.tools, runtime.root}
        )
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
end
