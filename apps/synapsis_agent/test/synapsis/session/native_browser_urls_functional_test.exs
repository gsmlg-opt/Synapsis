defmodule Synapsis.Session.NativeBrowserUrlsFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::browser"
  @ids ~w(urls-start urls-open urls-ready urls-main urls-main-act urls-frame urls-ai urls-read)

  test "document URL appendices reach native provider history, persistence and Worker replay", %{
    tmp_dir: root
  } do
    harness = browser_harness(root)
    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok =
             Worker.send_message(harness.session.id, "Inspect the local document URL appendices")

    requests = for index <- 0..8, do: receive_request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    final = List.last(requests)
    target = target_id(final)
    main = receipt(final, "urls-main")
    frame = receipt(final, "urls-frame")
    ai = receipt(final, "urls-ai")

    for {snapshot, refs_type} <- [{main, "role"}, {frame, "role"}, {ai, "aria"}] do
      assert_snapshot(snapshot, target, refs_type)
    end

    inside_url = Gaoxy.Test.url(harness.provider.fixture, "/inside-docs")
    outside_url = Gaoxy.Test.url(harness.provider.fixture, "/outside-docs")
    frame_url = Gaoxy.Test.url(harness.provider.fixture, "/frame-docs")
    main_links = "1. Inside docs -> #{inside_url}\n2. Outside docs -> #{outside_url}"
    assert appendix(main) == main_links
    assert appendix(ai) == main_links
    assert appendix(frame) == "1. Frame docs -> #{frame_url}"

    # The small role root owns its body refs; URL collection uses its document.
    assert Enum.map(main["refs"], &Map.take(&1, ~w(role name))) == [
             %{"role" => "button", "name" => "Main action"},
             %{"role" => "link", "name" => "Inside docs"}
           ]

    refute body(main) =~ "Outside docs"

    assert Enum.map(frame["refs"], &Map.take(&1, ~w(role name))) == [
             %{"role" => "button", "name" => "Frame action"}
           ]

    refute body(frame) =~ "Frame docs"
    assert body(ai) =~ "Frame docs"
    assert body(ai) =~ ~r/^\s+- \/url: \/frame-docs$/m
    assert Enum.any?(ai["refs"], &(&1["role"] == "button" and &1["name"] == "Frame action"))
    assert receipt(final, "urls-main-act")["ok"] == true

    assert %{
             "results" => [
               %{"ok" => true},
               %{
                 "ok" => true,
                 "value" => %{
                   "mainText" => "Main finished",
                   "mainClicks" => 1,
                   "frameText" => "Frame finished",
                   "frameClicks" => 1
                 }
               }
             ]
           } = receipt(final, "urls-read")

    assert frame["snapshotGeneration"] > main["snapshotGeneration"]
    assert ai["snapshotGeneration"] > frame["snapshotGeneration"]
    assert Enum.uniq(Enum.map([main, frame, ai], & &1["documentGeneration"])) |> length() == 1

    all_refs = for snapshot <- [main, frame, ai], ref <- snapshot["refs"], do: ref["ref"]
    assert Enum.uniq(all_refs) == all_refs
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
    assert :ok = Worker.send_message(harness.session.id, "Recall the document URL snapshots")
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

  defp assert_snapshot(snapshot, target, refs_type) do
    assert %{
             "targetId" => ^target,
             "format" => "ai",
             "refsType" => ^refs_type,
             "truncated" => false
           } = snapshot

    assert is_integer(snapshot["documentGeneration"])
    assert is_integer(snapshot["snapshotGeneration"])
    assert is_binary(snapshot["semantics"])
    assert snapshot["refCount"] == length(snapshot["refs"])
    assert String.length(snapshot["snapshot"]) <= 40_000
    assert byte_size(snapshot["snapshot"]) <= 262_144

    assert Regex.scan(~r/\[ref=(e\d+)\]/, snapshot["snapshot"], capture: :all_but_first)
           |> List.flatten() == Enum.map(snapshot["refs"], & &1["ref"])

    for ref <- snapshot["refs"] do
      assert Enum.sort(Map.keys(ref)) == ~w(name ref role)
    end
  end

  defp body(snapshot), do: snapshot["snapshot"] |> String.split("\n\nLinks:\n") |> hd()

  defp appendix(snapshot) do
    assert [_body, links] = String.split(snapshot["snapshot"], "\n\nLinks:\n")
    links
  end

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
      &Map.merge(&1, %{page_loads: 0, frame_loads: 0, main_effects: 0, frame_effects: 0})
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
      <!doctype html><html><head><title>Native URL source</title></head><body>
      <section id="scope">
      <button id="main-action" onclick="this.textContent='Main finished'; window.mainClicks=(window.mainClicks||0)+1; window.mainEffect=fetch('/main-effect',{method:'POST'})">Main action</button>
      <a href="/inside-docs">Inside docs</a>
      </section>
      <a href="/outside-docs"> Outside   docs </a><a href="/outside-docs">Duplicate label</a>
      <iframe id="panel" title="URL panel" src="/frame"></iframe>
      </body></html>
      """)
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/frame", fn conn ->
      Agent.update(harness.counter, &%{&1 | frame_loads: &1.frame_loads + 1})

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, """
      <!doctype html><html><body><section id="scope">
      <button id="frame-action" onclick="this.textContent='Frame finished'; window.frameClicks=(window.frameClicks||0)+1; window.frameEffect=fetch('/frame-effect',{method:'POST'})">Frame action</button>
      </section><a href="/frame-docs">Frame docs</a></body></html>
      """)
    end)

    for {path, field} <- [{"/main-effect", :main_effects}, {"/frame-effect", :frame_effects}] do
      Gaoxy.Test.stub(harness.provider.fixture, "POST", path, fn conn ->
        Agent.update(harness.counter, &Map.update!(&1, field, fn count -> count + 1 end))
        Plug.Conn.resp(conn, 200, "effect recorded")
      end)
    end

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

      send(owner, {:browser_urls_request, index, request})

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
        "selector" => "#scope",
        "interactive" => true,
        "urls" => true
      })

  defp call_input(4, request, _harness),
    do:
      act(request, %{
        "kind" => "click",
        "ref" => snapshot_ref(request, "urls-main", "button", "Main action")
      })

  defp call_input(5, request, _harness),
    do:
      input("snapshot", %{
        "targetId" => target_id(request),
        "frame" => "#panel",
        "selector" => "#scope",
        "interactive" => true,
        "urls" => true
      })

  defp call_input(6, request, _harness),
    do:
      input("snapshot", %{
        "targetId" => target_id(request),
        "snapshotFormat" => "ai",
        "refs" => "aria",
        "urls" => true
      })

  defp call_input(7, request, _harness) do
    act(request, %{
      "kind" => "batch",
      "actions" => [
        %{"kind" => "click", "ref" => snapshot_ref(request, "urls-ai", "button", "Frame action")},
        %{
          "kind" => "evaluate",
          "fn" => """
          async () => {
            const frame = document.querySelector('#panel');
            await Promise.all([window.mainEffect, frame.contentWindow.frameEffect]);
            return {mainText: document.querySelector('#main-action').textContent,
              mainClicks: window.mainClicks,
              frameText: frame.contentDocument.querySelector('#frame-action').textContent,
              frameClicks: frame.contentWindow.frameClicks};
          }
          """
        }
      ]
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
    assert %{page_loads: 1, frame_loads: 1, main_effects: 1, frame_effects: 1} =
             Agent.get(harness.counter, & &1)
  end

  defp blocks(request),
    do: Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

  defp successful_results?(request),
    do: Enum.all?(blocks(request), &(&1["type"] != "tool_result" or &1["is_error"] == false))

  defp receive_request(index) do
    assert_receive {:browser_urls_request, ^index, request}, 20_000

    assert successful_results?(request),
           "Browser failed before provider request #{index}: #{inspect(blocks(request))}"

    request
  end

  defp target_id(request), do: receipt(request, "urls-open")["targetId"]

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
           %{"type" => "text_delta", "text" => "Native Browser URLs inspected"}, "end_turn"}
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
