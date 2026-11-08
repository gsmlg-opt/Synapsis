defmodule Synapsis.Session.WorkerRuntimeTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Session.Worker
  alias Synapsis.Session.Worker.Runtime

  test "idle snapshots retain the runtime failure and its public message" do
    from = {self(), make_ref()}
    reason = Error.new(:unsupported_capability, "Selected tools unavailable or deferred: skills")
    data = %Worker{runtime_history_error: reason}

    assert {:keep_state, ^data, actions} =
             Worker.handle_event({:call, from}, :snapshot, :idle, data)

    assert {:reply, ^from, snapshot} = Enum.find(actions, &match?({:reply, _, _}, &1))
    assert snapshot.status == :error
    assert snapshot.error == reason.message
    refute Map.has_key?(snapshot, :runtime_history_error)
  end

  test "live tool failures expose the same safe text as canonical history" do
    session_id = Ecto.UUID.generate()
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session_id}")
    data = %{session_id: session_id}

    for {error, expected} <- [
          {Error.new(:forbidden, "private message", details: %{secret: "private details"}),
           "Tool denied by capability policy"},
          {Error.new(:execution_failure, "private failure", cause: "private cause"),
           "Tool execution failed"}
        ] do
      assert ^data =
               Runtime.event(data, %{
                 type: :tool_completed,
                 message: %{
                   tool_call_id: "call",
                   result: %{is_error: true, error: error}
                 }
               })

      assert_receive {"tool_result", %{tool_use_id: "call", is_error: true, content: ^expected}}
    end
  end

  test "a rejected approval operation reports the error and retains its pending interaction" do
    session_id = Ecto.UUID.generate()
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session_id}")
    data = %{session_id: session_id, runtime_permissions: [%{interaction_id: "waiting"}]}
    error = Error.new(:forbidden, "An authenticated operator is required for tool approval")

    assert ^data = Runtime.event(data, %{type: :runtime_operation_failed, error: error})
    assert_receive {"error", %{message: message}}
    assert message == error.message
    refute_receive {"runtime_permissions", []}
  end
end
