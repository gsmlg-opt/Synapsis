defmodule Synapsis.Session.NativeBrowserNavigationStateFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::browser"
  @ids ~w(navigation-start navigation-open navigation-navigate navigation-click navigation-proof)

  test "navigate inline state drives the next ref action and survives durable Worker replay", %{
    tmp_dir: root
  } do
    harness = browser_harness(root)
    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok =
             Worker.send_message(harness.session.id, "Navigate and use the returned page state")

    initial = for index <- 0..3, do: receive_request(index)
    navigation = receipt(List.last(initial), "navigation-navigate")
    target = target_id(List.last(initial))
    assert %{"pageState" => state} = navigation
    assert_page_state(state, navigation, target, next_url(harness))
    requests = initial ++ for(index <- 4..5, do: receive_request(index))
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    final = List.last(requests)
    ref = navigation_ref(final)
    assert ref =~ ~r/^e\d+$/
    assert state["snapshot"] =~ "- button \"Continue 雪😀\" [ref=#{ref}]"
    assert receipt(final, "navigation-click")["ok"] == true

    assert receipt(final, "navigation-proof")["value"] == %{
             "clicks" => 1,
             "selectedText" => "Continued 雪😀",
             "title" => "Native navigation destination 雪😀",
             "url" => next_url(harness)
           }

    descriptor = Enum.find(hd(requests)["tools"], &(&1["name"] == ToolName.encode(@name)))
    assert descriptor["description"] =~ "pageState"

    opened = receipt(final, "navigation-open")
    assert opened["label"] == "docs"
    assert opened["suggestedTargetId"] == "docs"
    assert opened["targetId"] == target
    refute Map.has_key?(opened, "pageState")

    parts = browser_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == @ids
    assert Enum.map(results, & &1.tool_use_id) == @ids
    assert Enum.all?(uses, &(&1.tool == @name))
    assert Enum.all?(results, &(&1.is_error == false))
    assert Enum.map(uses, & &1.input) == for(index <- 0..4, do: call_input(index, final, harness))
    refute Enum.any?(uses, &(&1.input["action"] == "snapshot"))
    assert Enum.at(uses, 2).input["args"]["targetId"] == " docs "
    assert Enum.at(uses, 3).input["args"]["request"] == %{"kind" => "click", "ref" => ref}

    for {request, count} <- Enum.with_index(requests) do
      assert_wire_history(request, Enum.take(uses, count), Enum.take(results, count))
    end

    for result <- results do
      assert %{"version" => 1, "result" => projected} = result.projection
      assert is_binary(projected["content"])
      assert result.content == projected["content"]
      assert Jason.decode!(result.content) == receipt(final, result.tool_use_id)
      assert projected["structured"] == receipt(final, result.tool_use_id)
      assert Map.drop(projected, ~w(content structured is_error)) == projected["structured"]
      assert projected["is_error"] == false
    end

    navigation_part = Enum.find(results, &(&1.tool_use_id == "navigation-navigate"))
    assert navigation_part.projection["result"]["structured"]["pageState"] == state
    assert Jason.decode!(navigation_part.content)["pageState"] == state
    assert_part_round_trips(parts)
    assert_durable_parts(harness.session.id, uses, results)
    assert_effect_counts(harness)
    {_resource, broker} = browser_resource(harness.session.id)
    owned = owned_processes(broker)
    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5_000
    assert_owned_exited(owned)
    refute Process.alive?(broker)

    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute new_worker == old_worker
    assert :ok = Worker.send_message(harness.session.id, "Recall the completed inline navigation")
    replay = receive_request(6)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(replay, uses, results)
    assert browser_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)
    assert_effect_counts(harness)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 7
    {_resource, replay_broker} = browser_resource(harness.session.id)
    refute replay_broker == broker
    assert :sys.get_state(replay_broker).port == nil
  end

  defp assert_page_state(state, navigation, target, url) do
    assert navigation["targetId"] == target
    assert navigation["url"] == url
    assert is_integer(navigation["generation"])
    assert is_integer(navigation["documentGeneration"])

    assert %{
             "targetId" => ^target,
             "url" => ^url,
             "format" => "ai",
             "refsType" => "role",
             "truncated" => false
           } = state

    assert state["generation"] == navigation["generation"]
    assert state["documentGeneration"] == navigation["documentGeneration"]
    assert is_integer(state["snapshotGeneration"])
    assert state["snapshotGeneration"] > 0
    assert state["refCount"] == 2

    assert Enum.map(state["refs"], &Map.take(&1, ~w(role name))) == [
             %{"role" => "button", "name" => "Continue 雪😀"},
             %{"role" => "button", "name" => "Other action"}
           ]

    for item <- state["refs"] do
      assert item["ref"] =~ ~r/^e\d+$/
      assert state["snapshot"] =~ "[ref=#{item["ref"]}]"
    end

    assert String.valid?(state["snapshot"])
    assert length(String.split(state["snapshot"], "\n")) <= 100
    assert utf16_length(state["snapshot"]) <= 8000
    refute state["snapshot"] =~ "Original action"
    refute state["snapshot"] =~ "Noninteractive destination heading"
    refute state["snapshot"] =~ "Ordinary destination prose"
    assert state["semantics"] =~ "Native Chromium AX roles"
    refute Map.has_key?(state, "newElements")
    refute Map.has_key?(state, "content")
    refute Map.has_key?(navigation, "content")
  end

  defp utf16_length(text),
    do: div(byte_size(:unicode.characters_to_binary(text, :utf8, {:utf16, :little})), 2)

  defp browser_harness(root) do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    Agent.update(
      harness.counter,
      &Map.merge(&1, %{old_loads: 0, next_loads: 0, navigation_effects: 0})
    )

    repository = Path.expand("../../../../..", __DIR__)

    browser = %{
      "default_profile" => "managed",
      "node_executable" => System.find_executable("node"),
      "helper_path" => Path.join(repository, "packages/tool-host/src/browser/stdio.mjs"),
      "profiles" => %{
        "managed" => %{
          "driver" => "managed-host",
          "target" => "host",
          "executable" => "/run/current-system/sw/bin/chromium",
          "data_dir" => Path.join(root, "browser-data"),
          "timeout_ms" => 15_000
        }
      }
    }

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{
               tools: [@name],
               config: Map.put(harness.agent_config.config, "browser", browser)
             })

    assert :ok =
             Synapsis.Provider.Registry.register(harness.provider.name, %{
               type: "anthropic",
               base_url: harness.provider.base_url,
               api_key: "test-key"
             })

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/old", fn conn ->
      Agent.update(harness.counter, &%{&1 | old_loads: &1.old_loads + 1})

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(
        200,
        "<!doctype html><title>Original page</title><button>Original action</button>"
      )
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/next", fn conn ->
      Agent.update(harness.counter, &%{&1 | next_loads: &1.next_loads + 1})

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, """
      <!doctype html><html><head><meta charset="utf-8"><title>Native navigation destination 雪😀</title></head><body>
      <main><h1>Noninteractive destination heading</h1><p>Ordinary destination prose 雪😀</p>
      <button id="continue-action">Continue 雪😀</button><button>Other action</button></main>
      <script>
        window.navigationClicks = 0;
        document.querySelector('#continue-action').addEventListener('click', () => {
          window.navigationClicks++;
          document.querySelector('#continue-action').textContent = 'Continued 雪😀';
          window.navigationEffect = fetch('/navigation-effect', {method:'POST'});
        });
      </script>
      </body></html>
      """)
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/navigation-effect", fn conn ->
      Agent.update(harness.counter, &%{&1 | navigation_effects: &1.navigation_effects + 1})
      Plug.Conn.resp(conn, 200, "navigation effect recorded")
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/favicon.ico", &Plug.Conn.resp(&1, 204, ""))
    harness
  end

  defp install_provider(harness) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:browser_navigation_state_request, index, request})

      call =
        if index < length(@ids) and successful_results?(request) and
             (index != 3 or not is_nil(navigation_ref(request))),
           do: {Enum.at(@ids, index), call_input(index, request, harness)}

      provider_response(conn, call)
    end)
  end

  defp call_input(0, _request, _harness), do: input("start")

  defp call_input(1, _request, harness),
    do:
      input("open", %{
        "targetUrl" => Gaoxy.Test.url(harness.provider.fixture, "/old"),
        "label" => " docs "
      })

  defp call_input(2, _request, harness),
    do: input("navigate", %{"targetId" => " docs ", "targetUrl" => next_url(harness)})

  defp call_input(3, request, _harness),
    do: act(request, %{"kind" => "click", "ref" => navigation_ref(request)})

  defp call_input(4, request, _harness) do
    act(request, %{
      "kind" => "evaluate",
      "fn" => """
      async () => {
        await window.navigationEffect;
        return {clicks: window.navigationClicks,
          selectedText: document.querySelector('#continue-action').textContent,
          title: document.title, url: location.href};
      }
      """
    })
  end

  defp navigation_ref(request) do
    request
    |> receipt("navigation-navigate")
    |> get_in(["pageState", "refs"])
    |> List.wrap()
    |> Enum.find(&(&1["role"] == "button" and &1["name"] == "Continue 雪😀"))
    |> case do
      nil -> nil
      ref -> Map.fetch!(ref, "ref")
    end
  end

  defp act(request, action),
    do: input("act", %{"targetId" => target_id(request), "request" => action})

  defp input(action, args \\ %{}),
    do: %{"action" => action, "args" => args, "profile" => "managed", "timeout_ms" => 15_000}

  defp next_url(harness), do: Gaoxy.Test.url(harness.provider.fixture, "/next")

  defp assert_effect_counts(harness) do
    assert %{old_loads: 1, next_loads: 1, navigation_effects: 1} =
             Agent.get(harness.counter, & &1)
  end

  defp blocks(request),
    do: Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

  defp successful_results?(request),
    do: Enum.all?(blocks(request), &(&1["type"] != "tool_result" or &1["is_error"] == false))

  defp receive_request(index) do
    assert_receive {:browser_navigation_state_request, ^index, request}, 20_000

    assert successful_results?(request),
           "Browser failed before provider request #{index}: #{inspect(blocks(request))}"

    request
  end

  defp target_id(request), do: receipt(request, "navigation-open")["targetId"]

  defp receipt(request, id) do
    result =
      Enum.find(blocks(request), &(&1["type"] == "tool_result" and &1["tool_use_id"] == id))

    text = result["content"] |> Enum.find(&(&1["type"] == "text")) |> Map.fetch!("text")
    Jason.decode!(text)
  end

  defp assert_wire_history(request, uses, results) do
    blocks = blocks(request)

    assert Enum.filter(blocks, &(&1["type"] == "tool_use")) ==
             Enum.map(uses, fn part ->
               %{
                 "type" => "tool_use",
                 "id" => part.tool_use_id,
                 "name" => ToolName.encode(part.tool),
                 "input" => part.input
               }
             end)

    assert Enum.filter(blocks, &(&1["type"] == "tool_result")) ==
             Enum.map(results, fn part ->
               %{
                 "type" => "tool_result",
                 "tool_use_id" => part.tool_use_id,
                 "is_error" => false,
                 "content" => [
                   %{"type" => "text", "text" => part.projection["result"]["content"]}
                 ]
               }
             end)
  end

  defp browser_parts(id) do
    for message <- Synapsis.Message.list_by_session(id),
        part <- message.parts,
        match?(%ToolUse{}, part) or match?(%ToolResult{}, part),
        do: part
  end

  defp assert_part_round_trips(parts) do
    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end
  end

  defp assert_durable_parts(id, uses, results) do
    assert {:ok, turns} = Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns) do
      assert {:ok, ^turn} = Store.get_turn(id, index)
    end

    raw = for turn <- turns, part <- turn.parts, do: part

    assert Enum.filter(raw, &(&1[:type] == "tool_use")) ==
             Enum.map(uses, fn part ->
               %{
                 type: "tool_use",
                 id: part.tool_use_id,
                 name: part.tool,
                 input: part.input,
                 status: to_string(part.status)
               }
             end)

    assert Enum.filter(raw, &(&1[:type] == "tool_result")) ==
             Enum.map(results, fn part ->
               %{
                 type: "tool_result",
                 tool_use_id: part.tool_use_id,
                 content: part.content,
                 is_error: part.is_error,
                 projection: part.projection
               }
             end)
  end

  defp browser_resource(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker, 1_000)
    adapter = :sys.get_state(data.runtime_pid, 1_000)
    assert [resource] = Map.values(adapter.browser_resources)
    assert %{"managed" => %{pid: broker}} = resource.profiles
    assert Process.alive?(broker)
    {resource, broker}
  end

  defp owned_processes(broker) do
    port = :sys.get_state(broker, 1_000).port
    assert is_port(port)
    assert {:os_pid, helper} = Port.info(port, :os_pid)

    children =
      "/proc/#{helper}/task/#{helper}/children"
      |> File.read!()
      |> String.split()
      |> Enum.map(&String.to_integer/1)

    assert children != []
    [helper | children]
  end

  defp assert_owned_exited(pids) do
    deadline = System.monotonic_time(:millisecond) + 15_000
    await_owned_exit(pids, deadline)
  end

  defp await_owned_exit(pids, deadline) do
    alive = Enum.filter(pids, &File.exists?("/proc/#{&1}"))

    if alive != [] do
      assert System.monotonic_time(:millisecond) < deadline,
             "owned Browser processes did not exit: #{inspect(alive)}"

      Process.sleep(10)
      await_owned_exit(alive, deadline)
    end
  end

  defp provider_response(conn, call) do
    {content, delta, stop} =
      case call do
        {id, input} ->
          {%{"type" => "tool_use", "id" => id, "name" => ToolName.encode(@name), "input" => %{}},
           %{"type" => "input_json_delta", "partial_json" => Jason.encode!(input)}, "tool_use"}

        nil ->
          {%{"type" => "text", "text" => ""},
           %{"type" => "text_delta", "text" => "Native inline navigation inspected"}, "end_turn"}
      end

    events = [
      %{"type" => "content_block_start", "index" => 0, "content_block" => content},
      %{"type" => "content_block_delta", "index" => 0, "delta" => delta},
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => stop}},
      %{"type" => "message_stop"}
    ]

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.resp(
      200,
      Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
    )
  end
end
