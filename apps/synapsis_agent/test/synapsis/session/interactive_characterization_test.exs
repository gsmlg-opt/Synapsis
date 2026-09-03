defmodule Synapsis.Session.InteractiveCharacterizationTest do
  @moduledoc """
  Characterization tests for existing interactive session PubSub projections.

  These lock current UI contracts (`done` / `error` / `session_status` /
  `tool_result` / `permission_requests`) before PR-01 changes internal events.
  """

  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.{DeterministicTool, SessionHarness}
  alias Synapsis.Session.Worker

  @moduletag :tmp_dir

  @tag :tmp_dir
  test "successful text turn projects done and idle session_status", %{tmp_dir: tmp_dir} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        scenario: :success,
        text: "hello characterization"
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok = Synapsis.Sessions.send_message(harness.session.id, "say hello")

    assert_receive {"done", %{}}, 15_000
    assert_receive {"session_status", %{status: "idle"}}, 15_000
    assert :waiting = Worker.get_status(harness.session.id)

    messages = Synapsis.Sessions.get_messages(harness.session.id)

    assert Enum.any?(messages, fn msg ->
             Enum.any?(
               msg.parts,
               &match?(%Synapsis.Part.Text{content: "hello characterization"}, &1)
             )
           end)
  end

  @tag :tmp_dir
  test "provider failure projects error and error session_status", %{tmp_dir: tmp_dir} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        scenario: :provider_failure
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok = Synapsis.Sessions.send_message(harness.session.id, "this will fail")

    assert_receive {"error", %{message: message}}, 15_000
    assert message =~ "Provider error"
    assert_receive {"session_status", %{status: "error"}}, 15_000
  end

  @tag :tmp_dir
  test "read tool success projects tool_result then done", %{tmp_dir: tmp_dir} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        scenario: :multi_turn_tool_result,
        tool_behavior: :read_success,
        permission_mode: "yolo",
        text: "tool path complete",
        tool_args: %{"value" => "verified"}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok = Synapsis.Sessions.send_message(harness.session.id, "run the tool")

    tool_name = harness.tool_name
    tool_call_id = harness.provider.tool_call_id

    assert_receive {"tool_result",
                    %{
                      tool_use_id: ^tool_call_id,
                      content: "deterministic read: verified",
                      is_error: false
                    }},
                   15_000

    assert_receive {"done", %{}}, 15_000
    assert_receive {"session_status", %{status: "idle"}}, 15_000
    assert length(DeterministicTool.executions(tool_name)) == 1
  end

  @tag :tmp_dir
  test "destructive tool under restrict projects permission_requests", %{tmp_dir: tmp_dir} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        scenario: :multi_turn_tool_result,
        tool_behavior: :deny,
        permission_mode: "restrict",
        tool_args: %{"value" => "need-approval"}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    tool_name = harness.tool_name
    tool_call_id = harness.provider.tool_call_id

    assert :requires_approval =
             Synapsis.Tool.Permission.check(tool_name, %{"value" => "need-approval"}, %{
               session_id: harness.session.id
             })

    assert :ok = Synapsis.Sessions.send_message(harness.session.id, "run destructive tool")

    assert_receive {"permission_requests",
                    %{
                      tools: [
                        %{
                          tool: ^tool_name,
                          tool_use_id: ^tool_call_id
                        }
                      ]
                    }},
                   15_000
  end

  @tag :tmp_dir
  test "tool crash projects tool_result error then continues to terminal projection", %{
    tmp_dir: tmp_dir
  } do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        scenario: :multi_turn_tool_result,
        tool_behavior: :crash,
        permission_mode: "yolo",
        text: "recovered after tool error",
        tool_opts: [max_retries: 0]
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    tool_call_id = harness.provider.tool_call_id

    assert :ok = Synapsis.Sessions.send_message(harness.session.id, "crash the tool")

    assert_receive {"tool_result",
                    %{
                      tool_use_id: ^tool_call_id,
                      is_error: true,
                      content: content
                    }},
                   15_000

    assert content =~ ~r/crash|failed|error/i

    # Coding loop continues after tool error and completes the second provider turn.
    assert_receive {"done", %{}}, 15_000
    assert_receive {"session_status", %{status: "idle"}}, 15_000
  end
end
