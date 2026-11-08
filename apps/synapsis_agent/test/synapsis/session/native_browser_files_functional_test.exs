defmodule Synapsis.Session.NativeBrowserFilesFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.ResourceRegistry
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::browser"
  @ids ~w(files-start files-open files-snapshot files-pdf-explicit files-pdf-default
          files-download files-schedule-default files-wait-default files-schedule-explicit
          files-wait-explicit files-upload-element files-read-element files-upload-input-ref
          files-read-input-ref files-upload-ref files-read-ref files-upload-arm
          files-click-chooser files-read-passive files-read-retained)
  @download "Native Browser download fixture.\n"
  @uploads [
    %{"name" => "native-first.txt", "type" => "text/plain", "text" => "First native upload.\n"},
    %{"name" => "native-second.txt", "type" => "text/plain", "text" => "Second native upload.\n"}
  ]
  @read_uploads """
  async () => {
    await window.waitForUploads(__UPLOAD_COUNT__);
    const inputs = {};
    for (const id of ['direct-file', 'reference-file', 'atomic-file', 'passive-file']) {
      inputs[id] = await Promise.all([...document.getElementById(id).files].map(async file =>
        ({name: file.name, type: file.type, size: file.size, text: await file.text()})));
    }
    return {inputs, changes: window.uploadChanges};
  }
  """

  test "Browser files reach the model and durable history, retain their owner and survive restart",
       %{tmp_dir: root} do
    harness = browser_harness(root)
    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Save browser files and upload fixtures")

    requests = for index <- 0..19, do: receive_request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000

    assert [%{"input_schema" => %{"properties" => %{"action" => %{"enum" => actions}}}}] =
             hd(requests)["tools"]

    assert length(actions) == 23
    assert Enum.all?(~w(pdf download waitfordownload upload), &(&1 in actions))
    following = List.last(requests)
    target = target_id(following)

    saved =
      for id <-
            ~w(files-pdf-explicit files-pdf-default files-download files-wait-default files-wait-explicit) do
        result = receipt(following, id)
        assert result["ok"] == true
        assert result["targetId"] == target
        assert result["url"] == page_url(harness)
        bytes = File.read!(result["path"])
        assert result["bytes"] == byte_size(bytes)
        assert result["sha256"] == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

        if id in ~w(files-pdf-explicit files-pdf-default) do
          assert <<"%PDF-", _::binary>> = bytes
          assert String.contains?(bytes, "%%EOF")
          assert result["mimeType"] == "application/pdf"
        else
          assert bytes == @download
          assert result["suggestedFilename"] == "native-fixture.txt"
        end

        {result["path"], bytes}
      end

    assert receipt(following, "files-pdf-explicit")["path"] ==
             Path.join(root, "saved/explicit.pdf")

    assert receipt(following, "files-download")["path"] == Path.join(root, "saved/clicked.txt")

    assert receipt(following, "files-wait-explicit")["path"] ==
             Path.join(root, "saved/waited.txt")

    for id <- ~w(files-pdf-default files-wait-default) do
      path = receipt(following, id)["path"]
      assert Path.dirname(path) == Path.join(root, ".synapsis/browser-files")
      assert Path.basename(path) =~ ~r/^[0-9a-f-]{36}\./
    end

    assert length(Enum.uniq(Enum.map(saved, &elem(&1, 0)))) == 5

    for {id, input_id, changes} <- [
          {"files-read-element", "direct-file", 1},
          {"files-read-input-ref", "reference-file", 2},
          {"files-read-ref", "atomic-file", 3},
          {"files-read-passive", "passive-file", 4}
        ] do
      value = receipt(following, id)["value"]
      assert value["changes"] == changes
      assert value["inputs"][input_id] == upload_values()
    end

    for id <- ~w(files-upload-element files-upload-input-ref files-upload-ref) do
      result = receipt(following, id)
      assert result["ok"] == true
      assert result["armed"] == false
      assert result["targetId"] == target

      assert %{"id" => upload_id, "state" => "completed", "fileCount" => 2} =
               result["browserState"]["upload"]["current"]

      assert result["uploadId"] == upload_id
    end

    armed = receipt(following, "files-upload-arm")
    assert %{"ok" => true, "armed" => true} = armed

    assert %{"id" => passive_id, "state" => "armed", "deadline" => deadline, "fileCount" => 2} =
             armed["browserState"]["upload"]["current"]

    assert armed["uploadId"] == passive_id
    assert armed["expiresAt"] == deadline
    assert {:ok, _, 0} = DateTime.from_iso8601(deadline)
    completed = receipt(following, "files-read-passive")["browserState"]["upload"]
    assert %{"id" => ^passive_id, "state" => "completed", "fileCount" => 2} = completed["current"]

    assert Enum.map(completed["recent"], & &1["id"]) ==
             for(
               id <- ~w(files-upload-element files-upload-input-ref files-upload-ref),
               do: receipt(following, id)["uploadId"]
             )

    assert Enum.all?(completed["recent"], &(&1["state"] == "completed"))
    {first_resource, broker} = browser_resource(harness.session.id)
    owned = owned_processes(broker)

    assert {:ok, ^broker} =
             ResourceRegistry.fetch(
               first_resource.binding.resource_registry,
               first_resource.profiles["managed"].handle,
               first_resource.binding.owner_id
             )

    assert :ok = Worker.send_message(harness.session.id, "Read the retained uploaded Files")
    before_read = receive_request(20)
    after_read = receive_request(21)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    {second_resource, second_broker} = browser_resource(harness.session.id)
    assert second_resource.binding.session == first_resource.binding.session
    assert second_resource.binding.owner_id == first_resource.binding.owner_id
    assert second_resource.binding.incarnation == first_resource.binding.incarnation
    assert second_resource.profiles == first_resource.profiles
    assert second_broker == broker
    assert owned_processes(second_broker) == owned

    assert receipt(after_read, "files-read-retained")["value"] ==
             receipt(following, "files-read-passive")["value"]

    parts = browser_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == @ids
    assert Enum.map(results, & &1.tool_use_id) == @ids
    assert Enum.all?(uses, &(&1.tool == @name))
    assert Enum.all?(results, &(&1.is_error == false))

    assert Enum.map(uses, & &1.input) ==
             for(index <- 0..18, do: call_input(index, following, harness)) ++
               [call_input(20, after_read, harness)]

    for {request, count} <- Enum.with_index(tl(requests), 1) do
      assert_wire_history(request, Enum.take(uses, count), Enum.take(results, count))
    end

    assert_wire_history(before_read, Enum.take(uses, 19), Enum.take(results, 19))
    assert_wire_history(after_read, uses, results)
    assert_part_round_trips(parts)
    assert_durable_parts(harness.session.id, uses, results)
    assert %{page_loads: 1, downloads: 3, tool_executions: 4} = Agent.get(harness.counter, & &1)

    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5_000
    assert_owned_exited(owned)
    refute Process.alive?(broker)
    for {path, bytes} <- saved, do: assert(File.read!(path) == bytes)
    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute new_worker == old_worker

    assert :ok =
             Worker.send_message(harness.session.id, "Recall saved files without browser work")

    replay = receive_request(22)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(replay, uses, results)
    assert browser_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)
    for {path, bytes} <- saved, do: assert(File.read!(path) == bytes)

    assert %{page_loads: 1, downloads: 3, tool_executions: 4, provider_requests: recorded} =
             Agent.get(harness.counter, & &1)

    assert length(recorded) == 23
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
    Agent.update(harness.counter, &Map.merge(&1, %{page_loads: 0, downloads: 0}))
    for file <- @uploads, do: File.write!(Path.join(root, file["name"]), file["text"])
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
      <!doctype html><html><head><title>Native Browser files</title></head><body>
      <h1>Native Browser files fixture</h1>
      <a id="download" href="/download" download="native-fixture.txt">Download fixture</a>
      <input id="direct-file" type="file" multiple aria-label="Direct upload">
      <input id="reference-file" type="file" multiple aria-label="Reference upload">
      <input id="atomic-file" type="file" multiple style="display:none">
      <input id="passive-file" type="file" multiple style="display:none">
      <button onclick="document.getElementById('atomic-file').click()">Atomic chooser</button>
      <button onclick="document.getElementById('passive-file').click()">Passive chooser</button>
      <script>
      window.uploadChanges = 0;
      window.completedUploads = 0;
      window.uploadWaiters = [];
      window.waitForUploads = count => window.completedUploads >= count ? Promise.resolve() :
        new Promise(resolve => window.uploadWaiters.push({count, resolve}));
      for (const input of document.querySelectorAll('input')) input.addEventListener('change', () => {
        const count = ++window.uploadChanges;
        fetch('/upload-observed', {method:'POST'}).then(r => r.text()).then(() => {
          window.completedUploads = count;
          const ready = window.uploadWaiters.filter(waiter => waiter.count <= count);
          window.uploadWaiters = window.uploadWaiters.filter(waiter => waiter.count > count);
          for (const waiter of ready) waiter.resolve();
        });
      });
      </script></body></html>
      """)
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/download", fn conn ->
      Agent.update(harness.counter, &%{&1 | downloads: &1.downloads + 1})

      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.put_resp_header(
        "content-disposition",
        "attachment; filename=native-fixture.txt"
      )
      |> Plug.Conn.resp(200, @download)
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/upload-observed", fn conn ->
      Agent.update(harness.counter, &%{&1 | tool_executions: &1.tool_executions + 1})
      Plug.Conn.resp(conn, 200, "upload observed")
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

      send(owner, {:browser_files_request, index, request})

      call =
        if index in 0..18 or index == 20 do
          if successful_results?(request),
            do:
              {Enum.at(@ids, if(index == 20, do: 19, else: index)),
               call_input(index, request, harness)}
        end

      provider_response(conn, call)
    end)
  end

  defp call_input(0, _request, _harness), do: input("start")
  defp call_input(1, _request, harness), do: input("open", %{"targetUrl" => page_url(harness)})

  defp call_input(index, request, _harness) do
    {action, extra} =
      case index do
        2 ->
          {"snapshot", %{}}

        3 ->
          {"pdf", %{"path" => "saved/explicit.pdf"}}

        4 ->
          {"pdf", %{}}

        5 ->
          {"download",
           %{"ref" => snapshot_ref(request, "Download fixture"), "path" => "saved/clicked.txt"}}

        6 ->
          {"act", evaluate(schedule_download())}

        7 ->
          {"waitfordownload", %{}}

        8 ->
          {"act", evaluate(schedule_download())}

        9 ->
          {"waitfordownload", %{"path" => "saved/waited.txt"}}

        10 ->
          {"upload", %{"paths" => upload_paths(), "element" => "#direct-file"}}

        11 ->
          {"act", evaluate(read_uploads(1))}

        12 ->
          {"upload",
           %{"paths" => upload_paths(), "inputRef" => snapshot_ref(request, "Reference upload")}}

        13 ->
          {"act", evaluate(read_uploads(2))}

        14 ->
          {"upload",
           %{"paths" => upload_paths(), "ref" => snapshot_ref(request, "Atomic chooser")}}

        15 ->
          {"act", evaluate(read_uploads(3))}

        16 ->
          {"upload", %{"paths" => upload_paths()}}

        17 ->
          {"act",
           %{"request" => %{"kind" => "click", "ref" => snapshot_ref(request, "Passive chooser")}}}

        18 ->
          {"act", evaluate(read_uploads(4))}

        20 ->
          {"act", evaluate(read_uploads(4))}
      end

    input(action, Map.put(extra, "targetId", target_id(request)))
  end

  defp evaluate(source), do: %{"request" => %{"kind" => "evaluate", "fn" => source}}

  defp read_uploads(count),
    do: String.replace(@read_uploads, "__UPLOAD_COUNT__", Integer.to_string(count))

  defp schedule_download,
    do:
      "() => { setTimeout(() => document.getElementById('download').click(), 1500); return 'scheduled'; }"

  defp upload_paths, do: Enum.map(@uploads, & &1["name"])
  defp upload_values, do: Enum.map(@uploads, &Map.put(&1, "size", byte_size(&1["text"])))

  defp snapshot_ref(request, name),
    do:
      receipt(request, "files-snapshot")["refs"]
      |> Enum.find(&(&1["name"] == name))
      |> Map.fetch!("ref")

  defp input(action, args \\ %{}),
    do: %{"action" => action, "args" => args, "profile" => "managed", "timeout_ms" => 15_000}

  defp page_url(harness), do: Gaoxy.Test.url(harness.provider.fixture, "/page")

  defp blocks(request),
    do: Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

  defp successful_results?(request),
    do: Enum.all?(blocks(request), &(&1["type"] != "tool_result" or &1["is_error"] == false))

  defp receive_request(index) do
    assert_receive {:browser_files_request, ^index, request}, 20_000

    assert successful_results?(request),
           "Browser failed before provider request #{index}: #{inspect(blocks(request))}"

    request
  end

  defp target_id(request), do: receipt(request, "files-open")["targetId"]

  defp receipt(request, id) do
    result =
      Enum.find(blocks(request), &(&1["type"] == "tool_result" and &1["tool_use_id"] == id))

    result["content"]
    |> Enum.find(&(&1["type"] == "text"))
    |> Map.fetch!("text")
    |> Jason.decode!()
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

    for {turn, index} <- Enum.with_index(turns),
        do: assert({:ok, ^turn} = Store.get_turn(id, index))

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

  defp assert_owned_exited(pids),
    do: await_owned_exit(pids, System.monotonic_time(:millisecond) + 15_000)

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
           %{"type" => "text_delta", "text" => "Browser files inspected"}, "end_turn"}
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
    |> Plug.Conn.resp(200, Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n")))
  end
end
