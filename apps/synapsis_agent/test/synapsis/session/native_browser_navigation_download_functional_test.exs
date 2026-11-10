defmodule Synapsis.Session.NativeBrowserNavigationDownloadFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::browser"
  @ids ~w(navigation-download-start navigation-download-open navigation-download-snapshot
          navigation-download-navigate navigation-download-click navigation-download-proof)
  @download "Native navigation attachment 世界 雪😀.\n"

  test "managed navigate downloads once, retains original refs and replays its durable receipt after normal restart",
       %{tmp_dir: root} do
    harness = browser_harness(root)
    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok =
             Worker.send_message(
               harness.session.id,
               "Navigate to an attachment and use the original page"
             )

    requests = for index <- 0..6, do: receive_request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    final = List.last(requests)
    opened = receipt(final, "navigation-download-open")
    snapshot = receipt(final, "navigation-download-snapshot")
    navigation = receipt(final, "navigation-download-navigate")
    target = opened["targetId"]
    ref = original_ref(final)

    assert opened["label"] == "docs"
    assert opened["suggestedTargetId"] == "docs"
    assert snapshot["targetId"] == target
    assert snapshot["url"] == page_url(harness)
    assert snapshot["snapshot"] =~ "Original control 雪😀"
    assert ref =~ ~r/^e\d+$/
    assert navigation["targetId"] == target
    assert navigation["url"] == download_url(harness)
    assert navigation["generation"] == snapshot["generation"]
    assert navigation["documentGeneration"] == snapshot["documentGeneration"]
    refute Map.has_key?(navigation, "pageState")
    refute Map.has_key?(navigation, "pageStateUnavailable")

    saved = navigation["download"]
    assert Enum.sort(Map.keys(saved)) == ~w(bytes path sha256 suggestedFilename url)
    assert saved["url"] == download_url(harness)
    assert saved["suggestedFilename"] == "native-navigation.txt"
    assert Path.dirname(saved["path"]) == Path.join(root, ".synapsis/browser-files")
    assert Path.basename(saved["path"]) =~ ~r/^[0-9a-f-]{36}\./
    assert File.read!(saved["path"]) == @download
    assert saved["bytes"] == byte_size(@download)
    assert saved["sha256"] == Base.encode16(:crypto.hash(:sha256, @download), case: :lower)
    assert receipt(final, "navigation-download-click")["ok"] == true

    assert receipt(final, "navigation-download-proof")["value"] == %{
             "clicks" => 1,
             "title" => "Retained native page 雪😀",
             "url" => page_url(harness),
             "selectedText" => "Original control 雪😀"
           }

    parts = browser_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == @ids
    assert Enum.map(results, & &1.tool_use_id) == @ids
    assert Enum.all?(uses, &(&1.tool == @name))
    assert Enum.all?(results, &(&1.is_error == false))
    assert Enum.map(uses, & &1.input) == for(index <- 0..5, do: call_input(index, final, harness))
    assert Enum.at(uses, 3).input["args"]["targetId"] == " docs "
    assert Enum.at(uses, 4).input["args"]["request"] == %{"kind" => "click", "ref" => ref}
    assert Enum.count(uses, &(&1.input["action"] == "snapshot")) == 1

    for {request, count} <- Enum.with_index(requests),
        do: assert_wire_history(request, Enum.take(uses, count), Enum.take(results, count))

    for result <- results do
      assert %{"version" => 1, "result" => projected} = result.projection
      assert projected["is_error"] == false
      assert result.content == projected["content"]
      assert Jason.decode!(result.content) == receipt(final, result.tool_use_id)
      assert projected["structured"] == receipt(final, result.tool_use_id)
      assert Map.drop(projected, ~w(content structured is_error)) == projected["structured"]
    end

    navigation_part = Enum.find(results, &(&1.tool_use_id == "navigation-download-navigate"))
    assert navigation_part.projection["result"]["structured"]["download"] == saved
    assert Jason.decode!(navigation_part.content)["download"] == saved
    assert_part_round_trips(parts)
    assert_durable_parts(harness.session.id, uses, results)
    assert_effect_counts(harness)
    assert_no_staging(root)

    {_resource, broker} = browser_resource(harness.session.id)
    owned = owned_processes(broker)
    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5_000
    assert_owned_exited(owned)
    refute Process.alive?(broker)
    assert File.read!(saved["path"]) == @download
    assert_no_staging(root)

    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute new_worker == old_worker

    assert :ok =
             Worker.send_message(
               harness.session.id,
               "Recall the saved attachment without browser work"
             )

    replay = receive_request(7)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(replay, uses, results)
    assert receipt(replay, "navigation-download-navigate") == navigation
    assert browser_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)
    assert File.read!(saved["path"]) == @download
    assert_effect_counts(harness)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 8
    {_resource, replay_broker} = browser_resource(harness.session.id)
    refute replay_broker == broker
    assert :sys.get_state(replay_broker).port == nil
    assert_no_staging(root)
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
      &Map.merge(&1, %{page_loads: 0, redirects: 0, downloads: 0, clicks: 0})
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
      <!doctype html><meta charset="utf-8"><title>Retained native page 雪😀</title>
      <button id="original">Original control 雪😀</button>
      <script>
      window.originalClicks = 0;
      document.getElementById('original').addEventListener('click', () => {
        window.originalClicks++;
        window.clickObserved = fetch('/click-observed', {method:'POST'});
      });
      </script>
      """)
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/redirect", fn conn ->
      Agent.update(harness.counter, &%{&1 | redirects: &1.redirects + 1})

      conn
      |> Plug.Conn.put_resp_header("location", download_url(harness))
      |> Plug.Conn.resp(302, "")
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/download", fn conn ->
      Agent.update(harness.counter, &%{&1 | downloads: &1.downloads + 1})

      conn
      |> Plug.Conn.put_resp_content_type("application/octet-stream")
      |> Plug.Conn.put_resp_header(
        "content-disposition",
        "attachment; filename=native-navigation.txt"
      )
      |> Plug.Conn.resp(200, @download)
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/click-observed", fn conn ->
      Agent.update(harness.counter, &%{&1 | clicks: &1.clicks + 1})
      Plug.Conn.resp(conn, 200, "original action observed")
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

      send(owner, {:navigation_download_request, index, request})

      call =
        if index < length(@ids) and successful_results?(request),
          do: {Enum.at(@ids, index), call_input(index, request, harness)}

      provider_response(conn, call)
    end)
  end

  defp call_input(0, _request, _harness), do: input("start")

  defp call_input(1, _request, harness),
    do: input("open", %{"targetUrl" => page_url(harness), "label" => " docs "})

  defp call_input(2, request, _harness),
    do: input("snapshot", %{"targetId" => target_id(request), "interactive" => true})

  defp call_input(3, _request, harness),
    do:
      input("navigate", %{
        "targetId" => " docs ",
        "targetUrl" => Gaoxy.Test.url(harness.provider.fixture, "/redirect")
      })

  defp call_input(4, request, _harness),
    do:
      input("act", %{
        "targetId" => target_id(request),
        "request" => %{"kind" => "click", "ref" => original_ref(request)}
      })

  defp call_input(5, request, _harness),
    do:
      input("act", %{
        "targetId" => target_id(request),
        "request" => %{
          "kind" => "evaluate",
          "fn" => """
          async () => {
            await window.clickObserved;
            return {clicks:window.originalClicks, title:document.title, url:location.href,
              selectedText:document.getElementById('original').textContent};
          }
          """
        }
      })

  defp input(action, args \\ %{}),
    do: %{"action" => action, "args" => args, "profile" => "managed", "timeout_ms" => 15_000}

  defp page_url(harness), do: Gaoxy.Test.url(harness.provider.fixture, "/page")
  defp download_url(harness), do: Gaoxy.Test.url(harness.provider.fixture, "/download")
  defp target_id(request), do: receipt(request, "navigation-download-open")["targetId"]

  defp original_ref(request),
    do:
      receipt(request, "navigation-download-snapshot")["refs"]
      |> Enum.find(&(&1["role"] == "button" and &1["name"] == "Original control 雪😀"))
      |> Map.fetch!("ref")

  defp assert_effect_counts(harness),
    do:
      assert(
        %{page_loads: 1, redirects: 1, downloads: 1, clicks: 1} = Agent.get(harness.counter, & &1)
      )

  defp assert_no_staging(root),
    do: assert(Path.wildcard(Path.join(root, ".synapsis/browser-files/.browser-stage-*")) == [])

  defp blocks(request),
    do: Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

  defp successful_results?(request),
    do: Enum.all?(blocks(request), &(&1["type"] != "tool_result" or &1["is_error"] == false))

  defp receive_request(index) do
    assert_receive {:navigation_download_request, ^index, request}, 20_000

    assert successful_results?(request),
           "Browser failed before request #{index}: #{inspect(blocks(request))}"

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
           %{"type" => "text_delta", "text" => "Navigation attachment inspected"}, "end_turn"}
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
