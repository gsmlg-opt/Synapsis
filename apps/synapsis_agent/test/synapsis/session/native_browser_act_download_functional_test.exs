defmodule Synapsis.Session.NativeBrowserActDownloadFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::browser"
  @ids ~w(act-download-start act-download-open act-download-snapshot
          act-download-click act-download-batch act-download-proof)

  test "root acts retain ordered download receipts through native Responses history and normal Worker reload",
       %{tmp_dir: root} do
    harness = browser_harness(root)
    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok =
             Worker.send_message(harness.session.id, "Download three files from the current page")

    requests = for index <- 0..6, do: receive_request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    final = List.last(requests)
    opened = receipt(final, "act-download-open")
    snapshot = receipt(final, "act-download-snapshot")
    clicked = receipt(final, "act-download-click")
    batch = receipt(final, "act-download-batch")
    proof = receipt(final, "act-download-proof")
    target = opened["targetId"]

    assert opened["label"] == "docs"
    assert opened["suggestedTargetId"] == "docs"
    assert snapshot["targetId"] == target
    assert snapshot["url"] == page_url(harness)
    for name <- ~w(one two three), do: assert(download_ref(final, name) =~ ~r/^e\d+$/)

    for result <- [clicked, batch, proof] do
      assert result["targetId"] == target
      assert result["url"] == page_url(harness)
      assert result["generation"] == snapshot["generation"]
      refute Map.has_key?(result, "pageState")
      refute Map.has_key?(result, "pageStateUnavailable")
    end

    assert clicked["ok"] == true
    assert [first] = clicked["downloads"]
    assert [second, third] = batch["downloads"]
    saved = [first, second, third]

    for {file, name} <- Enum.zip(saved, ~w(one two three)),
        do: assert_file(root, harness, file, name)

    assert length(Enum.uniq_by(saved, & &1["path"])) == 3
    assert {:ok, published} = File.ls(Path.join(root, ".synapsis/browser-files"))
    assert length(published) == 3

    assert batch["results"] == [
             %{"ok" => true, "value" => "before"},
             %{"ok" => true},
             %{
               "ok" => true,
               "results" => [
                 %{"ok" => true, "value" => "inside"},
                 %{"ok" => true},
                 %{"ok" => true, "value" => "after-inside"}
               ]
             },
             %{"ok" => true, "value" => "last"}
           ]

    refute Map.has_key?(batch, "aborted")
    refute Map.has_key?(proof, "downloads")

    assert proof["value"] == %{
             "effects" => ~w(one two three),
             "title" => "Native action page 雪😀",
             "url" => page_url(harness),
             "links" => Enum.map(~w(one two three), &("Download " <> &1 <> " 雪😀"))
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

    assert Enum.at(uses, 3).input["args"]["request"] == %{
             "kind" => "click",
             "ref" => download_ref(final, "one")
           }

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

    for {file, name} <- Enum.zip(saved, ~w(one two three)),
        do: assert_file(root, harness, file, name)

    assert_no_staging(root)

    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute new_worker == old_worker

    assert :ok =
             Worker.send_message(
               harness.session.id,
               "Recall the three receipts without browser work"
             )

    replay = receive_request(7)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(replay, uses, results)
    assert receipt(replay, "act-download-click") == clicked
    assert receipt(replay, "act-download-batch") == batch
    assert browser_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)

    for {file, name} <- Enum.zip(saved, ~w(one two three)),
        do: assert_file(root, harness, file, name)

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
        permission_mode: "yolo",
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn ->
      SessionHarness.cleanup!(harness)

      case Synapsis.Providers.get_by_name(harness.provider.name) do
        {:ok, provider} -> Synapsis.Providers.delete(provider.id)
        {:error, :not_found} -> :ok
      end
    end)

    Agent.update(harness.counter, &Map.merge(&1, %{page_loads: 0, redirects: [], downloads: []}))
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

    assert {:ok, _provider} =
             Synapsis.Providers.create(%{
               name: harness.provider.name,
               type: "openai_responses",
               base_url: harness.provider.base_url,
               api_key_encrypted: "test-key"
             })

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/page", fn conn ->
      Agent.update(harness.counter, &%{&1 | page_loads: &1.page_loads + 1})

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, """
      <!doctype html><meta charset="utf-8"><title>Native action page 雪😀</title>
      <a id="one" href="/redirect/one">Download one 雪😀</a>
      <a id="two" href="/redirect/two">Download two 雪😀</a>
      <a id="three" href="/redirect/three">Download three 雪😀</a>
      <script>
      window.effects = [];
      for (const link of document.querySelectorAll('a')) {
        link.addEventListener('click', () => window.effects.push(link.id));
      }
      </script>
      """)
    end)

    for name <- ~w(one two three) do
      Gaoxy.Test.stub(harness.provider.fixture, "GET", "/redirect/#{name}", fn conn ->
        Agent.update(harness.counter, &%{&1 | redirects: &1.redirects ++ [name]})

        conn
        |> Plug.Conn.put_resp_header("location", download_url(harness, name))
        |> Plug.Conn.resp(302, "")
      end)

      Gaoxy.Test.stub(harness.provider.fixture, "GET", "/download/#{name}", fn conn ->
        Agent.update(harness.counter, &%{&1 | downloads: &1.downloads ++ [name]})

        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.put_resp_header(
          "content-disposition",
          "attachment; filename=native-action-#{name}.txt"
        )
        |> Plug.Conn.resp(200, download_bytes(name))
      end)
    end

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/favicon.ico", &Plug.Conn.resp(&1, 204, ""))
    harness
  end

  defp install_provider(harness) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:act_download_request, index, request})

      call =
        if index < length(@ids),
          do: {Enum.at(@ids, index), call_input(index, request, harness)}

      provider_response(conn, call)
    end)
  end

  defp call_input(0, _request, _harness), do: input("start")

  defp call_input(1, _request, harness),
    do: input("open", %{"targetUrl" => page_url(harness), "label" => " docs "})

  defp call_input(2, request, _harness),
    do: input("snapshot", %{"targetId" => target_id(request), "interactive" => true})

  defp call_input(3, request, _harness),
    do: input("act", %{"targetId" => " docs ", "request" => click(request, "one")})

  defp call_input(4, request, _harness),
    do:
      input("act", %{
        "targetId" => target_id(request),
        "request" => %{
          "kind" => "batch",
          "actions" => [
            mark("before"),
            click(request, "two"),
            %{
              "kind" => "batch",
              "actions" => [mark("inside"), click(request, "three"), mark("after-inside")]
            },
            mark("last")
          ]
        }
      })

  defp call_input(5, request, _harness),
    do:
      input("act", %{
        "targetId" => target_id(request),
        "request" => %{
          "kind" => "evaluate",
          "fn" => """
          () => ({effects:window.effects, title:document.title, url:location.href,
            links:Array.from(document.querySelectorAll('a'), link => link.textContent)})
          """
        }
      })

  defp mark(value), do: %{"kind" => "evaluate", "fn" => "() => " <> Jason.encode!(value)}
  defp click(request, name), do: %{"kind" => "click", "ref" => download_ref(request, name)}

  defp input(action, args \\ %{}),
    do: %{"action" => action, "args" => args, "profile" => "managed", "timeout_ms" => 15_000}

  defp page_url(harness), do: Gaoxy.Test.url(harness.provider.fixture, "/page")

  defp download_url(harness, name),
    do: Gaoxy.Test.url(harness.provider.fixture, "/download/#{name}")

  defp download_bytes(name), do: "Native action attachment #{name}: 世界 雪😀.\n"
  defp target_id(request), do: receipt(request, "act-download-open")["targetId"]

  defp download_ref(request, name),
    do:
      receipt(request, "act-download-snapshot")["refs"]
      |> Enum.find(&(&1["role"] == "link" and &1["name"] == "Download #{name} 雪😀"))
      |> Map.fetch!("ref")

  defp assert_file(root, harness, saved, name) do
    bytes = download_bytes(name)
    assert Enum.sort(Map.keys(saved)) == ~w(bytes path sha256 suggestedFilename url)
    assert saved["url"] == download_url(harness, name)
    assert saved["suggestedFilename"] == "native-action-#{name}.txt"
    assert Path.dirname(saved["path"]) == Path.join(root, ".synapsis/browser-files")
    assert Path.basename(saved["path"]) =~ ~r/^[0-9a-f-]{36}\./
    assert File.read!(saved["path"]) == bytes
    assert saved["bytes"] == byte_size(bytes)
    assert saved["sha256"] == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end

  defp assert_effect_counts(harness),
    do:
      assert(
        %{page_loads: 1, redirects: ~w(one two three), downloads: ~w(one two three)} =
          Agent.get(harness.counter, & &1)
      )

  defp assert_no_staging(root),
    do: assert(Path.wildcard(Path.join(root, ".synapsis/browser-files/.browser-stage-*")) == [])

  defp receive_request(index) do
    assert_receive {:act_download_request, ^index, request}, 20_000
    request
  end

  defp receipt(request, id),
    do:
      request["input"]
      |> Enum.find(&(&1["type"] == "function_call_output" and &1["call_id"] == id))
      |> Map.fetch!("output")
      |> Jason.decode!()

  defp assert_wire_history(request, uses, results) do
    actual =
      Enum.filter(request["input"], &(&1["type"] in ~w(function_call function_call_output)))

    expected =
      Enum.zip(uses, results)
      |> Enum.flat_map(fn {use, result} ->
        [
          %{
            "type" => "function_call",
            "call_id" => use.tool_use_id,
            "name" => ToolName.encode(use.tool),
            "arguments" => Jason.encode!(use.input)
          },
          %{
            "type" => "function_call_output",
            "call_id" => result.tool_use_id,
            "output" => result.projection["result"]["content"]
          }
        ]
      end)

    assert actual == expected
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
    owned = process_tree(helper)
    assert length(owned) > 1
    owned
  end

  defp process_tree(pid) do
    children =
      case File.read("/proc/#{pid}/task/#{pid}/children") do
        {:ok, value} -> String.split(value) |> Enum.map(&String.to_integer/1)
        {:error, :enoent} -> []
      end

    [pid | Enum.flat_map(children, &process_tree/1)]
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

  defp provider_response(conn, {id, input}) do
    item = %{
      "type" => "function_call",
      "id" => id <> "-item",
      "call_id" => id,
      "namespace" => "synapsis",
      "name" => "browser",
      "arguments" => Jason.encode!(input)
    }

    sse(conn, [
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => Map.put(item, "arguments", "")
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "item_id" => item["id"],
        "delta" => Jason.encode!(input)
      },
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      completed([item])
    ])
  end

  defp provider_response(conn, nil),
    do:
      sse(conn, [
        %{"type" => "response.output_text.delta", "delta" => "Action downloads inspected"},
        completed([])
      ])

  defp completed(output),
    do: %{
      "type" => "response.completed",
      "response" => %{"status" => "completed", "output" => output}
    }

  defp sse(conn, events) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.resp(200, Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n")))
  end
end
