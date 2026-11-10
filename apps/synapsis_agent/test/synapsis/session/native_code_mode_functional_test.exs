defmodule Synapsis.Session.NativeCodeModeFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Codex
  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}
  alias Backplane.AgentRuntime.Codex.CodeMode, as: NativeCodeMode
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.{CodeMode, DisplayCatalog, Profiles}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @selection ~w(exec wait clock::curr_time exec_command)
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
  @source """
  text(await tools.clock__curr_time({}));
  text(await tools.exec_command({cmd: "printf 'run\\n' >> code-mode-count.txt; printf nested-shell", login: false, yield_time_ms: 1000}));
  store("marker", "continued");
  text("before-image");
  image("data:image/png;base64,#{@png}");
  text("before-yield");
  yield "ordinary-pause";
  text(load("marker"));
  text(await tools.clock__curr_time({}));
  text("after-yield");
  """
  @paused_source "text('owner-pause'); yield 'owner-cell'; text('owner-resumed');"
  @call_ids ~w(code-start code-resume)

  test "selected bundle retains original native descriptors and exact selection metadata" do
    session = start_supervised!({Session, owner_pid: self()})
    run_id = Ecto.UUID.generate()

    authority = %{
      caller: "native-code-mode-functional",
      run_id: run_id,
      grants: ~w(exec wait),
      tool_revision: 1,
      tool_revisions: %{"exec" => 1, "wait" => 1}
    }

    assert {:ok, binding} = Session.bind(session, authority)
    context = %{session_binding: binding}
    assert {:ok, [actual]} = CodeMode.bundles(context, authority, ~w(exec wait))

    assert {:ok, expected} =
             Codex.profile(
               :code_mode,
               Map.put(context, :deno_path, System.find_executable("deno")),
               authority,
               tools: ~w(exec wait)
             )

    assert Enum.sort(Map.keys(actual.registry.tools)) == ~w(exec wait)

    for name <- ~w(exec wait) do
      descriptor = actual.registry.tools[name]
      original = expected.registry.tools[name]

      for key <-
            ~w(tool_name tool_revision backend backend_context schema codex_input_kind codex_format)a do
        assert Map.get(descriptor, key) == Map.get(original, key)
      end

      assert descriptor.backend_context.session_binding == binding
      assert name in Profiles.supported_names()
      assert Enum.any?(DisplayCatalog.list(), &(&1.name == name))
    end

    assert {:ok, [only_exec]} = CodeMode.bundles(context, authority, ["exec"])
    assert Map.keys(only_exec.registry.tools) == ["exec"]
    assert {:ok, []} = CodeMode.bundles(%{}, %{}, [])
    assert {:ok, %{status: :confirmed}} = Session.close(session)
  end

  test "Worker resumes actual Deno nested tools and replays ordered media without repeating effects",
       %{tmp_dir: root} do
    harness = setup_harness(root, @selection)
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/responses", fn conn ->
      {index, request, conn} = capture_request(conn, harness)
      send(owner, {:code_request, index, request})

      case index do
        0 ->
          send(owner, {:code_runtime, runtime(harness.session.id)})
          custom_call(conn, "code-start", @source)

        1 ->
          cell = retained_cell(harness.session.id)
          send(owner, {:code_yielded, self(), cell})

          receive do
            :resume_code_mode ->
              function_call(conn, "code-resume", "wait", %{
                "cell_id" => cell.handle.resource_id,
                "yield_time_ms" => 1000
              })
          after
            5_000 -> raise "Code Mode resume handshake timed out"
          end

        _ ->
          answer(conn)
      end
    end)

    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Run native JavaScript and continue it")
    assert_receive {:code_request, 0, first}, 5_000
    assert_receive {:code_runtime, runtime}, 5_000

    assert Enum.sort(Enum.map(first["tools"], &Synapsis.Provider.ToolName.decode(&1["name"]))) ==
             Enum.sort(@selection)

    assert first["model"] == "characterization-model"

    for name <- ~w(exec wait) do
      descriptor = runtime.catalog.registry.tools[name]
      assert descriptor.backend == Backplane.AgentRuntime.Codex.Backend
      assert descriptor.backend_context.family == :code_mode
      assert descriptor.backend_context.session_binding == runtime.binding

      assert descriptor.backend_context.context.resource_registry ==
               runtime.binding.resource_registry

      assert descriptor.backend_context.context.session_registry ==
               runtime.binding.resource_registry
    end

    assert [%{"type" => "custom", "format" => format}] =
             Enum.filter(first["tools"], &(&1["name"] == "exec"))

    assert format == json_value(runtime.catalog.registry.tools["exec"].codex_format)
    assert format["type"] == "grammar"
    assert format["syntax"] == "lark"

    assert [%{"type" => "function", "parameters" => wait_schema}] =
             Enum.filter(first["tools"], &(&1["name"] == "wait"))

    assert wait_schema == json_value(runtime.catalog.registry.tools["wait"].schema)
    assert_receive {:code_request, 1, yielded_request}, 10_000
    assert_receive {:code_yielded, handler, cell}, 5_000
    assert cell.handle.owner_id == runtime.binding.owner_id
    assert cell.handle.incarnation == runtime.binding.incarnation
    assert cell.handle.kind == :continuation

    assert {:ok, worker} =
             ResourceRegistry.fetch(
               runtime.binding.resource_registry,
               cell.handle,
               runtime.binding.owner_id
             )

    assert worker == cell.worker
    assert Process.alive?(cell.worker)
    assert File.exists?("/proc/#{cell.os_identity.pid}")
    deno_monitor = Process.monitor(cell.worker)

    # Hold the next model response until both the BEAM worker and OS identity
    # have been observed live; resuming may complete and clean them immediately.
    send(handler, :resume_code_mode)
    assert_receive {:code_request, 2, following}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert_receive {:DOWN, ^deno_monitor, :process, ^worker, _}, 5_000
    assert_os_reaped(cell.os_identity.pid)

    parts = tool_parts(harness.session.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == @call_ids
    assert Enum.map(uses, & &1.tool) == ~w(exec wait)

    assert Enum.map(uses, & &1.input) == [
             @source,
             %{"cell_id" => cell.handle.resource_id, "yield_time_ms" => 1000}
           ]

    assert Enum.map(results, & &1.tool_use_id) == @call_ids
    assert Enum.all?(results, &(&1.is_error == false))
    assert [yielded, resumed] = results
    yielded_native = yielded.projection["result"]
    resumed_native = resumed.projection["result"]
    assert yielded_native["status"] == "yielded"
    assert yielded_native["cell_id"] == cell.handle.resource_id
    assert yielded_native["value"] == "ordinary-pause"

    assert [clock, shell, before_image, image, before_yield] = yielded_native["output"]
    assert clock["text"] =~ "current_time"
    assert shell["text"] =~ "nested-shell"
    assert before_image == %{"type" => "text", "text" => "before-image"}
    assert image == %{"type" => "image", "mimeType" => "image/png", "data" => @png}
    assert Base.decode64!(image["data"]) == Base.decode64!(@png)
    assert before_yield == %{"type" => "text", "text" => "before-yield"}
    assert Enum.take(yielded_native["content"], 5) == yielded_native["output"]
    assert yielded.content =~ "Cell ID: " <> cell.handle.resource_id
    assert yielded.content =~ "before-image"
    assert yielded.content =~ "before-yield"

    assert resumed_native["status"] == "completed"
    assert [continued, resumed_clock, after_yield] = resumed_native["output"]
    assert continued == %{"type" => "text", "text" => "continued"}
    assert resumed_clock["text"] =~ "current_time"
    assert after_yield == %{"type" => "text", "text" => "after-yield"}
    assert Enum.take(resumed_native["content"], 3) == resumed_native["output"]
    assert resumed.content =~ "Status: completed"

    assert_wire_history(yielded_request, Enum.take(uses, 1), Enum.take(results, 1))
    assert_wire_history(following, uses, results)
    assert_durable_parts(harness.session.id, uses, results)
    assert File.read!(Path.join(root, "code-mode-count.txt")) == "run\n"

    assert {:ok, aggregate} = Synapsis.Runtime.Store.load(runtime.store.namespace, runtime.run_id)

    intents =
      for {_, intent} <- aggregate.run.execution_intents, intent.type == :tool, do: intent

    assert Enum.sort(Enum.map(intents, & &1.operation.tool_name)) ==
             Enum.sort(~w(exec wait clock::curr_time exec_command clock::curr_time))

    assert map_size(aggregate.run.tool_results) == 5

    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    old_worker = runtime.worker

    monitors =
      for pid <- [
            old_worker,
            runtime.adapter,
            runtime.binding.session,
            runtime.binding.resource_registry
          ],
          do: {pid, Process.monitor(pid)}

    assert :ok = DynamicSupervisor.stop_session(harness.session.id)

    for {pid, monitor} <- monitors,
        do: assert_receive({:DOWN, ^monitor, :process, ^pid, _}, 5_000)

    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    assert new_worker != old_worker
    assert :ok = Worker.send_message(harness.session.id, "Recall the completed Code Mode run")
    assert_receive {:code_request, 3, replay}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert_wire_history(replay, uses, results)
    assert tool_parts(harness.session.id) == parts
    assert_durable_parts(harness.session.id, uses, results)
    assert File.read!(Path.join(root, "code-mode-count.txt")) == "run\n"

    assert [^first, ^yielded_request, ^following, ^replay] =
             Agent.get(harness.counter, & &1.provider_requests)
  end

  test "owning Session retains a yielded cell after turn completion and confirms its cleanup", %{
    tmp_dir: root
  } do
    harness = setup_harness(root, ~w(exec wait))
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/responses", fn conn ->
      {index, request, conn} = capture_request(conn, harness)
      send(owner, {:owner_request, index, request})

      if index == 0 do
        send(owner, {:owner_runtime, runtime(harness.session.id)})
        custom_call(conn, "owner-start", @paused_source)
      else
        send(owner, {:owner_yielded, self(), retained_cell(harness.session.id)})

        receive do
          :complete_owner_turn -> answer(conn)
        after
          5_000 -> raise "Code Mode owner handshake timed out"
        end
      end
    end)

    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Keep a yielded JavaScript cell")
    assert_receive {:owner_request, 0, _first}, 5_000
    assert_receive {:owner_runtime, runtime}, 5_000
    assert_receive {:owner_request, 1, following}, 10_000
    assert_receive {:owner_yielded, handler, cell}, 5_000
    assert Process.alive?(cell.worker)
    assert File.exists?("/proc/#{cell.os_identity.pid}")
    deno_monitor = Process.monitor(cell.worker)
    send(handler, :complete_owner_turn)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert %{phase: :idle} = Session.status(runtime.binding.session)

    assert {:ok, retained} =
             ResourceRegistry.fetch(
               runtime.binding.resource_registry,
               cell.handle,
               runtime.binding.owner_id
             )

    assert retained == cell.worker
    assert NativeCodeMode.Worker.ready_for_detach(retained)
    assert Process.alive?(retained)
    assert File.exists?("/proc/#{cell.os_identity.pid}")
    assert [%ToolUse{} = use, %ToolResult{} = result] = tool_parts(harness.session.id)
    assert result.projection["result"]["status"] == "yielded"
    assert result.projection["result"]["cell_id"] == cell.handle.resource_id
    assert result.projection["result"]["value"] == "owner-cell"
    assert result.projection["result"]["output"] == [%{"type" => "text", "text" => "owner-pause"}]
    assert_wire_history(following, [use], [result])
    assert_durable_parts(harness.session.id, [use], [result])

    assert {:ok, %{status: :confirmed, owner_id: owner_id}} =
             Session.close(runtime.binding.session)

    assert owner_id == runtime.binding.owner_id
    assert_receive {:DOWN, ^deno_monitor, :process, ^retained, _}, 5_000
    assert_os_reaped(cell.os_identity.pid)

    assert %{phase: :closed, cleanup: {:ok, %{status: :confirmed}}} =
             Session.status(runtime.binding.session)

    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_durable_parts(harness.session.id, [use], [result])
  end

  defp setup_harness(root, selection) do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn ->
      SessionHarness.cleanup!(harness)

      case Synapsis.Providers.get_by_name(harness.provider.name) do
        {:ok, provider} -> Synapsis.Providers.delete(provider.id)
        {:error, :not_found} -> :ok
      end
    end)

    assert {:ok, _} = Synapsis.AgentConfigs.update(harness.agent_config, %{tools: selection})

    assert {:ok, provider} =
             Synapsis.Providers.create(%{
               name: harness.provider.name,
               type: "openai_responses",
               base_url: harness.provider.base_url,
               api_key_encrypted: "test-key"
             })

    assert {:ok, %{id: provider_id, type: "openai_responses"}} =
             Synapsis.Providers.get_by_name(harness.provider.name)

    assert provider_id == provider.id

    assert {:ok, %{type: "openai_responses", provider_id: ^provider_id, base_url: base_url}} =
             Synapsis.Providers.runtime_config(harness.provider.name)

    assert base_url == harness.provider.base_url
    harness
  end

  defp capture_request(conn, harness) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)

    index =
      Agent.get_and_update(harness.counter, fn state ->
        {length(state.provider_requests),
         %{state | provider_requests: state.provider_requests ++ [request]}}
      end)

    {index, request, conn}
  end

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker)
    state = :sys.get_state(data.runtime_pid)

    %{
      worker: worker,
      adapter: data.runtime_pid,
      binding: state.binding,
      catalog: :sys.get_state(state.root).catalog,
      run_id: state.run_id,
      store: state.store
    }
  end

  defp retained_cell(id) do
    state = runtime(id)
    resources = :sys.get_state(state.binding.resource_registry).resources
    [resource] = for {_, entry} <- resources, entry.handle.kind == :continuation, do: entry
    assert {:ok, os_identity} = NativeCodeMode.Worker.os_identity(resource.value)
    %{handle: resource.handle, worker: resource.value, os_identity: os_identity}
  end

  defp assert_os_reaped(pid) do
    path = "/proc/#{pid}"
    deadline = System.monotonic_time(:millisecond) + 2_000
    await_os_reaped(path, deadline)
    refute File.exists?(path)
  end

  defp await_os_reaped(path, deadline) do
    if File.exists?(path) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      await_os_reaped(path, deadline)
    end
  end

  defp tool_parts(id) do
    for message <- Synapsis.Sessions.get_messages(id),
        part <- message.parts,
        match?(%ToolUse{}, part) or match?(%ToolResult{}, part),
        do: part
  end

  defp assert_durable_parts(id, uses, results) do
    assert {:ok, turns} = Store.list_turns(id)

    durable =
      for turn <- turns, part <- turn.parts, part[:type] in ~w(tool_use tool_result), do: part

    assert Enum.count(durable, &(&1[:type] == "tool_use")) == length(uses)
    assert Enum.count(durable, &(&1[:type] == "tool_result")) == length(results)

    for use <- uses do
      assert Enum.any?(
               durable,
               &(&1[:type] == "tool_use" and &1[:id] == use.tool_use_id and
                   &1[:name] == use.tool and &1[:input] == use.input)
             )
    end

    for result <- results do
      assert Enum.any?(
               durable,
               &(&1[:type] == "tool_result" and &1[:tool_use_id] == result.tool_use_id and
                   &1[:projection] == result.projection and &1[:content] == result.content and
                   &1[:is_error] == false)
             )
    end
  end

  defp assert_wire_history(request, uses, results) do
    for use <- uses do
      if use.tool == "exec" do
        assert %{
                 "type" => "custom_tool_call",
                 "call_id" => use.tool_use_id,
                 "name" => use.tool,
                 "input" => use.input
               } in request["input"]
      else
        assert Enum.any?(
                 request["input"],
                 &(&1["type"] == "function_call" and &1["call_id"] == use.tool_use_id and
                     &1["name"] == use.tool and Jason.decode!(&1["arguments"]) == use.input)
               )
      end
    end

    for {use, result} <- Enum.zip(uses, results) do
      type = if use.tool == "exec", do: "custom_tool_call_output", else: "function_call_output"
      content = result.projection["result"]["content"]

      output =
        if Enum.any?(content, &(&1["type"] == "image")) do
          Enum.map(content, fn
            %{"type" => "text", "text" => text} ->
              %{"type" => "input_text", "text" => text}

            %{"type" => "image", "mimeType" => mime, "data" => encoded} ->
              %{
                "type" => "input_image",
                "image_url" => "data:" <> mime <> ";base64," <> encoded,
                "detail" => "auto"
              }
          end)
        else
          result.content
        end

      expected = %{"type" => type, "call_id" => result.tool_use_id, "output" => output}
      assert expected in request["input"]

      assert Enum.find_index(
               request["input"],
               &(&1["call_id"] == use.tool_use_id and
                   &1["type"] in ["custom_tool_call", "function_call"])
             ) <
               Enum.find_index(request["input"], &(&1 == expected))
    end
  end

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp custom_call(conn, id, raw) do
    item = %{
      "type" => "custom_tool_call",
      "id" => id <> "-item",
      "call_id" => id,
      "name" => "exec",
      "input" => raw
    }

    sse(conn, [
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => Map.put(item, "input", "")
      },
      %{
        "type" => "response.custom_tool_call_input.delta",
        "item_id" => item["id"],
        "delta" => raw
      },
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      completed([item])
    ])
  end

  defp function_call(conn, id, name, args) do
    encoded = Jason.encode!(args)

    item = %{
      "type" => "function_call",
      "id" => id <> "-item",
      "call_id" => id,
      "name" => name,
      "arguments" => encoded
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
        "delta" => encoded
      },
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      completed([item])
    ])
  end

  defp answer(conn),
    do:
      sse(conn, [
        %{"type" => "response.output_text.delta", "delta" => "Code Mode complete"},
        completed([])
      ])

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
