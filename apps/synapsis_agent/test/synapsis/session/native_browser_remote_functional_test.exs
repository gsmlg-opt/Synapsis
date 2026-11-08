defmodule Synapsis.Session.NativeBrowserRemoteFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::browser"
  @ids ~w(remote-start remote-mutate remote-snapshot remote-screenshot remote-stop
          remote-reconnect remote-read remote-final-start remote-final-read)
  @mutate """
  async () => {
    window.remoteCounter = (window.remoteCounter || 0) + 1;
    document.querySelector('#counter').textContent = `Count: ${window.remoteCounter}`;
    await fetch('/mutation', {method: 'POST'});
    return {counter: window.remoteCounter, text: document.querySelector('#counter').textContent};
  }
  """
  @read "() => ({counter: window.remoteCounter, text: document.querySelector('#counter').textContent})"

  test "remote CDP retains external state through native stop, replay and Session close", %{
    tmp_dir: root
  } do
    harness = browser_harness(root)
    fixture = external_fixture(root, page_url(harness))
    on_exit(fn -> close_fixture_if_open(fixture.port) end)
    configure_remote(harness, fixture.endpoint)
    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Inspect the existing remote page")

    requests = for index <- 0..7, do: receive_request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    final = List.last(requests)
    started = receipt(final, "remote-start")
    assert started["driver"] == "remote-cdp"
    assert started["running"] == true
    assert Enum.all?(~w(start tabs snapshot screenshot pdf upload), &(&1 in started["actions"]))
    assert Enum.all?(started["actions"], &(&1 not in ~w(download waitfordownload)))
    assert receipt(final, "remote-mutate")["value"] == expected_value()
    assert receipt(final, "remote-snapshot")["snapshot"] =~ "Remote Browser fixture"
    assert receipt(final, "remote-snapshot")["snapshot"] =~ "Count: 1"
    assert receipt(final, "remote-stop")["cleanup_confirmed"] == true
    assert receipt(final, "remote-stop")["stopped"] == true
    assert receipt(final, "remote-reconnect")["running"] == true
    assert receipt(final, "remote-reconnect")["generation"] > started["generation"]
    assert receipt(final, "remote-read")["value"] == expected_value()

    screenshot =
      harness.session.id
      |> browser_parts()
      |> Enum.find(&match?(%ToolResult{tool_use_id: "remote-screenshot"}, &1))
      |> Map.fetch!(:projection)
      |> Map.fetch!("result")

    assert screenshot["type"] == "png"
    assert [text, image] = screenshot["content"]
    assert text["type"] == "text"
    assert image["type"] == "image"
    assert image["data"]["media_type"] == "image/png"
    png = Base.decode64!(image["data"]["data"])
    assert <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>> = png
    assert byte_size(png) == screenshot["bytes"]
    assert byte_size(png) in 1..196_608

    parts = browser_parts(harness.session.id)
    {uses, results} = assert_parts(parts, Enum.take(@ids, 7))

    assert Enum.map(uses, & &1.input) ==
             for(index <- 0..6, do: call_input(index, final, harness))

    for {request, count} <- Enum.with_index(tl(requests), 1) do
      assert_wire_history(request, Enum.take(uses, count), Enum.take(results, count))
    end

    assert_durable_parts(harness.session.id, uses, results)
    {resource, broker} = browser_resource(harness.session.id)

    assert :sys.get_state(broker).config == %{
             "driver" => "remote-cdp",
             "endpoint" => fixture.endpoint,
             "profile" => "remote",
             "project_root" => root,
             "timeout_ms" => 15_000,
             "max_image_bytes" => 196_608
           }

    assert ResourceRegistry.fetch(
             resource.binding.resource_registry,
             resource.profiles["remote"].handle,
             resource.binding.owner_id
           ) == {:ok, broker}

    helper = helper_pid(broker)
    assert_external_state(fixture)

    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5_000
    assert_exited(helper)
    assert_external_state(fixture)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Recall the completed remote work")
    replay = receive_request(8)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(replay, uses, results)
    assert browser_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)
    {_, replay_broker} = browser_resource(harness.session.id)
    assert :sys.get_state(replay_broker).port == nil
    assert_external_state(fixture)

    assert :ok =
             Worker.send_message(harness.session.id, "Reconnect and read the same external page")

    later = for index <- 9..11, do: receive_request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert receipt(List.last(later), "remote-final-read")["value"] == expected_value()
    {all_uses, all_results} = assert_parts(browser_parts(harness.session.id), @ids)
    assert_wire_history(List.last(later), all_uses, all_results)
    assert_durable_parts(harness.session.id, all_uses, all_results)
    {last_resource, last_broker} = browser_resource(harness.session.id)
    last_helper = helper_pid(last_broker)
    assert {:ok, %{status: :confirmed}} = Session.close(last_resource.binding.session)
    assert_exited(last_helper)
    refute Process.alive?(last_broker)
    assert_external_state(fixture)
    assert %{page_loads: 1, tool_executions: 1} = Agent.get(harness.counter, & &1)
    assert %{"closed" => true, "exited" => true} = fixture_call(fixture.port, "close")
    assert_receive {port, {:exit_status, 0}} when port == fixture.port, 10_000
    refute File.exists?("/proc/#{fixture.pid}")
  end

  defp browser_harness(root) do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    Agent.update(harness.counter, &Map.put(&1, :page_loads, 0))

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
      |> Plug.Conn.resp(
        200,
        "<!doctype html><html><head><title>Remote Browser fixture</title></head><body><h1>Remote Browser fixture</h1><p id='counter'>Count: 0</p></body></html>"
      )
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/mutation", fn conn ->
      Agent.update(harness.counter, &%{&1 | tool_executions: &1.tool_executions + 1})
      Plug.Conn.resp(conn, 200, "recorded")
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/favicon.ico", &Plug.Conn.resp(&1, 204, ""))
    harness
  end

  defp configure_remote(harness, endpoint) do
    repository = Path.expand("../../../../..", __DIR__)

    browser = %{
      "default_profile" => "remote",
      "node_executable" => System.find_executable("node"),
      "helper_path" => Path.join(repository, "packages/tool-host/src/browser/stdio.mjs"),
      "profiles" => %{
        "remote" => %{"target" => "host", "driver" => "remote-cdp", "endpoint" => endpoint}
      }
    }

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{
               tools: [@name],
               config: Map.put(harness.agent_config.config, "browser", browser)
             })
  end

  defp external_fixture(root, url) do
    repository = Path.expand("../../../../..", __DIR__)
    script = Path.join(repository, "packages/tool-host/test/fixtures/external-browser.mjs")

    port =
      Port.open(
        {:spawn_executable, to_charlist(System.find_executable("node"))},
        [
          :binary,
          :exit_status,
          {:line, 1_048_576},
          {:args,
           Enum.map(
             [script, "/run/current-system/sw/bin/chromium", Path.join(root, "external"), url],
             &to_charlist/1
           )}
        ]
      )

    assert_receive {^port, {:data, {:eol, line}}}, 20_000

    assert %{"event" => "ready", "endpoint" => endpoint, "pid" => pid, "markerPath" => marker} =
             Jason.decode!(line)

    %{port: port, endpoint: endpoint, pid: pid, marker: marker, url: url}
  end

  defp fixture_call(port, method, extra \\ %{}) do
    id = System.unique_integer([:positive])
    assert Port.command(port, Jason.encode!(Map.merge(extra, %{id: id, method: method})) <> "\n")
    assert_receive {^port, {:data, {:eol, line}}}, 10_000
    assert %{"id" => ^id} = reply = Jason.decode!(line)
    reply
  end

  defp assert_external_state(fixture) do
    assert File.exists?("/proc/#{fixture.pid}")
    assert File.read!(fixture.marker) == "external-browser-owned-by-fixture"

    assert %{"alive" => true, "pages" => pages} =
             fixture_call(fixture.port, "inspect", %{"fn" => @read})

    assert Enum.find(pages, &(&1["url"] == fixture.url))["value"] == expected_value()
  end

  defp close_fixture_if_open(port) do
    if Port.info(port) do
      Port.command(port, Jason.encode!(%{id: "cleanup", method: "close"}) <> "\n")
    end
  rescue
    ArgumentError -> :ok
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

      send(owner, {:remote_request, index, request})

      call =
        if index in 0..6 or index in 9..10,
          do:
            {Enum.at(@ids, if(index < 7, do: index, else: index - 2)),
             call_input(index, request, harness)}

      provider_response(conn, call)
    end)
  end

  defp call_input(0, _request, _harness), do: input("start")
  defp call_input(1, request, harness), do: evaluate(request, "remote-start", harness, @mutate)

  defp call_input(2, request, harness),
    do: input("snapshot", %{"targetId" => target(request, "remote-start", harness)})

  defp call_input(3, request, harness),
    do: input("screenshot", %{"targetId" => target(request, "remote-start", harness)})

  defp call_input(4, _request, _harness), do: input("stop")
  defp call_input(5, _request, _harness), do: input("start")
  defp call_input(6, request, harness), do: evaluate(request, "remote-reconnect", harness, @read)
  defp call_input(9, _request, _harness), do: input("start")

  defp call_input(10, request, harness),
    do: evaluate(request, "remote-final-start", harness, @read)

  defp evaluate(request, id, harness, fun),
    do:
      input("act", %{
        "targetId" => target(request, id, harness),
        "request" => %{"kind" => "evaluate", "fn" => fun}
      })

  defp input(action, args \\ %{}),
    do: %{"action" => action, "args" => args, "profile" => "remote", "timeout_ms" => 15_000}

  defp page_url(harness), do: Gaoxy.Test.url(harness.provider.fixture, "/page")
  defp expected_value, do: %{"counter" => 1, "text" => "Count: 1"}

  defp target(request, id, harness),
    do: Enum.find(receipt(request, id)["tabs"], &(&1["url"] == page_url(harness)))["targetId"]

  defp blocks(request),
    do: Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

  defp receive_request(index) do
    assert_receive {:remote_request, ^index, request}, 20_000

    assert Enum.all?(blocks(request), &(&1["type"] != "tool_result" or &1["is_error"] == false)),
           "remote Browser failed before request #{index}: #{inspect(blocks(request))}"

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

  defp browser_parts(id),
    do:
      for(
        message <- Synapsis.Message.list_by_session(id),
        part <- message.parts,
        match?(%ToolUse{}, part) or match?(%ToolResult{}, part),
        do: part
      )

  defp assert_parts(parts, ids) do
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == ids
    assert Enum.map(results, & &1.tool_use_id) == ids
    assert Enum.all?(uses, &(&1.tool == @name))
    assert Enum.all?(results, &(&1.is_error == false))

    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    {uses, results}
  end

  defp assert_wire_history(request, uses, results) do
    assert Enum.filter(blocks(request), &(&1["type"] == "tool_use")) ==
             Enum.map(
               uses,
               &%{
                 "type" => "tool_use",
                 "id" => &1.tool_use_id,
                 "name" => ToolName.encode(&1.tool),
                 "input" => &1.input
               }
             )

    assert Enum.filter(blocks(request), &(&1["type"] == "tool_result")) ==
             Enum.map(
               results,
               &%{
                 "type" => "tool_result",
                 "tool_use_id" => &1.tool_use_id,
                 "is_error" => false,
                 "content" => wire_content(&1.projection["result"]["content"])
               }
             )
  end

  defp wire_content(text) when is_binary(text), do: [%{"type" => "text", "text" => text}]

  defp wire_content(content),
    do:
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

  defp assert_durable_parts(id, uses, results) do
    assert {:ok, turns} = Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert({:ok, ^turn} = Store.get_turn(id, index))

    raw = for turn <- turns, part <- turn.parts, do: part

    assert Enum.filter(raw, &(&1[:type] == "tool_use")) ==
             Enum.map(
               uses,
               &%{
                 type: "tool_use",
                 id: &1.tool_use_id,
                 name: &1.tool,
                 input: &1.input,
                 status: to_string(&1.status)
               }
             )

    assert Enum.filter(raw, &(&1[:type] == "tool_result")) ==
             Enum.map(
               results,
               &%{
                 type: "tool_result",
                 tool_use_id: &1.tool_use_id,
                 content: &1.content,
                 is_error: &1.is_error,
                 projection: &1.projection
               }
             )
  end

  defp browser_resource(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker, 1_000)
    adapter = :sys.get_state(data.runtime_pid, 1_000)
    assert [resource] = Map.values(adapter.browser_resources)
    assert %{"remote" => %{pid: broker}} = resource.profiles
    assert Process.alive?(broker)
    {resource, broker}
  end

  defp helper_pid(broker) do
    assert {:os_pid, pid} =
             broker |> :sys.get_state(1_000) |> Map.fetch!(:port) |> Port.info(:os_pid)

    pid
  end

  defp assert_exited(pid) do
    deadline = System.monotonic_time(:millisecond) + 15_000
    await_exit(pid, deadline)
  end

  defp await_exit(pid, deadline) do
    if File.exists?("/proc/#{pid}") do
      assert System.monotonic_time(:millisecond) < deadline, "Browser helper remained alive"
      Process.sleep(10)
      await_exit(pid, deadline)
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
           %{"type" => "text_delta", "text" => "Remote Browser inspected"}, "end_turn"}
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
