defmodule Synapsis.Session.NativeBrowserScreenshotPathFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::browser"
  @ids ~w(path-start path-open path-resize path-snapshot path-png path-jpeg path-click path-read)
  @read """
  async element => {
    await window.clickEffect;
    await fetch('/screenshot-path/read', {method:'POST'});
    return {id:element.id,connected:element.isConnected,clicks:window.clicks,
      documentChildren:[...document.documentElement.children].map(node=>node.tagName),
      bodyChildren:[...document.body.children].map(node=>node.id)};
  }
  """

  test "trusted path screenshots reach the next provider, durable history and replay without recapture",
       %{tmp_dir: root} do
    harness = browser_harness(root)
    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Save the local screenshots")
    requests = for index <- 0..8, do: receive_request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    final = List.last(requests)
    target = target_id(final)

    assert [%{"input_schema" => %{"properties" => %{"action" => %{"enum" => actions}}}}] =
             hd(requests)["tools"]

    assert length(actions) == 23

    snapshot = receipt(final, "path-snapshot")
    assert snapshot["labels"] == true
    assert snapshot["labelsCount"] == 1

    assert snapshot["refs"] == [
             %{"ref" => button_ref(final), "role" => "button", "name" => "Saved action"}
           ]

    snapshot_wire = wire_result(Enum.at(requests, 4), "path-snapshot")

    assert [%{"type" => "text"}, %{"type" => "image", "source" => image}] =
             snapshot_wire["content"]

    png = Base.decode64!(image["data"])
    assert image["media_type"] == "image/png"
    assert <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", 320::32, 180::32, _::binary>> = png
    assert snapshot["path"] == snapshot["imagePath"]
    assert snapshot["imageType"] == "png"
    assert snapshot["media"] == %{"outbound" => false, "mediaUrl" => snapshot["path"]}
    assert Path.dirname(snapshot["path"]) == Path.join(root, ".synapsis/browser-files")
    assert File.read!(snapshot["path"]) == png
    assert snapshot["sha256"] == Base.encode16(:crypto.hash(:sha256, png), case: :lower)

    saved =
      for {id, type, index} <- [{"path-png", "png", 5}, {"path-jpeg", "jpeg", 6}] do
        result = receipt(Enum.at(requests, index), id)
        assert result == receipt(final, id)
        assert result["ok"] == true
        assert result["targetId"] == target
        assert result["url"] == page_url(harness)
        assert result["type"] == type
        assert result["mimeType"] == "image/" <> type
        assert result["media"] == %{"outbound" => false}
        assert result["annotationCount"] == 1
        assert String.length(result["path"]) <= 4_096
        assert Path.dirname(result["path"]) == Path.join(root, ".synapsis/browser-files")
        assert Path.extname(result["path"]) == "." <> type
        refute Map.has_key?(result, "annotations")
        refute Map.has_key?(result, "data")

        assert [%{"type" => "text", "text" => text}] =
                 wire_result(Enum.at(requests, index), id)["content"]

        assert Jason.decode!(text) == result
        bytes = File.read!(result["path"])
        assert byte_size(bytes) == result["bytes"]
        assert byte_size(bytes) in 1..196_608
        assert result["sha256"] == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

        if type == "png" do
          assert <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", 96::32, 48::32, _::binary>> =
                   bytes
        else
          assert <<255, 216, _::binary>> = bytes
        end

        {result["path"], bytes}
      end

    assert length(Enum.uniq(Enum.map(saved, &elem(&1, 0)))) == 2
    saved = [{snapshot["path"], png} | saved]
    assert length(Enum.uniq(Enum.map(saved, &elem(&1, 0)))) == 3
    assert receipt(final, "path-click")["ok"] == true

    assert receipt(final, "path-read")["value"] == %{
             "id" => "saved-button",
             "connected" => true,
             "clicks" => 1,
             "documentChildren" => ["HEAD", "BODY"],
             "bodyChildren" => ["saved-button"]
           }

    parts = browser_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == @ids
    assert Enum.map(results, & &1.tool_use_id) == @ids
    assert Enum.all?(uses, &(&1.tool == @name))
    assert Enum.all?(results, &(&1.is_error == false))
    assert Enum.map(uses, & &1.input) == for(index <- 0..7, do: call_input(index, final, harness))

    for id <- ~w(path-png path-jpeg) do
      part = Enum.find(results, &(&1.tool_use_id == id))
      assert %{"version" => 1, "result" => result} = part.projection
      assert result["structured"] == receipt(final, id)
      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert Jason.decode!(text) == result["structured"]
      assert part.content == text
      assert result["is_error"] == false
      refute Map.has_key?(result, "annotations")
    end

    for {request, count} <- Enum.with_index(requests) do
      assert_wire_history(request, Enum.take(uses, count), Enum.take(results, count))
    end

    assert_part_round_trips(parts)
    assert_durable_parts(harness.session.id, uses, results)
    assert_effect_counts(harness)
    assert_artifacts(root, saved)
    {_resource, broker} = browser_resource(harness.session.id)
    owned = owned_processes(broker)
    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5_000
    assert_owned_exited(owned)
    refute Process.alive?(broker)
    assert_artifacts(root, saved)

    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute new_worker == old_worker
    assert :ok = Worker.send_message(harness.session.id, "Recall the saved screenshots")
    replay = receive_request(9)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(replay, uses, results)
    assert browser_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)
    assert_effect_counts(harness)
    assert_artifacts(root, saved)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 10
    {_resource, replay_broker} = browser_resource(harness.session.id)
    refute replay_broker == broker
    assert :sys.get_state(replay_broker).port == nil
  end

  defp assert_artifacts(root, saved) do
    assert Enum.sort(File.ls!(Path.join(root, ".synapsis/browser-files"))) ==
             Enum.sort(Enum.map(saved, fn {path, _bytes} -> Path.basename(path) end))

    for {path, bytes} <- saved, do: assert(File.read!(path) == bytes)
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
      &Map.merge(&1, %{path_page_loads: 0, path_clicks: 0, path_reads: 0})
    )

    repository = Path.expand("../../../../..", __DIR__)

    browser = %{
      "default_profile" => "managed",
      "screenshot_result_mode" => "path",
      "node_executable" => System.find_executable("node"),
      "helper_path" => Path.join(repository, "packages/tool-host/src/browser/stdio.mjs"),
      "profiles" => %{
        "managed" => %{
          "driver" => "managed-host",
          "target" => "host",
          "executable" => "/run/current-system/sw/bin/chromium",
          "data_dir" => Path.join(root, "path-browser-data"),
          "timeout_ms" => 15_000
        }
      }
    }

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{
               tools: [@name],
               config: Map.put(harness.agent_config.config, "browser", browser)
             })

    assert Synapsis.AgentConfigs.get_by_name(harness.agent_name).config["browser"] == browser

    assert :ok =
             Synapsis.Provider.Registry.register(harness.provider.name, %{
               type: "anthropic",
               base_url: harness.provider.base_url,
               api_key: "test-key"
             })

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/screenshot-path/page", fn conn ->
      Agent.update(harness.counter, &Map.update!(&1, :path_page_loads, fn count -> count + 1 end))

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, """
      <!doctype html><html><head><title>Native saved screenshot</title>
      <meta name="viewport" content="width=device-width, initial-scale=1"><style>
      html,body{margin:0;background:white}button{position:absolute;left:24px;top:32px;width:96px;height:48px;border:0;padding:0;background:rgb(30,180,70)}
      </style></head><body><button id="saved-button" aria-label="Saved action" onclick="window.clicks=(window.clicks||0)+1;window.clickEffect=fetch('/screenshot-path/click',{method:'POST'})"></button></body></html>
      """)
    end)

    for {path, key} <- [{"click", :path_clicks}, {"read", :path_reads}] do
      Gaoxy.Test.stub(harness.provider.fixture, "POST", "/screenshot-path/" <> path, fn conn ->
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

      send(owner, {:browser_screenshot_path_request, index, request})

      call =
        if index < length(@ids) and successful_results?(request),
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
        "labels" => true,
        "interactive" => true,
        "compact" => true,
        "limit" => 12,
        "maxChars" => 4_000
      })

  defp call_input(4, request, _harness),
    do:
      input("screenshot", %{
        "targetId" => target_id(request),
        "ref" => button_ref(request),
        "labels" => true,
        "type" => "png"
      })

  defp call_input(5, request, _harness),
    do:
      input("screenshot", %{
        "targetId" => target_id(request),
        "ref" => button_ref(request),
        "labels" => true,
        "type" => "jpeg"
      })

  defp call_input(6, request, _harness),
    do: act(request, %{"kind" => "click", "ref" => button_ref(request)})

  defp call_input(7, request, _harness),
    do: act(request, %{"kind" => "evaluate", "ref" => button_ref(request), "fn" => @read})

  defp act(request, action),
    do: input("act", %{"targetId" => target_id(request), "request" => action})

  defp input(action, args \\ %{}),
    do: %{"action" => action, "args" => args, "profile" => "managed", "timeout_ms" => 15_000}

  defp page_url(harness), do: Gaoxy.Test.url(harness.provider.fixture, "/screenshot-path/page")
  defp target_id(request), do: receipt(request, "path-open")["targetId"]

  defp button_ref(request),
    do: receipt(request, "path-snapshot")["refs"] |> hd() |> Map.fetch!("ref")

  defp assert_effect_counts(harness),
    do:
      assert(
        %{path_page_loads: 1, path_clicks: 1, path_reads: 1} = Agent.get(harness.counter, & &1)
      )

  defp blocks(request),
    do: Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

  defp successful_results?(request),
    do: Enum.all?(blocks(request), &(&1["type"] != "tool_result" or &1["is_error"] == false))

  defp wire_result(request, id),
    do: Enum.find(blocks(request), &(&1["type"] == "tool_result" and &1["tool_use_id"] == id))

  defp receipt(request, id),
    do:
      wire_result(request, id)["content"]
      |> Enum.find(&(&1["type"] == "text"))
      |> Map.fetch!("text")
      |> Jason.decode!()

  defp receive_request(index) do
    assert_receive {:browser_screenshot_path_request, ^index, request}, 20_000

    assert successful_results?(request),
           "Browser failed before provider request #{index}: #{inspect(blocks(request))}"

    request
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
           %{"type" => "text_delta", "text" => "Saved Browser screenshots inspected"}, "end_turn"}
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
