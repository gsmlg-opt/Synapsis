defmodule Synapsis.Session.NativeBrowserReconnectFunctionalTest do
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
  @ids ~w(reconnect-start reconnect-first reconnect-second reconnect-focus
          reconnect-snapshot reconnect-click reconnect-stop reconnect-start-again
          reconnect-tabs reconnect-status reconnect-implicit reconnect-label
          reconnect-new-snapshot reconnect-nested reconnect-second-read)
  @read "() => ({path: location.pathname, counter: window.remoteCounter || 0})"

  test "profile aliases and fresh refs survive normal native reconnect and completed replay", %{
    tmp_dir: root
  } do
    harness = browser_harness(root)
    fixture = external_fixture(root, page_url(harness))
    on_exit(fn -> close_fixture_if_open(fixture.port) end)
    configure_remote(harness, fixture.endpoint)
    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Label the tabs and reconnect normally")
    requests = for index <- 0..15, do: receive_request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    final = List.last(requests)
    first = receipt(final, "reconnect-first")
    second = receipt(final, "reconnect-second")
    assert first["targetId"] != second["targetId"]
    assert first["label"] == "first"
    assert second["label"] == "second"

    for id <- ~w(reconnect-start-again reconnect-tabs reconnect-status) do
      tabs = receipt(final, id)["tabs"]

      for original <- [first, second] do
        actual = Enum.find(tabs, &(&1["targetId"] == original["targetId"]))

        assert Map.take(actual, ~w(targetId url tabId suggestedTargetId label)) ==
                 Map.take(original, ~w(targetId url tabId suggestedTargetId label))
      end

      assert Enum.map(Enum.filter(tabs, & &1["active"]), & &1["targetId"]) == [first["targetId"]]
    end

    assert receipt(final, "reconnect-stop")["cleanup_confirmed"] == true
    assert receipt(final, "reconnect-stop")["disconnected"] == true

    assert receipt(final, "reconnect-start-again")["generation"] >
             receipt(final, "reconnect-start")["generation"]

    for id <- ~w(reconnect-implicit reconnect-label) do
      assert receipt(final, id)["targetId"] == first["targetId"]
      assert receipt(final, id)["value"] == %{"path" => "/first", "counter" => 1}
    end

    old = receipt(final, "reconnect-snapshot")
    fresh = receipt(final, "reconnect-new-snapshot")
    assert fresh["targetId"] == first["targetId"]
    assert fresh["snapshot"] =~ "Reconnect action"
    refute Map.has_key?(fresh, "newElements")
    assert button_ref(final, "reconnect-snapshot") != button_ref(final, "reconnect-new-snapshot")

    assert Enum.all?(fresh["refs"], fn item ->
             Enum.all?(old["refs"], &(&1["ref"] != item["ref"]))
           end)

    assert receipt(final, "reconnect-nested")["targetId"] == first["targetId"]

    assert receipt(final, "reconnect-nested")["results"] == [
             %{"ok" => true},
             %{
               "ok" => true,
               "results" => [%{"ok" => true, "value" => %{"path" => "/first", "counter" => 2}}]
             }
           ]

    assert receipt(final, "reconnect-second-read")["targetId"] == second["targetId"]

    assert receipt(final, "reconnect-second-read")["value"] == %{
             "path" => "/second",
             "counter" => 0
           }

    parts = browser_parts(harness.session.id)
    {uses, results} = assert_parts(parts, @ids)

    assert Enum.map(uses, & &1.input) ==
             for(index <- 0..14, do: call_input(index, final, harness))

    for {request, count} <- Enum.with_index(requests),
        do: assert_wire_history(request, Enum.take(uses, count), Enum.take(results, count))

    for part <- results do
      value = receipt(final, part.tool_use_id)
      assert part.content == Jason.encode!(value)
      assert part.projection["result"]["structured"] == value
    end

    assert_durable_parts(harness.session.id, uses, results)
    {resource, broker} = browser_resource(harness.session.id)

    assert {:ok, ^broker} =
             ResourceRegistry.fetch(
               resource.binding.resource_registry,
               resource.profiles["remote"].handle,
               resource.binding.owner_id
             )

    helper = helper_pid(broker)
    assert_external_state(fixture)
    assert %{page_loads: 3, tool_executions: 2} = Agent.get(harness.counter, & &1)
    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    {_, data} = :sys.get_state(old_worker)
    monitors = for pid <- [old_worker, data.runtime_pid, broker], do: {Process.monitor(pid), pid}
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)

    for {monitor, pid} <- monitors,
        do: assert_receive({:DOWN, ^monitor, :process, ^pid, _}, 5_000)

    assert_exited(helper)
    assert_external_state(fixture)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Recall the completed reconnect work")
    replay = receive_request(16)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(replay, uses, results)
    assert browser_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)
    {_, replay_broker} = browser_resource(harness.session.id)
    assert :sys.get_state(replay_broker).port == nil
    assert_external_state(fixture)
    assert %{page_loads: 3, tool_executions: 2} = Agent.get(harness.counter, & &1)
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

    for path <- ~w(/page /first /second) do
      Gaoxy.Test.stub(harness.provider.fixture, "GET", path, fn conn ->
        Agent.update(harness.counter, &%{&1 | page_loads: &1.page_loads + 1})

        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.resp(
          200,
          "<!doctype html><html><head><title>Remote Browser fixture</title></head><body><h1>Remote Browser fixture</h1><button onclick=\"window.remoteCounter=(window.remoteCounter||0)+1;fetch('/mutation',{method:'POST'});\">Reconnect action</button></body></html>"
        )
      end)
    end

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

    assert Enum.find(pages, &String.ends_with?(&1["url"], "/first"))["value"] == %{
             "path" => "/first",
             "counter" => 2
           }

    assert Enum.find(pages, &String.ends_with?(&1["url"], "/second"))["value"] == %{
             "path" => "/second",
             "counter" => 0
           }

    assert Enum.find(pages, &(&1["url"] == fixture.url))["value"] == %{
             "path" => "/page",
             "counter" => 0
           }
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
        if index in 0..14,
          do: {Enum.at(@ids, index), call_input(index, request, harness)}

      provider_response(conn, call)
    end)
  end

  defp call_input(0, _request, _harness), do: input("start")

  defp call_input(1, _request, harness),
    do:
      input("open", %{
        "targetUrl" => Gaoxy.Test.url(harness.provider.fixture, "/first"),
        "label" => " first "
      })

  defp call_input(2, _request, harness),
    do:
      input("open", %{
        "targetUrl" => Gaoxy.Test.url(harness.provider.fixture, "/second"),
        "label" => "second"
      })

  defp call_input(3, _request, _harness), do: input("focus", %{"targetId" => "first"})
  defp call_input(4, _request, _harness), do: input("snapshot")

  defp call_input(5, request, _harness),
    do:
      input("act", %{
        "request" => %{"kind" => "click", "ref" => button_ref(request, "reconnect-snapshot")}
      })

  defp call_input(6, _request, _harness), do: input("stop")
  defp call_input(7, _request, _harness), do: input("start")
  defp call_input(8, _request, _harness), do: input("tabs")
  defp call_input(9, _request, _harness), do: input("status")

  defp call_input(10, _request, _harness),
    do: input("act", %{"request" => %{"kind" => "evaluate", "fn" => @read}})

  defp call_input(11, _request, _harness),
    do:
      input("act", %{"targetId" => " first ", "request" => %{"kind" => "evaluate", "fn" => @read}})

  defp call_input(12, _request, _harness), do: input("snapshot", %{"targetId" => "first"})

  defp call_input(13, request, _harness) do
    first = receipt(request, "reconnect-first")

    input("act", %{
      "request" => %{
        "kind" => "batch",
        "targetId" => first["tabId"],
        "actions" => [
          %{
            "kind" => "click",
            "targetId" => "first",
            "ref" => button_ref(request, "reconnect-new-snapshot")
          },
          %{
            "kind" => "batch",
            "targetId" => first["targetId"],
            "actions" => [%{"kind" => "evaluate", "fn" => @read}]
          }
        ]
      }
    })
  end

  defp call_input(14, _request, _harness),
    do:
      input("act", %{"targetId" => "second", "request" => %{"kind" => "evaluate", "fn" => @read}})

  defp button_ref(request, id),
    do:
      receipt(request, id)["refs"]
      |> Enum.find(&(&1["name"] == "Reconnect action"))
      |> Map.fetch!("ref")

  defp input(action, args \\ %{}),
    do: %{"action" => action, "args" => args, "profile" => "remote", "timeout_ms" => 15_000}

  defp page_url(harness), do: Gaoxy.Test.url(harness.provider.fixture, "/page")

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
