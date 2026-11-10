defmodule Synapsis.Session.NativePatchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Codex.{ApplyPatch, Backend}
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.Profiles
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Session.{Store, Worker}

  @moduletag :tmp_dir
  @call_id "native-patch-call"
  @patch """
  *** Begin Patch
  *** Add File: created.txt
  +first 你好
  *** Update File: created.txt
  @@
  -first 你好
  +second 你好
  *** Update File: existing.txt
  @@
  -before
  +after
  *** Delete File: obsolete.txt
  *** Update File: source.txt
  *** Move to: nested/destination.txt
  @@
  -move before
  +move after
  *** End Patch
  """

  test "public preflight preserves ordered repeated targets and leaves ordinary files unchanged",
       ctx do
    seed(ctx.tmp_dir)
    before = files(ctx.tmp_dir)
    assert {:ok, inspected} = ApplyPatch.preflight(ctx.tmp_dir, @patch)
    assert inspected.root == ctx.tmp_dir
    assert inspected.patch_sha256 == Base.encode16(:crypto.hash(:sha256, @patch), case: :lower)

    assert inspected.operations == [
             %{kind: :add, path: path(ctx, "created.txt")},
             %{kind: :update, path: path(ctx, "created.txt"), destination: nil},
             %{kind: :update, path: path(ctx, "existing.txt"), destination: nil},
             %{kind: :delete, path: path(ctx, "obsolete.txt")},
             %{
               kind: :update,
               path: path(ctx, "source.txt"),
               destination: path(ctx, "nested/destination.txt")
             }
           ]

    assert files(ctx.tmp_dir) == before
  end

  test "selected native raw patch executes through Worker and Responses with durable replay",
       ctx do
    assert "apply_patch" in Profiles.supported_names()
    seed(ctx.tmp_dir)

    harness =
      SessionHarness.setup_session!(
        tmp_dir: ctx.tmp_dir,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{tools: ["apply_patch"]})

    assert :ok =
             Synapsis.Provider.Registry.register(harness.provider.name, %{
               type: "openai_responses",
               base_url: harness.provider.base_url,
               api_key: "test-key"
             })

    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:patch_request, index, request})

      if index == 0 do
        [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
        {_, data} = :sys.get_state(worker, 1_000)
        runtime = :sys.get_state(data.runtime_pid, 1_000)
        descriptor = :sys.get_state(runtime.root, 1_000).catalog.registry.tools["apply_patch"]
        send(owner, {:patch_descriptor, descriptor})

        item = %{
          "type" => "custom_tool_call",
          "id" => "native-patch-item",
          "call_id" => @call_id,
          "name" => "apply_patch",
          "input" => @patch
        }

        sse(conn, [
          %{
            "type" => "response.output_item.added",
            "output_index" => 0,
            "item" => Map.put(item, "input", "")
          },
          %{
            "type" => "response.custom_tool_call_input.delta",
            "item_id" => "native-patch-item",
            "delta" => @patch
          },
          %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
          completed([item])
        ])
      else
        sse(conn, [
          %{"type" => "response.output_text.delta", "delta" => "Patch complete"},
          completed([])
        ])
      end
    end)

    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    assert :ok = Worker.send_message(harness.session.id, "Apply the multi-action patch")
    assert_receive {:patch_request, 0, first}, 5_000
    assert_receive {:patch_descriptor, descriptor}, 5_000
    assert descriptor.backend == Backend
    assert descriptor.backend_context.family == :local
    assert descriptor.codex_input_kind == :custom
    assert [%{"type" => "custom", "name" => "apply_patch", "format" => format}] = first["tools"]
    assert format == descriptor.codex_format
    assert format["type"] == "grammar"
    assert format["syntax"] == "lark"
    assert format["definition"] =~ "*** Begin Patch"
    assert_receive {:patch_request, 1, following}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    expected_files = [
      %{"action" => "added", "path" => path(ctx, "created.txt")},
      %{"action" => "updated", "path" => path(ctx, "created.txt")},
      %{"action" => "updated", "path" => path(ctx, "existing.txt")},
      %{"action" => "deleted", "path" => path(ctx, "obsolete.txt")},
      %{
        "action" => "moved",
        "from" => path(ctx, "source.txt"),
        "path" => path(ctx, "nested/destination.txt")
      }
    ]

    assert files(ctx.tmp_dir) == %{
             "created.txt" => "second 你好\n",
             "existing.txt" => "after\n",
             "nested/destination.txt" => "move after\n"
           }

    assert {:ok, turns} = Store.list_turns(harness.session.id)
    parts = for turn <- turns, part <- turn.parts, do: part
    assert [raw_use] = Enum.filter(parts, &(&1[:type] == "tool_use"))
    assert %{id: @call_id, name: "apply_patch", input: @patch} = raw_use
    assert [raw_result] = Enum.filter(parts, &(&1[:type] == "tool_result"))

    assert %{
             tool_use_id: @call_id,
             is_error: false,
             projection: projection,
             content: summary
           } = raw_result

    host_parts =
      for message <- Synapsis.Sessions.get_messages(harness.session.id),
          part <- message.parts,
          do: part

    assert [%ToolUse{tool_use_id: @call_id, tool: "apply_patch", input: @patch}] =
             Enum.filter(host_parts, &match?(%ToolUse{}, &1))

    assert [
             %ToolResult{
               tool_use_id: @call_id,
               is_error: false,
               projection: ^projection,
               content: ^summary
             }
           ] = Enum.filter(host_parts, &match?(%ToolResult{}, &1))

    assert projection["result"]["files"] == expected_files
    assert projection["result"]["status"] == "applied"
    assert summary =~ "Patch applied"
    assert summary =~ "Moved:"
    assert_wire_replay(following, summary)

    assert :ok = Worker.send_message(harness.session.id, "Summarize the completed patch")
    assert_receive {:patch_request, 2, replay}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert_wire_replay(replay, summary)
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 3
  end

  defp assert_wire_replay(request, summary) do
    assert %{
             "type" => "custom_tool_call",
             "call_id" => @call_id,
             "name" => "apply_patch",
             "input" => @patch
           } in request["input"]

    assert %{"type" => "custom_tool_call_output", "call_id" => @call_id, "output" => summary} in request[
             "input"
           ]
  end

  defp seed(root) do
    File.write!(Path.join(root, "existing.txt"), "before\n")
    File.write!(Path.join(root, "obsolete.txt"), "remove\n")
    File.write!(Path.join(root, "source.txt"), "move before\n")
  end

  defp path(ctx, relative), do: Path.join(ctx.tmp_dir, relative)

  defp files(root) do
    Path.wildcard(Path.join(root, "**/*"))
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, root), File.read!(&1)})
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
