defmodule Synapsis.Session.NativeXSearchFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.{DisplayCatalog, Profiles}
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @name "synapsis::x_search"

  test "selected native X search retains raw calls, citations, cached results and new Worker history",
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
               name: h.agent_name <> " x_search",
               key: "fixture-x_search-key"
             })

    on_exit(fn ->
      try do
        SessionHarness.cleanup!(h)
      after
        Synapsis.Credentials.delete(credential.id)
      end
    end)

    config =
      Map.put(h.agent_config.config, "x_search", %{
        "credential_id" => credential.id,
        "base_url" => " " <> Gaoxy.Test.url(h.provider.fixture, "/v1/") <> " ",
        "inline_citations" => true,
        "max_turns" => 3
      })

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(h.agent_config, %{tools: [@name], config: config})

    Agent.update(h.counter, &Map.put(&1, :searches, []))

    payload = %{
      "output" => [
        %{
          "type" => "message",
          "content" => [
            %{
              "type" => "output_text",
              "text" => "Posts 😀",
              "annotations" => [
                %{"type" => "url_citation", "url" => "https://x.com/alpha/status/1"}
              ]
            },
            %{"type" => "output_text", "text" => " and updates."}
          ]
        }
      ],
      "inline_citations" => [
        %{"start_index" => 0, "end_index" => 8, "url" => "https://x.com/alpha/status/1"}
      ]
    }

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      Agent.update(
        h.counter,
        &Map.update!(&1, :searches, fn requests -> requests ++ [Jason.decode!(body)] end)
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)

    args = %{
      "query" => "  Show the release posts  ",
      "allowed_x_handles" => ["alpha", "beta"],
      "from_date" => "2026-10-01",
      "to_date" => "2026-10-28",
      "enable_image_understanding" => true,
      "enable_video_understanding" => true
    }

    calls = [{"x_search-first", @name, args}, {"x_search-repeat", @name, args}]
    owner = self()

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)

      index =
        Agent.get_and_update(h.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [req]}}
        end)

      send(owner, {:x_search_request, index, req})

      if index == 0 do
        [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
        {_, data} = :sys.get_state(worker)
        runtime = :sys.get_state(data.runtime_pid)

        send(
          owner,
          {:x_search_descriptor, :sys.get_state(runtime.root).catalog.registry.tools[@name]}
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
              DeterministicProvider.text_chunk("Search complete"),
              DeterministicProvider.finish_chunk("stop")
            ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)

    SessionHarness.subscribe!(h.session.id)
    SessionHarness.ensure_running!(h.session.id)
    assert :ok = Worker.send_message(h.session.id, "X Search the configured fixture page")
    initial = request(0)
    assert_receive {:x_search_descriptor, descriptor}, 5_000
    assert descriptor.backend == Synapsis.Agent.Tools.Web.XSearch
    assert descriptor.backend_context.config.timeout_ms == 30_000

    assert descriptor.backend_context.config.base_url ==
             Gaoxy.Test.url(h.provider.fixture, "/v1/")

    assert hd(initial["tools"])["function"]["parameters"] == descriptor.schema
    assert Enum.map(initial["tools"], &ToolName.decode(&1["function"]["name"])) == [@name]
    _after_first = request(1)
    after_repeat = request(2)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    parts = parts(h.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input}) == calls
    assert Enum.map(results, & &1.tool_use_id) == ["x_search-first", "x_search-repeat"]
    assert Enum.all?(results, &(&1.is_error == false))
    [first, repeated] = Enum.map(results, &Jason.decode!(&1.content))
    assert Enum.map(results, & &1.projection["result"]["structured"]) == [first, repeated]

    assert is_integer(first["tookMs"]) and first["tookMs"] >= 0

    assert Map.delete(first, "tookMs") == %{
             "query" => "Show the release posts",
             "provider" => "xai",
             "model" => "grok-4.7",
             "content" => "Posts 😀 and updates.",
             "citations" => ["https://x.com/alpha/status/1"],
             "inlineCitations" => [
               %{"start_index" => 0, "end_index" => 8, "url" => "https://x.com/alpha/status/1"}
             ],
             "allowedXHandles" => ["alpha", "beta"],
             "fromDate" => "2026-10-01",
             "toDate" => "2026-10-28",
             "enableImageUnderstanding" => true,
             "enableVideoUnderstanding" => true
           }

    assert repeated == Map.put(first, "cached", true)

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
    assert :ok = Worker.send_message(h.session.id, "Recall the completed x_search")
    replay = request(3)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_wire(replay, calls, results)

    assert parts(h.session.id) ==
             parts ++
               [
                 %Text{content: "Recall the completed x_search"},
                 %Text{content: "Search complete"}
               ]

    assert_effect(h, args)
  end

  defp request(index) do
    assert_receive {:x_search_request, ^index, req}, 15_000
    req
  end

  defp parts(id),
    do: for(message <- Synapsis.Message.list_by_session(id), part <- message.parts, do: part)

  defp assert_effect(h, _args) do
    expected = %{
      "model" => "grok-4.7",
      "input" => [%{"role" => "user", "content" => "Show the release posts"}],
      "tools" => [
        %{
          "type" => "x_search",
          "allowed_x_handles" => ["alpha", "beta"],
          "from_date" => "2026-10-01",
          "to_date" => "2026-10-28",
          "enable_image_understanding" => true,
          "enable_video_understanding" => true
        }
      ],
      "store" => false,
      "reasoning" => %{"effort" => "low"},
      "max_turns" => 3
    }

    assert Agent.get(h.counter, & &1.searches) == [expected]
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
