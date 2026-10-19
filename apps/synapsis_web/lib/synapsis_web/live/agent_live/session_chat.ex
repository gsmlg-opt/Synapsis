defmodule SynapsisWeb.AgentLive.SessionChat do
  @moduledoc "Presentation projection for the Agent session React Chat island."

  alias Synapsis.Part
  alias SynapsisWeb.MessageHelpers

  def live_id(session_id), do: "agent-live-#{session_id}"

  def snapshot(assigns) do
    user_questions = Map.get(assigns, :user_questions, [])
    waiting? = user_questions != []
    active? = assigns.session_status in ~w(streaming tool_executing) or waiting?
    label = assistant_label(assigns.agent_config, assigns.agent_id)
    session = Map.get(assigns, :current_session, %{})
    subagents? = Synapsis.Session.subagents_enabled?(session)
    roster = Map.get(assigns, :subagent_roster, %{})

    recovery? =
      roster[:recovery_required] == true or not is_nil(roster[:error]) or
        get_in(roster, [:root, :status]) in [:unknown_outcome, "unknown_outcome"]

    %{
      messages:
        Enum.map(
          assigns.messages,
          &message(
            &1,
            label,
            assigns.session_status == "idle" and not waiting? and not subagents?
          )
        ) ++
          live_messages(assigns, label, active?) ++
          Enum.map(assigns.queued_inputs, &queued_message/1) ++
          Enum.map(assigns.heartbeat_notifications, &heartbeat_message/1) ++
          Enum.map(Enum.sort(assigns.code_agent_sessions), &code_agent_message/1),
      metadata: %{
        kind: "agent",
        assistantLabel: label,
        assistantAvatar: assistant_avatar(assigns.agent_config),
        attachmentsAllowed: true,
        canStop: true,
        userQuestions: user_questions
      },
      runtime: %{
        phase: if(waiting?, do: "waiting_for_user", else: assigns.session_status),
        active: active?
      },
      admission: %{
        canSubmit:
          assigns.session_status in ~w(idle error streaming tool_executing) and not recovery?,
        allowWhileStreaming: true,
        sendLabel: if(active?, do: "Queue", else: "Send"),
        canSteer: active? and not waiting?,
        canRetry: assigns.session_status == "error" and not subagents?
      }
    }
  end

  defp message(message, label, can_regenerate?) do
    parts = Enum.map(message.parts || [], &part(&1, message.role))

    %{
      id: message.id,
      role: message.role,
      content: parts |> Enum.filter(&(&1.type == "text")) |> Enum.map_join("\n\n", & &1.content),
      status: "complete",
      author: author(message.role, label),
      metadata: %{
        parts: parts,
        timestamp: message.inserted_at,
        tokenCount: message.token_count || 0
      },
      tools: [],
      actions:
        if(message.role == "assistant" and can_regenerate?,
          do: [%{id: "regenerate", label: "Regenerate"}],
          else: []
        )
    }
  end

  defp live_messages(assigns, label, active?) do
    if active? or assigns.streaming_text != "" or assigns.streaming_reasoning != "" or
         map_size(assigns.tool_calls) > 0 or assigns.permission_requests != [] do
      tools =
        Enum.map(Enum.sort(assigns.tool_calls), fn {id, tool} ->
          %{
            id: id,
            name: tool[:name] || "tool",
            status: tool[:status] || "pending",
            input: tool[:input] || %{},
            result: tool[:result]
          }
        end)

      [
        %{
          id: live_id(assigns.current_session.id),
          role: "assistant",
          content: assigns.streaming_text,
          status:
            cond do
              Map.get(assigns, :user_questions, []) != [] -> "pending"
              active? -> "streaming"
              true -> "complete"
            end,
          author: label,
          metadata: %{
            reasoning: assigns.streaming_reasoning,
            permissions:
              Enum.map(
                assigns.permission_requests,
                &Map.take(&1, [:tool, :tool_use_id, :input, :level])
              )
          },
          tools: tools,
          actions: []
        }
      ]
    else
      []
    end
  end

  defp queued_message(input) do
    %{
      id: "queued-input-#{input.id}",
      role: "user",
      content: input.content,
      status: "pending",
      author: "You",
      metadata: %{
        queued: true,
        parts: [
          %{type: "text", content: input.content}
          | Enum.map(Map.get(input, :image_parts, []) || [], &part(&1, "user"))
        ]
      },
      tools: [],
      actions: []
    }
  end

  defp heartbeat_message(notification) do
    %{
      id: "heartbeat-#{notification.id}",
      role: "system",
      content: notification.result,
      status: "complete",
      author: notification.name,
      metadata: %{
        heartbeat: %{
          id: notification.id,
          name: notification.name,
          timestamp: notification.timestamp
        }
      },
      tools: [],
      actions: [%{id: "dismiss_heartbeat", label: "Dismiss"}]
    }
  end

  defp code_agent_message({id, agent}) do
    %{
      id: "code-agent-#{id}",
      role: "assistant",
      content: agent[:completion] || "",
      status: if(agent[:status] == "running", do: "streaming", else: "complete"),
      author: "Code Agent",
      metadata: %{codeAgent: Map.take(agent, [:prompt, :status, :tool_calls, :completion])},
      tools: [],
      actions: []
    }
  end

  defp part(%Part.Text{content: content}, "system") do
    if MessageHelpers.compaction_summary?(content) do
      {count, summary} = MessageHelpers.parse_compaction(content)
      %{type: "compaction", count: count, content: summary}
    else
      %{type: "text", content: content || ""}
    end
  end

  defp part(%Part.Text{content: content}, _role), do: %{type: "text", content: content || ""}

  defp part(%Part.Reasoning{content: content}, _role),
    do: %{type: "reasoning", content: content || ""}

  defp part(%Part.Image{} = image, _role),
    do: image |> Map.from_struct() |> Map.put(:type, "image")

  defp part(%Part.File{} = file, _role), do: file |> Map.from_struct() |> Map.put(:type, "file")

  defp part(%Part.ToolUse{} = tool, _role),
    do: %{
      type: "tool_use",
      id: tool.tool_use_id,
      name: tool.tool,
      input: tool.input,
      status: to_string(tool.status || :pending)
    }

  defp part(%Part.ToolResult{} = tool, _role),
    do: tool |> Map.from_struct() |> Map.put(:type, "tool_result")

  defp part(%Part.Agent{} = agent, _role),
    do: agent |> Map.from_struct() |> Map.put(:type, "agent")

  defp part(%Part.Snapshot{files: files}, _role), do: %{type: "snapshot", files: files}
  defp part(_part, _role), do: %{type: "text", content: ""}

  defp author("user", _label), do: "You"
  defp author("system", _label), do: "System"
  defp author(_role, label), do: label

  defp assistant_label(%{label: label}, agent_id) do
    label = if label in [nil, ""], do: String.capitalize(agent_id), else: label
    if String.ends_with?(label, "Agent"), do: label, else: "#{label} Agent"
  end

  defp assistant_avatar(%{icon: icon}) when is_binary(icon) do
    if String.contains?(icon, "-") or length(String.graphemes(icon)) > 3, do: nil, else: icon
  end

  defp assistant_avatar(_config), do: nil
end
