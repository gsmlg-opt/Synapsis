defmodule Synapsis.Session.NativeBrowserObservationFunctionalTest do
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
  @ids ~w(observation-start observation-open observation-ready observation-console
          observation-requests observation-errors observation-text observation-emulate
          observation-environment observation-dialog observation-prompt observation-final-text
          observation-pending-prompt observation-accept-pending observation-finish-pending)
  @environment """
  () => ({width: innerWidth, height: innerHeight, dpr: devicePixelRatio,
    coarse: matchMedia('(pointer: coarse)').matches,
    dark: matchMedia('(prefers-color-scheme: dark)').matches,
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    locale: Intl.DateTimeFormat().resolvedOptions().locale})
  """
  @prompt """
  async () => {
    window.promptExecutions = (window.promptExecutions || 0) + 1;
    const answer = prompt('Observation name', 'default name');
    document.querySelector('#dialog-result').textContent = `Accepted: ${answer}`;
    await fetch('/prompt-observed', {method: 'POST'});
    return {answer, executions: window.promptExecutions,
      text: document.querySelector('#dialog-result').textContent};
  }
  """

  @pending_prompt """
  async () => {
    window.pendingPromptExecutions = (window.pendingPromptExecutions || 0) + 1;
    window.pendingPromptDone = new Promise(resolve => window.recordPendingPrompt = resolve);
    const answer = prompt('Continue the native observation', 'waiting name');
    await new Promise(resolve => window.finishPendingPrompt = resolve);
    document.querySelector('#pending-result').textContent = `Continued: ${answer}`;
    await fetch('/pending-observed', {method: 'POST'});
    const result = {answer, executions: window.pendingPromptExecutions,
      text: document.querySelector('#pending-result').textContent};
    window.recordPendingPrompt(result);
    return result;
  }
  """
  @finish_pending """
  async () => {
    const before = document.querySelector('#pending-result').textContent;
    window.finishPendingPrompt();
    const result = await window.pendingPromptDone;
    return {before, ...result};
  }
  """

  test "six Browser observation actions reach the model, durable history and Worker restart replay",
       %{
         tmp_dir: root
       } do
    harness = browser_harness(root)
    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok =
             Worker.send_message(
               harness.session.id,
               "Observe the local browser page and answer its prompt"
             )

    requests = for index <- 0..15, do: receive_request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000

    assert [%{"input_schema" => %{"properties" => %{"action" => %{"enum" => actions}}}}] =
             hd(requests)["tools"]

    assert Enum.all?(~w(console requests errors text emulate dialog), &(&1 in actions))
    following = List.last(requests)
    target = target_id(following)
    parts = browser_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == @ids
    assert Enum.map(results, & &1.tool_use_id) == @ids
    assert Enum.all?(results, &(&1.is_error == false))
    assert Enum.all?(uses, &(&1.tool == @name))

    assert Enum.map(uses, & &1.input) ==
             for(index <- 0..14, do: call_input(index, following, harness))

    console = receipt(following, "observation-console")
    assert console["targetId"] == target

    assert Enum.any?(
             console["messages"],
             &(&1["type"] == "info" and &1["text"] == "native-observation-console")
           )

    assert console["returned"] == length(console["messages"])
    assert console["truncated"] == false

    network = receipt(following, "observation-requests")
    assert network["targetId"] == target

    assert [%{"url" => observed_url, "method" => "POST", "status" => 200, "ok" => true}] =
             Enum.map(network["requests"], &Map.take(&1, ~w(url method status ok)))

    assert observed_url == Gaoxy.Test.url(harness.provider.fixture, "/page-observed")

    errors = receipt(following, "observation-errors")
    assert errors["targetId"] == target

    assert Enum.any?(
             errors["errors"],
             &(&1["name"] == "Error" and &1["message"] == "native-observation-page-error")
           )

    assert Enum.any?(errors["errors"], &String.contains?(&1["stack"], "/page"))

    assert %{
             "ok" => true,
             "text" => "Observation prose for the native model.",
             "truncated" => false
           } =
             receipt(following, "observation-text")

    assert %{"ok" => true, "applied" => ["device", "colorScheme", "timezoneId", "locale"]} =
             receipt(following, "observation-emulate")

    assert receipt(following, "observation-environment")["value"] == %{
             "width" => 390,
             "height" => 664,
             "dpr" => 3,
             "coarse" => true,
             "dark" => true,
             "timezone" => "Asia/Tokyo",
             "locale" => "fr-FR"
           }

    assert %{"ok" => true, "armed" => true} = receipt(following, "observation-dialog")

    assert receipt(following, "observation-prompt")["value"] == %{
             "answer" => "native accepted",
             "executions" => 1,
             "text" => "Accepted: native accepted"
           }

    assert %{"text" => "Accepted: native accepted", "truncated" => false} =
             receipt(following, "observation-final-text")

    pending = receipt(following, "observation-pending-prompt")
    assert pending["dialogPending"] == true
    assert [dialog] = pending["browserState"]["dialogs"]["pending"]
    assert dialog["type"] == "prompt"
    assert dialog["message"] == "Continue the native observation"
    assert dialog["defaultValue"] == "waiting name"
    assert [pending_action] = pending["browserState"]["pendingActions"]
    assert Enum.sort(Map.keys(pending_action)) == ~w(deadline id)
    assert is_binary(pending_action["id"])
    assert {:ok, _, 0} = DateTime.from_iso8601(pending_action["deadline"])
    assert pending["browserState"]["pendingActionLimit"] == 8
    assert pending["browserState"]["capacityAvailable"] == 7

    accepted = receipt(following, "observation-accept-pending")
    assert accepted["ok"] == true
    assert accepted["armed"] == false
    assert accepted["dialogId"] == dialog["id"]
    assert accepted["browserState"]["dialogs"]["pending"] == []
    assert accepted["browserState"]["pendingActions"] == [pending_action]

    assert Enum.any?(
             accepted["browserState"]["dialogs"]["recent"],
             &(&1["id"] == dialog["id"] and &1["closedBy"] == "handled")
           )

    assert receipt(following, "observation-finish-pending")["value"] == %{
             "before" => "Waiting for continuation",
             "answer" => "native continuation",
             "executions" => 1,
             "text" => "Continued: native continuation"
           }

    assert_receive {:pending_browser_owner, 13, before_resource, before_broker, before_owned,
                    before_counts}

    assert_receive {:pending_browser_owner, 14, after_resource, after_broker, after_owned,
                    after_counts}

    assert before_resource.binding.session == after_resource.binding.session
    assert before_resource.binding.owner_id == after_resource.binding.owner_id
    assert before_resource.binding.incarnation == after_resource.binding.incarnation
    assert before_resource.binding.resource_registry == after_resource.binding.resource_registry
    assert before_resource.profiles == after_resource.profiles
    assert before_broker == after_broker
    assert before_owned == after_owned
    assert before_counts == %{pending_prompt_submissions: 0, tool_executions: 1}
    assert after_counts == before_counts

    for {request, count} <- Enum.with_index(tl(requests), 1) do
      assert_wire_history(request, Enum.take(uses, count), Enum.take(results, count))
    end

    assert_part_round_trips(parts)
    assert_durable_parts(harness.session.id, uses, results)

    assert %{
             page_loads: 1,
             page_observations: 1,
             tool_executions: 1,
             pending_prompt_submissions: 1
           } =
             Agent.get(harness.counter, & &1)

    {resource, broker} = browser_resource(harness.session.id)
    owned = owned_processes(broker)
    assert broker == before_broker
    assert owned == before_owned

    assert {:ok, ^broker} =
             ResourceRegistry.fetch(
               resource.binding.resource_registry,
               resource.profiles["managed"].handle,
               resource.binding.owner_id
             )

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
               "Recall the completed observations without repeating them"
             )

    replay = receive_request(16)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(replay, uses, results)
    assert browser_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)

    assert %{
             page_loads: 1,
             page_observations: 1,
             tool_executions: 1,
             pending_prompt_submissions: 1,
             provider_requests: recorded
           } =
             Agent.get(harness.counter, & &1)

    assert length(recorded) == 17
    {_resource, restarted_broker} = browser_resource(harness.session.id)
    refute restarted_broker == broker
    assert :sys.get_state(restarted_broker).port == nil
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
      &Map.merge(&1, %{page_loads: 0, page_observations: 0, pending_prompt_submissions: 0})
    )

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
          "timeout_ms" => 15_000
        }
      }
    }

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{
               tools: [@name],
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
      |> Plug.Conn.resp(200, """
      <!doctype html><html><head><title>Native observations</title>
      <meta name="viewport" content="width=device-width,initial-scale=1"></head><body>
      <article id="prose">Observation prose for the native model.</article>
      <p id="dialog-result">Awaiting prompt</p>
      <p id="pending-result">Waiting for continuation</p>
      <script>console.info('native-observation-console');
      window.fixtureReady = fetch('/page-observed', {method:'POST'}).then(r => r.text());</script>
      <script>throw new Error('native-observation-page-error');</script>
      </body></html>
      """)
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/page-observed", fn conn ->
      Agent.update(harness.counter, &%{&1 | page_observations: &1.page_observations + 1})
      Plug.Conn.resp(conn, 200, "page observation complete")
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/prompt-observed", fn conn ->
      Agent.update(harness.counter, &%{&1 | tool_executions: &1.tool_executions + 1})
      Plug.Conn.resp(conn, 200, "prompt observation complete")
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/pending-observed", fn conn ->
      Agent.update(
        harness.counter,
        &%{&1 | pending_prompt_submissions: &1.pending_prompt_submissions + 1}
      )

      Plug.Conn.resp(conn, 200, "pending prompt continuation complete")
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

      send(owner, {:browser_observation_request, index, request})

      if index in [13, 14] and successful_results?(request) do
        {resource, broker} = browser_resource(harness.session.id)

        counts =
          Agent.get(
            harness.counter,
            &Map.take(&1, [:pending_prompt_submissions, :tool_executions])
          )

        send(
          owner,
          {:pending_browser_owner, index, resource, broker, owned_processes(broker), counts}
        )
      end

      call =
        if index < 15 and successful_results?(request),
          do: {Enum.at(@ids, index), call_input(index, request, harness)}

      provider_response(conn, call)
    end)
  end

  defp call_input(0, _request, _harness), do: input("start")
  defp call_input(1, _request, harness), do: input("open", %{"targetUrl" => page_url(harness)})

  defp call_input(index, request, _harness) do
    args = %{"targetId" => target_id(request)}

    {action, extra} =
      case index do
        2 ->
          {"act",
           %{
             "request" => %{
               "kind" => "evaluate",
               "fn" => "async () => { await window.fixtureReady; return document.readyState; }"
             }
           }}

        3 ->
          {"console", %{"level" => "info", "limit" => 20}}

        4 ->
          {"requests", %{"filter" => "/page-observed", "limit" => 20}}

        5 ->
          {"errors", %{"limit" => 20}}

        6 ->
          {"text", %{"selector" => "#prose", "maxChars" => 1000}}

        7 ->
          {"emulate",
           %{
             "device" => "iPhone 13",
             "colorScheme" => "dark",
             "timezoneId" => "Asia/Tokyo",
             "locale" => "fr-FR"
           }}

        8 ->
          {"act", %{"request" => %{"kind" => "evaluate", "fn" => @environment}}}

        9 ->
          {"dialog",
           %{"accept" => true, "promptText" => "native accepted", "timeoutMs" => 15_000}}

        10 ->
          {"act", %{"request" => %{"kind" => "evaluate", "fn" => @prompt}}}

        11 ->
          {"text", %{"selector" => "#dialog-result", "maxChars" => 1000}}

        12 ->
          {"act", %{"request" => %{"kind" => "evaluate", "fn" => @pending_prompt}}}

        13 ->
          [dialog] =
            receipt(request, "observation-pending-prompt")["browserState"]["dialogs"]["pending"]

          {"dialog",
           %{"accept" => true, "promptText" => "native continuation", "dialogId" => dialog["id"]}}

        14 ->
          {"act", %{"request" => %{"kind" => "evaluate", "fn" => @finish_pending}}}
      end

    input(action, Map.merge(args, extra))
  end

  defp input(action, args \\ %{}),
    do: %{"action" => action, "args" => args, "profile" => "managed", "timeout_ms" => 15_000}

  defp page_url(harness), do: Gaoxy.Test.url(harness.provider.fixture, "/page")

  defp blocks(request),
    do: Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

  defp successful_results?(request),
    do: Enum.all?(blocks(request), &(&1["type"] != "tool_result" or &1["is_error"] == false))

  defp receive_request(index) do
    assert_receive {:browser_observation_request, ^index, request}, 20_000

    assert successful_results?(request),
           "Browser failed before provider request #{index}: #{inspect(blocks(request))}"

    request
  end

  defp target_id(request, id \\ "observation-open"), do: receipt(request, id)["targetId"]

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
