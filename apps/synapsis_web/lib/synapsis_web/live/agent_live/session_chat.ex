defmodule SynapsisWeb.AgentLive.SessionChat do
  @moduledoc "Presentation projection for the Agent session React Chat island."

  alias Synapsis.{Message, Part}
  alias Synapsis.Session.EventReply
  alias SynapsisServer.VoiceImageController
  alias SynapsisWeb.{MessageHelpers, ToolResultView}

  def live_id(session_id), do: "agent-live-#{session_id}"

  def snapshot(assigns) do
    user_questions = Map.get(assigns, :user_questions, [])
    waiting? = user_questions != []
    label = assistant_label(assigns.agent_config, assigns.agent_id)
    session = Map.get(assigns, :current_session, %{})
    voice? = Synapsis.Sessions.voice?(session)

    host_history? = Synapsis.Sessions.host_history?(session, assigns.agent_config)
    voice = Map.get(assigns, :voice_chat) || %{}
    voice_phase = Map.get(voice, :phase, :offline)
    voice_ready? = voice_phase in [:listening, :responding]

    active? =
      if voice?,
        do: voice_phase == :responding,
        else: assigns.session_status in ~w(streaming tool_executing) or waiting?

    subagents? = Synapsis.Session.subagents_enabled?(session)
    roster = Map.get(assigns, :subagent_roster, %{})

    recovery? =
      roster[:recovery_required] == true or not is_nil(roster[:error]) or
        get_in(roster, [:root, :status]) in [:unknown_outcome, "unknown_outcome"]

    messages = if voice?, do: Map.get(voice, :messages, []), else: assigns.messages

    displayed =
      messages
      |> Enum.with_index(fn message, index ->
        case display_message(message) do
          nil ->
            nil

          message when voice? ->
            voice_message(message, voice.facts, assigns.voice_image_token, index)

          message ->
            message
        end
      end)
      |> Enum.reject(&is_nil/1)

    live =
      if voice?,
        do: voice_reply(voice[:reply], label),
        else: live_messages(assigns, label, active?)

    results = settled_tool_results(displayed)

    message_actions = %{
      voice: voice? or host_history?,
      regenerate: assigns.session_status == "idle" and not waiting? and not subagents?,
      branch_and_send: assigns.session_status in ~w(idle error) and not waiting? and not recovery?
    }

    %{
      messages:
        Enum.flat_map(displayed, &message(&1, label, message_actions, results)) ++
          live ++
          Enum.map(assigns.heartbeat_notifications, &heartbeat_message/1) ++
          Enum.map(Enum.sort(assigns.code_agent_sessions), &code_agent_message/1),
      metadata: %{
        kind: "agent",
        host: assigns.composer_host,
        access: access_label(assigns, host_history?),
        sessionKind: if(voice?, do: "Voice", else: "Chat"),
        model: composer_model(assigns, voice?, host_history?),
        assistantLabel: label,
        assistantAvatar: assistant_avatar(assigns.agent_config),
        attachmentsAllowed: not host_history?,
        canStop: not voice? and not host_history?,
        voiceCall: voice?,
        voiceQueued: Map.get(voice, :queued, 0),
        userQuestions: user_questions,
        queue: Enum.map(assigns.queued_inputs, &queue_item/1)
      },
      runtime: %{
        phase:
          if(voice?,
            do: to_string(voice_phase),
            else: if(waiting?, do: "waiting_for_user", else: assigns.session_status)
          ),
        active: active?
      },
      admission: %{
        canSubmit:
          not host_history? and
            if(voice?,
              do: voice_ready?,
              else:
                assigns.session_status in ~w(idle error streaming tool_executing) and
                  not recovery?
            ),
        allowWhileStreaming: true,
        sendLabel: if(active? or voice[:busy] == true, do: "Queue", else: "Send"),
        canSteer: not host_history? and not voice? and active? and not waiting?,
        canRetry:
          not host_history? and not voice? and assigns.session_status == "error" and
            not subagents?
      }
    }
  end

  defp access_label(_assigns, true), do: "Read-only history"
  defp access_label(%{agent_config: %{read_only: true}}, _), do: "Read only"

  defp access_label(
         %{
           session_access: %{
             allow_read: :allow,
             allow_write: :allow,
             allow_execute: :allow,
             allow_destructive: :allow,
             overrides: []
           }
         },
         _
       ),
       do: "Full access"

  defp access_label(_assigns, _), do: "Configured access"

  defp composer_model(%{current_session: session}, _, true), do: %{label: session.model}
  defp composer_model(%{agent_config: agent}, true, false), do: %{label: agent.voice_model}

  defp composer_model(assigns, false, false) do
    session = assigns.current_session
    saved_id = (session.config || %{})["model_id"]

    selected =
      Enum.find(assigns.configured_models, fn model ->
        if saved_id,
          do: model.id == saved_id,
          else: model.provider == session.provider and model.model == session.model
      end)

    %{
      value: if(selected, do: selected.id, else: ""),
      label:
        if(selected,
          do: selected.name,
          else: "#{session.provider}/#{session.model} (unavailable)"
        ),
      disabled:
        assigns.awaiting_session_idle or assigns.session_status in ~w(streaming tool_executing),
      choices:
        Enum.map(
          assigns.configured_models,
          &Map.take(&1, [:id, :provider, :name, :context_window])
        )
    }
  end

  defp voice_reply(%{id: id, text: text}, label) when text != "" do
    [%{id: id, role: "assistant", content: text, status: "streaming", author: label, tools: []}]
  end

  defp voice_reply(_, _), do: []

  defp voice_message(message, facts, token, turn_index) do
    parts =
      message.parts
      |> Enum.with_index(fn
        %Part.Image{}, part_index ->
          {:voice_image, VoiceImageController.path(token, turn_index, part_index, message.id)}

        %Part.CommittedAudio{} = audio, _ ->
          key = audio.connection_generation <> ":" <> audio.item_id

          %Part.Text{
            content:
              get_in(facts, [:voice_transcript, key]) || "Voice input · waiting for transcript"
          }

        %Part.SpokenAudio{} = audio, _ ->
          key =
            audio.connection_generation <>
              ":" <> audio.item_id <> ":" <> Integer.to_string(audio.content_index)

          playback =
            case get_in(facts, [:voice_playback, key]) do
              %{interrupted: false} ->
                "Playback complete"

              %{interrupted: true, cursor: ms} when is_integer(ms) ->
                "Playback stopped at #{ms} ms"

              %{interrupted: true} ->
                "Playback stopped · position unavailable"

              _ ->
                "Generated speech"
            end

          %Part.Text{content: "#{audio.text}\n\n#{playback}"}

        part, _ ->
          part
      end)

    %{message | parts: parts}
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

  defp message(message, label, availability, results) do
    raw_parts = message.parts || []

    visible =
      Enum.reject(
        raw_parts,
        &match?(%Part.ToolResult{tool_use_id: id} when is_map_key(results, id), &1)
      )

    if raw_parts != [] and visible == [] do
      []
    else
      [message(message, visible, label, availability, results)]
    end
  end

  defp message(message, visible, label, availability, results) do
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
      actions: message_actions(message, availability)
    }
  end

  defp message_actions(_, %{voice: true}), do: []

  defp message_actions(%Message{role: "assistant"}, %{regenerate: true}),
    do: [%{id: "regenerate", label: "Regenerate"}]

  defp message_actions(message, availability) do
    case user_prompt_input(message) do
      {:ok, _input} ->
        [
          %{id: "edit_message", label: "Edit", disabled: not availability.branch_and_send},
          %{id: "fork_message", label: "Fork", title: "Fork at this message"},
          %{
            id: "retry_message",
            label: "Retry",
            title: "Retry in a new session",
            disabled: not availability.branch_and_send
          }
        ]

      :error ->
        []
    end
  end

  @doc "Recover a user-authored chat prompt with its durable attachments."
  def user_prompt_input(%Message{role: "user", id: id, internal_turn_source: nil, parts: parts})
      when is_binary(id) and id != "" and is_list(parts) do
    if Enum.all?(parts, &(is_struct(&1, Part.Text) or is_struct(&1, Part.Image))) do
      text = Enum.join(for(%Part.Text{content: content} <- parts, do: content), "\n\n")
      images = for %Part.Image{} = image <- parts, do: image

      if String.trim(text) != "" or images != [], do: {:ok, {text, images}}, else: :error
    else
      :error
    end
  end

  def user_prompt_input(_message), do: :error

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

  # Queued prompts are not transcript turns yet; Chat.Queue renders them above
  # the composer until each one starts or is withdrawn.
  defp queue_item(input) do
    images = Enum.map(Map.get(input, :image_parts, []) || [], &part(&1, "user"))

    attachment =
      case images do
        [%{type: "image", media_type: type, data: data} | _] ->
          %{src: "data:#{type};base64,#{data}", alt: "Attached image"}

        _ ->
          nil
      end

    %{id: input.id, text: input.content, attachment: attachment, steerable: images == []}
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

  defp part({:voice_image, src}, _role), do: %{type: "image", src: src}

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
