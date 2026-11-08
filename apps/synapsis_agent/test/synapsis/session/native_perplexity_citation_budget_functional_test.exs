defmodule Synapsis.Session.NativePerplexityCitationBudgetFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.Web.Search
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Provider.WebSearch.TextBudget
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::web_search"
  @call_id "perplexity-citation-budget"
  @complete "Citation references retained"

  test "full citation-budget reference survives native admission, persistence and fresh Worker replay",
       %{tmp_dir: root} do
    row = reference()
    original = row["providerResult"]
    urls = original["citations"]
    assert original["content"] == "Nonempty ordinary answer"
    assert length(urls) == 20

    assert Enum.all?(
             urls,
             &(String.starts_with?(&1, "https://") and TextBudget.units(&1) == 1000)
           )

    assert Enum.sum(Enum.map(urls, &TextBudget.units/1)) == 20_000

    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    assert {:ok, credential} =
             Synapsis.Credentials.create(%{
               name: harness.agent_name <> " citation budget",
               key: "ordinary-local-citation-budget"
             })

    on_exit(fn ->
      try do
        SessionHarness.cleanup!(harness)
      after
        Synapsis.Credentials.delete(credential.id)
      end
    end)

    Agent.update(harness.counter, &Map.put(&1, :search_requests, []))
    install_search(harness, original)

    config =
      Map.put(harness.agent_config.config, "web_search", %{
        "provider" => "perplexity",
        "mode" => "chat_completions",
        "credential_id" => credential.id,
        "base_url" => Gaoxy.Test.url(harness.provider.fixture, "/citation-budget"),
        "timeout_ms" => 5000
      })

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{
               tools: [@name],
               config: config
             })

    arguments = %{"query" => row["query"], "count" => 1}
    install_provider(harness, arguments)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Retain all citation references")
    first = request(0)
    following = request(1)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_receive {:citation_budget_descriptors, descriptors, initial_root}, 5000
    assert descriptors[@name].backend == Search

    function =
      Enum.find_value(first["tools"], fn tool ->
        if tool["function"]["name"] == ToolName.encode(@name), do: tool["function"]
      end)

    assert function["parameters"] == descriptors[@name].schema
    original_parts = parts(harness.session.id)
    assert [%ToolUse{} = tool_use] = Enum.filter(original_parts, &match?(%ToolUse{}, &1))
    assert {tool_use.tool_use_id, tool_use.tool, tool_use.input} == {@call_id, @name, arguments}

    assert [%ToolResult{tool_use_id: @call_id, is_error: false} = result] =
             Enum.filter(original_parts, &match?(%ToolResult{}, &1))

    public = Jason.decode!(result.content)

    assert Map.drop(public, ["tookMs"]) ==
             Map.drop(row["publicUnwrappedResult"], ~w(tookMs externalContent))

    assert is_integer(public["tookMs"]) and public["tookMs"] >= 0
    assert public["content"] == ""
    assert public["truncated"] == true
    assert Enum.map(public["citations"], & &1["url"]) == urls
    assert result.projection["result"]["structured"] == public
    assert_wire(first, [], [])
    assert_wire(following, [tool_use], [result])

    for part <- [tool_use, result] do
      assert {:ok, dumped} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dumped |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert_durable(harness.session.id, tool_use, result)
    assert_source_request(harness, original)
    assert is_pid(initial_root)
    refute Process.alive?(initial_root)
    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5000
    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute new_worker == old_worker

    assert :ok = Worker.send_message(harness.session.id, "Recall the complete citation result")
    replay = request(2)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_wire(replay, [tool_use], [result])

    assert parts(harness.session.id) ==
             original_parts ++
               [%Text{content: "Recall the complete citation result"}, %Text{content: @complete}]

    assert_durable(harness.session.id, tool_use, result)
    assert_source_request(harness, original)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 3
  end

  defp reference do
    Path.expand("../../fixtures/openclaw/488631c/perplexity-search.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("normalizerCases")
    |> Enum.find(&(&1["id"] == "answer-citations-exhaust-body"))
  end

  defp install_search(harness, original) do
    payload = %{
      "choices" => [%{"message" => %{"content" => original["content"]}}],
      "citations" => original["citations"]
    }

    Gaoxy.Test.stub(
      harness.provider.fixture,
      "POST",
      "/citation-budget/chat/completions",
      fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        Agent.update(
          harness.counter,
          &%{&1 | search_requests: &1.search_requests ++ [Jason.decode!(body)]}
        )

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(payload))
      end
    )
  end

  defp assert_source_request(harness, original) do
    assert Agent.get(harness.counter, & &1.search_requests) == [
             %{
               "model" => original["model"],
               "messages" => [%{"role" => "user", "content" => original["query"]}]
             }
           ]
  end

  defp install_provider(harness, arguments) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [decoded]}}
        end)

      send(owner, {:citation_budget_request, index, decoded})

      chunks =
        if index == 0 do
          [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
          {_, data} = :sys.get_state(worker)
          runtime = :sys.get_state(data.runtime_pid)
          descriptors = :sys.get_state(runtime.root).catalog.registry.tools
          send(owner, {:citation_budget_descriptors, descriptors, runtime.root})

          [
            DeterministicProvider.tool_call_chunk(ToolName.encode(@name), @call_id, arguments),
            DeterministicProvider.finish_chunk("tool_calls")
          ]
        else
          [
            DeterministicProvider.text_chunk(@complete),
            DeterministicProvider.finish_chunk("stop")
          ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)
  end

  defp request(index) do
    assert_receive {:citation_budget_request, ^index, decoded}, 15_000
    decoded
  end

  defp parts(id),
    do: for(message <- Synapsis.Message.list_by_session(id), part <- message.parts, do: part)

  defp assert_wire(request, uses, results) do
    calls =
      for message <- request["messages"], call <- List.wrap(message["tool_calls"]), do: call

    assert Enum.map(calls, fn call ->
             {call["id"], ToolName.decode(call["function"]["name"]),
              Jason.decode!(call["function"]["arguments"])}
           end) == Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input})

    assert Enum.filter(request["messages"], &(&1["role"] == "tool")) ==
             Enum.map(results, fn result ->
               %{
                 "role" => "tool",
                 "tool_call_id" => result.tool_use_id,
                 "content" => result.content
               }
             end)
  end

  defp assert_durable(id, tool_use, result) do
    assert {:ok, turns} = Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert(Store.get_turn(id, index) == {:ok, turn})

    raw = for turn <- turns, part <- turn.parts, do: part

    assert Enum.map(Enum.filter(raw, &(&1[:type] == "tool_use")), &{&1.id, &1.name, &1.input}) ==
             [{tool_use.tool_use_id, tool_use.tool, tool_use.input}]

    assert Enum.map(
             Enum.filter(raw, &(&1[:type] == "tool_result")),
             &{&1.tool_use_id, &1.is_error, &1.content, &1.projection}
           ) == [{result.tool_use_id, false, result.content, result.projection}]
  end
end
