defmodule Synapsis.Session.NativeBrowserTargetAliasesFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::browser"
  @ids ~w(aliases-start aliases-open-first aliases-batch aliases-snapshot aliases-capture
          aliases-open-second aliases-status aliases-read-label aliases-close aliases-tabs
          aliases-read-first aliases-read-implicit)
  @read "() => ({path: location.pathname, order: window.aliasOrder || []})"
  @replacement_ids ~w(aliases-replacement-tabs aliases-replacement-read
                       aliases-replacement-snapshot aliases-replacement-capture)

  test "raw CDP aliases and replacement continuity reach native history with fresh refs and replay",
       %{
         tmp_dir: root
       } do
    harness = browser_harness(root)
    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok = Worker.send_message(harness.session.id, "Label and inspect the two local tabs")
    requests = for index <- 0..12, do: receive_request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    final = List.last(requests)
    first = target_id(final)
    second = receipt(final, "aliases-open-second")["targetId"]
    refute first == second
    first_alias = receipt(final, "aliases-open-first")["tabId"]
    second_alias = receipt(final, "aliases-open-second")["tabId"]
    assert String.match?(first, ~r/^[0-9A-Fa-f]{32}$/)
    assert String.match?(second, ~r/^[0-9A-Fa-f]{32}$/)
    assert String.match?(first_alias, ~r/^t[1-9][0-9]*$/)
    assert String.match?(second_alias, ~r/^t[1-9][0-9]*$/)
    refute first_alias == second_alias
    refute first == first_alias
    refute second == second_alias

    for {id, target, tab_alias, url} <- [
          {"aliases-open-first", first, first_alias, first_url(harness)},
          {"aliases-open-second", second, second_alias, second_url(harness)}
        ] do
      assert Map.take(receipt(final, id), ~w(targetId url tabId suggestedTargetId label)) == %{
               "targetId" => target,
               "url" => url,
               "tabId" => tab_alias,
               "suggestedTargetId" => "docs",
               "label" => "docs"
             }
    end

    assert receipt(final, "aliases-batch")["targetId"] == first
    assert receipt(final, "aliases-batch")["url"] == first_url(harness)

    assert receipt(final, "aliases-batch")["results"] == [
             %{"ok" => true, "value" => "outer"},
             %{"ok" => true, "results" => [%{"ok" => true, "value" => "inner"}]},
             %{"ok" => true, "value" => "tail"}
           ]

    refute Map.has_key?(receipt(final, "aliases-batch"), "aborted")

    snapshot = receipt(final, "aliases-snapshot")
    ref = button_ref(final)
    assert snapshot["targetId"] == first
    assert snapshot["url"] == first_url(harness)

    assert snapshot["refs"] == [
             %{"ref" => ref, "role" => "button", "name" => "Alias original target"}
           ]

    status_tabs = receipt(final, "aliases-status")["tabs"]
    first_status = Enum.find(status_tabs, &(&1["targetId"] == first))
    second_status = Enum.find(status_tabs, &(&1["targetId"] == second))

    assert Map.take(first_status, ~w(targetId url tabId suggestedTargetId)) == %{
             "targetId" => first,
             "url" => first_url(harness),
             "tabId" => first_alias,
             "suggestedTargetId" => first_alias
           }

    refute Map.has_key?(first_status, "label")

    assert Map.take(second_status, ~w(targetId url tabId suggestedTargetId label)) == %{
             "targetId" => second,
             "url" => second_url(harness),
             "tabId" => second_alias,
             "suggestedTargetId" => "docs",
             "label" => "docs"
           }

    assert receipt(final, "aliases-read-label")["targetId"] == second
    assert receipt(final, "aliases-read-label")["url"] == second_url(harness)
    assert receipt(final, "aliases-read-label")["value"] == %{"path" => "/second", "order" => []}

    assert Map.take(receipt(final, "aliases-close"), ~w(targetId closed)) == %{
             "targetId" => second,
             "closed" => true
           }

    remaining_tabs = receipt(final, "aliases-tabs")["tabs"]
    expected_targets = status_tabs |> Enum.map(& &1["targetId"]) |> Enum.reject(&(&1 == second))
    assert Enum.map(remaining_tabs, & &1["targetId"]) == expected_targets
    remaining_first = Enum.find(remaining_tabs, &(&1["targetId"] == first))

    assert Map.take(remaining_first, ~w(targetId url tabId suggestedTargetId)) == %{
             "targetId" => first,
             "url" => first_url(harness),
             "tabId" => first_alias,
             "suggestedTargetId" => first_alias
           }

    refute Map.has_key?(remaining_first, "label")
    assert receipt(final, "aliases-read-first")["targetId"] == first
    assert receipt(final, "aliases-read-first")["url"] == first_url(harness)

    assert receipt(final, "aliases-read-first")["value"] == %{
             "path" => "/first",
             "order" => ["outer", "inner", "tail"]
           }

    assert receipt(final, "aliases-read-implicit")["targetId"] == first
    assert receipt(final, "aliases-read-implicit")["url"] == first_url(harness)

    assert receipt(final, "aliases-read-implicit")["value"] ==
             receipt(final, "aliases-read-first")["value"]

    for id <-
          ~w(aliases-batch aliases-snapshot aliases-capture aliases-read-label aliases-close aliases-read-first aliases-read-implicit),
        field <- ~w(tabId suggestedTargetId label) do
      refute Map.has_key?(receipt(final, id), field)
    end

    parts = browser_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == @ids
    assert Enum.map(results, & &1.tool_use_id) == @ids
    assert Enum.all?(uses, &(&1.tool == @name))
    assert Enum.all?(results, &(&1.is_error == false))

    assert Enum.map(uses, & &1.input) ==
             for(index <- 0..11, do: call_input(index, final, harness))

    part = Enum.find(results, &(&1.tool_use_id == "aliases-capture"))
    assert %{"version" => 1, "result" => screenshot} = part.projection
    assert screenshot["targetId"] == first
    assert screenshot["url"] == first_url(harness)
    assert screenshot["type"] == "png"
    assert [text, image] = screenshot["content"]
    assert text["type"] == "text"
    metadata = Map.take(screenshot, ~w(targetId url type bytes path sha256 media))
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

    assert {width, height} == {96, 40}
    assert byte_size(png) == screenshot["bytes"]
    assert byte_size(png) in 1..196_608
    assert part.content == text["text"]
    assert screenshot["media"] == %{"outbound" => false, "mediaUrl" => screenshot["path"]}
    assert Path.dirname(screenshot["path"]) == Path.join(root, ".synapsis/browser-files")
    assert File.read!(screenshot["path"]) == png
    assert screenshot["sha256"] == Base.encode16(:crypto.hash(:sha256, png), case: :lower)

    for {request, count} <- Enum.with_index(requests) do
      assert_wire_history(request, Enum.take(uses, count), Enum.take(results, count))
    end

    assert_part_round_trips(parts)
    assert_durable_parts(harness.session.id, uses, results)
    assert_effect_counts(harness)
    {retained_resource, retained_broker} = browser_resource(harness.session.id)

    replacement = replace_page(root, harness)
    assert replacement["oldTargetId"] == first
    refute replacement["targetId"] == first

    assert :ok =
             Worker.send_message(
               harness.session.id,
               "Inspect the replacement using its stable tab alias"
             )

    replacement_requests = for index <- 13..17, do: receive_request(index)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    replacement_final = List.last(replacement_requests)
    replacement_id = replacement["targetId"]

    replacement_tab =
      replacement_final
      |> receipt("aliases-replacement-tabs")
      |> Map.fetch!("tabs")
      |> Enum.find(&(&1["targetId"] == replacement_id))

    assert Map.take(replacement_tab, ~w(tabId suggestedTargetId active)) == %{
             "tabId" => first_alias,
             "suggestedTargetId" => first_alias,
             "active" => true
           }

    assert receipt(replacement_final, "aliases-replacement-read")["targetId"] == replacement_id

    assert receipt(replacement_final, "aliases-replacement-read")["value"] == %{
             "path" => "/first",
             "order" => []
           }

    replacement_snapshot = receipt(replacement_final, "aliases-replacement-snapshot")
    assert replacement_snapshot["targetId"] == replacement_id
    refute Map.has_key?(replacement_snapshot, "newElements")
    replacement_ref = hd(replacement_snapshot["refs"])["ref"]
    refute replacement_ref == ref
    replacement_capture = receipt(replacement_final, "aliases-replacement-capture")
    assert replacement_capture["targetId"] == replacement_id
    assert replacement_capture["url"] == first_url(harness)

    replacement_part =
      Enum.find(browser_parts(harness.session.id), fn
        %ToolResult{tool_use_id: "aliases-replacement-capture"} -> true
        _ -> false
      end)

    assert %{"version" => 1, "result" => replacement_projection} = replacement_part.projection

    assert Map.take(replacement_projection, ~w(targetId url type bytes path sha256 media)) ==
             replacement_capture

    assert [_, %{"data" => %{"data" => replacement_png}}] = replacement_projection["content"]
    assert byte_size(Base.decode64!(replacement_png)) == replacement_capture["bytes"]

    assert <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", 96::32, 40::32, _::binary>> =
             Base.decode64!(replacement_png)

    saved = %{
      screenshot["path"] => png,
      replacement_capture["path"] => Base.decode64!(replacement_png)
    }

    assert map_size(saved) == 2

    assert replacement_capture["media"] == %{
             "outbound" => false,
             "mediaUrl" => replacement_capture["path"]
           }

    assert replacement_capture["sha256"] ==
             Base.encode16(:crypto.hash(:sha256, Base.decode64!(replacement_png)), case: :lower)

    assert_generated_artifacts(root, saved)

    parts = browser_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == @ids ++ @replacement_ids
    assert Enum.map(results, & &1.tool_use_id) == @ids ++ @replacement_ids

    for {request, count} <- Enum.with_index(replacement_requests, length(@ids)) do
      assert_wire_history(request, Enum.take(uses, count), Enum.take(results, count))
    end

    assert_part_round_trips(parts)
    assert_durable_parts(harness.session.id, uses, results)
    assert_effect_counts(harness, 2)
    {resource, broker} = browser_resource(harness.session.id)
    assert resource.profiles["managed"].handle == retained_resource.profiles["managed"].handle
    assert broker == retained_broker
    owned = owned_processes(broker)

    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5_000
    assert_owned_exited(owned)
    refute Process.alive?(broker)
    assert_generated_artifacts(root, saved)
    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute new_worker == old_worker
    assert :ok = Worker.send_message(harness.session.id, "Recall the completed target aliases")
    replay = receive_request(18)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire_history(replay, uses, results)
    assert browser_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)
    assert_effect_counts(harness, 2)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 19
    {_resource, replay_broker} = browser_resource(harness.session.id)
    refute replay_broker == broker
    assert :sys.get_state(replay_broker).port == nil
    assert_generated_artifacts(root, saved)
  end

  defp assert_generated_artifacts(root, saved) do
    directory = Path.join(root, ".synapsis/browser-files")

    assert Enum.sort(File.ls!(directory)) ==
             Enum.sort(Enum.map(Map.keys(saved), &Path.basename/1))

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
    Agent.update(harness.counter, &Map.merge(&1, %{first_loads: 0, second_loads: 0, markers: []}))
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

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/first", fn conn ->
      Agent.update(harness.counter, &%{&1 | first_loads: &1.first_loads + 1})

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, """
      <!doctype html><html><head><title>Alias original page</title><style>
      html,body { margin: 0; background: white; }
      button { position: absolute; left: 32px; top: 40px; width: 96px; height: 40px;
        border: 0; padding: 0; background: #208040; }
      </style></head><body><button aria-label="Alias original target"></button></body></html>
      """)
    end)

    Gaoxy.Test.stub(harness.provider.fixture, "GET", "/second", fn conn ->
      Agent.update(harness.counter, &%{&1 | second_loads: &1.second_loads + 1})

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, "<!doctype html><title>Alias moved page</title><p>Second tab</p>")
    end)

    for marker <- ~w(outer inner tail) do
      Gaoxy.Test.stub(harness.provider.fixture, "POST", "/marker/#{marker}", fn conn ->
        Agent.update(harness.counter, &%{&1 | markers: &1.markers ++ [marker]})
        Plug.Conn.resp(conn, 200, marker)
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

      send(owner, {:browser_target_aliases_request, index, request})

      call =
        cond do
          index < length(@ids) and successful_results?(request) ->
            {Enum.at(@ids, index), call_input(index, request, harness)}

          index in 13..16 and successful_results?(request) ->
            {Enum.at(@replacement_ids, index - 13), replacement_input(index - 13, request)}

          true ->
            nil
        end

      provider_response(conn, call)
    end)
  end

  defp call_input(0, _request, _harness), do: input("start")

  defp call_input(1, _request, harness),
    do: input("open", %{"targetUrl" => first_url(harness), "label" => " docs "})

  defp call_input(2, request, _harness) do
    canonical = target_id(request)

    input("act", %{
      "targetId" => raw_prefix(canonical),
      "request" => %{
        "kind" => "batch",
        "targetId" => canonical,
        "actions" => [
          marker("outer", receipt(request, "aliases-open-first")["tabId"]),
          %{"kind" => "batch", "targetId" => canonical, "actions" => [marker("inner", "docs")]},
          marker("tail", raw_prefix(canonical))
        ]
      }
    })
  end

  defp call_input(3, request, _harness),
    do: input("snapshot", %{"targetId" => raw_prefix(target_id(request)), "interactive" => true})

  defp call_input(4, request, _harness),
    do:
      input("screenshot", %{
        "targetId" => receipt(request, "aliases-open-first")["tabId"],
        "ref" => button_ref(request)
      })

  defp call_input(5, _request, harness),
    do: input("open", %{"targetUrl" => second_url(harness), "label" => "docs"})

  defp call_input(6, _request, _harness), do: input("status")

  defp call_input(7, _request, _harness),
    do: input("act", %{"targetId" => "docs", "request" => %{"kind" => "evaluate", "fn" => @read}})

  defp call_input(8, request, _harness),
    do:
      input("close", %{
        "targetId" => raw_prefix(receipt(request, "aliases-open-second")["targetId"])
      })

  defp call_input(9, _request, _harness), do: input("tabs")

  defp call_input(10, request, _harness),
    do:
      input("act", %{
        "targetId" => raw_prefix(target_id(request)),
        "request" => %{"kind" => "evaluate", "fn" => @read}
      })

  defp call_input(11, _request, _harness),
    do: input("act", %{"request" => %{"kind" => "evaluate", "fn" => @read}})

  defp replacement_input(0, _request), do: input("tabs")

  defp replacement_input(1, _request),
    do: input("act", %{"request" => %{"kind" => "evaluate", "fn" => @read}})

  defp replacement_input(2, request),
    do:
      input("snapshot", %{
        "targetId" => receipt(request, "aliases-open-first")["tabId"],
        "interactive" => true
      })

  defp replacement_input(3, request),
    do:
      input("screenshot", %{
        "ref" => hd(receipt(request, "aliases-replacement-snapshot")["refs"])["ref"]
      })

  defp replace_page(root, harness) do
    [port_file] =
      Path.wildcard(Path.join([root, "browser-data", "synapsis-browser-*", "DevToolsActivePort"]))

    script = """
    import {readFile} from 'node:fs/promises';
    import {chromium} from 'playwright-core';
    const deadline=setTimeout(()=>{process.stderr.write('replacement fixture deadline');process.exit(1)},12000);
    const [file,url]=process.argv.slice(1);
    const [port,path]=(await readFile(file,'utf8')).trim().split('\\n');
    const browser=await chromium.connectOverCDP(`ws://127.0.0.1:${port}${path}`, {timeout:10000,noDefaults:true});
    try {
      const context=browser.contexts()[0]; context.setDefaultTimeout(10000);
      const old=context.pages().find(page=>page.url()===url);
      const oldSession=await context.newCDPSession(old);
      const {targetInfo:oldInfo}=await oldSession.send('Target.getTargetInfo');
      await oldSession.detach();
      const replacement=await context.newPage();
      await replacement.goto(url,{waitUntil:'domcontentloaded',timeout:10000});
      const session=await context.newCDPSession(replacement);
      const {targetInfo}=await session.send('Target.getTargetInfo');
      await session.detach(); await old.close();
      process.stdout.write(JSON.stringify({oldTargetId:oldInfo.targetId,targetId:targetInfo.targetId})+'\\n');
    } finally {await browser.close();clearTimeout(deadline);}
    """

    port =
      Port.open({:spawn_executable, System.find_executable("node")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["--input-type=module", "-e", script, port_file, first_url(harness)]
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    collect_replacement(port, "", System.monotonic_time(:millisecond) + 15_000)
  end

  defp collect_replacement(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect_replacement(port, output <> data, deadline)

      {^port, {:exit_status, status}} ->
        assert status == 0, output
        Jason.decode!(String.trim(output))
    after
      remaining -> flunk("replacement fixture did not finish: #{output}")
    end
  end

  defp marker(name, target) do
    %{
      "kind" => "evaluate",
      "targetId" => target,
      "fn" => """
      async () => {
        window.aliasOrder = [...(window.aliasOrder || []), #{Jason.encode!(name)}];
        await fetch('/marker/#{name}', {method:'POST'});
        return #{Jason.encode!(name)};
      }
      """
    }
  end

  defp input(action, args \\ %{}),
    do: %{"action" => action, "args" => args, "profile" => "managed", "timeout_ms" => 15_000}

  defp first_url(harness), do: Gaoxy.Test.url(harness.provider.fixture, "/first")
  defp second_url(harness), do: Gaoxy.Test.url(harness.provider.fixture, "/second")

  defp assert_effect_counts(harness, first_loads \\ 1) do
    assert %{first_loads: ^first_loads, second_loads: 1, markers: ["outer", "inner", "tail"]} =
             Agent.get(harness.counter, & &1)
  end

  defp blocks(request),
    do: Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

  defp successful_results?(request),
    do: Enum.all?(blocks(request), &(&1["type"] != "tool_result" or &1["is_error"] == false))

  defp receive_request(index) do
    assert_receive {:browser_target_aliases_request, ^index, request}, 20_000

    assert successful_results?(request),
           "Browser failed before provider request #{index}: #{inspect(blocks(request))}"

    request
  end

  defp raw_prefix(target), do: target |> String.slice(0, 24) |> String.downcase()

  defp target_id(request), do: receipt(request, "aliases-open-first")["targetId"]

  defp button_ref(request) do
    request
    |> receipt("aliases-snapshot")
    |> Map.fetch!("refs")
    |> Enum.find(&(&1["role"] == "button" and &1["name"] == "Alias original target"))
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
           %{"type" => "text_delta", "text" => "Browser target aliases inspected"}, "end_turn"}
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
