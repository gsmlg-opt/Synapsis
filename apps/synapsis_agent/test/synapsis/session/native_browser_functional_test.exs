defmodule Synapsis.Session.NativeBrowserFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.{Browser, DisplayCatalog, Profiles}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::browser"
  @ids ~w(browser-start browser-open browser-mutate browser-snapshot browser-screenshot)
  @mutate """
  async () => {
    window.browserCounter = (window.browserCounter || 0) + 1;
    document.querySelector('#counter').textContent = `Count: ${window.browserCounter}`;
    await fetch('/mutation', {method: 'POST'});
    return {counter: window.browserCounter, text: document.querySelector('#counter').textContent};
  }
  """
  @read "() => ({counter: window.browserCounter, text: document.querySelector('#counter').textContent})"
  @child_prompt "Use a separate browser page for the ordinary child marker"

  test "selected Browser reaches owned Chromium, durable PNG results and restarted Worker replay",
       %{
         tmp_dir: root
       } do
    assert @name in Profiles.supported_names()
    assert length(Profiles.supported_names()) == 57
    assert [%{name: @name}] = Enum.filter(DisplayCatalog.list(), &(&1.name == @name))

    harness = browser_harness(root)
    install_provider(harness, :image_replay)
    start_turn(harness, "Open the local page, increment the counter and inspect its screenshot")

    assert_receive {:browser_request, 0, first}, 5_000
    assert_receive {:browser_descriptor, descriptor}, 5_000
    assert descriptor.backend == Browser
    assert descriptor.codex_exposure == :direct_model_only
    assert [%{"name" => encoded, "input_schema" => schema}] = first["tools"]
    assert ToolName.decode(encoded) == @name
    assert schema == descriptor.schema

    requests =
      for index <- 1..5 do
        receive_request(index)
      end

    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    following = List.last(requests)
    parts = browser_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    target = target_id(following)

    expected_inputs = [
      input("start"),
      input("open", %{"targetUrl" => page_url(harness)}),
      input("act", %{"targetId" => target, "request" => %{"kind" => "evaluate", "fn" => @mutate}}),
      input("snapshot", %{"targetId" => target}),
      input("screenshot", %{"targetId" => target})
    ]

    assert Enum.map(uses, &{&1.tool_use_id, &1.tool, &1.input}) ==
             Enum.zip_with(@ids, expected_inputs, &{&1, @name, &2})

    assert Enum.map(results, & &1.tool_use_id) == @ids
    assert Enum.all?(results, &(&1.is_error == false))

    [started, opened, mutated, snapshot, screenshot] =
      Enum.map(results, & &1.projection["result"])

    assert started["running"] == true
    assert opened["targetId"] == target
    assert opened["url"] == page_url(harness)
    assert mutated["value"] == %{"counter" => 1, "text" => "Count: 1"}
    assert snapshot["snapshot"] =~ "Native Browser fixture"
    assert snapshot["snapshot"] =~ "Count: 1"
    assert screenshot["targetId"] == target
    assert screenshot["type"] == "png"
    assert [text, image] = screenshot["content"]
    assert text["type"] == "text"

    assert Jason.decode!(text["text"]) ==
             Map.take(screenshot, ~w(targetId url type bytes path sha256 media))

    assert image["type"] == "image"
    assert image["data"]["source"] == "base64"
    assert image["data"]["media_type"] == "image/png"
    png = Base.decode64!(image["data"]["data"])
    assert <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>> = png
    assert byte_size(png) == screenshot["bytes"]
    assert byte_size(png) in 1..196_608

    artifact = screenshot["path"]
    artifact_dir = Path.join(root, ".synapsis/browser-files")
    assert Path.dirname(artifact) == artifact_dir
    assert screenshot["media"] == %{"outbound" => false, "mediaUrl" => artifact}
    assert screenshot["sha256"] == Base.encode16(:crypto.hash(:sha256, png), case: :lower)
    assert File.read!(artifact) == png

    for {request, count} <- Enum.with_index(requests, 1) do
      assert_wire_history(request, Enum.take(uses, count), Enum.take(results, count))
    end

    assert_part_round_trips(parts)
    assert_durable_parts(harness.session.id, uses, results)
    assert %{page_loads: 1, tool_executions: 1} = Agent.get(harness.counter, & &1)
    {resource, broker} = browser_resource(harness.session.id)
    owned = owned_processes(broker)

    assert ResourceRegistry.fetch(
             resource.binding.resource_registry,
             resource.profiles["managed"].handle,
             resource.binding.owner_id
           ) == {:ok, broker}

    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5_000
    assert_owned_exited(owned)
    assert File.read!(artifact) == png
    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute new_worker == old_worker

    assert :ok = Worker.send_message(harness.session.id, "Recall the completed browser work")
    replay = receive_request(6)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(replay, uses, results)
    assert browser_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)

    assert %{page_loads: 1, tool_executions: 1, provider_requests: requests} =
             Agent.get(harness.counter, & &1)

    assert length(requests) == 7
    assert File.read!(artifact) == png
    assert File.ls!(artifact_dir) == [Path.basename(artifact)]
    {_resource, restarted_broker} = browser_resource(harness.session.id)
    refute restarted_broker == broker
    assert :sys.get_state(restarted_broker).port == nil
  end

  test "a successful later turn reads the retained session-owned page before Session close", %{
    tmp_dir: root
  } do
    harness = browser_harness(root)
    install_provider(harness, :retained_page)
    start_turn(harness, "Open the local page and increment its counter")

    for index <- 0..3 do
      receive_request(index)
    end

    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    {first_resource, first_broker} = browser_resource(harness.session.id)
    owned = owned_processes(first_broker)
    assert :ok = Worker.send_message(harness.session.id, "Read the same page's retained counter")
    before_read = receive_request(4)
    after_read = receive_request(5)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    {second_resource, second_broker} = browser_resource(harness.session.id)
    assert second_resource.binding.owner_id == first_resource.binding.owner_id
    assert second_resource.binding.incarnation == first_resource.binding.incarnation
    assert second_resource.profiles == first_resource.profiles
    refute second_resource.binding.run_id == first_resource.binding.run_id
    assert second_broker == first_broker
    assert owned_processes(second_broker) == owned

    parts = browser_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == Enum.take(@ids, 3) ++ ["browser-read-retained"]
    assert Enum.map(results, & &1.tool_use_id) == Enum.map(uses, & &1.tool_use_id)
    assert Enum.all?(results, &(&1.is_error == false))

    assert List.last(uses).input ==
             input("act", %{
               "targetId" => target_id(before_read),
               "request" => %{"kind" => "evaluate", "fn" => @read}
             })

    assert List.last(results).projection["result"]["value"] ==
             %{"counter" => 1, "text" => "Count: 1"}

    assert_wire_history(before_read, Enum.take(uses, 3), Enum.take(results, 3))
    assert_wire_history(after_read, uses, results)
    assert_part_round_trips(parts)
    assert_durable_parts(harness.session.id, uses, results)

    assert %{page_loads: 1, tool_executions: 1, provider_requests: requests} =
             Agent.get(harness.counter, & &1)

    assert length(requests) == 6

    assert {:ok, %{status: :confirmed}} = Session.close(second_resource.binding.session)
    assert_owned_exited(owned)
    refute Process.alive?(second_broker)
  end

  test "a real child Session retains a separate Browser page and both owners close their processes",
       %{
         tmp_dir: root
       } do
    harness = browser_harness(root, true)
    install_child_provider(harness)
    start_turn(harness, "Retain the parent browser marker while the child uses its own browser")
    parent_requests = for index <- 0..6, do: receive_child_request(:parent, index)
    child_requests = for index <- 0..5, do: receive_child_request(:child, index)
    assert_receive {:run_event, %{type: "session.completed"}}, 30_000
    parent = List.last(parent_requests)
    child = List.last(child_requests)
    assert receipt(parent, "parent-marker")["value"] == "parent-A"
    assert receipt(parent, "parent-read")["value"] == "parent-A"
    assert receipt(child, "child-initial")["value"] == nil
    assert receipt(child, "child-marker")["value"] == "child-B"
    assert receipt(child, "child-read")["value"] == "child-B"
    assert receipt(parent, "parent-open")["url"] == page_url(harness)
    assert receipt(child, "child-open")["url"] == page_url(harness)
    assert %{page_loads: 2} = Agent.get(harness.counter, & &1)

    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    {_, data} = :sys.get_state(worker, 1_000)
    adapter = :sys.get_state(data.runtime_pid, 1_000)
    assert [child_session] = Map.values(adapter.child_sessions)
    assert map_size(adapter.browser_resources) == 2

    parent_resource =
      Enum.find_value(adapter.browser_resources, fn {_key, resource} ->
        if resource.binding.session == adapter.session, do: resource
      end)

    child_resource =
      Enum.find_value(adapter.browser_resources, fn {_key, resource} ->
        if resource.binding.session == child_session.session, do: resource
      end)

    assert is_map(parent_resource)
    assert is_map(child_resource)
    refute parent_resource.binding.session == child_resource.binding.session
    refute parent_resource.binding.owner_id == child_resource.binding.owner_id
    refute parent_resource.binding.resource_registry == child_resource.binding.resource_registry
    refute parent_resource.profiles["managed"].handle == child_resource.profiles["managed"].handle
    refute parent_resource.profiles["managed"].pid == child_resource.profiles["managed"].pid
    assert Session.status(parent_resource.binding.session).phase == :idle
    assert Session.status(child_resource.binding.session).phase == :idle

    assert [%{name: "/root/browser_child", status: :completed}] =
             Worker.snapshot(harness.session.id).subagents.agents

    owned =
      Enum.map([parent_resource, child_resource], fn resource ->
        profile = resource.profiles["managed"]

        assert {:ok, broker} =
                 ResourceRegistry.fetch(
                   resource.binding.resource_registry,
                   profile.handle,
                   resource.binding.owner_id
                 )

        assert broker == profile.pid
        {broker, owned_processes(broker)}
      end)

    [{_, parent_pids}, {_, child_pids}] = owned
    assert MapSet.disjoint?(MapSet.new(parent_pids), MapSet.new(child_pids))
    assert {:ok, %{status: :confirmed}} = Session.close(parent_resource.binding.session)

    for {broker, pids} <- owned do
      assert_owned_exited(pids)
      refute Process.alive?(broker)
    end

    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
  end

  defp browser_harness(root, subagents? \\ false) do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => subagents?, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    Agent.update(harness.counter, &Map.put(&1, :page_loads, 0))
    repository = Path.expand("../../../../..", __DIR__)

    browser_config = %{
      "default_profile" => "managed",
      "node_executable" => System.find_executable("node"),
      "helper_path" => Path.join(repository, "packages/tool-host/src/browser/stdio.mjs"),
      "profiles" => %{
        "managed" => %{
          "driver" => "managed-host",
          "target" => "host",
          "executable" => "/run/current-system/sw/bin/chromium",
          "data_dir" => Path.join(root, "browser-data"),
          "timeout_ms" => 15_000,
          "max_image_bytes" => 196_608
        }
      }
    }

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{
               tools: if(subagents?, do: [@name, "spawn_agent", "wait_agent"], else: [@name]),
               config: Map.put(harness.agent_config.config, "browser", browser_config)
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
      |> Plug.Conn.resp(
        200,
        "<!doctype html><html><head><title>Native Browser fixture</title></head><body><h1>Native Browser fixture</h1><p id='counter'>Count: 0</p></body></html>"
      )
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/mutation", fn conn ->
      Agent.update(harness.counter, &%{&1 | tool_executions: &1.tool_executions + 1})
      Plug.Conn.resp(conn, 200, "recorded")
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/favicon.ico", &Plug.Conn.resp(&1, 204, ""))
    harness
  end

  defp install_provider(harness, scenario) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:browser_request, index, request})

      if index == 0 do
        [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
        {_, data} = :sys.get_state(worker, 1_000)
        runtime = :sys.get_state(data.runtime_pid, 1_000)

        send(
          owner,
          {:browser_descriptor, :sys.get_state(runtime.root, 1_000).catalog.registry.tools[@name]}
        )
      end

      call =
        case {index, scenario, successful_results?(request)} do
          {_, _, false} ->
            nil

          {0, _, true} ->
            {hd(@ids), input("start")}

          {1, _, true} ->
            {Enum.at(@ids, 1), input("open", %{"targetUrl" => page_url(harness)})}

          {2, _, true} ->
            {Enum.at(@ids, 2),
             input("act", %{
               "targetId" => target_id(request),
               "request" => %{"kind" => "evaluate", "fn" => @mutate}
             })}

          {3, :image_replay, true} ->
            {Enum.at(@ids, 3), input("snapshot", %{"targetId" => target_id(request)})}

          {4, :image_replay, true} ->
            {Enum.at(@ids, 4), input("screenshot", %{"targetId" => target_id(request)})}

          {4, :retained_page, true} ->
            {"browser-read-retained",
             input("act", %{
               "targetId" => target_id(request),
               "request" => %{"kind" => "evaluate", "fn" => @read}
             })}

          _ ->
            nil
        end

      provider_response(conn, call)
    end)
  end

  defp start_turn(harness, prompt) do
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, prompt)
  end

  defp install_child_provider(harness) do
    owner = self()
    Agent.update(harness.counter, &Map.put(&1, :browser_requests, %{parent: 0, child: 0}))

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      role =
        if Enum.any?(request["messages"], fn message ->
             message["role"] == "user" and
               case message["content"] do
                 text when is_binary(text) ->
                   text == @child_prompt

                 parts when is_list(parts) ->
                   Enum.map_join(parts, &(&1["text"] || "")) == @child_prompt
               end
           end),
           do: :child,
           else: :parent

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {state.browser_requests[role],
           %{
             state
             | browser_requests: Map.update!(state.browser_requests, role, &(&1 + 1)),
               provider_requests: state.provider_requests ++ [request]
           }}
        end)

      send(owner, {:browser_child_request, role, index, request})

      call =
        case {role, index, successful_results?(request)} do
          {_, _, false} ->
            nil

          {:parent, 0, true} ->
            {"parent-start", input("start")}

          {:parent, 1, true} ->
            {"parent-open", input("open", %{"targetUrl" => page_url(harness)})}

          {:parent, 2, true} ->
            {"parent-marker",
             evaluate(
               request,
               "parent-open",
               "() => { window.browserMarker = 'parent-A'; return window.browserMarker; }"
             )}

          {:parent, 3, true} ->
            {"parent-spawn", "spawn_agent",
             %{"task_name" => "browser_child", "message" => @child_prompt, "fork_turns" => "none"}}

          {:parent, 4, true} ->
            {"parent-wait", "wait_agent", %{"timeout_ms" => 15_000}}

          {:parent, 5, true} ->
            {"parent-read", evaluate(request, "parent-open", "() => window.browserMarker")}

          {:child, 0, true} ->
            {"child-start", input("start")}

          {:child, 1, true} ->
            {"child-open", input("open", %{"targetUrl" => page_url(harness)})}

          {:child, 2, true} ->
            {"child-initial",
             evaluate(request, "child-open", "() => window.browserMarker ?? null")}

          {:child, 3, true} ->
            {"child-marker",
             evaluate(
               request,
               "child-open",
               "() => { window.browserMarker = 'child-B'; return window.browserMarker; }"
             )}

          {:child, 4, true} ->
            {"child-read", evaluate(request, "child-open", "() => window.browserMarker")}

          _ ->
            nil
        end

      provider_response(conn, call)
    end)
  end

  defp evaluate(request, open_id, function),
    do:
      input("act", %{
        "targetId" => target_id(request, open_id),
        "request" => %{"kind" => "evaluate", "fn" => function}
      })

  defp receive_child_request(role, index) do
    assert_receive {:browser_child_request, ^role, ^index, request}, 20_000

    assert successful_results?(request),
           "#{role} Browser failed before request #{index}: #{inspect(blocks(request))}"

    request
  end

  defp input(action, args \\ %{}),
    do: %{"action" => action, "args" => args, "profile" => "managed", "timeout_ms" => 15_000}

  defp page_url(harness), do: Gaoxy.Test.url(harness.provider.fixture, "/page")

  defp blocks(request),
    do: Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

  defp successful_results?(request),
    do: Enum.all?(blocks(request), &(&1["type"] != "tool_result" or &1["is_error"] == false))

  defp receive_request(index) do
    assert_receive {:browser_request, ^index, request}, 20_000

    assert successful_results?(request),
           "Browser failed before provider request #{index}: #{inspect(blocks(request))}"

    request
  end

  defp target_id(request, id \\ "browser-open"), do: receipt(request, id)["targetId"]

  defp receipt(request, id) do
    result =
      Enum.find(
        blocks(request),
        &(&1["type"] == "tool_result" and &1["tool_use_id"] == id)
      )

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
    call =
      case call do
        {id, input} -> {id, @name, input}
        other -> other
      end

    {content, delta, stop} =
      case call do
        {id, name, input} ->
          {%{"type" => "tool_use", "id" => id, "name" => ToolName.encode(name), "input" => %{}},
           %{"type" => "input_json_delta", "partial_json" => Jason.encode!(input)}, "tool_use"}

        nil ->
          {%{"type" => "text", "text" => ""},
           %{"type" => "text_delta", "text" => "Browser inspected"}, "end_turn"}
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
