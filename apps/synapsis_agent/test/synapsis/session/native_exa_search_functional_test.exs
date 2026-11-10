defmodule Synapsis.Session.NativeExaSearchFunctionalTest do
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

  test "selected Exa retains content filters, raw calls and completed durable history without another effect",
       %{tmp_dir: root} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    {:ok, credential} =
      Synapsis.Credentials.create(%{
        name: harness.agent_name <> " Exa",
        key: "ordinary-native-exa"
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
    base = Gaoxy.Test.url(harness.provider.fixture, "/exa/search/?route=ordinary#local")

    config =
      Map.put(harness.agent_config.config, "web_search", %{
        "provider" => "exa",
        "credential_id" => credential.id,
        "base_url" => "  " <> base <> "  ",
        "timeout_ms" => 5000,
        "count" => 100
      })

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{tools: [@name], config: config})

    args = %{
      "query" => " native Exa search ",
      "count" => 12,
      "type" => "deep-reasoning",
      "date_after" => " 2026-01-02 ",
      "date_before" => "2026-03-04",
      "contents" => %{
        "summary" => %{"query" => " raw summary "},
        "text" => false,
        "highlights" => %{
          "maxCharacters" => 50,
          "query" => " raw highlight ",
          "numSentences" => 2,
          "highlightsPerUrl" => 3
        }
      }
    }

    calls = [{"exa-first", @name, args}, {"exa-cached", @name, args}]
    install_provider(harness, calls)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Search Exa")
    requests = for index <- 0..2, do: request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_receive {:search_descriptors, descriptors, initial_root}, 5000
    assert Map.keys(descriptors) == [@name]
    assert descriptors[@name].backend == Search
    schema = descriptors[@name].schema
    assert hd(hd(requests)["tools"])["function"]["parameters"] == schema

    assert Enum.sort(Map.keys(schema["properties"])) ==
             ~w(contents count date_after date_before freshness query type)

    assert schema["properties"]["count"]["maximum"] == 100

    assert schema["properties"]["type"]["enum"] ==
             ~w(auto neural fast deep deep-reasoning instant)

    parts = parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input}) == calls
    assert Enum.all?(results, &(&1.is_error == false))
    [first, cached] = Enum.map(results, &Jason.decode!(&1.content))
    assert first["provider"] == "exa"
    assert first["query"] == " native Exa search "
    assert first["kind"] == "results"
    assert first["count"] == 10
    assert first["truncated"] == true
    assert Enum.map(first["results"], & &1["title"]) == for(index <- 1..10, do: "Source #{index}")

    assert Enum.map(first["results"], & &1["snippet"]) ==
             for(index <- 1..10, do: "Passage #{index}\n次の行")

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
    payload = %{
      "results" =>
        for(
          index <- 1..12,
          do: %{
            "title" => "Source #{index}",
            "url" => "https://www.example.org/source-#{index}",
            "highlights" => [" Passage #{index} ", " 次の行 "],
            "summary" => "Summary",
            "highlightScores" => [0.8, 0],
            "publishedDate" => "2026-01-03"
          }
        )
    }

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/exa/search", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      Agent.update(
        harness.counter,
        &%{
          &1
          | search_requests:
              &1.search_requests ++
                [
                  {conn.query_string, Jason.decode!(body),
                   Plug.Conn.get_req_header(conn, "x-exa-integration")}
                ]
        }
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end

  defp assert_effect(harness) do
    assert [{"route=ordinary", body, ["synapsis"]}] =
             Agent.get(harness.counter, & &1.search_requests)

    assert body == %{
             "query" => "native Exa search",
             "numResults" => 12,
             "type" => "deep-reasoning",
             "startPublishedDate" => "2026-01-02",
             "endPublishedDate" => "2026-03-04",
             "contents" => %{
               "summary" => %{"query" => " raw summary "},
               "text" => false,
               "highlights" => %{
                 "maxCharacters" => 50,
                 "query" => " raw highlight ",
                 "numSentences" => 2,
                 "highlightsPerUrl" => 3
               }
             }
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
