defmodule Synapsis.Session.NativeBrowserAriaFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::browser"
  @ids ~w(aria-start aria-open aria-ready aria-ai aria-ai-act aria-raw aria-raw-act aria-read)

  test "page-wide AI and native AX refs reach provider history, persistence and Worker replay", %{
    tmp_dir: root
  } do
    harness = browser_harness(root)
    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok =
             Worker.send_message(harness.session.id, "Use the local AI and raw ARIA snapshots")

    requests = for index <- 0..8, do: receive_request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    final = List.last(requests)
    target = target_id(final)
    ai = receipt(final, "aria-ai")
    raw = receipt(final, "aria-raw")
    assert_ai_snapshot(ai, target)
    assert_raw_snapshot(raw, target)
    assert raw["documentGeneration"] == ai["documentGeneration"]
    assert raw["snapshotGeneration"] > ai["snapshotGeneration"]

    ai_numbers = Enum.map(ai["refs"], &ref_number(&1["ref"]))
    raw_numbers = Enum.map(raw["nodes"], &ref_number(&1["ref"]))
    assert Enum.uniq(ai_numbers ++ raw_numbers) == ai_numbers ++ raw_numbers
    assert Enum.min(raw_numbers) > Enum.max(ai_numbers)

    for id <- ["aria-ai-act", "aria-raw-act"] do
      assert %{"results" => [%{"ok" => true}, %{"ok" => true}]} = receipt(final, id)
    end

    assert receipt(final, "aria-read")["value"] == %{
             "account" => "raw account",
             "mainText" => "Main finished",
             "mainClicks" => 1,
             "frameText" => "Frame finished",
             "frameValue" => "native frame value"
           }

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
      assert %{"version" => 1, "result" => %{"content" => content}} = result.projection
      assert result.content == content
      assert Jason.decode!(content) == receipt(final, result.tool_use_id)
    end

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
    assert :ok = Worker.send_message(harness.session.id, "Recall the completed ARIA actions")
    replay = receive_request(9)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(replay, uses, results)
    assert browser_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)
    assert_effect_counts(harness)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 10
    {_resource, replay_broker} = browser_resource(harness.session.id)
    refute replay_broker == broker
    assert :sys.get_state(replay_broker).port == nil
  end

  defp assert_ai_snapshot(snapshot, target) do
    assert %{
             "targetId" => ^target,
             "format" => "ai",
             "refsType" => "aria",
             "truncated" => false
           } = snapshot

    assert snapshot["refCount"] == length(snapshot["refs"])
    assert is_integer(snapshot["documentGeneration"])
    assert is_integer(snapshot["snapshotGeneration"])
    assert is_binary(snapshot["semantics"])
    assert snapshot["snapshot"] =~ "initial account"
    assert snapshot["snapshot"] =~ ~r/^\s+- \/placeholder: Local account$/m
    assert snapshot["snapshot"] =~ ~r/^\s+- \/url: \/guide$/m

    for {role, name} <- [
          {"textbox", "Account"},
          {"textbox", "Frame value"},
          {"button", "Main action"},
          {"button", "Frame action"}
        ] do
      assert Enum.any?(snapshot["refs"], &(&1["role"] == role and &1["name"] == name))
    end

    for ref <- snapshot["refs"] do
      assert Enum.sort(Map.keys(ref)) == ~w(name ref role)
      assert ref["ref"] =~ ~r/^e\d+$/
      assert snapshot["snapshot"] =~ "[ref=#{ref["ref"]}]"
    end
  end

  defp assert_raw_snapshot(snapshot, target) do
    assert %{
             "targetId" => ^target,
             "format" => "aria",
             "refsType" => "ax",
             "truncated" => false
           } = snapshot

    assert snapshot["nodeCount"] == length(snapshot["nodes"])
    assert snapshot["refCount"] == length(snapshot["refs"])
    assert snapshot["nodeCount"] > snapshot["refCount"]
    assert String.downcase(snapshot["semantics"]) =~ "native"

    assert %{
             "role" => "RootWebArea",
             "name" => "Native ARIA source",
             "depth" => 0,
             "actionable" => false
           } = hd(snapshot["nodes"])

    assert Enum.any?(snapshot["nodes"], fn node ->
             node["role"] == "StaticText" and node["name"] == "Account hint" and
               node["actionable"] == false and node["depth"] > 0
           end)

    assert Enum.any?(snapshot["nodes"], fn node ->
             node["role"] == "textbox" and node["name"] == "Account" and
               node["value"] == "native account" and node["description"] == "Account hint" and
               node["actionable"] == true and is_integer(node["backendDOMNodeId"])
           end)

    for node <- snapshot["nodes"] do
      assert node["ref"] =~ ~r/^ax\d+$/
      assert is_integer(node["depth"])
      assert is_boolean(node["actionable"])
      assert is_binary(node["role"])
      assert is_binary(node["name"])
    end

    assert snapshot["refs"] ==
             for(
               node <- snapshot["nodes"],
               node["actionable"],
               do: %{
                 "ref" => node["ref"],
                 "role" => String.downcase(node["role"]),
                 "name" => node["name"]
               }
             )
  end

  defp ref_number("e" <> number), do: String.to_integer(number)
  defp ref_number("ax" <> number), do: String.to_integer(number)

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
      &Map.merge(&1, %{page_loads: 0, frame_loads: 0, frame_effects: 0})
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

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/page", fn conn ->
      Agent.update(harness.counter, &%{&1 | page_loads: &1.page_loads + 1})

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, """
      <!doctype html><html><head><title>Native ARIA source</title></head><body>
      <h1>Ordinary ARIA source</h1><p id="account-hint">Account hint</p>
      <input id="account" aria-label="Account" aria-describedby="account-hint"
        placeholder="Local account" value="initial account">
      <a href="/guide">Local guide</a>
      <button id="main-action" onclick="this.textContent='Main finished'; window.mainClicks=(window.mainClicks || 0)+1">Main action</button>
      <iframe id="panel" title="ARIA panel" src="/frame"></iframe>
      </body></html>
      """)
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/frame", fn conn ->
      Agent.update(harness.counter, &%{&1 | frame_loads: &1.frame_loads + 1})

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, """
      <!doctype html><html><body>
      <input id="frame-value" aria-label="Frame value" value="initial frame value">
      <button id="frame-action" onclick="this.textContent='Frame finished'; window.frameEffect=fetch('/frame-effect', {method:'POST'})">Frame action</button>
      </body></html>
      """)
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/frame-effect", fn conn ->
      Agent.update(harness.counter, &%{&1 | frame_effects: &1.frame_effects + 1})
      Plug.Conn.resp(conn, 200, "frame effect recorded")
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

      send(owner, {:browser_aria_request, index, request})

      call =
        if index < length(@ids) and successful_results?(request),
          do: {Enum.at(@ids, index), call_input(index, request, harness)}

      provider_response(conn, call)
    end)
  end

  defp call_input(0, _request, _harness), do: input("start")

  defp call_input(1, _request, harness),
    do: input("open", %{"targetUrl" => Gaoxy.Test.url(harness.provider.fixture, "/page")})

  defp call_input(2, request, _harness),
    do: act(request, %{"kind" => "wait", "loadState" => "load"})

  defp call_input(3, request, _harness),
    do:
      input("snapshot", %{
        "targetId" => target_id(request),
        "snapshotFormat" => "ai",
        "refs" => "aria"
      })

  defp call_input(4, request, _harness) do
    act(request, %{
      "kind" => "batch",
      "actions" => [
        %{
          "kind" => "fill",
          "fields" => [
            %{
              "ref" => snapshot_ref(request, "aria-ai", "textbox", "Account"),
              "value" => "native account"
            },
            %{
              "ref" => snapshot_ref(request, "aria-ai", "textbox", "Frame value"),
              "value" => "native frame value"
            }
          ]
        },
        %{"kind" => "click", "ref" => snapshot_ref(request, "aria-ai", "button", "Frame action")}
      ]
    })
  end

  defp call_input(5, request, _harness),
    do: input("snapshot", %{"targetId" => target_id(request), "snapshotFormat" => "aria"})

  defp call_input(6, request, _harness) do
    act(request, %{
      "kind" => "batch",
      "actions" => [
        %{
          "kind" => "fill",
          "fields" => [
            %{
              "ref" => snapshot_ref(request, "aria-raw", "textbox", "Account"),
              "value" => "raw account"
            }
          ]
        },
        %{"kind" => "click", "ref" => snapshot_ref(request, "aria-raw", "button", "Main action")}
      ]
    })
  end

  defp call_input(7, request, _harness) do
    act(request, %{
      "kind" => "evaluate",
      "ref" => snapshot_ref(request, "aria-raw", "button", "Main action"),
      "fn" => """
      async element => {
        const frame = document.querySelector('#panel');
        await frame.contentWindow.frameEffect;
        return {account: document.querySelector('#account').value,
          mainText: element.textContent, mainClicks: window.mainClicks,
          frameText: frame.contentDocument.querySelector('#frame-action').textContent,
          frameValue: frame.contentDocument.querySelector('#frame-value').value};
      }
      """
    })
  end

  defp snapshot_ref(request, id, role, name) do
    receipt(request, id)["refs"]
    |> Enum.find(&(&1["role"] == role and &1["name"] == name))
    |> Map.fetch!("ref")
  end

  defp act(request, action),
    do: input("act", %{"targetId" => target_id(request), "request" => action})

  defp input(action, args \\ %{}),
    do: %{"action" => action, "args" => args, "profile" => "managed", "timeout_ms" => 15_000}

  defp assert_effect_counts(harness) do
    assert %{page_loads: 1, frame_loads: 1, frame_effects: 1} = Agent.get(harness.counter, & &1)
  end

  defp blocks(request),
    do: Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

  defp successful_results?(request),
    do: Enum.all?(blocks(request), &(&1["type"] != "tool_result" or &1["is_error"] == false))

  defp receive_request(index) do
    assert_receive {:browser_aria_request, ^index, request}, 20_000

    assert successful_results?(request),
           "Browser failed before provider request #{index}: #{inspect(blocks(request))}"

    request
  end

  defp target_id(request), do: receipt(request, "aria-open")["targetId"]

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
           %{"type" => "text_delta", "text" => "Native Browser ARIA inspected"}, "end_turn"}
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
