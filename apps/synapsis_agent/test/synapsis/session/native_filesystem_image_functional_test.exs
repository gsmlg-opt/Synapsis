defmodule Synapsis.Session.NativeFilesystemImageFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Conversation
  alias Backplane.AgentRuntime.Codex.Session, as: NativeSession
  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.Filesystem
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @read "synapsis::read"
  @arguments %{"path" => "texture.png"}
  @text "Read image file [image/png]"
  @contract %{schema_version: 1, output_limit: 5_767_168, json_limit: 11_010_048}
  @identity_keys ~w(run_id incarnation catalog_revision invocation_id tool_name tool_revision turn_id step_id attempt_id tool_call_id enclosing_invocation_id)a
  @nested_source """
  // @exec: {"yield_time_ms":10000,"max_output_tokens":150000}
  const result = await tools.synapsis__read({path: "texture.png"});
  text(JSON.stringify(result));
  return result;
  """

  setup %{tmp_dir: root} do
    previous_node = Application.fetch_env(:synapsis_agent, :filesystem_node)

    Application.put_env(
      :synapsis_agent,
      :filesystem_node,
      System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
    )

    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    assert {:ok, provider} =
             Synapsis.Providers.create(%{
               name: harness.provider.name,
               type: "openai_responses",
               base_url: harness.provider.base_url,
               api_key_encrypted: "fixture-key"
             })

    on_exit(fn ->
      SessionHarness.cleanup!(harness)
      Synapsis.Providers.delete(provider.id)

      case previous_node do
        {:ok, value} -> Application.put_env(:synapsis_agent, :filesystem_node, value)
        :error -> Application.delete_env(:synapsis_agent, :filesystem_node)
      end
    end)

    bytes = original_png()
    File.write!(Path.join(root, "texture.png"), bytes)
    trace = trace_filesystem()
    %{harness: harness, bytes: bytes, expected: expected_source(bytes), trace: trace}
  end

  for mode <- [:direct, :nested] do
    @mode mode

    test "#{mode} canonical image survives next Responses request, Parts, Concord and fresh Worker",
         ctx do
      mode = @mode
      selected = if mode == :direct, do: [@read], else: [@read, "exec"]
      assert {:ok, _} = Synapsis.AgentConfigs.update(ctx.harness.agent_config, %{tools: selected})
      install_provider(ctx)
      SessionHarness.subscribe!(ctx.harness.session.id)
      SessionHarness.ensure_running!(ctx.harness.session.id)

      assert :ok =
               Worker.switch_model(ctx.harness.session.id, ctx.harness.provider.name, "gpt-4o")

      assert :ok = Worker.send_message(ctx.harness.session.id, "Read the original local image")
      first = request(0)
      initial = first.runtime
      descriptor = initial.catalog.registry.tools[@read]
      assert descriptor.backend == Filesystem
      assert descriptor.tool_revision == 1
      assert descriptor.backend_context.root == ctx.tmp_dir
      assert descriptor.backend_context.run_id == initial.run_id
      assert descriptor.backend_context.incarnation == initial.binding.run_incarnation
      assert descriptor.backend_context.catalog_revision == initial.catalog.revision
      assert descriptor.backend_context.execution_options[:model_has_vision] == true
      refute Keyword.has_key?(descriptor.backend_context.execution_options, :auto_resize_images)

      assert descriptor.backend_context.execution_options[:node_executable] ==
               System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")

      assert {:ok, issued} = Filesystem.descriptors(descriptor.backend_context)
      assert descriptor in issued

      assert Enum.sort(Enum.map(first.request["tools"], &ToolName.decode(&1["name"]))) ==
               Enum.sort(selected)

      {call_id, call_name, arguments} = call(mode)
      send(first.handler, {:invoke, call_id, call_name, arguments})
      following = request(1)
      observed = traced(ctx.trace)

      [executed] =
        for {:trace, _, :call, {Filesystem, :execute, [operation]}} <- observed,
            do: operation

      assert executed.tool_name == @read
      assert executed.tool_revision == 1
      assert executed.arguments == @arguments
      assert executed.result_contract == @contract
      assert executed.run_id == initial.run_id
      assert executed.incarnation == initial.binding.run_incarnation
      assert executed.backend_context.root == ctx.tmp_dir

      assert [ctx.expected] ==
               for(
                 {:trace, _, :return_from, {Filesystem, :execute, 1}, {:ok, result}} <- observed,
                 do: json_value(result)
               )

      assert_prepared_target(descriptor, initial.catalog, executed, ctx.tmp_dir)
      assert {:ok, aggregate} = Synapsis.Agent.Runtime.Store.load(initial.store, initial.run_id)
      read_intent = aggregate.run.execution_intents["tool:" <> executed.invocation_id]
      assert read_intent.status == :consumed
      assert read_intent.operation.result_contract == @contract
      assert read_intent.operation.arguments == @arguments
      expected_result = Map.put(ctx.expected, "is_error", false)

      assert json_value(aggregate.run.tool_results[executed.invocation_id]) == expected_result

      assert {:ok, host_messages} =
               ProviderMessages.to_host(Conversation.status(following.runtime.root).messages)

      host_parts = for message <- host_messages, part <- message.parts, do: part
      [use] = Enum.filter(host_parts, &match?(%ToolUse{}, &1))
      [result] = Enum.filter(host_parts, &match?(%ToolResult{}, &1))
      assert use.tool_use_id == call_id
      assert use.tool == call_name
      assert use.input == arguments
      assert result.tool_use_id == call_id
      assert result.is_error == false

      case mode do
        :direct ->
          assert executed.tool_call_id == call_id
          assert executed.enclosing_invocation_id == executed.invocation_id
          assert result.content == @text

          assert result.projection == %{
                   "version" => 2,
                   "tool_name" => @read,
                   "result" => expected_result
                 }

        :nested ->
          outer = aggregate.run.execution_intents["tool:" <> executed.enclosing_invocation_id]
          assert outer.status == :consumed
          assert outer.operation.tool_name == "exec"
          assert outer.operation.tool_call_id == call_id
          assert outer.operation.arguments == @nested_source
          assert executed.invocation_id != outer.operation.invocation_id
          native_outer = json_value(aggregate.run.tool_results[outer.operation.invocation_id])
          assert native_outer["status"] == "completed"
          assert native_outer["value"] == ctx.expected
          assert native_outer["output_truncated"] == false
          assert [%{"type" => "text", "text" => logged}] = native_outer["output"]
          assert Jason.decode!(logged) == ctx.expected
          assert result.projection["version"] == 2
          assert result.projection["tool_name"] == "exec"
          projected = result.projection["result"]
          assert Map.drop(projected, ["content"]) == native_outer
          assert projected["value"] == ctx.expected
          assert projected["output"] == native_outer["output"]
          assert Enum.take(projected["content"], 1) == native_outer["output"]
          assert Jason.decode!(hd(projected["content"])["text"]) == ctx.expected
          assert :sys.get_state(initial.binding.resource_registry, 1_000).resources == %{}
      end

      assert_wire(following.request, use, result, mode, ctx.bytes)
      send(following.handler, :complete)
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000
      original_messages = Synapsis.Message.list_by_session(ctx.harness.session.id)
      original_parts = for message <- original_messages, part <- message.parts, do: part
      original_turns = assert_durable(ctx.harness.session.id, [use, result])

      for part <- original_parts do
        assert {:ok, dumped} = Synapsis.Part.dump(part)
        assert {:ok, ^part} = dumped |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
      end

      assert %{phase: :idle} = NativeSession.status(initial.binding.session)
      traced(ctx.trace)

      monitors =
        for pid <- [
              initial.worker,
              initial.adapter,
              initial.binding.session,
              initial.binding.resource_registry
            ],
            do: {pid, Process.monitor(pid)}

      assert :ok = DynamicSupervisor.stop_session(ctx.harness.session.id)

      for {pid, monitor} <- monitors,
          do: assert_receive({:DOWN, ^monitor, :process, ^pid, _}, 10_000)

      SessionHarness.ensure_running!(ctx.harness.session.id)
      assert :ok = Worker.send_message(ctx.harness.session.id, "Recall the completed image read")
      replay = request(2)
      assert replay.runtime.worker != initial.worker
      assert replay.runtime.adapter != initial.adapter
      assert_wire(replay.request, use, result, mode, ctx.bytes)
      send(replay.handler, :complete)
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000

      messages = Synapsis.Message.list_by_session(ctx.harness.session.id)
      assert Enum.take(messages, length(original_messages)) == original_messages

      assert for(message <- messages, part <- message.parts, do: part) ==
               original_parts ++
                 [
                   %Text{content: "Recall the completed image read"},
                   %Text{content: "Image read complete"}
                 ]

      turns = assert_durable(ctx.harness.session.id, [use, result])
      assert Enum.take(turns, length(original_turns)) == original_turns
      assert durable_tool_parts(ctx.harness.session.id) == [use, result]
      assert File.read!(Path.join(ctx.tmp_dir, "texture.png")) == ctx.bytes

      assert [] ==
               for(
                 {:trace, _, :call, {Filesystem, :execute, [_]}} <- traced(ctx.trace),
                 do: :read
               )

      assert [first.request, following.request, replay.request] ==
               Agent.get(ctx.harness.counter, & &1.provider_requests)
    end
  end

  # Frozen before production changes: one 400x300 RGB texture. This constructs a
  # valid input PNG, not an image decoder or a replica of source read behavior.
  # Every pixel byte and dimension stays identical in the two independent cases.
  defp original_png do
    pixels =
      for(index <- 0..11_249, into: <<>>, do: :crypto.hash(:sha256, <<index::unsigned-big-32>>))

    scanlines =
      for row <- 0..299, into: <<>> do
        <<0>> <> binary_part(pixels, row * 1_200, 1_200)
      end

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      png_chunk("IHDR", <<400::unsigned-big-32, 300::unsigned-big-32, 8, 2, 0, 0, 0>>) <>
      png_chunk("IDAT", :zlib.compress(scanlines)) <> png_chunk("IEND", <<>>)
  end

  defp png_chunk(type, payload) do
    <<byte_size(payload)::unsigned-big-32>> <>
      type <> payload <> <<:erlang.crc32(type <> payload)::unsigned-big-32>>
  end

  # Literal source envelope: read_content.mjs at OpenClaw 488631c returns this
  # ordered text/image pair; image-resize.mjs preserves this ordinary PNG input.
  defp expected_source(bytes) do
    %{
      "content" => [
        %{"type" => "text", "text" => @text},
        %{"type" => "image", "data" => Base.encode64(bytes), "mimeType" => "image/png"}
      ],
      "details" => %{"kind" => "image", "content" => @text, "mimeType" => "image/png"}
    }
  end

  defp call(:direct), do: {"direct-image-read", @read, @arguments}
  defp call(:nested), do: {"nested-image-read", "exec", @nested_source}

  defp install_provider(ctx) do
    owner = self()

    Gaoxy.Test.stub(ctx.harness.provider.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = read_body(conn, "")
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(ctx.harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(
        owner,
        {:filesystem_image_request, index, request, self(), runtime(ctx.harness.session.id)}
      )

      receive do
        {:invoke, id, "exec", source} -> custom_call(conn, id, source)
        {:invoke, id, name, arguments} -> function_call(conn, id, name, arguments)
        :complete -> answer(conn)
      after
        20_000 -> raise "ordinary image provider handshake timed out"
      end
    end)
  end

  defp read_body(conn, acc) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> {:ok, acc <> body, conn}
      {:more, body, conn} -> read_body(conn, acc <> body)
    end
  end

  defp request(index) do
    receive do
      {:filesystem_image_request, ^index, request, handler, runtime} ->
        %{index: index, request: request, handler: handler, runtime: runtime}
    after
      20_000 -> flunk("No ordinary filesystem image provider request #{index}")
    end
  end

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker, 1_000)
    native = :sys.get_state(data.runtime_pid, 1_000)

    %{
      worker: worker,
      adapter: data.runtime_pid,
      root: native.root,
      binding: native.binding,
      store: native.store,
      run_id: native.run_id,
      catalog: :sys.get_state(native.root, 1_000).catalog
    }
  end

  defp assert_prepared_target(descriptor, catalog, operation, root) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(operation.arguments, [:deterministic]))

    assert {:ok, record} =
             descriptor.backend_context.prepared_target_resolver.(
               Map.take(operation, @identity_keys),
               catalog,
               digest
             )

    assert record.public_path == "texture.png"
    assert record.source_path == "texture.png"
    assert record.source_prefix == ""
    assert record.target == {:local, Path.join(root, "texture.png"), "texture.png"}
    assert record.prepared_arguments_digest == digest
  end

  defp assert_wire(request, use, result, mode, bytes) do
    encoded_use = Enum.find(request["input"], &(&1["call_id"] == use.tool_use_id))
    assert ToolName.decode(encoded_use["name"]) == use.tool

    output =
      Enum.find(request["input"], fn item ->
        item["type"] in ~w(function_call_output custom_tool_call_output) and
          item["call_id"] == result.tool_use_id
      end)

    case mode do
      :direct ->
        assert encoded_use["type"] == "function_call"
        assert Jason.decode!(encoded_use["arguments"]) == @arguments

        assert output == %{
                 "type" => "function_call_output",
                 "call_id" => use.tool_use_id,
                 "output" => [
                   %{"type" => "input_text", "text" => @text},
                   %{
                     "type" => "input_image",
                     "image_url" => "data:image/png;base64," <> Base.encode64(bytes),
                     "detail" => "auto"
                   }
                 ]
               }

      :nested ->
        assert encoded_use["type"] == "custom_tool_call"
        assert encoded_use["input"] == @nested_source

        assert output == %{
                 "type" => "custom_tool_call_output",
                 "call_id" => use.tool_use_id,
                 "output" => result.content
               }

        [logged | _] = result.projection["result"]["content"]
        assert Jason.decode!(logged["text"]) == expected_source(bytes)
        assert String.starts_with?(output["output"], logged["text"])
    end
  end

  defp durable_tool_parts(id) do
    for message <- Synapsis.Message.list_by_session(id),
        part <- message.parts,
        match?(%ToolUse{}, part) or match?(%ToolResult{}, part),
        do: part
  end

  defp assert_durable(id, original) do
    assert {:ok, turns} = Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert(Store.get_turn(id, index) == {:ok, turn})

    persisted =
      for turn <- turns, part <- turn.parts, part[:type] in ~w(tool_use tool_result), do: part

    assert Enum.map(persisted, fn
             %{type: "tool_use"} = part ->
               {:use, part.id, part.name, part.input}

             %{type: "tool_result"} = part ->
               {:result, part.tool_use_id, part.content, part.projection, part.is_error}
           end) ==
             Enum.map(original, fn
               %ToolUse{} = part ->
                 {:use, part.tool_use_id, part.tool, part.input}

               %ToolResult{} = part ->
                 {:result, part.tool_use_id, part.content, part.projection, part.is_error}
             end)

    turns
  end

  defp trace_filesystem do
    Code.ensure_loaded!(Filesystem)
    trace = :trace.session_create(:filesystem_image358, self(), [])
    on_exit(fn -> :trace.session_destroy(trace) end)
    :trace.function(trace, {Filesystem, :execute, 1}, [{:_, [], [{:return_trace}]}], [:local])
    :trace.process(trace, :all, true, [:call])
    trace
  end

  defp traced(trace) do
    barrier = :trace.delivered(trace, :all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    drain_trace([])
  end

  defp drain_trace(acc) do
    receive do
      {:trace, _, :call, _} = event -> drain_trace([event | acc])
      {:trace, _, :return_from, _, _} = event -> drain_trace([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp function_call(conn, id, name, arguments) do
    item = %{
      "type" => "function_call",
      "id" => id <> "-item",
      "call_id" => id,
      "name" => ToolName.encode(name),
      "arguments" => Jason.encode!(arguments)
    }

    response(conn, [
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
  end

  defp custom_call(conn, id, source) do
    item = %{
      "type" => "custom_tool_call",
      "id" => id <> "-item",
      "call_id" => id,
      "name" => "exec",
      "input" => source
    }

    response(conn, [
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => Map.put(item, "input", "")
      },
      %{
        "type" => "response.custom_tool_call_input.delta",
        "item_id" => item["id"],
        "delta" => source
      },
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      completed([item])
    ])
  end

  defp answer(conn),
    do:
      response(conn, [
        %{"type" => "response.output_text.delta", "delta" => "Image read complete"},
        completed([])
      ])

  defp completed(output),
    do: %{
      "type" => "response.completed",
      "response" => %{"status" => "completed", "output" => output}
    }

  defp response(conn, events),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
      )
end
