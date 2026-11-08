defmodule Synapsis.Session.NativePerplexitySearchFunctionalTest do
  use ExUnit.Case, async: false
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.Web.Search
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::web_search"

  for mode <- ["search_api", "chat_completions"] do
    @mode mode
    test "selected #{@mode} retains raw invocation, public output and durable effect-free replay",
         %{tmp_dir: root} do
      mode = @mode

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
      install_search(harness, mode)
      base = Gaoxy.Test.url(harness.provider.fixture, "/perplexity")

      config =
        Map.put(harness.agent_config.config, "web_search", %{
          "provider" => "perplexity",
          "mode" => mode,
          "credential_id" => credential.id,
          "base_url" => base,
          "timeout_ms" => 5000
        })

      assert {:ok, _} =
               Synapsis.AgentConfigs.update(harness.agent_config, %{
                 tools: [@name],
                 config: config
               })

      args =
        if mode == "search_api",
          do: %{
            "query" => " native search ",
            "count" => 2,
            "language" => " EN ",
            "domain_filter" => [" example.org "],
            "freshness" => " PW "
          },
          else: %{"query" => " native search ", "count" => 2, "freshness" => " PW "}

      cached_args = if mode == "chat_completions", do: Map.put(args, "count", 9), else: args
      calls = [{"perplexity-first", @name, args}, {"perplexity-cached", @name, cached_args}]
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
      assert hd(hd(requests)["tools"])["function"]["parameters"] == schema

      assert Enum.sort(Map.keys(schema["properties"])) ==
               if(mode == "search_api",
                 do:
                   ~w(count country date_after date_before domain_filter freshness language max_tokens max_tokens_per_page query),
                 else: ~w(count freshness query)
               )

      parts = parts(harness.session.id)
      uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
      results = Enum.filter(parts, &match?(%ToolResult{}, &1))
      assert Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input}) == calls
      assert Enum.all?(results, &(&1.is_error == false))
      [first, cached] = Enum.map(results, &Jason.decode!(&1.content))
      assert first["provider"] == "perplexity"
      assert first["query"] == " native search "
      assert cached == Map.put(first, "cached", true)

      if mode == "search_api" do
        assert first["kind"] == "results"
        assert Enum.map(first["results"], & &1["title"]) == ["Source"]
      else
        assert first["kind"] == "answer"
        assert first["content"] == "Ordinary native answer"

        assert first["citations"] == [
                 %{"url" => "https://b.example/"},
                 %{"url" => "https://a.example/"}
               ]

        assert hd(results).projection["result"]["structured"] == first
      end

      for {req, count} <- Enum.with_index(requests),
          do: assert_wire(req, Enum.take(calls, count), Enum.take(results, count))

      for part <- uses ++ results do
        assert {:ok, dump} = Synapsis.Part.dump(part)
        assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
      end

      assert_durable(harness.session.id, uses, results)
      assert_effect(harness, mode)
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
      assert_effect(harness, mode)
      assert length(Agent.get(harness.counter, & &1.provider_requests)) == 4
    end
  end

  defp install_search(harness, mode) do
    path = if mode == "search_api", do: "/perplexity/search", else: "/perplexity/chat/completions"

    payload =
      if mode == "search_api",
        do: %{
          "results" => [
            %{"title" => "Source", "url" => "https://example.org/source", "snippet" => "Passage"}
          ]
        },
        else: %{
          "choices" => [%{"message" => %{"content" => "Ordinary native answer"}}],
          "citations" => ["https://b.example/", "https://a.example/"]
        }

    Gaoxy.Test.stub(harness.provider.fixture, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      Agent.update(
        harness.counter,
        &%{&1 | search_requests: &1.search_requests ++ [{path, Jason.decode!(body)}]}
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end

  defp assert_effect(harness, mode) do
    assert [{path, body}] = Agent.get(harness.counter, & &1.search_requests)

    if mode == "search_api" do
      assert path == "/perplexity/search"

      assert body == %{
               "query" => "native search",
               "max_results" => 2,
               "search_language_filter" => ["EN"],
               "search_domain_filter" => ["example.org"],
               "search_recency_filter" => "week"
             }
    else
      assert path == "/perplexity/chat/completions"

      assert body == %{
               "model" => "perplexity/sonar-pro",
               "messages" => [%{"role" => "user", "content" => "native search"}],
               "search_recency_filter" => "week"
             }
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
