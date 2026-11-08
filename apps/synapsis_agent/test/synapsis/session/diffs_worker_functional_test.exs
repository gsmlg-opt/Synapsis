defmodule Synapsis.Session.DiffsWorkerFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.DiffsDelivery
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.Diffs
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.Diffs.PortSession
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag timeout: 150_000
  @name "synapsis::diffs"
  @call_id "ordinary-worker-diffs"
  @arguments %{
    "before" => "const value = 1;\n",
    "after" => "const value = 2;\n",
    "path" => "src/value.ts",
    "title" => "Worker comparison",
    "mode" => "both"
  }

  test "real Worker preserves source receipts through Responses, Part JSON, Concord and normal replacement" do
    root =
      Path.join([
        System.tmp_dir!(),
        "synapsis-diffs359-worker-#{System.get_env("MIX_TEST_PARTITION", "0")}",
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
                 "artifactRoot" => Path.join(root, "original-artifacts"),
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

    observe_renderer()
    install_provider(h)
    SessionHarness.subscribe!(h.session.id)
    SessionHarness.ensure_running!(h.session.id)
    assert :ok = Worker.send_message(h.session.id, "Create the comparison viewer and PNG")
    assert_receive {:diffs_request, 0, first}, 5_000
    assert_receive {:diffs_descriptor, descriptor}, 5_000
    assert descriptor.backend == Diffs
    assert descriptor.codex_exposure == :direct_model_only
    assert [%{"type" => "function", "name" => encoded, "parameters" => schema}] = first["tools"]
    assert ToolName.decode(encoded) == @name
    assert schema == descriptor.schema
    assert_receive {:diffs_request, 1, following}, 120_000
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000

    assert_receive {"tool_result",
                    %{
                      tool_use_id: @call_id,
                      is_error: false,
                      projection: projection,
                      content: summary
                    }},
                   5_000

    assert [use, result] = diffs_parts(h.session.id)
    assert %ToolUse{tool: @name, tool_use_id: @call_id, input: @arguments} = use

    assert %ToolResult{
             tool_use_id: @call_id,
             is_error: false,
             projection: ^projection,
             content: ^summary
           } = result

    assert projection["version"] == 1
    public = projection["result"]
    details = public["details"]
    assert public["content"] == [%{"type" => "text", "text" => summary}]
    assert details["changed"] == true
    assert details["mode"] == "both"
    assert details["title"] == "Worker comparison"
    assert details["inputKind"] == "before_after"
    assert details["fileCount"] == 1
    assert details["context"] == %{"agentId" => h.agent_config.id, "sessionId" => h.session.id}
    assert details["fileFormat"] == "png"
    assert details["path"] == details["filePath"]
    assert details["fileDelivery"]["session_id"] == h.session.id
    assert {:ok, _, 0} = DateTime.from_iso8601(details["expiresAt"])
    assert {:ok, _, 0} = DateTime.from_iso8601(details["fileExpiresAt"])

    assert summary ==
             "Diff viewer: #{details["viewerUrl"]}\nDiff PNG generated at: #{details["filePath"]}\nTo send this file, use an available file-sending tool to send it as an attachment."

    assert_wire(following, summary)
    assert_part_json_and_concord(h.session.id, [use, result])
    first_bytes = read_both(details)
    assert first_bytes.viewer.bytes =~ "Worker comparison"
    assert first_bytes.viewer.bytes =~ "src/value.ts"
    assert first_bytes.viewer.bytes =~ "const value = 1;"
    assert first_bytes.viewer.bytes =~ "const value = 2;"
    assert first_bytes.file.bytes == File.read!(details["filePath"])
    assert byte_size(first_bytes.file.bytes) == details["fileBytes"]
    assert first_bytes.viewer.record.public_id != first_bytes.file.record.public_id
    before_replacement = renderer_events()

    assert length(
             for {:trace, _, :call, {PortSession, :start_link, _}} <- before_replacement,
                 do: :started
           ) == 1

    assert Enum.map(
             for(
               {:trace, _, :call, {PortSession, :render, [_, plan, _]}} <- before_replacement,
               do: plan
             ),
             & &1["renderTarget"]
           ) == ["viewer", "image"]

    assert Enum.any?(before_replacement, fn event ->
             match?(
               {:trace, _, :return_from, {PortSession, :close, 1},
                {:ok, %{cleanup_confirmed: true, worker_closed: true, exit_status: 0}}},
               event
             )
           end)

    [{old, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
    monitor = Process.monitor(old)
    assert :ok = DynamicSupervisor.stop_session(h.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old, reason}, 5_000
    assert reason in [:normal, :shutdown]
    assert diffs_parts(h.session.id) == [use, result]
    assert_part_json_and_concord(h.session.id, [use, result])

    # New catalog construction uses a new artifact root; old facts keep theirs.
    assert {:ok, current} = ConfigStore.get(:diffs, "default")
    new_root = Path.join(root, "replacement-artifacts")
    File.mkdir_p!(new_root)
    assert {:ok, _} = ConfigStore.put(:diffs, put_in(current, ["host", "artifactRoot"], new_root))
    SessionHarness.ensure_running!(h.session.id)
    [{replacement, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
    refute replacement == old
    assert :ok = Worker.send_message(h.session.id, "Recall the existing comparison receipts")
    assert_receive {:diffs_request, 2, replay}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_wire(replay, summary)
    assert diffs_parts(h.session.id) == [use, result]
    assert_part_json_and_concord(h.session.id, [use, result])
    assert read_both(details) == first_bytes
    assert File.ls!(new_root) == []
    assert renderer_events() == []
    assert [^first, ^following, ^replay] = Agent.get(h.counter, & &1.provider_requests)
    assert :ok = DiffsDelivery.remove_artifact(first_bytes.viewer.record, [])
    assert :ok = DiffsDelivery.remove_artifact(first_bytes.file.record, [])
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

      send(owner, {:diffs_request, index, request})

      if index == 0 do
        [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
        {_, data} = :sys.get_state(worker, 1_000)
        runtime = :sys.get_state(data.runtime_pid, 1_000)

        send(
          owner,
          {:diffs_descriptor, :sys.get_state(runtime.root, 1_000).catalog.registry.tools[@name]}
        )

        item = %{
          "type" => "function_call",
          "id" => "ordinary-diffs-item",
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
        sse(conn, [
          %{"type" => "response.output_text.delta", "delta" => "Comparison received"},
          completed([])
        ])
      end
    end)
  end

  defp assert_wire(request, summary) do
    assert [call] = Enum.filter(request["input"], &(&1["type"] == "function_call"))
    assert call["call_id"] == @call_id
    assert ToolName.decode(call["name"]) == @name
    assert Jason.decode!(call["arguments"]) == @arguments

    assert [%{"type" => "function_call_output", "call_id" => @call_id, "output" => ^summary}] =
             Enum.filter(request["input"], &(&1["type"] == "function_call_output"))
  end

  defp diffs_parts(id) do
    for message <- Synapsis.Message.list_by_session(id),
        part <- message.parts,
        match?(%ToolUse{tool: @name}, part) or match?(%ToolResult{tool_use_id: @call_id}, part),
        do: part
  end

  defp assert_part_json_and_concord(id, [use, result]) do
    for part <- [use, result] do
      assert {:ok, dumped} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dumped |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert {:ok, turns} = Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert({:ok, ^turn} = Store.get_turn(id, index))

    assert [stored_use] =
             for(turn <- turns, part <- turn.parts, part[:type] == "tool_use", do: part)

    assert stored_use.id == use.tool_use_id
    assert stored_use.input == @arguments

    assert [stored_result] =
             for(turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part)

    assert stored_result.tool_use_id == result.tool_use_id
    assert stored_result.content == result.content
    assert stored_result.projection == result.projection
  end

  defp read_both(details) do
    assert ["", "plugins", "diffs", "view", id, token] = String.split(details["viewerPath"], "/")
    assert {:ok, viewer} = DiffsDelivery.read_viewer(id, token, [])
    reference = details["fileDelivery"]
    assert {:ok, file} = DiffsDelivery.read_file(reference["session_id"], reference["id"], [])

    assert {:ok, attachment} =
             DiffsDelivery.resolve_attachment(reference["session_id"], details["filePath"], [])

    assert attachment.bytes == file.bytes
    %{viewer: viewer, file: file}
  end

  defp observe_renderer do
    Code.ensure_loaded!(PortSession)

    for {function, arity} <- [start_link: 1, render: 3, close: 1],
        do:
          :erlang.trace_pattern({PortSession, function, arity}, [{:_, [], [{:return_trace}]}], [
            :local
          ])

    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])

      for {function, arity} <- [start_link: 1, render: 3, close: 1],
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
      {:trace, _, :return_from, {PortSession, _, _}, _} = event -> drain_renderer([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
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
