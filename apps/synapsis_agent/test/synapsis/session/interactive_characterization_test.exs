defmodule Synapsis.Session.InteractiveCharacterizationTest do
  @moduledoc """
  Characterization tests for existing interactive session PubSub projections.

  These lock current UI contracts (`done` / `error` / `session_status` /
  `tool_result` / `permission_requests`) before PR-01 changes internal events.
  """

  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.SessionHarness

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

    assert_receive {:run_event, %{type: "session.completed", session_id: session_id}}, 15_000
    assert session_id == harness.session.id
    assert_receive {"done", %{}}, 15_000
    assert_receive {"session_status", %{status: "idle"}}, 15_000
    assert :ok = SessionHarness.await_waiting!(harness.session.id)

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

    assert_receive {:run_event, %{type: "session.failed"}}, 15_000
    assert_receive {"error", %{message: message}}, 15_000
    assert message =~ "Provider error"
    assert_receive {"session_status", %{status: "error"}}, 15_000
  end
end
