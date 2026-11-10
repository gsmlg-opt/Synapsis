defmodule Synapsis.Session.NativeBrowserLabelsFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::browser"
  @ids ~w(labels-start labels-open labels-resize labels-page labels-ref labels-plain labels-read)
  @read """
  async element => {
    window.labelReads = (window.labelReads || 0) + 1;
    await fetch('/retained-read', {method: 'POST'});
    const rect = element.getBoundingClientRect();
    return {id: element.id, name: element.getAttribute('aria-label'),
      width: rect.width, height: rect.height, connected: element.isConnected,
      documentChildren: [...document.documentElement.children].map(node => node.tagName),
      bodyChildren: [...document.body.children].map(node => node.id),
      reads: window.labelReads};
  }
  """

  test "labeled screenshot refs and image annotations survive native history and clean replay", %{
    tmp_dir: root
  } do
    harness = browser_harness(root)
    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok =
             Worker.send_message(
               harness.session.id,
               "Label the local page and capture its button"
             )

    requests = for index <- 0..7, do: receive_request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    final = List.last(requests)
    target = target_id(final)
    ref = button_ref(final)

    offscreen_ref =
      final
      |> receipt("labels-page")
      |> Map.fetch!("annotations")
      |> Enum.find(&(&1["name"] == "Offscreen label target"))
      |> Map.fetch!("ref")

    assert receipt(final, "labels-page")["annotations"] == [
             annotation(ref, "Visible label target", 40, 48, 96, 48),
             annotation(offscreen_ref, "Offscreen label target", 40, 360, 80, 32)
           ]

    assert receipt(final, "labels-page")["labels"] == true
    assert receipt(final, "labels-page")["labelsCount"] == 1
    assert receipt(final, "labels-page")["labelsSkipped"] == 1
    assert receipt(final, "labels-ref")["labels"] == true
    assert receipt(final, "labels-ref")["labelsCount"] == 1
    assert receipt(final, "labels-ref")["labelsSkipped"] == 0

    assert receipt(final, "labels-ref")["annotations"] == [
             annotation(ref, "Visible label target", 0, 0, 96, 48)
           ]

    plain = receipt(final, "labels-plain")
    refute Map.has_key?(plain, "labels")
    refute Map.has_key?(plain, "labelsCount")
    refute Map.has_key?(plain, "labelsSkipped")
    refute Map.has_key?(plain, "annotations")

    assert receipt(final, "labels-read")["value"] == %{
             "id" => "label-button",
             "name" => "Visible label target",
             "width" => 96,
             "height" => 48,
             "connected" => true,
             "documentChildren" => ["HEAD", "BODY"],
             "bodyChildren" => ["label-button", "offscreen-button"],
             "reads" => 1
           }

    parts = browser_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == @ids
    assert Enum.map(results, & &1.tool_use_id) == @ids
    assert Enum.all?(uses, &(&1.tool == @name))
    assert Enum.all?(results, &(&1.is_error == false))

    assert Enum.map(uses, & &1.input) ==
             for(index <- 0..6, do: call_input(index, final, harness))

    for {id, dimensions} <- [
          {"labels-page", {320, 240}},
          {"labels-ref", {96, 48}},
          {"labels-plain", {96, 48}}
        ] do
      part = Enum.find(results, &(&1.tool_use_id == id))
      assert %{"version" => 1, "result" => screenshot} = part.projection
      assert screenshot["targetId"] == target
      assert screenshot["url"] == page_url(harness)
      assert screenshot["type"] == "png"

      assert [text, image] = screenshot["content"]
      assert text["type"] == "text"

      metadata =
        Map.take(
          screenshot,
          ~w(targetId url type bytes labels labelsCount labelsSkipped annotations truncated path sha256 media)
        )

      assert Jason.decode!(text["text"]) == metadata
      assert is_integer(screenshot["generation"])
      assert screenshot["generation"] > 0
      assert screenshot["is_error"] == false
      assert screenshot["structured"] == Map.put(metadata, "generation", screenshot["generation"])

      assert %{
               "type" => "image",
               "data" => %{"source" => "base64", "media_type" => "image/png", "data" => data}
             } = image

      png = Base.decode64!(data)

      assert <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", width::32, height::32, _::binary>> =
               png

      assert {width, height} == dimensions
      assert byte_size(png) == screenshot["bytes"]
      assert byte_size(png) in 1..196_608
      assert part.content == text["text"]
    end

    for {request, count} <- Enum.with_index(requests) do
      assert_wire_history(request, Enum.take(uses, count), Enum.take(results, count))
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

    assert :ok =
             Worker.send_message(harness.session.id, "Recall the completed labeled screenshots")

    replay = receive_request(8)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(replay, uses, results)
    assert browser_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)
    assert_effect_counts(harness)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 9
    {_resource, replay_broker} = browser_resource(harness.session.id)
    refute replay_broker == broker
    assert :sys.get_state(replay_broker).port == nil
  end

  defp annotation(ref, name, x, y, width, height) do
    assert "e" <> digits = ref
    {number, ""} = Integer.parse(digits)
    assert number > 0

    %{
      "ref" => ref,
      "number" => number,
      "role" => "button",
      "name" => name,
      "box" => %{"x" => x, "y" => y, "width" => width, "height" => height}
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
    Agent.update(harness.counter, &Map.merge(&1, %{page_loads: 0, retained_reads: 0}))
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
      <!doctype html><html><head><title>Native labeled capture</title>
      <meta name="viewport" content="width=device-width, initial-scale=1"><style>
      html, body { margin: 0; padding: 0; width: 100%; background: white; }
      body { height: 440px; }
      button { position: absolute; border: 0; padding: 0; }
      #label-button { left: 40px; top: 48px; width: 96px; height: 48px; background: #2060d0; }
      #offscreen-button { left: 40px; top: 360px; width: 80px; height: 32px; background: #20a040; }
      </style></head><body><button id="label-button" aria-label="Visible label target"></button>
      <button id="offscreen-button" aria-label="Offscreen label target"></button></body></html>
      """)
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/retained-read", fn conn ->
      Agent.update(harness.counter, &%{&1 | retained_reads: &1.retained_reads + 1})
      Plug.Conn.resp(conn, 200, "retained")
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

      send(owner, {:browser_labels_request, index, request})

      call =
        if index < length(@ids) and successful_results?(request),
          do: {Enum.at(@ids, index), call_input(index, request, harness)}

      provider_response(conn, call)
    end)
  end

  defp call_input(0, _request, _harness), do: input("start")
  defp call_input(1, _request, harness), do: input("open", %{"targetUrl" => page_url(harness)})

  defp call_input(2, request, _harness),
    do:
      input("act", %{
        "targetId" => target_id(request),
        "request" => %{"kind" => "resize", "width" => 320, "height" => 240}
      })

  defp call_input(3, request, _harness),
    do: input("screenshot", %{"targetId" => target_id(request), "labels" => true})

  defp call_input(4, request, _harness),
    do:
      input("screenshot", %{
        "targetId" => target_id(request),
        "ref" => button_ref(request),
        "element" => "#offscreen-button",
        "labels" => true
      })

  defp call_input(5, request, _harness),
    do:
      input("screenshot", %{
        "targetId" => target_id(request),
        "ref" => button_ref(request),
        "labels" => false
      })

  defp call_input(6, request, _harness) do
    input("act", %{
      "targetId" => target_id(request),
      "request" => %{"kind" => "evaluate", "ref" => button_ref(request), "fn" => @read}
    })
  end

  defp input(action, args \\ %{}),
    do: %{"action" => action, "args" => args, "profile" => "managed", "timeout_ms" => 15_000}

  defp page_url(harness), do: Gaoxy.Test.url(harness.provider.fixture, "/page")

  defp assert_effect_counts(harness) do
    assert %{page_loads: 1, retained_reads: 1} = Agent.get(harness.counter, & &1)
  end

  defp blocks(request),
    do: Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

  defp successful_results?(request),
    do: Enum.all?(blocks(request), &(&1["type"] != "tool_result" or &1["is_error"] == false))

  defp receive_request(index) do
    assert_receive {:browser_labels_request, ^index, request}, 20_000

    assert successful_results?(request),
           "Browser failed before provider request #{index}: #{inspect(blocks(request))}"

    request
  end

  defp target_id(request), do: receipt(request, "labels-open")["targetId"]

  defp button_ref(request) do
    request
    |> receipt("labels-page")
    |> Map.fetch!("annotations")
    |> Enum.find(&(&1["role"] == "button" and &1["name"] == "Visible label target"))
    |> Map.fetch!("ref")
  end

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
           %{"type" => "text_delta", "text" => "Labeled Browser screenshots inspected"},
           "end_turn"}
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
