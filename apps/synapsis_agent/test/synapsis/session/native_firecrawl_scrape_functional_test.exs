defmodule Synapsis.Session.NativeFirecrawlScrapeFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.{DisplayCatalog, Profiles}
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @name "synapsis::firecrawl_scrape"

  test "selected native scrape retains raw calls, text metadata and effect-free new Worker history",
       %{tmp_dir: root} do
    assert @name in Profiles.supported_names()
    assert Enum.any?(DisplayCatalog.list(), &(&1.name == @name and &1.category == :web))

    h =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    assert {:ok, credential} =
             Synapsis.Credentials.create(%{
               name: h.agent_name <> " scrape",
               key: "fixture-scrape-key"
             })

    on_exit(fn ->
      try do
        SessionHarness.cleanup!(h)
      after
        Synapsis.Credentials.delete(credential.id)
      end
    end)

    config =
      Map.put(h.agent_config.config, "firecrawl_scrape", %{
        "credential_id" => credential.id,
        "base_url" => Gaoxy.Test.url(h.provider.fixture, "/ignored?local=fixture")
      })

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(h.agent_config, %{tools: [@name], config: config})

    Agent.update(h.counter, &Map.put(&1, :scrapes, []))

    payload = %{
      "success" => true,
      "data" => %{
        "markdown" => "# Operational notes\n\n- [Alpha](https://pages.example/a)\n- `Beta`\n",
        "metadata" => %{
          "sourceURL" => "https://PAGES.example:443/final",
          "statusCode" => "200.9",
          "title" => "  Page title  "
        }
      },
      "warning" => "  Ordinary provider notice\n"
    }

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v2/scrape", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      Agent.update(
        h.counter,
        &Map.update!(&1, :scrapes, fn requests -> requests ++ [Jason.decode!(body)] end)
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)

    args = %{
      "url" => " https://pages.example/original ",
      "extractMode" => "text",
      "maxChars" => 1000,
      "onlyMainContent" => false,
      "maxAgeMs" => 0,
      "proxy" => "basic",
      "storeInCache" => false
    }

    calls = [{"scrape-first", @name, args}, {"scrape-repeat", @name, args}]
    owner = self()

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)

      index =
        Agent.get_and_update(h.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [req]}}
        end)

      send(owner, {:scrape_request, index, req})

      if index == 0 do
        [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
        {_, data} = :sys.get_state(worker)
        runtime = :sys.get_state(data.runtime_pid)

        send(
          owner,
          {:scrape_descriptor, :sys.get_state(runtime.root).catalog.registry.tools[@name]}
        )
      end

      completed = Enum.count(req["messages"], &(&1["role"] == "tool"))

      chunks =
        case Enum.at(calls, completed) do
          {id, name, arguments} ->
            [
              DeterministicProvider.tool_call_chunk(ToolName.encode(name), id, arguments),
              DeterministicProvider.finish_chunk("tool_calls")
            ]

          nil ->
            [
              DeterministicProvider.text_chunk("Scrape complete"),
              DeterministicProvider.finish_chunk("stop")
            ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)

    SessionHarness.subscribe!(h.session.id)
    SessionHarness.ensure_running!(h.session.id)
    assert :ok = Worker.send_message(h.session.id, "Scrape the configured fixture page")
    initial = request(0)
    assert_receive {:scrape_descriptor, descriptor}, 5_000
    assert descriptor.backend == Synapsis.Agent.Tools.Web.Scrape
    assert descriptor.backend_context.config.timeout_ms == 60_000
    assert hd(initial["tools"])["function"]["parameters"] == descriptor.schema
    assert Enum.map(initial["tools"], &ToolName.decode(&1["function"]["name"])) == [@name]
    _after_first = request(1)
    after_repeat = request(2)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    parts = parts(h.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input}) == calls
    assert Enum.map(results, & &1.tool_use_id) == ["scrape-first", "scrape-repeat"]
    assert Enum.all?(results, &(&1.is_error == false))
    [first, repeated] = Enum.map(results, &Jason.decode!(&1.content))
    assert Enum.map(results, & &1.projection["result"]["structured"]) == [first, repeated]

    text = "Operational notes\n\nAlpha\nBeta"

    assert first == %{
             "url" => "https://pages.example/original",
             "finalUrl" => "https://pages.example/final",
             "status" => 200,
             "title" => "  Page title  ",
             "extractor" => "firecrawl",
             "extractMode" => "text",
             "truncated" => false,
             "rawLength" => Synapsis.Provider.WebSearch.TextBudget.units(text),
             "length" => Synapsis.Provider.WebSearch.TextBudget.units(text),
             "text" => text,
             "warning" => "  Ordinary provider notice\n"
           }

    assert repeated == first

    assert_wire(after_repeat, calls, results)
    assert {:ok, turns} = Store.list_turns(h.session.id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert(Store.get_turn(h.session.id, index) == {:ok, turn})

    for part <- uses ++ results do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert_effect(h, args)
    [{old, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
    monitor = Process.monitor(old)
    assert :ok = DynamicSupervisor.stop_session(h.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old, _}, 5_000
    SessionHarness.ensure_running!(h.session.id)
    assert :ok = Worker.send_message(h.session.id, "Recall the completed scrape")
    replay = request(3)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_wire(replay, calls, results)

    assert parts(h.session.id) ==
             parts ++
               [
                 %Text{content: "Recall the completed scrape"},
                 %Text{content: "Scrape complete"}
               ]

    assert_effect(h, args)
  end

  defp request(index) do
    assert_receive {:scrape_request, ^index, req}, 15_000
    req
  end

  defp parts(id),
    do: for(message <- Synapsis.Message.list_by_session(id), part <- message.parts, do: part)

  defp assert_effect(h, _args) do
    expected = %{
      "url" => "https://pages.example/original",
      "formats" => ["markdown"],
      "onlyMainContent" => false,
      "timeout" => 60_000,
      "maxAge" => 0,
      "proxy" => "basic",
      "storeInCache" => false
    }

    assert Agent.get(h.counter, & &1.scrapes) == [expected, expected]
  end

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
end
