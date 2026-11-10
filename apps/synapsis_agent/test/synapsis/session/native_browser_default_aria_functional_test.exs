defmodule Synapsis.Session.NativeBrowserDefaultAriaFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::browser"
  @ids ~w(default-start default-open default-ready default-capture default-repeat default-act default-proof)

  test "default page-wide refs drive real native actions, provider history, Concord and ordinary Worker replay",
       %{tmp_dir: root} do
    harness = browser_harness(root)
    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok =
             Worker.send_message(
               harness.session.id,
               "Inspect and use the default local Browser snapshot"
             )

    initial = for index <- 0..5, do: receive_request(index)
    # End normally on the old missing child ref. Never issue an undefined ref or
    # convert the dispatch regression into a provider timeout/fixture exception.
    complete? = actionable_page?(List.last(initial))

    requests =
      if complete?, do: initial ++ for(index <- 6..7, do: receive_request(index)), else: initial

    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    final = List.last(requests)
    first = receipt(final, "default-capture")
    repeated = receipt(final, "default-repeat")
    expected_ids = if complete?, do: @ids, else: Enum.take(@ids, 5)

    descriptor = Enum.find(hd(requests)["tools"], &(&1["name"] == ToolName.encode(@name)))
    assert is_map(descriptor)
    parts = browser_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == expected_ids
    assert Enum.map(results, & &1.tool_use_id) == expected_ids
    assert Enum.all?(uses, &(&1.tool == @name))
    assert Enum.all?(results, &(&1.is_error == false))

    assert Enum.map(uses, & &1.input) ==
             for(index <- 0..(length(expected_ids) - 1), do: call_input(index, final, harness))

    for {request, count} <- Enum.with_index(requests) do
      assert_wire_history(request, Enum.take(uses, count), Enum.take(results, count))
    end

    for result <- results do
      assert %{"version" => 1, "result" => projected} = result.projection
      assert result.content == projected["content"]
      assert Jason.decode!(result.content) == receipt(final, result.tool_use_id)
      assert projected["structured"] == receipt(final, result.tool_use_id)
      assert projected["is_error"] == false
    end

    assert_part_round_trips(parts)
    assert_durable_parts(harness.session.id, uses, results)
    assert_effect_counts(harness, complete?)
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
             Worker.send_message(
               harness.session.id,
               "Recall the completed default Browser actions"
             )

    replay = receive_request(length(requests))
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(replay, uses, results)
    assert browser_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)
    assert_effect_counts(harness, complete?)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == length(requests) + 1
    {_resource, replay_broker} = browser_resource(harness.session.id)
    refute replay_broker == broker
    assert :sys.get_state(replay_broker).port == nil
    replay_monitor = Process.monitor(new_worker)
    replay_broker_monitor = Process.monitor(replay_broker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^replay_monitor, :process, ^new_worker, _}, 5_000
    # Normal registered Session cleanup closes and terminates the dormant broker.
    assert_receive {:DOWN, ^replay_broker_monitor, :process, ^replay_broker, :shutdown}, 5_000
    refute Process.alive?(replay_broker)

    # Assert the real behavior only after the ordinary turn and owned cleanup.
    assert_snapshot(first, target_id(final))
    assert_snapshot(repeated, target_id(final))
    refute Map.has_key?(first, "newElements")
    assert repeated["newElements"] == 0
    assert repeated["snapshotGeneration"] > first["snapshotGeneration"]
    assert repeated["documentGeneration"] == first["documentGeneration"]

    assert Enum.all?(repeated["refs"], fn ref ->
             Enum.all?(first["refs"], &(&1["ref"] != ref["ref"]))
           end)

    assert complete?

    assert %{"results" => [%{"ok" => true}, %{"ok" => true}, %{"ok" => true}, %{"ok" => true}]} =
             receipt(final, "default-act")

    assert receipt(final, "default-proof")["value"] == %{
             "main" => [1, "Main filled"],
             "shadow" => [1, "Shadow filled"],
             "child" => [1, "Child filled"]
           }
  end

  defp assert_snapshot(snapshot, target) do
    assert %{"targetId" => ^target, "format" => "ai", "refsType" => "aria", "truncated" => false} =
             snapshot

    assert snapshot["semantics"] =~ "Page-wide public Playwright AI YAML"
    assert snapshot["refCount"] == length(snapshot["refs"])
    assert is_integer(snapshot["documentGeneration"])
    assert is_integer(snapshot["snapshotGeneration"])

    for name <- ~w(Main Shadow Child), role <- ~w(button textbox) do
      suffix = if role == "button", do: "action", else: "field"

      assert Enum.any?(
               snapshot["refs"],
               &(&1["role"] == role and &1["name"] == "#{name} #{suffix}")
             )
    end

    for ref <- snapshot["refs"] do
      assert Enum.sort(Map.keys(ref)) == ~w(name ref role)
      assert ref["ref"] =~ ~r/^e\d+$/
      assert snapshot["snapshot"] =~ "[ref=#{ref["ref"]}]"
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

    Agent.update(
      harness.counter,
      &Map.merge(&1, %{page_loads: 0, frame_loads: 0, frame_effects: 0, provider_completed: false})
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
          "executable" =>
            System.get_env("SYNAPSIS_TEST_CHROMIUM", "/run/current-system/sw/bin/chromium"),
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
      <!doctype html><title>Default native source</title><h2>Ordinary page-wide controls</h2>
      <label>Main field<input id="main-field" value="Main initial"></label>
      <button onclick="window.mainClicks=(window.mainClicks||0)+1">Main action</button>
      <div id="shadow"></div><iframe id="child" title="Child controls" src="/frame"></iframe>
      <script>document.querySelector('#shadow').attachShadow({mode:'open'}).innerHTML='<label>Shadow field<input value="Shadow initial"></label><button onclick="window.shadowClicks=(window.shadowClicks||0)+1">Shadow action</button>';</script>
      """)
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/frame", fn conn ->
      Agent.update(harness.counter, &%{&1 | frame_loads: &1.frame_loads + 1})

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, """
      <!doctype html><title>Child source</title><label>Child field<input value="Child initial"></label>
      <button onclick="window.childClicks=(window.childClicks||0)+1;window.effect=fetch('/frame-effect',{method:'POST'})">Child action</button>
      """)
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/frame-effect", fn conn ->
      Agent.update(harness.counter, &%{&1 | frame_effects: &1.frame_effects + 1})
      Plug.Conn.resp(conn, 200, "child effect recorded")
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/favicon.ico", &Plug.Conn.resp(&1, 204, ""))
    harness
  end

  defp install_provider(harness) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      {index, completed?} =
        Agent.get_and_update(harness.counter, fn state ->
          {{length(state.provider_requests), state.provider_completed},
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:browser_default_request, index, request})

      call =
        cond do
          completed? -> nil
          not successful_results?(request) -> nil
          index >= length(@ids) -> nil
          index == 5 and not actionable_page?(request) -> nil
          true -> {Enum.at(@ids, index), call_input(index, request, harness)}
        end

      if is_nil(call), do: Agent.update(harness.counter, &%{&1 | provider_completed: true})
      provider_response(conn, call)
    end)
  end

  defp call_input(0, _request, _harness), do: input("start")

  defp call_input(1, _request, harness),
    do: input("open", %{"targetUrl" => Gaoxy.Test.url(harness.provider.fixture, "/page")})

  defp call_input(2, request, _harness),
    do: act(request, %{"kind" => "wait", "loadState" => "load"})

  defp call_input(3, request, _harness),
    do: input("snapshot", %{"targetId" => target_id(request), "snapshotFormat" => "ai"})

  defp call_input(4, request, _harness),
    do: input("snapshot", %{"targetId" => target_id(request)})

  defp call_input(5, request, _harness) do
    act(request, %{
      "kind" => "batch",
      "actions" => [
        %{
          "kind" => "fill",
          "fields" =>
            for(
              name <- ~w(Main Shadow Child),
              do: %{
                "ref" => page_ref(request, "textbox", "#{name} field"),
                "value" => "#{name} filled"
              }
            )
        }
        | for(
            name <- ~w(Main Shadow Child),
            do: %{"kind" => "click", "ref" => page_ref(request, "button", "#{name} action")}
          )
      ]
    })
  end

  defp call_input(6, request, _harness) do
    act(request, %{
      "kind" => "evaluate",
      "fn" => """
      async () => {
        const child = document.querySelector('#child').contentWindow;
        await child.effect;
        return {main:[window.mainClicks,document.querySelector('#main-field').value],
          shadow:[window.shadowClicks,document.querySelector('#shadow').shadowRoot.querySelector('input').value],
          child:[child.childClicks,child.document.querySelector('input').value]};
      }
      """
    })
  end

  defp actionable_page?(request) do
    snapshot = receipt(request, "default-repeat")

    Enum.all?(
      for(
        name <- ~w(Main Shadow Child),
        role <- ~w(button textbox),
        do: {role, "#{name} #{if role == "button", do: "action", else: "field"}"}
      ),
      fn {role, name} ->
        Enum.any?(snapshot["refs"], &(&1["role"] == role and &1["name"] == name))
      end
    )
  end

  defp page_ref(request, role, name),
    do:
      receipt(request, "default-repeat")["refs"]
      |> Enum.find(&(&1["role"] == role and &1["name"] == name))
      |> Map.fetch!("ref")

  defp act(request, action),
    do: input("act", %{"targetId" => target_id(request), "request" => action})

  defp input(action, args \\ %{}),
    do: %{"action" => action, "args" => args, "profile" => "managed", "timeout_ms" => 15_000}

  defp assert_effect_counts(harness, complete?) do
    expected_effects = if complete?, do: 1, else: 0

    assert %{page_loads: 1, frame_loads: 1, frame_effects: ^expected_effects} =
             Agent.get(harness.counter, & &1)
  end

  defp blocks(request),
    do: Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

  defp successful_results?(request),
    do: Enum.all?(blocks(request), &(&1["type"] != "tool_result" or &1["is_error"] == false))

  defp receive_request(index) do
    assert_receive {:browser_default_request, ^index, request}, 20_000

    assert successful_results?(request),
           "Browser failed before provider request #{index}: #{inspect(blocks(request))}"

    request
  end

  defp target_id(request), do: receipt(request, "default-open")["targetId"]

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
           %{"type" => "text_delta", "text" => "Default page-wide Browser inspected"}, "end_turn"}
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
