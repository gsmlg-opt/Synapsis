defmodule Synapsis.Session.WorkerTest do
  use Synapsis.Agent.DataCase, async: true

  alias Synapsis.Session.Worker

  describe "handle_cast(:cancel, state)" do
    test "writes cancellation tool results for open tool uses" do
      project =
        %Synapsis.Project{}
        |> Synapsis.Project.changeset(%{
          path: "/tmp/worker-test",
          slug: "worker-test",
          name: "worker-test"
        })
        |> Repo.insert!()

      session =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          title: "test",
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          status: "streaming"
        })
        |> Repo.insert!()

      tool_use = %Synapsis.Part.ToolUse{
        tool: "bash",
        tool_use_id: "tu_cancelled",
        input: %{"command" => "sleep 10"},
        status: :pending
      }

      %Synapsis.Message{}
      |> Synapsis.Message.changeset(%{
        session_id: session.id,
        role: "assistant",
        parts: [tool_use],
        token_count: 10
      })
      |> Repo.insert!()

      state = %Worker{
        session_id: session.id,
        session: session,
        execution_mode: :graph
      }

      assert {:noreply, _new_state, _timeout} = Worker.handle_cast(:cancel, state)

      [_assistant, result] = Synapsis.Message.list_by_session(session.id)

      assert [
               %Synapsis.Part.ToolResult{
                 tool_use_id: "tu_cancelled",
                 content: "Tool use cancelled by user.",
                 is_error: true
               }
             ] = result.parts
    end
  end
end
