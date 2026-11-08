defmodule Synapsis.Session.NativeBrowserInputFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::browser"
  @ids ~w(input-start input-open input-actions input-read)

  test "Browser pointer and key phases preserve text, durable raw calls and effect-free Worker replay",
       %{
         tmp_dir: root
       } do
    harness = browser_harness(root)
    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Run the local Browser input phases")

    requests = for index <- 0..4, do: receive_request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert [%{"name" => encoded}] = hd(requests)["tools"]
    assert ToolName.decode(encoded) == @name
    final = List.last(requests)
    proof = receipt(final, "input-read")["value"]
    assert_input_effects(proof)

    assert receipt(final, "input-actions")["targetId"] == target_id(final)

    assert receipt(final, "input-actions")["results"] == [
             %{"ok" => true},
             %{"ok" => true, "results" => List.duplicate(%{"ok" => true}, 2)},
             %{"ok" => true, "results" => List.duplicate(%{"ok" => true}, 7)},
             %{"ok" => true, "results" => List.duplicate(%{"ok" => true}, 3)},
             %{"ok" => true, "value" => "marked"}
           ]

    parts = browser_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == @ids
    assert Enum.map(results, & &1.tool_use_id) == @ids
    assert Enum.all?(uses, &(&1.tool == @name))
    assert Enum.all?(results, &(&1.is_error == false))
    assert Enum.map(uses, & &1.input) == for(index <- 0..3, do: call_input(index, final, harness))

    for {request, count} <- Enum.with_index(requests) do
      assert_wire_history(request, Enum.take(uses, count), Enum.take(results, count))
    end

    for result <- results do
      assert %{"version" => 1, "result" => %{"content" => content}} = result.projection
      assert result.content == content
      assert Jason.decode!(content) == receipt(final, result.tool_use_id)
    end

    assert_part_round_trips(parts)
    assert_durable_parts(harness.session.id, uses, results)
    assert_effect_counts(harness, proof)
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
    assert :ok = Worker.send_message(harness.session.id, "Recall the completed Browser inputs")
    replay = receive_request(5)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(replay, uses, results)
    assert browser_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)
    assert_effect_counts(harness, proof)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 6
    {_resource, replay_broker} = browser_resource(harness.session.id)
    refute replay_broker == broker
    assert :sys.get_state(replay_broker).port == nil
  end

  defp assert_input_effects(proof) do
    assert proof["path"] == "/page"
    assert proof["markers"] == ["input"]
    assert proof["elapsedMs"] < 10_000
    delayed = proof["pointer"]["delayed"]
    assert Enum.map(delayed, & &1["type"]) == ~w(mouseenter mousedown mouseup click)
    assert event_time(delayed, "mousedown") - event_time(delayed, "mouseenter") >= 150
    assert Enum.find(delayed, &(&1["type"] == "click"))["shift"] == true

    doubled = proof["pointer"]["doubled"]

    assert Enum.map(doubled, & &1["type"]) ==
             ~w(mouseenter mousedown mouseup click mousedown mouseup click dblclick)

    assert event_time(doubled, "mousedown") - event_time(doubled, "mouseenter") >= 90
    assert for(event <- doubled, event["type"] == "click", do: event["detail"]) == [1, 2]

    coords = proof["pointer"]["coords"]
    assert Enum.map(coords, & &1["type"]) == ~w(mouseenter mousedown mouseup click)
    assert event_time(coords, "mouseup") - event_time(coords, "mousedown") >= 150

    keys = proof["keys"]
    downs = Enum.filter(keys, &(&1["type"] == "keydown"))

    assert Enum.map(downs, & &1["key"]) ==
             ["Escape", "Enter", "Delete", "Control", "Shift", "K", " ", " ", "+"]

    assert Enum.map(Enum.filter(keys, &(&1["type"] == "keyup")), & &1["key"]) ==
             ["Escape", "Enter", "Delete", "K", "Shift", "Control", " ", " ", "+"]

    assert Enum.find(downs, &(&1["key"] == "K")) |> Map.take(["ctrl", "shift"]) ==
             %{"ctrl" => true, "shift" => true}

    for {key, minimum} <- [{"Escape", 150}, {"Enter", 110}, {"K", 130}] do
      held = Enum.filter(keys, &(&1["key"] == key))
      assert event_time(held, "keyup") - event_time(held, "keydown") >= minimum
    end

    assert proof["values"] == %{
             "keys" => "  +",
             "slow" => "seed:ABC",
             "extended" => "kept:XY",
             "plain" => "filled"
           }

    assert Enum.map(proof["slow"], & &1["value"]) == ["seed:A", "seed:AB", "seed:ABC"]
    assert Enum.map(proof["extended"], & &1["value"]) == ["kept:X", "kept:XY"]
    assert_intervals(proof["slow"], 55)
    assert_intervals(proof["extended"], 90)
  end

  defp event_time(events, type), do: Enum.find(events, &(&1["type"] == type))["time"]

  defp assert_intervals(events, minimum) do
    for [left, right] <- Enum.chunk_every(events, 2, 1, :discard) do
      assert right["time"] - left["time"] >= minimum
    end
  end

  defp browser_harness(root) do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    Agent.update(harness.counter, &Map.merge(&1, %{page_loads: 0, markers: []}))
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

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/page", fn conn ->
      Agent.update(harness.counter, &%{&1 | page_loads: &1.page_loads + 1})

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, """
      <!doctype html><html><head><title>Native Browser input phases</title>
      <style>
      body { margin: 0; }
      button, input { position: absolute; left: 20px; box-sizing: border-box; height: 40px; }
      button { width: 160px; }
      input { width: 300px; font: 16px monospace; }
      #delayed { top: 20px; } #doubled { top: 80px; } #coords { top: 140px; }
      #slow { top: 200px; } #extended { top: 260px; } #plain { top: 320px; }
      #keys { top: 380px; }
      </style></head><body>
      <button id="delayed">Delayed click</button><button id="doubled">Double click</button>
      <button id="coords">Coordinate click</button>
      <input id="slow" value="seed:"><input id="extended" value="kept:">
      <input id="plain" value="replace me"><input id="keys" value="">
      <script>
      window.inputEvents = {pointer: {}, keys: [], slow: [], extended: []};
      window.markers = [];
      for (const id of ['delayed', 'doubled', 'coords']) {
        const events = window.inputEvents.pointer[id] = [];
        for (const type of ['mouseenter', 'mousedown', 'mouseup', 'click', 'dblclick']) {
          document.getElementById(id).addEventListener(type, event => events.push({
            type, time: event.timeStamp, detail: event.detail, shift: event.shiftKey
          }));
        }
      }
      for (const type of ['keydown', 'keyup']) {
        document.getElementById('keys').addEventListener(type, event => {
          window.inputEvents.keys.push({type, key: event.key, time: event.timeStamp,
            ctrl: event.ctrlKey, shift: event.shiftKey});
          if (event.ctrlKey) event.preventDefault();
        });
      }
      for (const id of ['slow', 'extended']) {
        document.getElementById(id).addEventListener('input', event => {
          window.inputEvents[id].push({time: event.timeStamp, value: event.target.value});
        });
      }
      window.inputProof = () => ({...window.inputEvents, markers: window.markers, elapsedMs: window.inputElapsed,
        path: location.pathname, values: Object.fromEntries(
          ['keys', 'slow', 'extended', 'plain'].map(id => [id, document.getElementById(id).value]))});
      </script></body></html>
      """)
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/marker/input", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      proof = Jason.decode!(body)
      Agent.update(harness.counter, &%{&1 | markers: &1.markers ++ [proof]})
      Plug.Conn.resp(conn, 200, "marked")
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

      send(owner, {:browser_input_request, index, request})

      call =
        if index < length(@ids) and successful_results?(request),
          do: {Enum.at(@ids, index), call_input(index, request, harness)}

      provider_response(conn, call)
    end)
  end

  defp call_input(0, _request, _harness), do: input("start")
  defp call_input(1, _request, harness), do: input("open", %{"targetUrl" => page_url(harness)})

  defp call_input(index, request, _harness) do
    action =
      case index do
        2 ->
          batch([
            %{
              "kind" => "click",
              "selector" => "#delayed",
              "delayMs" => 180,
              "modifiers" => ["Shift"]
            },
            batch([
              %{
                "kind" => "click",
                "selector" => "#doubled",
                "doubleClick" => true,
                "delayMs" => 120
              },
              %{"kind" => "clickCoords", "x" => 100, "y" => 160, "delayMs" => 180}
            ]),
            batch([
              %{"kind" => "press", "selector" => "#keys", "key" => "Esc", "delayMs" => 180},
              %{"kind" => "press", "key" => "Return", "delayMs" => 140},
              %{"kind" => "press", "selector" => "#keys", "key" => "Del"},
              %{"kind" => "press", "key" => "Ctrl+Shift+K", "delayMs" => 160},
              %{"kind" => "press", "key" => " "},
              %{"kind" => "press", "key" => "space"},
              %{"kind" => "press", "key" => " + "}
            ]),
            batch([
              %{"kind" => "type", "selector" => "#slow", "text" => "ABC", "slowly" => true},
              %{
                "kind" => "type",
                "selector" => "#extended",
                "text" => "XY",
                "slowly" => true,
                "delayMs" => 120
              },
              %{"kind" => "type", "selector" => "#plain", "text" => "filled"}
            ]),
            %{
              "kind" => "evaluate",
              "fn" => """
              async () => {
                window.inputElapsed = performance.now() - window.inputEvents.pointer.delayed[0].time;
                window.markers.push('input');
                await fetch('/marker/input', {method: 'POST', body: JSON.stringify(window.inputProof())});
                return 'marked';
              }
              """
            }
          ])

        3 ->
          %{"kind" => "evaluate", "fn" => "() => window.inputProof()"}
      end

    input("act", %{"targetId" => target_id(request), "request" => action})
  end

  defp batch(actions), do: %{"kind" => "batch", "actions" => actions}

  defp input(action, args \\ %{}),
    do: %{"action" => action, "args" => args, "profile" => "managed", "timeout_ms" => 15_000}

  defp page_url(harness), do: Gaoxy.Test.url(harness.provider.fixture, "/page")

  defp assert_effect_counts(harness, proof) do
    assert %{page_loads: 1, markers: [^proof]} = Agent.get(harness.counter, & &1)
  end

  defp blocks(request),
    do: Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

  defp successful_results?(request),
    do: Enum.all?(blocks(request), &(&1["type"] != "tool_result" or &1["is_error"] == false))

  defp receive_request(index) do
    assert_receive {:browser_input_request, ^index, request}, 20_000

    assert successful_results?(request),
           "Browser failed before provider request #{index}: #{inspect(blocks(request))}"

    request
  end

  defp target_id(request), do: receipt(request, "input-open")["targetId"]

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
           %{"type" => "text_delta", "text" => "Browser input phases inspected"}, "end_turn"}
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
