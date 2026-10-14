defmodule Synapsis.Session.Worker.IOHandlerTest do
  # The poll-retry resume race (`:not_waiting`) is eliminated in the Engine
  # collapse (ADR-006 A1) — the Worker now steps the engine inline, so there
  # is no separate Runner process to race against. Tests for IOHandler I/O
  # handling live in the integration-level session worker tests.
  use ExUnit.Case, async: true

  alias Synapsis.Session.Worker
  alias Synapsis.Session.Worker.IOHandler

  @tag :tmp_dir
  test "graph tool dispatch carries the epoch into ask_user notifications", %{tmp_dir: tmp_dir} do
    session_id = Ecto.UUID.generate()
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session_id}")
    tool_id = Ecto.UUID.generate()

    tool_use = %Synapsis.Part.ToolUse{
      tool: "ask_user",
      tool_use_id: tool_id,
      input: %{"question" => "Continue?"}
    }

    IOHandler.handle_dispatch_tools(
      [{:approved, tool_use}],
      %{project_path: tmp_dir, session_id: session_id},
      %Worker{session_id: session_id, epoch: 42}
    )

    assert_receive {:ask_user, ref, payload}, 1_000
    on_exit(fn -> send(payload.owner, {:ask_user_cancelled, ref}) end)
    assert payload.session_epoch == 42
    send(payload.owner, {:ask_user_cancelled, ref})
    assert_receive {:tool_result, 42, ^tool_id, "Question cancelled", true}, 1_000
    assert_receive {:ask_user_closed, ^ref}
  end
end
