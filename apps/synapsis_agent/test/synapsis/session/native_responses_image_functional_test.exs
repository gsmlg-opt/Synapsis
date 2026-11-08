defmodule Synapsis.Session.NativeResponsesImageFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Conversation
  alias Backplane.AgentRuntime.Codex.Backend
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @call_id "native-responses-image-call"
  @item_id "native-responses-image-item"
  @arguments %{"path" => "tiny.png", "detail" => "original"}
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="

  test "native image reaches Responses tool output and survives Worker restart replay", %{
    tmp_dir: root
  } do
    bytes = Base.decode64!(@png)
    File.write!(Path.join(root, "tiny.png"), bytes)

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

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{tools: ["view_image"]})

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
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:responses_image_request, index, request})

      if index == 0 do
        [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
        {_, data} = :sys.get_state(worker, 1_000)
        runtime = :sys.get_state(data.runtime_pid, 1_000)
        descriptor = :sys.get_state(runtime.root, 1_000).catalog.registry.tools["view_image"]
        send(owner, {:responses_image_native, worker, descriptor})
        image_call(conn)
      else
        if index == 1 do
          [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
          {_, data} = :sys.get_state(worker, 1_000)
          runtime = :sys.get_state(data.runtime_pid, 1_000)

          native_results =
            runtime.root
            |> Conversation.status()
            |> Map.fetch!(:messages)
            |> Enum.filter(&(&1.role == :tool))

          send(owner, {:responses_image_native_results, native_results})
        end

        text_response(conn)
      end
    end)

    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Inspect the local PNG")
    assert_receive {:responses_image_request, 0, first}, 5_000
    assert_receive {:responses_image_native, worker, descriptor}, 5_000
    assert descriptor.backend == Backend
    assert descriptor.backend_context.family == :local
    assert descriptor.backend_context.context.workspace == root

    assert [%{"type" => "function", "name" => "view_image", "parameters" => schema}] =
             first["tools"]

    assert schema == descriptor.schema
    assert first["model"] == "characterization-model"
    assert_receive {:responses_image_request, 1, following}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    assert_receive {:responses_image_native_results, [%{tool_call_id: @call_id, result: native}]},
                   5_000

    assert native.path == "tiny.png"
    assert native.detail == "original"
    assert native.mime_type == "image/png"
    assert native.bytes == byte_size(bytes)
    assert native.data == bytes
    assert native.image_url == "data:image/png;base64," <> @png

    assert {:ok, turns} = Store.list_turns(harness.session.id)
    parts = for turn <- turns, part <- turn.parts, do: part

    assert [%{id: @call_id, name: "view_image", input: @arguments}] =
             Enum.filter(parts, &(&1[:type] == "tool_use"))

    assert [%{tool_use_id: @call_id, is_error: false, projection: projection, content: summary}] =
             Enum.filter(parts, &(&1[:type] == "tool_result"))

    host_parts = host_parts(harness.session.id)

    assert [%ToolUse{tool_use_id: @call_id, tool: "view_image", input: @arguments}] =
             Enum.filter(host_parts, &match?(%ToolUse{}, &1))

    assert [part] = Enum.filter(host_parts, &match?(%ToolResult{}, &1))

    assert %ToolResult{
             tool_use_id: @call_id,
             is_error: false,
             projection: ^projection,
             content: ^summary
           } = part

    assert {:ok, dump} = Synapsis.Part.dump(part)
    assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()

    assert summary ==
             "Image: tiny.png\nDetail: original\nMIME type: image/png\nBytes: #{byte_size(bytes)}"

    assert projection == %{
             "version" => 1,
             "result" => %{
               "path" => "tiny.png",
               "detail" => "original",
               "mime_type" => "image/png",
               "bytes" => byte_size(bytes),
               "is_error" => false,
               "content" => [
                 %{"type" => "text", "text" => summary},
                 %{
                   "type" => "image",
                   "data" => %{"source" => "base64", "media_type" => "image/png", "data" => @png}
                 }
               ]
             }
           }

    assert [%Text{content: "Image inspected"}] =
             Enum.filter(host_parts, &match?(%Text{content: "Image inspected"}, &1))

    assert_wire_image(following, summary, bytes)

    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert host_parts(harness.session.id) == host_parts
    assert {:ok, ^turns} = Store.list_turns(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    [{restarted, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    assert restarted != worker
    assert :ok = Worker.send_message(harness.session.id, "Describe the image again")
    assert_receive {:responses_image_request, 2, replay}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert_wire_image(replay, summary, bytes)

    replayed_parts = host_parts(harness.session.id)
    assert [^part] = Enum.filter(replayed_parts, &match?(%ToolResult{}, &1))

    assert [%ToolUse{tool_use_id: @call_id, tool: "view_image", input: @arguments}] =
             Enum.filter(replayed_parts, &match?(%ToolUse{}, &1))

    assert [%Text{content: "Image inspected"}, %Text{content: "Image inspected"}] =
             Enum.filter(replayed_parts, &match?(%Text{content: "Image inspected"}, &1))

    assert [
             {"tool_use", %{tool: "view_image", tool_use_id: @call_id, input: @arguments}},
             {"tool_result",
              %{
                tool_use_id: @call_id,
                is_error: false,
                projection: ^projection,
                content: ^summary
              }}
           ] = execution_events()

    assert [^first, ^following, ^replay] = Agent.get(harness.counter, & &1.provider_requests)
    assert File.read!(Path.join(root, "tiny.png")) == bytes
  end

  defp host_parts(session_id) do
    for message <- Synapsis.Message.list_by_session(session_id), part <- message.parts, do: part
  end

  defp execution_events(acc \\ []) do
    receive do
      {type, _payload} = event when type in ["tool_use", "tool_result"] ->
        execution_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_wire_image(request, summary, bytes) do
    assert [call] = Enum.filter(request["input"], &(&1["type"] == "function_call"))

    assert call == %{
             "type" => "function_call",
             "call_id" => @call_id,
             "name" => "view_image",
             "arguments" => Jason.encode!(@arguments)
           }

    assert [output] = Enum.filter(request["input"], &(&1["type"] == "function_call_output"))

    assert output == %{
             "type" => "function_call_output",
             "call_id" => @call_id,
             "output" => [
               %{"type" => "input_text", "text" => summary},
               %{
                 "type" => "input_image",
                 "image_url" => "data:image/png;base64," <> @png,
                 "detail" => "auto"
               }
             ]
           }

    [_, image] = output["output"]
    assert "data:image/png;base64," <> encoded = image["image_url"]
    assert Base.decode64!(encoded) == bytes

    assert Enum.find_index(request["input"], &(&1 == call)) <
             Enum.find_index(request["input"], &(&1 == output))
  end

  defp image_call(conn) do
    item = %{
      "type" => "function_call",
      "id" => @item_id,
      "call_id" => @call_id,
      "name" => "view_image",
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
        "item_id" => @item_id,
        "delta" => Jason.encode!(@arguments)
      },
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      completed([item])
    ])
  end

  defp text_response(conn) do
    sse(conn, [
      %{"type" => "response.output_text.delta", "delta" => "Image inspected"},
      completed([])
    ])
  end

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
