defmodule Synapsis.Session.NativeBrowserFillFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Codex.ResourceRegistry
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::browser"
  @ids ~w(fill-start fill-open fill-ready fill-capture fill-direct fill-nested fill-submit fill-read)

  # Post-implementation positive capability coverage only, never old-host RED.
  # Scalar and checked-state expectations are literal from reference 488631c
  # browser/form-fields.ts and pw-tools-core.interactions.actions.ts.
  test "native scalar form fill submits once and preserves raw calls across durable ordinary replay",
       %{tmp_dir: root} do
    harness = browser_harness(root)
    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Fill and submit the local Browser form")

    requests = for index <- 0..8, do: receive_request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    final = List.last(requests)
    proof = receipt(final, "fill-read")["value"]
    expected = expected_proof()
    assert_event_blocks(proof["events"], expected["events"])

    assert Map.drop(proof, ["events", "submission"]) ==
             Map.drop(expected, ["events", "submission"])

    assert proof["submission"] ==
             put_in(expected["submission"], ["payload", "events"], proof["events"])

    metadata = %{
      "generation" => receipt(final, "fill-capture")["generation"],
      "targetId" => target_id(final),
      "url" => page_url(harness)
    }

    assert receipt(final, "fill-direct") == Map.put(metadata, "ok", true)

    assert receipt(final, "fill-nested") ==
             Map.put(metadata, "results", [
               %{
                 "ok" => true,
                 "results" => [%{"ok" => true}, %{"ok" => true, "value" => "filled"}]
               }
             ])

    assert receipt(final, "fill-submit") ==
             Map.put(metadata, "results", [%{"ok" => true}, %{"ok" => true}])

    descriptor = Enum.find(hd(requests)["tools"], &(&1["name"] == ToolName.encode(@name)))
    assert is_map(descriptor)
    snapshot = receipt(final, "fill-capture")
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
    assert Enum.map(uses, & &1.input) == for(index <- 0..7, do: call_input(index, final, harness))

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

    # Independent raw ToolUse assertions: normalization must not rewrite history.
    direct =
      Enum.find(uses, &(&1.tool_use_id == "fill-direct")).input["args"]["request"]["fields"]

    assert Enum.at(direct, 0) == %{
             "ref" => " \t#{page_ref(final, "spinbutton", "Quantity")}\n",
             "type" => " number ",
             "value" => 7
           }

    assert Enum.at(direct, 1) == %{
             "ref" => page_ref(final, "textbox", "Default boolean"),
             "value" => false
           }

    assert Enum.at(direct, 2) == %{
             "ref" => page_ref(final, "textbox", "Null clear"),
             "value" => nil
           }

    assert Enum.at(direct, 3) == %{"ref" => page_ref(final, "textbox", "Missing clear")}
    assert Enum.at(direct, 5)["value"] == "  notes\nkept  "

    nested =
      Enum.find(uses, &(&1.tool_use_id == "fill-nested")).input["args"]["request"]["actions"]
      |> hd()

    fields = nested["actions"] |> hd() |> Map.fetch!("fields")
    assert Enum.at(fields, 2)["type"] == " \t"
    assert Enum.at(fields, 2)["value"] == "  padded value  "
    assert Enum.at(fields, 3)["type"] == 7
    assert Enum.at(fields, 4)["value"] == " true "

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
    before_read = receive_request(9)
    second = receive_request(10)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(before_read, uses, results)
    assert receipt(second, "fill-retained")["value"] == proof
    parts = browser_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == @ids ++ ["fill-retained"]
    assert Enum.map(results, & &1.tool_use_id) == @ids ++ ["fill-retained"]
    assert List.last(uses).input == call_input(7, final, harness)
    assert_wire_history(second, uses, results)
    retained = List.last(results)
    assert retained.is_error == false
    assert retained.projection["result"]["structured"] == receipt(second, "fill-retained")
    assert Jason.decode!(retained.content) == receipt(second, "fill-retained")
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

    replay = receive_request(11)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(replay, uses, results)
    assert browser_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)
    assert_effect_counts(harness, proof)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 12
    {_resource, replay_broker} = browser_resource(harness.session.id)
    refute replay_broker == broker
    assert :sys.get_state(replay_broker).port == nil
    replay_monitor = Process.monitor(new_worker)
    replay_broker_monitor = Process.monitor(replay_broker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^replay_monitor, :process, ^new_worker, :shutdown}, 5_000
    assert_receive {:DOWN, ^replay_broker_monitor, :process, ^replay_broker, :shutdown}, 15_000
  end

  # The pin specifies ordered writes; Chromium owns input-event multiplicity.
  # Preserve the complete raw ledger and require every event to belong to the
  # next nonempty contiguous block with its literal source-derived value.
  defp assert_event_blocks(actual, expected) do
    blocks = Enum.chunk_by(actual, fn [id, _value] -> id end)
    assert Enum.map(blocks, &hd/1) == expected

    for {block, expected_event} <- Enum.zip(blocks, expected) do
      for event <- block, do: assert(event == expected_event)
      if hd(expected_event) == "after", do: assert(length(block) == 1)
    end
  end

  defp expected_proof do
    values = %{
      "quantity" => "7",
      "default-boolean" => "false",
      "null-clear" => "",
      "missing-clear" => "",
      "email" => "ada@example.test",
      "notes" => "  notes\nkept  ",
      "case-sensitive" => "false",
      "true-text" => "true",
      "numeric-text" => "12",
      "blank-type" => "  padded value  ",
      "nonstring-type" => "true"
    }

    events = [
      ["quantity", "7"],
      ["default-boolean", "false"],
      ["null-clear", ""],
      ["missing-clear", ""],
      ["email", "ada@example.test"],
      ["notes", "  notes\nkept  "],
      ["case-sensitive", "false"],
      ["checked", true],
      ["radio-new", true],
      ["true-text", "true"],
      ["numeric-text", "12"],
      ["blank-type", "  padded value  "],
      ["nonstring-type", "true"],
      ["checked", false],
      ["after", "filled"]
    ]

    payload = %{"fields" => Map.put(values, "choice", "new"), "events" => events}

    %{
      "values" => values,
      "events" => events,
      "checkbox" => false,
      "radios" => [false, true],
      "submission" => %{"status" => 200, "body" => "accepted", "payload" => payload},
      "path" => "/page"
    }
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
      <!doctype html><title>Native form fill</title><form>
      <label>Quantity<input id="quantity" name="quantity" type="number" value="3"></label>
      <label>Default boolean<input id="default-boolean" name="default-boolean" value="seed"></label>
      <label>Null clear<input id="null-clear" name="null-clear" value="seed"></label>
      <label>Missing clear<input id="missing-clear" name="missing-clear" value="seed"></label>
      <label>Email<input id="email" name="email" type="email" value="seed@example.test"></label>
      <label>Notes<textarea id="notes" name="notes">seed</textarea></label>
      <label>Case sensitive<input id="case-sensitive" name="case-sensitive" value="seed"></label>
      <label>True text<input id="true-text" name="true-text" value="seed"></label>
      <label>Numeric text<input id="numeric-text" name="numeric-text" value="seed"></label>
      <label>Blank type<input id="blank-type" name="blank-type" value="seed"></label>
      <label>Nonstring type<input id="nonstring-type" name="nonstring-type" value="seed"></label>
      <label>Checked<input id="checked" name="checked" type="checkbox"></label>
      <label>Radio previous<input id="radio-old" type="radio" name="choice" value="old" checked></label>
      <label>Radio chosen<input id="radio-new" type="radio" name="choice" value="new"></label>
      <button type="submit">Submit form</button></form><script>
      window.events = [];
      document.addEventListener('input', event => {
        const el = event.target;
        window.events.push([el.id, el.type === 'checkbox' || el.type === 'radio' ? el.checked : el.value]);
      });
      document.querySelector('form').onsubmit = async event => {
        event.preventDefault();
        const payload = {fields: Object.fromEntries(new FormData(event.target)), events: window.events};
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

      send(owner, {:browser_fill_request, index, request})

      call =
        cond do
          index < length(@ids) and successful_results?(request) ->
            {Enum.at(@ids, index), call_input(index, request, harness)}

          index == 9 and successful_results?(request) ->
            {"fill-retained", call_input(7, request, harness)}

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
      "kind" => "fill",
      "fields" => [
        %{
          "ref" => " \t#{page_ref(request, "spinbutton", "Quantity")}\n",
          "type" => " number ",
          "value" => 7
        },
        %{"ref" => page_ref(request, "textbox", "Default boolean"), "value" => false},
        %{"ref" => page_ref(request, "textbox", "Null clear"), "value" => nil},
        %{"ref" => page_ref(request, "textbox", "Missing clear")},
        %{
          "ref" => page_ref(request, "textbox", "Email"),
          "type" => "email",
          "value" => "ada@example.test"
        },
        %{
          "ref" => page_ref(request, "textbox", "Notes"),
          "type" => " textarea ",
          "value" => "  notes\nkept  "
        },
        %{
          "ref" => page_ref(request, "textbox", "Case sensitive"),
          "type" => "Checkbox",
          "value" => false
        },
        %{
          "ref" => page_ref(request, "checkbox", "Checked"),
          "type" => " checkbox ",
          "value" => 1
        },
        %{
          "ref" => " #{page_ref(request, "radio", "Radio chosen")} ",
          "type" => " radio ",
          "value" => "true"
        }
      ]
    })
  end

  defp call_input(5, request, _harness) do
    act(
      request,
      batch([
        batch([
          %{
            "kind" => "fill",
            "fields" => [
              %{
                "ref" => page_ref(request, "textbox", "True text"),
                "type" => " text ",
                "value" => true
              },
              %{"ref" => page_ref(request, "textbox", "Numeric text"), "value" => 12},
              %{
                "ref" => page_ref(request, "textbox", "Blank type"),
                "type" => " \t",
                "value" => "  padded value  "
              },
              %{
                "ref" => page_ref(request, "textbox", "Nonstring type"),
                "type" => 7,
                "value" => true
              },
              %{
                "ref" => page_ref(request, "checkbox", "Checked"),
                "type" => "checkbox",
                "value" => " true "
              }
            ]
          },
          %{
            "kind" => "evaluate",
            "fn" => "() => { window.events.push(['after','filled']); return 'filled'; }"
          }
        ])
      ])
    )
  end

  defp call_input(6, request, _harness) do
    act(
      request,
      batch([
        %{"kind" => "click", "ref" => page_ref(request, "button", "Submit form")},
        %{"kind" => "wait", "fn" => "() => Boolean(window.submission)"}
      ])
    )
  end

  defp call_input(7, request, _harness) do
    act(request, %{
      "kind" => "evaluate",
      "fn" => """
      () => ({values:Object.fromEntries([...document.querySelectorAll('input:not([type=checkbox]):not([type=radio]),textarea')].map(el => [el.id,el.value])),
        events:window.events,checkbox:document.querySelector('#checked').checked,
        radios:[...document.querySelectorAll('input[type=radio]')].map(el => el.checked),
        submission:window.submission,path:location.pathname})
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
      receipt(request, "fill-capture")["refs"]
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
    assert_receive {:browser_fill_request, ^index, request}, 20_000

    assert successful_results?(request),
           "Browser failed before provider request #{index}: #{inspect(blocks(request))}"

    request
  end

  defp target_id(request), do: receipt(request, "fill-open")["targetId"]

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
           %{"type" => "text_delta", "text" => "Browser form fill inspected"}, "end_turn"}
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
