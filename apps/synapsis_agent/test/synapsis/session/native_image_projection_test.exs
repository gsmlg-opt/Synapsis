defmodule Synapsis.Session.NativeImageProjectionTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Conversation}
  alias Backplane.AgentRuntime.Codex.Backend
  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof
  alias Synapsis.{Message, Part, Session.Store}
  alias Synapsis.Provider.Adapter

  @moduletag :tmp_dir
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="

  test "original native image reaches an actual local Anthropic request after durable reload", %{
    tmp_dir: root
  } do
    bytes = Base.decode64!(@png)
    File.write!(Path.join(root, "tiny.png"), bytes)
    {bundle, runtime} = native_conversation(root, "tiny.png")
    descriptor = bundle.registry.tools["view_image"]
    assert descriptor.backend == Backend
    assert descriptor.backend_context.family == :local
    assert descriptor.backend_context.context.workspace == root

    assert [%{role: :tool, tool_call_id: "image-call", result: native}] =
             Enum.filter(runtime, &(&1.role == :tool))

    assert native.data == bytes
    assert native.bytes == byte_size(bytes)
    assert native.image_url == "data:image/png;base64," <> @png
    refute native.is_error
    assert {:ok, live} = ProviderMessages.tool_result_text(native, "view_image")
    assert {:ok, host} = ProviderMessages.to_host(runtime)
    part = host |> Enum.find(&(&1.role == :tool)) |> Map.fetch!(:parts) |> hd()
    assert part.content == live
    assert {:ok, dump} = Part.dump(part)
    assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Part.load()

    Store.ensure_started()
    session_id = Ecto.UUID.generate()
    on_exit(fn -> Store.delete_session(session_id) end)

    Enum.with_index(host, fn message, index ->
      stored = %Message{
        id: Ecto.UUID.generate(),
        session_id: session_id,
        role: Atom.to_string(message.role),
        parts: message.parts,
        inserted_at: DateTime.utc_now()
      }

      assert :ok = Store.commit_turn(session_id, index, Message.encode(stored), %{})
    end)

    reloaded = Message.list_by_session(session_id)

    reloaded_part =
      reloaded
      |> Enum.find(&Enum.any?(&1.parts, fn part -> match?(%Synapsis.Part.ToolResult{}, part) end))
      |> Map.fetch!(:parts)
      |> hd()

    assert reloaded_part == part
    assert {:ok, replay} = ProviderMessages.from_host(reloaded)
    assert {:ok, replay_host} = ProviderMessages.to_host(replay)
    assert replay_host == host
    public = reloaded_part.projection["result"]
    refute Map.has_key?(public, "data")
    refute Map.has_key?(public, "image_url")
    assert public["path"] == "tiny.png"
    assert public["bytes"] == byte_size(bytes)

    fixture = Gaoxy.Test.open()
    owner = self()

    Gaoxy.Test.expect_once(fixture, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:image_request, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "stop_reason" => "end_turn",
          "content" => [%{"type" => "text", "text" => "seen"}]
        })
      )
    end)

    request = Adapter.format_request(reloaded, [], %{provider_type: :anthropic, model: "fixture"})

    config = %{
      type: "anthropic",
      api_key: "fixture",
      base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
    }

    assert {:ok, "seen"} = Adapter.complete(request, config)
    assert_receive {:image_request, wire}, 1_000
    blocks = Enum.flat_map(wire["messages"], &List.wrap(&1["content"]))

    assert %{"type" => "tool_use", "id" => "image-call", "name" => "view_image"} =
             Enum.find(blocks, &(&1["type"] == "tool_use"))

    assert %{"tool_use_id" => "image-call", "is_error" => false, "content" => [text, image]} =
             Enum.find(blocks, &(&1["type"] == "tool_result"))

    assert text == %{"type" => "text", "text" => live}
    assert image["type"] == "image"
    assert image["source"]["type"] == "base64"
    assert image["source"]["media_type"] == "image/png"
    assert Base.decode64!(image["source"]["data"]) == bytes
  end

  test "original native missing and unsupported files remain explicit errors", %{tmp_dir: root} do
    File.write!(Path.join(root, "unsupported.txt"), "not an image")

    for path <- ["missing.png", "unsupported.txt"] do
      {_bundle, runtime} = native_conversation(root, path)
      assert [%{result: %{is_error: true} = result}] = Enum.filter(runtime, &(&1.role == :tool))
      assert %Backplane.AgentRuntime.Error{} = result.error
      assert {:ok, host} = ProviderMessages.to_host(runtime)
      part = host |> Enum.find(&(&1.role == :tool)) |> Map.fetch!(:parts) |> hd()
      assert part.is_error
      assert part.content == "Tool execution failed"
      assert part.projection["result"]["error"]["class"] == Atom.to_string(result.error.class)
      refute Map.has_key?(part.projection["result"], "data")
      refute Map.has_key?(part.projection["result"], "image_url")
    end
  end

  defp native_conversation(root, path) do
    run_id = "native-image-" <> Ecto.UUID.generate()

    authority = %{
      caller: "image-projection-proof",
      run_id: run_id,
      grants: ["view_image"],
      tool_revision: 1
    }

    assert {:ok, bundle} =
             Codex.profile(:pinned_local, %{workspace: root}, authority, tools: ["view_image"])

    script = fn request ->
      if Enum.any?(request.messages, &(&1.role == :tool)) do
        [Proof.completed("done")]
      else
        [
          %{
            type: :tool_call_completed,
            tool_call: %{
              id: "image-call",
              name: "view_image",
              arguments: %{"path" => path, "detail" => "original"}
            }
          },
          %{
            type: :response_completed,
            message: %{
              role: :assistant,
              content: [
                %{type: :text, text: "reading"},
                %{
                  type: :tool_call,
                  id: "image-call",
                  name: "view_image",
                  arguments: %{"path" => path, "detail" => "original"}
                }
              ]
            }
          }
        ]
      end
    end

    options =
      Proof.options(run_id, script,
        registry: bundle.registry,
        authority: bundle.authority,
        tools: bundle.tools,
        schema_admission: :strict,
        work: 4
      )

    pid = start_supervised!(%{id: make_ref(), start: {Conversation, :start_link, [options]}})
    caller = start_supervised!(%{id: make_ref(), start: {Task.Supervisor, :start_link, [[]]}})
    assert {:ok, _} = Proof.prompt(caller, pid, "Inspect the local image")
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 2_000
    {bundle, Conversation.status(pid).messages}
  end
end
