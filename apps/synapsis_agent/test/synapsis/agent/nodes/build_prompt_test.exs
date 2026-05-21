defmodule Synapsis.Agent.Nodes.BuildPromptTest do
  use Synapsis.Agent.DataCase, async: true

  alias Synapsis.Agent.Nodes.BuildPrompt
  alias Synapsis.Agent.Graphs.CodingLoop

  setup do
    project =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{path: "/tmp/test-bp", slug: "test-bp", name: "test-bp"})
      |> Repo.insert!()

    session =
      %Synapsis.Session{}
      |> Synapsis.Session.changeset(%{
        title: "test",
        project_id: project.id,
        provider: "anthropic",
        model: "claude-sonnet-4-20250514"
      })
      |> Repo.insert!()

    %{session: session, project: project}
  end

  describe "run/2" do
    test "builds request and advances to :default", %{session: session} do
      state =
        CodingLoop.initial_state(%{session_id: session.id})
        |> Map.put(:agent_config, %{
          name: "test",
          system_prompt: "You are a test agent.",
          model: "claude-sonnet-4-20250514",
          project_id: nil
        })

      assert {:next, :default, new_state} = BuildPrompt.run(state, %{provider: "anthropic"})
      assert is_map(new_state[:request])
      assert new_state.user_input == nil
    end

    test "repairs missing tool results before building provider request", %{session: session} do
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

      %Synapsis.Message{}
      |> Synapsis.Message.changeset(%{
        session_id: session.id,
        role: "user",
        parts: [%Synapsis.Part.Text{content: "next question"}],
        token_count: 2
      })
      |> Repo.insert!()

      state =
        CodingLoop.initial_state(%{session_id: session.id})
        |> Map.put(:agent_config, %{
          name: "test",
          system_prompt: "You are a test agent.",
          model: "claude-sonnet-4-20250514",
          project_id: nil
        })

      assert {:next, :default, new_state} = BuildPrompt.run(state, %{provider: "anthropic"})

      [_assistant, user] = Synapsis.Message.list_by_session(session.id)

      assert [
               %Synapsis.Part.ToolResult{
                 tool_use_id: "tu_cancelled",
                 is_error: true
               },
               %Synapsis.Part.Text{content: "next question"}
             ] = user.parts

      assert [
               %{type: "tool_result", tool_use_id: "tu_cancelled", is_error: true},
               %{type: "text", text: "next question"}
             ] = List.last(new_state.request.messages).content
    end
  end
end
