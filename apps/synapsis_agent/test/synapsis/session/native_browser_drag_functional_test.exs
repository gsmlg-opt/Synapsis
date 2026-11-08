defmodule Synapsis.Session.NativeBrowserDragFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.ResourceRegistry
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 150_000
  @name "synapsis::browser"
  @ids ~w(drag-start drag-open drag-snapshot drag-prepare drag-action drag-proof)
  @prepare_fn "() => window.prepareDrag()"
  @proof_fn """
  async () => {
    await window.dragObserved;
    return {...window.effects,output:document.getElementById('result').textContent,
      source:window.sourceElement.id,destination:window.destinationElement.id,
      scrolled:document.getElementById('scroller').scrollTop > 0,path:location.pathname};
  }
  """

  test "native distant retained-handle drag preserves raw history and durable effect-free normal replay",
       %{tmp_dir: root} do
    harness = browser_harness(root)
    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Drag the retained local controls")

    requests = for index <- 0..6, do: receive_request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    final = List.last(requests)
    snapshot = receipt(final, "drag-snapshot")
    target = target_id(final)
    proof = receipt(final, "drag-proof")["value"]

    assert snapshot["targetId"] == target
    assert snapshot["url"] == page_url(harness)
    assert snapshot["refsType"] == "role"
    assert snapshot["snapshot"] =~ "Drag source"
    assert snapshot["snapshot"] =~ "Drag destination"
    assert page_ref(final, "Drag source") =~ ~r/^e\d+$/
    assert page_ref(final, "Drag destination") =~ ~r/^e\d+$/
    refute page_ref(final, "Drag source") == page_ref(final, "Drag destination")

    metadata = %{
      "generation" => snapshot["generation"],
      "targetId" => target,
      "url" => page_url(harness)
    }

    assert receipt(final, "drag-prepare") ==
             Map.put(metadata, "value", %{
               "source" => "retained-source",
               "destination" => "retained-destination"
             })

    assert receipt(final, "drag-action") == Map.put(metadata, "ok", true)

    assert proof == %{
             "presses" => [
               %{
                 "source" => "original-source",
                 "button" => 0,
                 "buttons" => 1,
                 "trusted" => true,
                 "destinationVisible" => false
               }
             ],
             "releases" => [
               %{
                 "destination" => "original-destination",
                 "button" => 0,
                 "buttons" => 0,
                 "trusted" => true
               }
             ],
             "transfers" => [["original-source", "original-destination"]],
             "output" => "original-source -> original-destination",
             "source" => "retained-source",
             "destination" => "retained-destination",
             "scrolled" => true,
             "path" => "/page"
           }

    descriptor = Enum.find(hd(requests)["tools"], &(&1["name"] == ToolName.encode(@name)))
    assert is_map(descriptor)
    parts = browser_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == @ids
    assert Enum.map(results, & &1.tool_use_id) == @ids
    assert Enum.all?(uses, &(&1.tool == @name))
    assert Enum.all?(results, &(&1.is_error == false))
    assert Enum.map(uses, & &1.input) == for(index <- 0..5, do: call_input(index, final, harness))
    assert Enum.count(uses, &(&1.input["action"] == "snapshot")) == 1

    assert Enum.at(uses, 4).input["args"]["request"] == %{
             "kind" => "drag",
             "startRef" => " \t#{page_ref(final, "Drag source")}\n",
             "endRef" => " \t#{page_ref(final, "Drag destination")}\n"
           }

    for {request, count} <- Enum.with_index(requests) do
      assert_wire_history(request, Enum.take(uses, count), Enum.take(results, count))
    end

    for result <- results do
      assert %{"version" => 1, "result" => native} = result.projection
      assert native["is_error"] == false
      assert native["structured"] == receipt(final, result.tool_use_id)
      assert Map.drop(native, ~w(content structured is_error)) == native["structured"]
      assert result.content == native["content"]
      assert Jason.decode!(result.content) == receipt(final, result.tool_use_id)
    end

    assert_part_round_trips(parts)
    assert_durable_parts(harness.session.id, uses, results)
    assert_runtime_results(harness.session.id, results)
    assert_effect_counts(harness, proof)
    {resource, broker} = browser_resource(harness.session.id)

    assert ResourceRegistry.fetch(
             resource.binding.resource_registry,
             resource.profiles["managed"].handle,
             resource.binding.owner_id
           ) == {:ok, broker}

    owned = owned_processes(broker)
    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    worker_monitor = Process.monitor(old_worker)
    broker_monitor = Process.monitor(broker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^worker_monitor, :process, ^old_worker, :shutdown}, 5_000
    assert_receive {:DOWN, ^broker_monitor, :process, ^broker, :shutdown}, 15_000
    assert_owned_exited(owned)

    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute new_worker == old_worker
    assert :ok = Worker.send_message(harness.session.id, "Recall the durable drag receipt")
    replay = receive_request(7)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(replay, uses, results)
    assert receipt(replay, "drag-action") == receipt(final, "drag-action")
    assert receipt(replay, "drag-proof")["value"] == proof
    assert browser_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)
    assert_effect_counts(harness, proof)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 8
    {_resource, replay_broker} = browser_resource(harness.session.id)
    refute replay_broker == broker
    assert :sys.get_state(replay_broker).port == nil
  end

  defp browser_harness(root) do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    Agent.update(harness.counter, &Map.merge(&1, %{page_loads: 0, drags: []}))
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
      <!doctype html><meta charset="utf-8"><title>Native retained drag</title>
      <style>
      #scroller{height:240px;width:640px;overflow:auto;scroll-behavior:auto}
      #area{height:2500px;position:relative}
      [role=button]{position:absolute;width:180px;height:60px;box-sizing:border-box;background:#ddd;user-select:none}
      [data-identity="original-source"]{left:30px;top:40px}
      [data-identity="original-destination"]{left:30px;top:2300px}
      </style>
      <div id="scroller"><div id="area">
      <div role="button" tabindex="0" id="source" data-identity="original-source">Drag source</div>
      <div role="button" tabindex="0" id="destination" data-identity="original-destination">Drag destination</div>
      </div></div><output id="result">waiting</output>
      <script>
      var sourceElement = document.getElementById('source');
      var destinationElement = document.getElementById('destination');
      var scroller = document.getElementById('scroller');
      var dragStart;
      window.effects = {presses:[],releases:[],transfers:[]};
      sourceElement.addEventListener('mousedown', function(event) {
        event.preventDefault(); dragStart = this.dataset.identity;
        var bounds = destinationElement.getBoundingClientRect();
        var viewport = scroller.getBoundingClientRect();
        effects.presses.push({source:dragStart,button:event.button,buttons:event.buttons,
          trusted:event.isTrusted,destinationVisible:bounds.top >= viewport.top && bounds.bottom <= viewport.bottom});
      });
      destinationElement.addEventListener('mouseup', function(event) {
        effects.releases.push({destination:this.dataset.identity,button:event.button,buttons:event.buttons,trusted:event.isTrusted});
        effects.transfers.push([dragStart,this.dataset.identity]);
        document.getElementById('result').textContent = dragStart + ' -> ' + this.dataset.identity;
        window.dragObserved = fetch('/drag-observed',{method:'POST',body:JSON.stringify(effects)}).then(async function(response) {
          if (response.status !== 200 || await response.text() !== 'drag accepted') throw new Error('drag observation');
        });
      });
      window.prepareDrag = function() {
        for (var element of [sourceElement,destinationElement]) {
          var id = element.id; var name = element.textContent;
          element.id = 'retained-' + id; element.textContent = 'Retained ' + id;
          var decoy = document.createElement('div');
          decoy.id = id; decoy.setAttribute('role','button'); decoy.tabIndex = 0;
          decoy.textContent = name; decoy.style.left = '440px';
          decoy.style.top = element.offsetTop + 'px';
          document.getElementById('area').appendChild(decoy);
        }
        return {source:sourceElement.id,destination:destinationElement.id};
      };
      </script>
      """)
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/drag-observed", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      Agent.update(harness.counter, &%{&1 | drags: &1.drags ++ [payload]})
      Plug.Conn.resp(conn, 200, "drag accepted")
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

      send(owner, {:browser_drag_request, index, request})

      call =
        if index < length(@ids) and successful_results?(request),
          do: {Enum.at(@ids, index), call_input(index, request, harness)}

      provider_response(conn, call)
    end)
  end

  defp call_input(0, _request, _harness), do: input("start")
  defp call_input(1, _request, harness), do: input("open", %{"targetUrl" => page_url(harness)})

  defp call_input(2, request, _harness),
    do: input("snapshot", %{"targetId" => target_id(request), "interactive" => true})

  defp call_input(3, request, _harness),
    do: act(request, %{"kind" => "evaluate", "fn" => @prepare_fn})

  defp call_input(4, request, _harness) do
    act(request, %{
      "kind" => "drag",
      "startRef" => " \t#{page_ref(request, "Drag source")}\n",
      "endRef" => " \t#{page_ref(request, "Drag destination")}\n"
    })
  end

  defp call_input(5, request, _harness),
    do: act(request, %{"kind" => "evaluate", "fn" => @proof_fn})

  defp act(request, action),
    do: input("act", %{"targetId" => target_id(request), "request" => action})

  defp input(action, args \\ %{}),
    do: %{"action" => action, "args" => args, "profile" => "managed", "timeout_ms" => 15_000}

  defp page_url(harness), do: Gaoxy.Test.url(harness.provider.fixture, "/page")
  defp target_id(request), do: receipt(request, "drag-open")["targetId"]

  defp page_ref(request, name),
    do:
      receipt(request, "drag-snapshot")["refs"]
      |> Enum.find(&(&1["role"] == "button" and &1["name"] == name))
      |> Map.fetch!("ref")

  defp assert_effect_counts(harness, proof) do
    observed = Map.take(proof, ~w(presses releases transfers))
    assert %{page_loads: 1, drags: [^observed]} = Agent.get(harness.counter, & &1)
  end

  defp blocks(request),
    do: Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

  defp successful_results?(request),
    do: Enum.all?(blocks(request), &(&1["type"] != "tool_result" or &1["is_error"] == false))

  defp receive_request(index) do
    assert_receive {:browser_drag_request, ^index, request}, 20_000

    assert successful_results?(request),
           "Browser failed before provider request #{index}: #{inspect(blocks(request))}"

    request
  end

  defp receipt(request, id) do
    result =
      Enum.find(blocks(request), &(&1["type"] == "tool_result" and &1["tool_use_id"] == id))

    result["content"]
    |> Enum.find(&(&1["type"] == "text"))
    |> Map.fetch!("text")
    |> Jason.decode!()
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

    tool_messages =
      for message <- request["messages"],
          content =
            Enum.filter(
              List.wrap(message["content"]),
              &(is_map(&1) and &1["type"] in ["tool_use", "tool_result"])
            ),
          content != [],
          do: %{"role" => message["role"], "content" => content}

    assert tool_messages ==
             Enum.flat_map(Enum.zip(uses, results), fn {use, result} ->
               [
                 %{
                   "role" => "assistant",
                   "content" => [
                     %{
                       "type" => "tool_use",
                       "id" => use.tool_use_id,
                       "name" => ToolName.encode(use.tool),
                       "input" => use.input
                     }
                   ]
                 },
                 %{
                   "role" => "user",
                   "content" => [
                     %{
                       "type" => "tool_result",
                       "tool_use_id" => result.tool_use_id,
                       "is_error" => false,
                       "content" => [
                         %{"type" => "text", "text" => result.projection["result"]["content"]}
                       ]
                     }
                   ]
                 }
               ]
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

    for {turn, index} <- Enum.with_index(turns),
        do: assert({:ok, ^turn} = Store.get_turn(id, index))

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

  defp assert_runtime_results(id, parts) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker, 1_000)
    adapter = :sys.get_state(data.runtime_pid, 1_000)
    assert {:ok, aggregate} = Synapsis.Agent.Runtime.Store.load(adapter.store, adapter.run_id)
    messages = get_in(aggregate, [:run, :context, :conversation, :messages])
    results = Enum.filter(messages, &(&1[:role] == :tool))
    assert Enum.map(results, & &1.tool_call_id) == Enum.map(parts, & &1.tool_use_id)

    for part <- parts do
      message = Enum.find(results, &(&1.tool_call_id == part.tool_use_id))
      native = message.result |> Jason.encode!() |> Jason.decode!()
      assert native == part.projection["result"]
      assert native["structured"] == Jason.decode!(native["content"])
    end
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
    owned = process_tree(helper)
    assert length(owned) > 1
    owned
  end

  defp process_tree(pid) do
    children =
      case File.read("/proc/#{pid}/task/#{pid}/children") do
        {:ok, content} -> String.split(content) |> Enum.map(&String.to_integer/1)
        {:error, :enoent} -> []
      end

    [pid | Enum.flat_map(children, &process_tree/1)]
  end

  defp assert_owned_exited(pids),
    do: await_owned_exit(pids, System.monotonic_time(:millisecond) + 15_000)

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
           %{"type" => "text_delta", "text" => "Retained drag inspected"}, "end_turn"}
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
