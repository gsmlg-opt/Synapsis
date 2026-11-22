defmodule Synapsis.Session.NativePerplexitySearchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.Web.Search
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::web_search"

  test "Perplexity Search retains raw invocation, public output and durable effect-free replay",
       %{tmp_dir: root} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    {:ok, credential} =
      Synapsis.Credentials.create(%{
        name: harness.agent_name <> " search",
        key: "ordinary-native-perplexity"
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
    base = Gaoxy.Test.url(harness.provider.fixture, "/perplexity")

    config =
      Map.put(harness.agent_config.config, "web_search", %{
        "provider" => "perplexity",
        "mode" => "search_api",
        "credential_id" => credential.id,
        "base_url" => base,
        "timeout_ms" => 5000
      })

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{
               tools: [@name],
               config: config
             })

    args = %{
      "query" => " native search ",
      "count" => 2,
      "language" => " EN ",
      "domain_filter" => [" example.org "],
      "freshness" => " PW "
    }

    calls = [{"perplexity-first", @name, args}, {"perplexity-cached", @name, args}]
    install_provider(harness, calls)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Search Perplexity")
    requests = for index <- 0..2, do: request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_receive {:search_descriptors, descriptors, initial_root}, 5000
    assert Map.keys(descriptors) == [@name]
    assert descriptors[@name].backend == Search
    schema = descriptors[@name].schema
    assert hd(hd(requests)["tools"])["parameters"] == schema

    assert Enum.sort(Map.keys(schema["properties"])) ==
             ~w(count country date_after date_before domain_filter freshness language max_tokens max_tokens_per_page query)

    parts = parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input}) == calls
    assert Enum.all?(results, &(&1.is_error == false))
    [first, cached] = Enum.map(results, &Formata.JSON.decode!(&1.content))
    assert first["provider"] == "perplexity"
    assert first["query"] == " native search "
    assert cached == Map.put(first, "cached", true)

    assert first["kind"] == "results"
    assert Enum.map(first["results"], & &1["title"]) == ["Source"]

    for {req, count} <- Enum.with_index(requests),
        do: assert_wire(req, Enum.take(calls, count), Enum.take(results, count))

    for part <- uses ++ results do
      assert {:ok, dump} = Synapsis.Part.dump(part)

      assert {:ok, ^part} =
               dump |> Formata.JSON.encode!() |> Formata.JSON.decode!() |> Synapsis.Part.load()
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
    replay = request(3)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_wire(replay, calls, results)

    assert parts(harness.session.id) ==
             parts ++ [%Text{content: "Recall searches"}, %Text{content: "Searches complete"}]

    assert_durable(harness.session.id, uses, results)
    assert_effect(harness)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 4
  end

  defp install_search(harness) do
    path = "/perplexity/search"

    payload = %{
      "results" => [
        %{"title" => "Source", "url" => "https://example.org/source", "snippet" => "Passage"}
      ]
    }

    Gaoxy.Test.stub(harness.provider.fixture, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      Agent.update(
        harness.counter,
        &%{&1 | search_requests: &1.search_requests ++ [{path, Formata.JSON.decode!(body)}]}
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Formata.JSON.encode!(payload))
    end)
  end

  defp assert_effect(harness) do
    assert [{"/perplexity/search", body}] = Agent.get(harness.counter, & &1.search_requests)

    assert body == %{
             "query" => "native search",
             "max_results" => 2,
             "search_language_filter" => ["EN"],
             "search_domain_filter" => ["example.org"],
             "search_recency_filter" => "week"
           }
  end

  defp install_provider(harness, calls) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Formata.JSON.decode!(body)

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

      completed = Enum.count(req["input"], &(&1["type"] == "function_call_output"))

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
    uses = Enum.filter(req["input"], &(&1["type"] == "function_call"))

    assert Enum.map(uses, fn call ->
             {call["call_id"], ToolName.decode(call["name"]),
              Formata.JSON.decode!(call["arguments"])}
           end) == calls

    actual = for message <- req["input"], message["type"] == "function_call_output", do: message

    assert actual ==
             Enum.map(
               results,
               &%{
                 "type" => "function_call_output",
                 "call_id" => &1.tool_use_id,
                 "output" => &1.content
               }
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
