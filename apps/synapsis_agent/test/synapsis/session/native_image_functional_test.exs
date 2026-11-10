defmodule Synapsis.Session.NativeImageFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Codex
  alias Backplane.AgentRuntime.Codex.Backend
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.{DisplayCatalog, Profiles}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @call_id "native-image-call"
  @arguments %{"path" => "tiny.png", "detail" => "original"}
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="

  test "selected native image reaches Worker Anthropic requests and durable next-turn replay", %{
    tmp_dir: root
  } do
    assert "view_image" in Profiles.supported_names()

    assert [%{category: :filesystem}] =
             Enum.filter(DisplayCatalog.list(), &(&1.name == "view_image"))

    bytes = Base.decode64!(@png)
    File.write!(Path.join(root, "tiny.png"), bytes)

    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{tools: ["view_image"]})

    assert :ok =
             Synapsis.Provider.Registry.register(harness.provider.name, %{
               type: "anthropic",
               base_url: harness.provider.base_url,
               api_key: "test-key"
             })

    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:image_request, index, request})

      if index == 0 do
        [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
        {_, data} = :sys.get_state(worker, 1_000)
        runtime = :sys.get_state(data.runtime_pid, 1_000)
        catalog = :sys.get_state(runtime.root, 1_000).catalog
        send(owner, {:image_descriptor, catalog.registry.tools["view_image"], catalog.authority})
        image_call(conn)
      else
        text_response(conn)
      end
    end)

    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Inspect the local PNG")
    assert_receive {:image_request, 0, first}, 5_000
    assert_receive {:image_descriptor, descriptor, authority}, 5_000
    assert descriptor.backend == Backend
    assert descriptor.backend_context.family == :local
    assert descriptor.backend_context.context.workspace == root

    assert {:ok, original} =
             Codex.profile(:pinned_local, descriptor.backend_context.context, authority,
               tools: ["view_image"]
             )

    assert descriptor == original.registry.tools["view_image"]
    assert [%{"name" => "view_image", "input_schema" => schema}] = first["tools"]
    assert schema == descriptor.schema
    assert_receive {:image_request, 1, following}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    assert {:ok, turns} = Store.list_turns(harness.session.id)
    parts = for turn <- turns, part <- turn.parts, do: part

    assert [%{id: @call_id, name: "view_image", input: @arguments}] =
             Enum.filter(parts, &(&1[:type] == "tool_use"))

    assert [%{tool_use_id: @call_id, is_error: false, projection: projection, content: summary}] =
             Enum.filter(parts, &(&1[:type] == "tool_result"))

    host_parts =
      for message <- Synapsis.Message.list_by_session(harness.session.id),
          part <- message.parts,
          do: part

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
    assert projection["result"]["path"] == "tiny.png"
    assert projection["result"]["bytes"] == byte_size(bytes)
    assert projection["result"]["detail"] == "original"

    assert summary ==
             "Image: tiny.png\nDetail: original\nMIME type: image/png\nBytes: #{byte_size(bytes)}"

    assert_wire_image(following, summary, bytes)

    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Describe the image again")
    assert_receive {:image_request, 2, replay}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert_wire_image(replay, summary, bytes)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 3
    assert File.read!(Path.join(root, "tiny.png")) == bytes
  end

  defp assert_wire_image(request, summary, bytes) do
    blocks = Enum.flat_map(request["messages"], &List.wrap(&1["content"]))

    assert %{
             "type" => "tool_use",
             "id" => @call_id,
             "name" => "view_image",
             "input" => @arguments
           } in blocks

    assert %{"tool_use_id" => @call_id, "is_error" => false, "content" => [text, image]} =
             Enum.find(blocks, &(&1["type"] == "tool_result"))

    assert text == %{"type" => "text", "text" => summary}

    assert image == %{
             "type" => "image",
             "source" => %{"type" => "base64", "media_type" => "image/png", "data" => @png}
           }

    assert Base.decode64!(image["source"]["data"]) == bytes
  end

  defp image_call(conn) do
    response(conn, [
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{
          "type" => "tool_use",
          "id" => @call_id,
          "name" => "view_image",
          "input" => %{}
        }
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "input_json_delta", "partial_json" => Jason.encode!(@arguments)}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}},
      %{"type" => "message_stop"}
    ])
  end

  defp text_response(conn) do
    response(conn, [
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "Image inspected"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
      %{"type" => "message_stop"}
    ])
  end

  defp response(conn, events) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.resp(200, Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n")))
  end
end
