defmodule Synapsis.Session.NativeBrowserSnapshotLabelsFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::browser"
  @ids ~w(snaplabels-start snaplabels-open snaplabels-resize snaplabels-role
          snaplabels-role-click snaplabels-aria snaplabels-shadow-click snaplabels-read)
  @read """
  async element => {
    await Promise.all([window.roleEffect, window.shadowEffect]);
    await fetch('/snapshot-labels/read', {method: 'POST'});
    const shadow = document.querySelector('#shadow').shadowRoot.querySelector('button');
    return {id: element.id, connected: element.isConnected,
      mainClicks: window.roleClicks, shadowClicks: window.shadowClicks,
      mainText: document.querySelector('#role-button').textContent,
      shadowText: shadow.textContent,
      documentChildren: [...document.documentElement.children].map(node => node.tagName),
      bodyChildren: [...document.body.children].map(node => node.id)};
  }
  """

  test "combined role and AI ARIA labeled snapshots retain exact refs, images and clean Worker replay",
       %{tmp_dir: root} do
    harness = browser_harness(root)
    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Use the local labeled snapshots")

    initial = for index <- 0..4, do: receive_request(index)
    role_request = List.last(initial)
    assert_combined_wire(role_request, "snaplabels-role")
    remaining = for index <- 5..8, do: receive_request(index)
    requests = initial ++ remaining
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    final = List.last(requests)
    target = target_id(final)
    role = receipt(final, "snaplabels-role")
    aria = receipt(final, "snaplabels-aria")

    assert_labeled_snapshot(role, target, "role")
    assert_labeled_snapshot(aria, target, "aria")

    assert role["refs"] == [
             %{
               "ref" => snapshot_ref(final, "snaplabels-role", "Scoped action"),
               "role" => "button",
               "name" => "Scoped action"
             },
             %{
               "ref" => snapshot_ref(final, "snaplabels-role", "Local help"),
               "role" => "link",
               "name" => "Local help"
             }
           ]

    assert role["snapshot"] =~ "/snapshot-labels/help"

    assert Enum.map(aria["refs"], & &1["name"]) ==
             ["Scoped action", "Local help", "Outside action", "Shadow action"]

    assert aria["documentGeneration"] == role["documentGeneration"]
    assert aria["snapshotGeneration"] == role["snapshotGeneration"] + 1

    assert Enum.min(Enum.map(aria["refs"], &ref_number(&1["ref"]))) >
             Enum.max(Enum.map(role["refs"], &ref_number(&1["ref"])))

    assert role["labelsCount"] == 2
    assert aria["labelsCount"] == 4
    assert role["labelsSkipped"] == 0
    assert aria["labelsSkipped"] == 0
    assert receipt(final, "snaplabels-role-click")["ok"] == true
    assert receipt(final, "snaplabels-shadow-click")["ok"] == true

    assert receipt(final, "snaplabels-read")["value"] == %{
             "id" => "shadow-button",
             "connected" => true,
             "mainClicks" => 1,
             "shadowClicks" => 1,
             "mainText" => "Main finished",
             "shadowText" => "Shadow finished",
             "documentChildren" => ["HEAD", "BODY"],
             "bodyChildren" => ["scope", "outside", "shadow", "fixture-script"]
           }

    parts = browser_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == @ids
    assert Enum.map(results, & &1.tool_use_id) == @ids
    assert Enum.all?(uses, &(&1.tool == @name))
    assert Enum.all?(results, &(&1.is_error == false))
    assert Enum.map(uses, & &1.input) == for(index <- 0..7, do: call_input(index, final, harness))

    for id <- ~w(snaplabels-role snaplabels-aria) do
      assert_combined_wire(final, id)
      part = Enum.find(results, &(&1.tool_use_id == id))
      assert %{"version" => 1, "result" => snapshot} = part.projection
      assert [text, image] = snapshot["content"]
      metadata = Map.drop(snapshot, ~w(content structured is_error))
      assert Jason.decode!(text["text"]) == metadata
      assert metadata == receipt(final, id)
      assert snapshot["targetId"] == target
      assert snapshot["url"] == page_url(harness)
      assert is_integer(snapshot["generation"])
      assert snapshot["generation"] > 0
      assert snapshot["is_error"] == false
      assert snapshot["structured"] == metadata

      assert %{
               "type" => "image",
               "data" => %{
                 "source" => "base64",
                 "media_type" => "image/png",
                 "data" => data
               }
             } = image

      png = Base.decode64!(data)

      assert <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", width::32, height::32, _::binary>> =
               png

      assert {width, height} == {320, 180}
      assert byte_size(png) == snapshot["bytes"]
      assert byte_size(png) in 1..196_608
      assert part.content == text["text"]
      assert snapshot["path"] == snapshot["imagePath"]
      assert snapshot["imageType"] == "png"
      assert snapshot["media"] == %{"outbound" => false, "mediaUrl" => snapshot["path"]}
      assert Path.dirname(snapshot["path"]) == Path.join(root, ".synapsis/browser-files")
      assert File.read!(snapshot["path"]) == png
      assert snapshot["sha256"] == Base.encode16(:crypto.hash(:sha256, png), case: :lower)
    end

    for {request, count} <- Enum.with_index(requests) do
      assert_wire_history(request, Enum.take(uses, count), Enum.take(results, count))
    end

    saved =
      for id <- ~w(snaplabels-role snaplabels-aria), into: %{} do
        path = receipt(final, id)["path"]
        {path, File.read!(path)}
      end

    assert map_size(saved) == 2
    assert_generated_artifacts(root, saved)
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
    assert_generated_artifacts(root, saved)

    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute new_worker == old_worker
    assert :ok = Worker.send_message(harness.session.id, "Recall the completed labeled snapshots")
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
    assert_generated_artifacts(root, saved)
  end

  defp assert_generated_artifacts(root, saved) do
    directory = Path.join(root, ".synapsis/browser-files")

    assert Enum.sort(File.ls!(directory)) ==
             Enum.sort(Enum.map(Map.keys(saved), &Path.basename/1))

    for {path, bytes} <- saved, do: assert(File.read!(path) == bytes)
  end

  defp assert_combined_wire(request, id) do
    result =
      Enum.find(blocks(request), &(&1["type"] == "tool_result" and &1["tool_use_id"] == id))

    assert [%{"type" => "text"}, %{"type" => "image"}] = result["content"]
    assert receipt(request, id)["labels"] == true
  end

  defp assert_labeled_snapshot(snapshot, target, refs_type) do
    assert %{
             "targetId" => ^target,
             "format" => "ai",
             "refsType" => ^refs_type,
             "type" => "png",
             "labels" => true,
             "truncated" => false
           } = snapshot

    assert snapshot["refCount"] == length(snapshot["refs"])
    assert is_integer(snapshot["documentGeneration"])
    assert is_integer(snapshot["snapshotGeneration"])
    assert is_binary(snapshot["semantics"])
    assert String.length(snapshot["snapshot"]) <= 4_000
    assert snapshot["labelsCount"] == length(snapshot["annotations"])

    for ref <- snapshot["refs"] do
      assert snapshot["snapshot"] =~ "[ref=#{ref["ref"]}]"
      assert annotation = Enum.find(snapshot["annotations"], &(&1["ref"] == ref["ref"]))
      assert Map.take(annotation, ~w(ref role name)) == ref
      assert annotation["number"] == ref_number(ref["ref"])
      assert %{"x" => x, "y" => y, "width" => width, "height" => height} = annotation["box"]
      assert x >= 0 and x < 320 and y >= 0 and y < 180
      assert width > 0 and height > 0
    end
  end

  defp ref_number("e" <> digits), do: String.to_integer(digits)

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
      &Map.merge(&1, %{
        snapshot_page_loads: 0,
        snapshot_role_effects: 0,
        snapshot_shadow_effects: 0,
        snapshot_reads: 0
      })
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
          "data_dir" => Path.join(root, "snapshot-labels-browser-data"),
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

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/snapshot-labels/page", fn conn ->
      Agent.update(harness.counter, &%{&1 | snapshot_page_loads: &1.snapshot_page_loads + 1})

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, """
      <!doctype html><html><head><title>Native combined snapshots</title>
      <meta name="viewport" content="width=device-width, initial-scale=1"><style>
      html,body { margin:0; padding:0; background:white; }
      button,a { position:absolute; border:0; padding:0; width:88px; height:32px; }
      #role-button { left:16px; top:24px; background:#2060d0; }
      #help { left:112px; top:24px; } #outside { left:216px; top:24px; }
      #shadow { position:absolute; left:16px; top:100px; }
      </style></head><body><section id="scope" class="scope">
      <button id="role-button" aria-label="Scoped action" onclick="window.roleClicks=(window.roleClicks||0)+1;this.textContent='Main finished';window.roleEffect=fetch('/snapshot-labels/role-effect',{method:'POST'})"></button>
      <a id="help" href="/snapshot-labels/help">Local help</a></section>
      <button id="outside" aria-label="Outside action"></button><div id="shadow"></div>
      <script id="fixture-script">
      const shadow=document.querySelector('#shadow').attachShadow({mode:'open'});
      shadow.innerHTML='<style>button{width:96px;height:32px;border:0;padding:0;background:#20a040}</style><button id="shadow-button" aria-label="Shadow action"></button>';
      shadow.querySelector('button').onclick=event=>{window.shadowClicks=(window.shadowClicks||0)+1;event.target.textContent='Shadow finished';window.shadowEffect=fetch('/snapshot-labels/shadow-effect',{method:'POST'})};
      </script></body></html>
      """)
    end)

    for {path, key} <- [
          {"role-effect", :snapshot_role_effects},
          {"shadow-effect", :snapshot_shadow_effects},
          {"read", :snapshot_reads}
        ] do
      Gaoxy.Test.stub(harness.provider.fixture, "POST", "/snapshot-labels/" <> path, fn conn ->
        Agent.update(harness.counter, &Map.update!(&1, key, fn count -> count + 1 end))
        Plug.Conn.resp(conn, 200, "recorded")
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

      send(owner, {:browser_snapshot_labels_request, index, request})

      combined =
        index not in [4, 6] or
          Enum.any?(blocks(request), fn block ->
            block["type"] == "tool_result" and is_list(block["content"]) and
              Enum.any?(block["content"], &(&1["type"] == "image")) and
              block["tool_use_id"] == Enum.at(@ids, index - 1)
          end)

      call =
        if index < length(@ids) and successful_results?(request) and combined,
          do: {Enum.at(@ids, index), call_input(index, request, harness)}

      provider_response(conn, call)
    end)
  end

  defp call_input(0, _request, _harness), do: input("start")
  defp call_input(1, _request, harness), do: input("open", %{"targetUrl" => page_url(harness)})

  defp call_input(2, request, _harness),
    do: act(request, %{"kind" => "resize", "width" => 320, "height" => 180})

  defp call_input(3, request, _harness),
    do:
      input("snapshot", %{
        "targetId" => target_id(request),
        "snapshotFormat" => "ai",
        "refs" => "role",
        "selector" => ".scope",
        "interactive" => true,
        "compact" => true,
        "urls" => true,
        "labels" => true,
        "limit" => 12,
        "maxChars" => 4_000
      })

  defp call_input(4, request, _harness),
    do:
      act(request, %{
        "kind" => "click",
        "ref" => snapshot_ref(request, "snaplabels-role", "Scoped action")
      })

  defp call_input(5, request, _harness),
    do:
      input("snapshot", %{
        "targetId" => target_id(request),
        "snapshotFormat" => "ai",
        "refs" => "aria",
        "interactive" => true,
        "compact" => true,
        "urls" => true,
        "labels" => true,
        "limit" => 12,
        "maxChars" => 4_000
      })

  defp call_input(6, request, _harness),
    do:
      act(request, %{
        "kind" => "click",
        "ref" => snapshot_ref(request, "snaplabels-aria", "Shadow action")
      })

  defp call_input(7, request, _harness),
    do:
      act(request, %{
        "kind" => "evaluate",
        "ref" => snapshot_ref(request, "snaplabels-aria", "Shadow action"),
        "fn" => @read
      })

  defp snapshot_ref(request, id, name),
    do: receipt(request, id)["refs"] |> Enum.find(&(&1["name"] == name)) |> Map.fetch!("ref")

  defp act(request, action),
    do: input("act", %{"targetId" => target_id(request), "request" => action})

  defp input(action, args \\ %{}),
    do: %{"action" => action, "args" => args, "profile" => "managed", "timeout_ms" => 15_000}

  defp page_url(harness), do: Gaoxy.Test.url(harness.provider.fixture, "/snapshot-labels/page")

  defp assert_effect_counts(harness) do
    assert %{
             snapshot_page_loads: 1,
             snapshot_role_effects: 1,
             snapshot_shadow_effects: 1,
             snapshot_reads: 1
           } = Agent.get(harness.counter, & &1)
  end

  defp blocks(request),
    do: Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

  defp successful_results?(request),
    do: Enum.all?(blocks(request), &(&1["type"] != "tool_result" or &1["is_error"] == false))

  defp receive_request(index) do
    assert_receive {:browser_snapshot_labels_request, ^index, request}, 20_000

    assert successful_results?(request),
           "Browser failed before provider request #{index}: #{inspect(blocks(request))}"

    request
  end

  defp target_id(request), do: receipt(request, "snaplabels-open")["targetId"]

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
                 "content" => wire_content(part.projection["result"]["content"])
               }
             end)
  end

  defp wire_content(text) when is_binary(text), do: [%{"type" => "text", "text" => text}]

  defp wire_content(content) do
    Enum.map(content, fn
      %{"type" => "text", "text" => text} ->
        %{"type" => "text", "text" => text}

      %{
        "type" => "image",
        "data" => %{"source" => "base64", "media_type" => mime, "data" => data}
      } ->
        %{
          "type" => "image",
          "source" => %{"type" => "base64", "media_type" => mime, "data" => data}
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
           %{"type" => "text_delta", "text" => "Labeled Browser snapshots inspected"}, "end_turn"}
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
