defmodule Synapsis.Session.NativeBrowserSelectFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.ResourceRegistry
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::browser"
  @ids ~w(select-start select-open select-ready select-capture select-direct select-nested select-local select-submit select-read)

  # Post-implementation positive capability coverage only, never old-host RED.
  # Literal ref/value expectations come from reference 488631c
  # routes/agent.act.normalize.ts:239-247 and
  # pw-tools-core.interactions.actions.ts:91-101,158-166.
  test "native select trims current refs and preserves option content across durable ordinary replay",
       %{tmp_dir: root} do
    harness = browser_harness(root)
    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok =
             Worker.send_message(harness.session.id, "Select and submit the local Browser form")

    requests = for index <- 0..9, do: receive_request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    final = List.last(requests)
    proof = receipt(final, "select-read")["value"]

    assert Map.drop(proof, ["events", "submission"]) == %{
             "selections" => %{
               "single" => [" padded "],
               "multi" => ["", " padded "],
               "decoy" => ["seed"],
               "local" => [""]
             },
             "path" => "/page"
           }

    assert_select_events(proof["events"], [
      ["single", [" padded "]],
      ["multi", ["", " padded "]],
      ["local", [""]]
    ])

    assert proof["submission"] == %{
             "status" => 200,
             "body" => "accepted",
             "payload" => %{
               "fields" => [
                 ["single", " padded "],
                 ["multi", ""],
                 ["multi", " padded "],
                 ["decoy", "seed"],
                 ["local", ""]
               ],
               "events" => proof["events"]
             }
           }

    metadata = %{
      "generation" => receipt(final, "select-capture")["generation"],
      "targetId" => target_id(final),
      "url" => page_url(harness)
    }

    assert receipt(final, "select-direct") == Map.put(metadata, "ok", true)
    assert receipt(final, "select-local") == Map.put(metadata, "ok", true)

    assert receipt(final, "select-nested") ==
             Map.put(metadata, "results", [
               %{
                 "ok" => true,
                 "results" => [%{"ok" => true}, %{"ok" => true, "value" => "selected"}]
               }
             ])

    assert receipt(final, "select-submit") ==
             Map.put(metadata, "results", [%{"ok" => true}, %{"ok" => true}])

    descriptor = Enum.find(hd(requests)["tools"], &(&1["name"] == ToolName.encode(@name)))
    assert is_map(descriptor)
    snapshot = receipt(final, "select-capture")
    assert snapshot["refsType"] == "aria"
    assert snapshot["truncated"] == false
    assert snapshot["refCount"] == length(snapshot["refs"])

    parts = browser_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == @ids
    assert Enum.map(results, & &1.tool_use_id) == @ids
    assert Enum.all?(uses, &(&1.tool == @name))
    assert Enum.all?(results, &(&1.is_error == false))
    assert Enum.map(uses, & &1.input) == for(index <- 0..8, do: call_input(index, final, harness))

    for {request, count} <- Enum.with_index(requests) do
      assert_wire_history(request, Enum.take(uses, count), Enum.take(results, count))
    end

    for result <- results do
      assert %{"version" => 1, "result" => native} = result.projection
      assert native["is_error"] == false
      assert native["structured"] == receipt(final, result.tool_use_id)
      assert Map.drop(native, ["content", "structured", "is_error"]) == native["structured"]
      assert result.content == native["content"]
      assert Jason.decode!(native["content"]) == receipt(final, result.tool_use_id)
    end

    # The private helper normalization must never rewrite raw ToolUse/history.
    direct = Enum.find(uses, &(&1.tool_use_id == "select-direct")).input["args"]["request"]

    assert direct == %{
             "kind" => "select",
             "ref" => " \t#{page_ref(final, "combobox", "Single choice")}\n",
             "selector" => "#decoy",
             "values" => [" padded "]
           }

    nested = Enum.find(uses, &(&1.tool_use_id == "select-nested")).input["args"]["request"]

    assert nested == %{
             "kind" => "batch",
             "actions" => [
               %{
                 "kind" => "batch",
                 "actions" => [
                   %{
                     "kind" => "select",
                     "ref" => " \t#{page_ref(final, "listbox", "Many choices")}\n",
                     "values" => [" padded ", ""]
                   },
                   %{"kind" => "evaluate", "fn" => "() => 'selected'"}
                 ]
               }
             ]
           }

    assert Enum.find(uses, &(&1.tool_use_id == "select-local")).input["args"]["request"] == %{
             "kind" => "select",
             "selector" => "#local",
             "values" => [""]
           }

    assert_part_round_trips(parts)
    assert_durable_parts(harness.session.id, uses, results)
    assert_runtime_results(harness.session.id, results)
    assert_effect_counts(harness, proof)
    {resource, broker} = browser_resource(harness.session.id)
    owned = owned_processes(broker)
    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    assert is_pid(resource.binding.owner_pid)
    assert Process.alive?(resource.binding.owner_pid)

    assert ResourceRegistry.fetch(
             resource.binding.resource_registry,
             resource.profiles["managed"].handle,
             resource.binding.owner_id
           ) == {:ok, broker}

    # A normal next turn reads the retained form through the same native owner.
    assert :ok = Worker.send_message(harness.session.id, "Read the retained submitted form")
    before_read = receive_request(10)
    second = receive_request(11)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(before_read, uses, results)
    assert receipt(second, "select-retained")["value"] == proof
    parts = browser_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == @ids ++ ["select-retained"]
    assert Enum.map(results, & &1.tool_use_id) == @ids ++ ["select-retained"]
    assert List.last(uses).input == call_input(8, final, harness)
    assert_wire_history(second, uses, results)
    retained = List.last(results)
    assert retained.is_error == false
    assert retained.projection["result"]["structured"] == receipt(second, "select-retained")
    assert Jason.decode!(retained.content) == receipt(second, "select-retained")
    assert_part_round_trips(parts)
    assert_runtime_results(harness.session.id, results)
    {continued_resource, continued_broker} = browser_resource(harness.session.id)
    assert continued_broker == broker
    assert continued_resource.profiles == resource.profiles

    assert Map.take(continued_resource.binding, [
             :owner_id,
             :owner_pid,
             :incarnation,
             :session,
             :resource_registry
           ]) ==
             Map.take(resource.binding, [
               :owner_id,
               :owner_pid,
               :incarnation,
               :session,
               :resource_registry
             ])

    refute continued_resource.binding.run_id == resource.binding.run_id

    assert ResourceRegistry.fetch(
             continued_resource.binding.resource_registry,
             continued_resource.profiles["managed"].handle,
             continued_resource.binding.owner_id
           ) == {:ok, broker}

    assert [{^old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    assert_effect_counts(harness, proof)
    assert_durable_parts(harness.session.id, uses, results)

    monitor = Process.monitor(old_worker)
    broker_monitor = Process.monitor(broker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, :shutdown}, 5_000
    assert_receive {:DOWN, ^broker_monitor, :process, ^broker, :shutdown}, 15_000
    assert_owned_exited(owned)

    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute new_worker == old_worker

    assert :ok =
             Worker.send_message(harness.session.id, "Recall the durable Browser form submission")

    replay = receive_request(12)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(replay, uses, results)
    assert browser_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)
    assert_effect_counts(harness, proof)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 13
    {_resource, replay_broker} = browser_resource(harness.session.id)
    refute replay_broker == broker
    assert :sys.get_state(replay_broker).port == nil
    replay_monitor = Process.monitor(new_worker)
    replay_broker_monitor = Process.monitor(replay_broker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^replay_monitor, :process, ^new_worker, :shutdown}, 5_000
    assert_receive {:DOWN, ^replay_broker_monitor, :process, ^replay_broker, :shutdown}, 15_000
  end

  # Keep every raw input/change event and require ordered nonempty control
  # blocks, without assuming browser-specific native event multiplicity.
  defp assert_select_events(actual, expected) do
    blocks = Enum.chunk_by(actual, fn [_type, id, _values] -> id end)
    assert Enum.map(blocks, fn [[_type, id, values] | _] -> [id, values] end) == expected

    for {block, expected_selection} <- Enum.zip(blocks, expected) do
      assert block |> Enum.map(&hd/1) |> Enum.uniq() |> Enum.sort() == ["change", "input"]

      for [type, id, values] <- block do
        assert type in ["input", "change"]
        assert [id, values] == expected_selection
      end
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
    Agent.update(harness.counter, &Map.merge(&1, %{page_loads: 0, submissions: []}))
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
             Synapsis.AgentConfigs.update(
               harness.agent_config,
               %{tools: [@name], config: Map.put(harness.agent_config.config, "browser", browser)}
             )

    assert :ok =
             Synapsis.Provider.Registry.register(
               harness.provider.name,
               %{type: "anthropic", base_url: harness.provider.base_url, api_key: "test-key"}
             )

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/page", fn conn ->
      Agent.update(harness.counter, &%{&1 | page_loads: &1.page_loads + 1})

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, """
      <!doctype html><title>Native select</title><form>
      <label>Single choice<select id="single" name="single"><option value="seed" selected>Seed</option><option value="">Empty</option><option value=" padded ">Padded</option><option value="padded">Unpadded</option></select></label>
      <label>Many choices<select id="multi" name="multi" multiple size="4"><option value="seed" selected>Seed</option><option value="">Empty</option><option value=" padded ">Padded</option><option value="padded">Unpadded</option></select></label>
      <label>Decoy choice<select id="decoy" name="decoy"><option value="seed" selected>Seed</option><option value="">Empty</option><option value=" padded ">Padded</option><option value="padded">Unpadded</option></select></label>
      <label>Local choice<select id="local" name="local"><option value="seed" selected>Seed</option><option value="">Empty</option><option value=" padded ">Padded</option><option value="padded">Unpadded</option></select></label>
      <button type="submit">Submit form</button></form><script>
      window.events = [];
      for (const type of ['input', 'change']) document.addEventListener(type, event => {
        const el = event.target;
        if (el.tagName === 'SELECT') window.events.push([event.type, el.id, [...el.selectedOptions].map(option => option.value)]);
      });
      document.querySelector('form').onsubmit = async event => {
        event.preventDefault();
        const payload = {fields: [...new FormData(event.target)], events: window.events};
        const response = await fetch('/submit', {method:'POST', body:JSON.stringify(payload)});
        window.submission = {status:response.status, body:await response.text(), payload};
      };
      </script>
      """)
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/submit", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      Agent.update(harness.counter, &%{&1 | submissions: &1.submissions ++ [payload]})
      Plug.Conn.resp(conn, 200, "accepted")
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

      send(owner, {:browser_select_request, index, request})

      call =
        cond do
          index < length(@ids) and successful_results?(request) ->
            {Enum.at(@ids, index), call_input(index, request, harness)}

          index == 10 and successful_results?(request) ->
            {"select-retained", call_input(8, request, harness)}

          true ->
            nil
        end

      provider_response(conn, call)
    end)
  end

  defp call_input(0, _request, _harness), do: input("start")
  defp call_input(1, _request, harness), do: input("open", %{"targetUrl" => page_url(harness)})

  defp call_input(2, request, _harness),
    do: act(request, %{"kind" => "wait", "loadState" => "load"})

  defp call_input(3, request, _harness),
    do: input("snapshot", %{"targetId" => target_id(request)})

  defp call_input(4, request, _harness) do
    act(request, %{
      "kind" => "select",
      "ref" => " \t#{page_ref(request, "combobox", "Single choice")}\n",
      "selector" => "#decoy",
      "values" => [" padded "]
    })
  end

  defp call_input(5, request, _harness) do
    act(
      request,
      batch([
        batch([
          %{
            "kind" => "select",
            "ref" => " \t#{page_ref(request, "listbox", "Many choices")}\n",
            "values" => [" padded ", ""]
          },
          %{"kind" => "evaluate", "fn" => "() => 'selected'"}
        ])
      ])
    )
  end

  defp call_input(6, request, _harness) do
    act(request, %{"kind" => "select", "selector" => "#local", "values" => [""]})
  end

  defp call_input(7, request, _harness) do
    act(
      request,
      batch([
        %{"kind" => "click", "ref" => page_ref(request, "button", "Submit form")},
        %{"kind" => "wait", "fn" => "() => Boolean(window.submission)"}
      ])
    )
  end

  defp call_input(8, request, _harness) do
    act(request, %{
      "kind" => "evaluate",
      "fn" => """
      () => ({selections:Object.fromEntries([...document.querySelectorAll('select')].map(el => [el.id,[...el.selectedOptions].map(option => option.value)])),
        events:window.events,submission:window.submission,path:location.pathname})
      """
    })
  end

  defp batch(actions), do: %{"kind" => "batch", "actions" => actions}

  defp act(request, action),
    do: input("act", %{"targetId" => target_id(request), "request" => action})

  defp input(action, args \\ %{}),
    do: %{"action" => action, "args" => args, "profile" => "managed", "timeout_ms" => 15_000}

  defp page_url(harness), do: Gaoxy.Test.url(harness.provider.fixture, "/page")

  defp page_ref(request, role, name),
    do:
      receipt(request, "select-capture")["refs"]
      |> Enum.find(&(&1["role"] == role and &1["name"] == name))
      |> Map.fetch!("ref")

  defp assert_effect_counts(harness, proof) do
    assert %{page_loads: 1, submissions: [submission]} = Agent.get(harness.counter, & &1)
    assert submission == proof["submission"]["payload"]
  end

  defp blocks(request),
    do: Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

  defp successful_results?(request),
    do: Enum.all?(blocks(request), &(&1["type"] != "tool_result" or &1["is_error"] == false))

  defp receive_request(index) do
    assert_receive {:browser_select_request, ^index, request}, 20_000

    assert successful_results?(request),
           "Browser failed before provider request #{index}: #{inspect(blocks(request))}"

    request
  end

  defp target_id(request), do: receipt(request, "select-open")["targetId"]

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
           %{"type" => "text_delta", "text" => "Browser selections inspected"}, "end_turn"}
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
