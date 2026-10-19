defmodule Synapsis.Session.WorkerRuntimeTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Session.Worker.Runtime

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
end
