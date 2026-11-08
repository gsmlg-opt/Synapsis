defmodule SynapsisWeb.AgentLive.DiffsResultChatFunctionalTest do
  use SynapsisWeb.ConnCase, async: false

  alias Synapsis.Agent.DiffsDelivery
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.Diffs.PortSession
  alias Synapsis.Part.ToolResult
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag timeout: 150_000
  @name "synapsis::diffs"
  @call_id "chat-native-diffs"
  @arguments %{
    "before" => "const value = 1;\n",
    "after" => "const value = 2;\n",
    "path" => "src/value.ts",
    "title" => "Chat comparison",
    "mode" => "both"
  }

  test "real both receipts become viewer and download links in current and reopened chat", %{
    conn: conn
  } do
    root =
      Path.join([
        System.tmp_dir!(),
        "synapsis-diffs359-chat-#{System.get_env("MIX_TEST_PARTITION", "0")}",
        Ecto.UUID.generate()
      ])

    File.mkdir_p!(root)
    previous = ConfigStore.get(:diffs, "default")

    assert {:ok, _} =
             ConfigStore.put(:diffs, %{
               "id" => "default",
               "host" => %{
                 "nodeExecutable" => System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE"),
                 "chromiumExecutable" => System.fetch_env!("SYNAPSIS_DIFFS_CHROMIUM"),
                 "artifactRoot" => Path.join(root, "artifacts"),
                 "timeoutMs" => 120_000
               }
             })

    h =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    assert {:ok, _} = Synapsis.AgentConfigs.update(h.agent_config, %{tools: [@name]})

    assert {:ok, provider} =
             Synapsis.Providers.create(%{
               name: h.provider.name,
               type: "openai_responses",
               base_url: h.provider.base_url,
               api_key_encrypted: "ordinary-fixture"
             })

    on_exit(fn ->
      SessionHarness.cleanup!(h)
      Synapsis.Providers.delete(provider.id)

      case previous do
        {:ok, record} -> ConfigStore.put(:diffs, record)
        {:error, :not_found} -> ConfigStore.delete(:diffs, "default")
      end

      File.rm_rf!(root)
    end)

    install_provider(h)
    observe_renderer()
    SessionHarness.subscribe!(h.session.id)
    route = ~p"/agent/agents/#{h.agent_name}/sessions/#{h.session.id}"
    assert {:ok, view, _} = live(conn, route)
    assert :ok = Worker.send_message(h.session.id, "Create the comparison viewer and PNG")
    assert_receive {:diffs_chat_request, 0, _initial, _}, 5_000
    assert_receive {:diffs_chat_request, 1, following, provider_pid}, 120_000
    current = chat(view)
    tool = current.messages |> Enum.flat_map(& &1.tools) |> Enum.find(&(&1.id == @call_id))
    assert tool.status == "complete"
    assert %{isError: false, blocks: [text, viewer_link, file_link]} = tool.display
    details = Enum.find(tool.display.sidecars, &(&1.key == "details")).value
    assert text.type == "text"

    assert text.text ==
             "Diff viewer: #{details["viewerUrl"]}\nDiff PNG generated at: #{details["filePath"]}\nTo send this file, use an available file-sending tool to send it as an attachment."

    assert viewer_link == %{
             type: "link",
             kind: "diffs-viewer",
             label: "Open diff viewer",
             href: details["viewerUrl"],
             expiresAt: details["expiresAt"]
           }

    assert {:ok, file_url} = DiffsDelivery.file_url(details["fileDelivery"])

    assert file_link == %{
             type: "link",
             kind: "diffs-file",
             label: "Download PNG",
             href: file_url,
             filename: "preview.png",
             mediaType: "image/png",
             bytes: details["fileBytes"],
             expiresAt: details["fileExpiresAt"]
           }

    assert details["path"] == details["filePath"]
    assert details["context"] == %{"agentId" => h.agent_config.id, "sessionId" => h.session.id}
    assert_wire(following, text.text)
    reference = details["fileDelivery"]
    assert {:ok, file} = DiffsDelivery.read_file(reference["session_id"], reference["id"], [])
    assert file.bytes == File.read!(details["filePath"])
    download = get(recycle(conn), file_url)
    assert response(download, 200) == file.bytes
    assert get_resp_header(download, "content-type") == ["image/png"]

    assert get_resp_header(download, "content-disposition") == [
             "attachment; filename=\"preview.png\""
           ]

    assert get_resp_header(download, "content-length") == [
             Integer.to_string(details["fileBytes"])
           ]

    assert ["", "plugins", "diffs", "view", id, token] = String.split(details["viewerPath"], "/")
    assert {:ok, viewer} = DiffsDelivery.read_viewer(id, token, [])
    assert viewer.bytes =~ "Chat comparison"
    assert response(get(recycle(conn), details["viewerPath"]), 200) == viewer.bytes
    send(provider_pid, :complete)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    result = stored_result(h.session.id)
    assert result.content == text.text
    assert result.projection["version"] == 1
    assert result.projection["result"]["details"] == details
    assert {:ok, dumped} = Synapsis.Part.dump(result)
    assert {:ok, ^result} = dumped |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    initial_events = renderer_events()

    assert length(
             for {:trace, _, :call, {PortSession, :start_link, _}} <- initial_events, do: :started
           ) == 1

    assert length(
             for {:trace, _, :call, {PortSession, :render, _}} <- initial_events, do: :rendered
           ) == 2

    [{old, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
    monitor = Process.monitor(old)
    assert :ok = DynamicSupervisor.stop_session(h.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old, reason}, 5_000
    assert reason in [:normal, :shutdown]
    assert {:ok, reopened, _} = live(conn, route)
    history = chat(reopened)
    assert result_part(history).display == tool.display
    SessionHarness.ensure_running!(h.session.id)
    [{fresh, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
    refute fresh == old
    assert :ok = Worker.send_message(h.session.id, "Recall the existing comparison")
    assert_receive {:diffs_chat_request, 2, replay, replay_provider}, 10_000
    assert_wire(replay, text.text)
    send(replay_provider, :complete)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    replayed = chat(reopened)
    assert result_part(replayed).display == tool.display
    assert stored_result(h.session.id) == result
    assert {:ok, ^file} = DiffsDelivery.read_file(reference["session_id"], reference["id"], [])
    assert {:ok, ^viewer} = DiffsDelivery.read_viewer(id, token, [])
    assert response(get(recycle(conn), file_url), 200) == file.bytes
    assert renderer_events() == []
    assert length(Agent.get(h.counter, & &1.provider_requests)) == 3

    export(%{
      live: current,
      history: history,
      replay: replayed,
      viewerPath: details["viewerPath"],
      fileUrl: file_url
    })

    assert :ok = DiffsDelivery.remove_artifact(viewer.record, [])
    assert :ok = DiffsDelivery.remove_artifact(file.record, [])
  end

  defp install_provider(h) do
    owner = self()

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(h.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:diffs_chat_request, index, request, self()})

      if index == 0 do
        item = %{
          "type" => "function_call",
          "id" => "chat-diffs-item",
          "call_id" => @call_id,
          "name" => ToolName.encode(@name),
          "arguments" => Jason.encode!(@arguments)
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
            "delta" => item["arguments"]
          },
          %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
          completed([item])
        ])
      else
        receive do
          :complete ->
            sse(conn, [
              %{"type" => "response.output_text.delta", "delta" => "Comparison received"},
              completed([])
            ])
        after
          15_000 -> raise "ordinary Diffs chat completion was not released"
        end
      end
    end)
  end

  defp chat(view) do
    render(view)
    :sys.get_state(view.pid).socket.assigns.react_chat
  end

  defp result_part(snapshot),
    do:
      snapshot.messages
      |> Enum.flat_map(&(&1.metadata[:parts] || []))
      |> Enum.find(&(&1.type == "tool_result"))

  defp stored_result(id) do
    assert {:ok, turns} = Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert({:ok, ^turn} = Store.get_turn(id, index))

    assert [stored] =
             for(turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part)

    assert [result] =
             for(
               message <- Synapsis.Message.list_by_session(id),
               part <- message.parts,
               match?(%ToolResult{}, part),
               do: part
             )

    assert stored.content == result.content
    assert stored.projection == result.projection
    result
  end

  defp assert_wire(request, text) do
    assert [%{"call_id" => @call_id, "output" => ^text}] =
             Enum.filter(request["input"], &(&1["type"] == "function_call_output"))
  end

  defp observe_renderer do
    Code.ensure_loaded!(PortSession)

    for {function, arity} <- [start_link: 1, render: 3],
        do: :erlang.trace_pattern({PortSession, function, arity}, true, [:local])

    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])

      for {function, arity} <- [start_link: 1, render: 3],
          do: :erlang.trace_pattern({PortSession, function, arity}, false, [:local])
    end)
  end

  defp renderer_events do
    ref = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^ref}, 5_000
    drain_renderer([])
  end

  defp drain_renderer(acc) do
    receive do
      {:trace, _, :call, {PortSession, _, _}} = event -> drain_renderer([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp export(snapshot) do
    if directory = System.get_env("SYNAPSIS_DIFFS_UI_EVIDENCE"),
      do: File.write!(Path.join(directory, "diffs-chat.json"), Jason.encode!(snapshot))
  end

  defp completed(output),
    do: %{
      "type" => "response.completed",
      "response" => %{"status" => "completed", "output" => output}
    }

  defp sse(conn, events),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
      )
end
