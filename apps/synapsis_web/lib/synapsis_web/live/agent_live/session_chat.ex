defmodule SynapsisWeb.AgentLive.SessionChat do
  @moduledoc "Presentation projection for the Agent session React Chat island."

  alias Synapsis.Part
  alias Synapsis.Session.EventReply
  alias SynapsisWeb.{MessageHelpers, ToolResultView}

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

    displayed = assigns.messages |> Enum.map(&display_message/1) |> Enum.reject(&is_nil/1)
    results = settled_tool_results(displayed)
    can_regenerate? = assigns.session_status == "idle" and not waiting? and not subagents?

    %{
      messages:
        Enum.flat_map(displayed, &message(&1, label, can_regenerate?, results)) ++
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

  # The authored input remains in durable/provider history. Only this explicit
  # host completion source is internal to chat presentation; assistant Audio and
  # ordinary prompts still use the existing display projection.
  defp display_message(%Synapsis.Message{
         role: "user",
         internal_turn_source: "event",
         input_provenance: %{
           "kind" => "inter_session",
           "event_type" => "task_completion",
           "source_tool" => "music_generate"
         }
       }),
       do: nil

  defp display_message(message), do: EventReply.display_message(message)

  # Provider history carries tool results as user-role turns. Presentation
  # settles each result onto its matching tool card instead, so a completed
  # call shows its outcome and result-only turns do not render as "You".
  defp settled_tool_results(messages) do
    parts = Enum.flat_map(messages, &(&1.parts || []))
    calls = for %Part.ToolUse{tool_use_id: id} <- parts, into: MapSet.new(), do: id

    for %Part.ToolResult{tool_use_id: id} = result <- parts,
        MapSet.member?(calls, id),
        into: %{},
        do: {id, result}
  end

  defp message(message, label, can_regenerate?, results) do
    raw_parts = message.parts || []

    visible =
      Enum.reject(
        raw_parts,
        &match?(%Part.ToolResult{tool_use_id: id} when is_map_key(results, id), &1)
      )

    if raw_parts != [] and visible == [] do
      []
    else
      [message(message, visible, label, can_regenerate?, results)]
    end
  end

  defp message(message, visible, label, can_regenerate?, results) do
    parts = Enum.map(visible, &settle(part(&1, message.role), results))

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
    presentation = Map.get(assigns, :reply_presentation)
    settled? = is_map(presentation) and presentation.phase in ["committed", "closed"]
    text = if is_map(presentation), do: presentation[:text] || "", else: assigns.streaming_text

    if not settled? and
         (active? or text != "" or assigns.streaming_reasoning != "" or
            map_size(assigns.tool_calls) > 0 or assigns.permission_requests != []) do
      tools =
        Enum.map(Enum.sort(assigns.tool_calls), fn {id, tool} ->
          %{
            id: id,
            name: tool[:name] || "tool",
            status: tool[:status] || "pending",
            input: tool[:input] || %{},
            result: tool[:result],
            display: tool[:display]
          }
        end)

      [
        %{
          id: live_id(assigns.current_session.id),
          role: "assistant",
          content: text,
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

  defp settle(%{type: "tool_use", id: id} = tool, results) when is_map_key(results, id) do
    result = Map.fetch!(results, id)

    Map.merge(tool, %{
      status: if(result.is_error, do: "error", else: "complete"),
      result: result.content,
      display: ToolResultView.present(result)
    })
  end

  defp settle(part, _results), do: part

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

  defp part(%Part.DeliveredImage{} = image, _role),
    do: %{type: "text", content: Part.DeliveredImage.summary(image)}

  defp part(%Part.Audio{} = audio, _role), do: %{type: "text", content: Part.Audio.summary(audio)}

  defp part(%Part.Video{} = video, _role), do: %{type: "text", content: Part.Video.summary(video)}

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
    do:
      tool
      |> Map.from_struct()
      |> Map.delete(:projection)
      |> Map.put(:type, "tool_result")
      |> Map.put(:display, ToolResultView.present(tool))

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
