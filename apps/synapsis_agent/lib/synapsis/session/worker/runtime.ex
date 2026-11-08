defmodule Synapsis.Session.Worker.Runtime do
  @moduledoc "Projects the native Conversation into the existing session shell."

  alias Synapsis.Agent.Runtime.{ProviderMessages, SessionAdapter}
  alias Synapsis.Agent.Tools.{MCPSources, Questions}
  alias Synapsis.Agent.Events.Emitter
  alias Synapsis.Session.Worker.{Config, PendingInputs, Persistence, SuggestedTurn}
  alias Synapsis.Session.{EventReply, Store}
  alias Synapsis.{Message, Part, Session}

  @settled [:completed, :errored, :interrupted, :closed, :shutdown]

  def initial_roster(session_id) do
    case Synapsis.Runtime.Store.get_projection(session_id) do
      {:ok, roster} ->
        roster =
          Map.update(roster, :agents, [], fn agents ->
            Enum.map(agents, fn agent ->
              if agent[:status] in @settled,
                do: Map.merge(agent, %{historical: true, resident: false}),
                else: Map.put(agent, :status, :unknown_outcome)
            end)
          end)

        root = roster[:root]

        uncertain =
          (is_map(root) and root[:status] not in @settled) or
            Enum.any?(roster.agents, &(&1[:status] not in @settled))

        roster = if uncertain, do: Map.put(roster, :recovery_required, true), else: roster

        if is_map(root) and root[:status] not in @settled,
          do: Map.put(roster, :root, Map.put(root, :status, :unknown_outcome)),
          else: roster

      :not_found ->
        %{agents: []}

      {:error, _} ->
        %{agents: [], error: :storage_unavailable}
    end
  end

  def enabled?(%{session: %Session{}}), do: true

  def start_turn(data, content, image_parts, pending_input \\ nil) do
    with :ok <- validate_prompt_context(pending_input, data.session_id),
         :ok <- Synapsis.Agent.Daemon.NativeSelection.validate_association(data.session),
         {:ok, data} <- Config.refresh_agent_defaults(data),
         {:ok, data} <- ensure_adapter(data) do
      task =
        Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
          prepare_turn(data, content, image_parts, pending_input)
        end)

      Persistence.broadcast(data.session_id, "session_status", %{status: "streaming"})

      {:ok,
       %{
         data
         | runtime_active: true,
           runtime_run_id: nil,
           runtime_task: task,
           runtime_phase: :preparing,
           runtime_history: nil,
           runtime_history_error: nil,
           runtime_cancelled: false,
           runtime_pending_terminal: nil,
           reply_presentation: new_reply_presentation(data.session_id, pending_input),
           stream_acc: Synapsis.Agent.StreamAccumulator.new()
       }}
    end
  end

  defp validate_prompt_context(%{kind: "prompt", input_provenance: context, id: id}, session_id)
       when not is_nil(context) do
    with :ok <- Synapsis.Session.InputContext.validate(context, session_id),
         true <- context["input_id"] == id do
      :ok
    else
      _ -> {:error, :invalid_input_context}
    end
  end

  defp validate_prompt_context(_, _), do: :ok

  defp prepare_turn(data, content, image_parts, pending_input) do
    with {:ok, agent} <- MCPSources.refresh(data.agent),
         {:ok, agent} <- Synapsis.Agent.Resolver.refresh_skills(agent) do
      if not is_nil(pending_input) and pending_input.kind == "system_event" and
           pending_input.event["target_agent_id"] != agent[:id] do
        {:error, :agent_mismatch}
      else
        prepare_selected_turn(data, content, image_parts, agent, pending_input)
      end
    end
  end

  defp prepare_selected_turn(data, content, image_parts, agent, pending_input) do
    prompt_options = [
      agent_id: data.session.agent,
      session_id: data.session_id,
      user_message: content,
      workspace_path: data.project_path,
      memory_context: (data.session.config || %{})["memory_context"] != false,
      agent_config: agent
    ]

    system_prompt = Synapsis.Agent.ContextBuilder.build_system_prompt(:coding, prompt_options)

    child_system_prompt =
      Synapsis.Agent.ContextBuilder.build_system_prompt(
        :coding,
        Keyword.put(prompt_options, :memory_context, false)
      )

    {:ok, _} =
      Synapsis.Session.Compactor.maybe_compact(data.session_id, agent[:model],
        provider: agent[:provider],
        context_window: agent[:model_context_window],
        extra_tokens:
          Synapsis.ContextWindow.estimate_tokens(system_prompt <> content) +
            length(image_parts) * 1_000
      )

    messages = Message.list_by_session(data.session_id)

    user = %Message{
      id: Ecto.UUID.generate(),
      session_id: data.session_id,
      role: "user",
      inserted_at: DateTime.utc_now(),
      parts: user_parts(content, image_parts, pending_input),
      token_count: Synapsis.ContextWindow.estimate_tokens(content) + length(image_parts) * 1_000
    }

    user =
      case pending_input do
        %{kind: "system_event"} ->
          %{
            user
            | id: pending_input.id,
              input_provenance: pending_input.input_provenance,
              internal_turn_source: "event"
          }

        %{kind: "prompt", input_provenance: context} when not is_nil(context) ->
          %{user | id: pending_input.id, input_provenance: context}

        _ ->
          user
      end

    artifacts = completion_artifacts(data.session_id, pending_input)
    messages = messages ++ artifacts

    with {:ok, history} <- ProviderMessages.from_host(messages),
         {:ok, [input]} <- ProviderMessages.from_host([user]),
         {:ok, offset} <- Store.count_turns(data.session_id),
         {:ok, meta} <- Store.get_meta(data.session_id),
         :ok <-
           commit_input(data.session_id, pending_input, offset, artifacts ++ [user], meta) do
      context = %{
        session: data.session,
        agent: agent,
        provider_config: data.provider_config,
        project_path: data.project_path,
        messages: messages,
        system_prompt: system_prompt,
        child_system_prompt: child_system_prompt,
        input_context:
          if(user.internal_turn_source == "event", do: nil, else: user.input_provenance)
      }

      {:ok, context, input.content, length(history) + 1, offset + length(artifacts) + 1}
    end
  end

  defp completion_artifacts(session_id, %{
         event: %{"completion" => c},
         input_provenance: provenance
       }) do
    audios =
      Enum.map(c["audio_parts"], fn portable ->
        {:ok, audio} = Part.load(portable)
        audio
      end)

    [
      %Message{
        id: c["artifact_message_id"],
        session_id: session_id,
        role: "assistant",
        inserted_at: DateTime.utc_now(),
        input_provenance: provenance,
        parts: [%Part.Text{content: c["result"]} | audios]
      }
    ]
  end

  defp completion_artifacts(_, _), do: []

  defp commit_input(session_id, %{id: id, event: %{"completion" => _}}, offset, messages, meta) do
    # The supervised preparation task waits on the existing serialized persistence
    # lane; the Worker itself remains responsive. Native start follows this commit.
    Synapsis.Session.Worker.apply_music_completion(session_id, id, %{
      start_n: offset,
      turns: Enum.map(messages, &Message.encode/1),
      expected_meta: meta,
      meta: Map.merge(meta, %{status: "streaming", updated_at: DateTime.utc_now()}),
      deadline: System.monotonic_time(:millisecond) + 5_000
    })
  end

  defp commit_input(session_id, _, offset, messages, meta) do
    Store.commit_turns(
      session_id,
      offset,
      Enum.map(messages, &Message.encode/1),
      Map.merge(meta, %{status: "streaming", updated_at: DateTime.utc_now()})
    )
  end

  # Event text already uses ECMAScript trimming at admission. Unicode whitespace
  # such as NEL remains meaningful event body data and must survive preparation.
  defp user_parts(content, images, %{kind: "system_event"}),
    do: [%Part.Text{content: content} | images]

  defp user_parts(content, images, _pending_input) do
    if String.trim(content) == "", do: images, else: [%Part.Text{content: content} | images]
  end

  defp ensure_adapter(%{runtime_pid: pid} = data) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, data}, else: start_adapter(data)
  end

  defp ensure_adapter(data), do: start_adapter(data)

  defp start_adapter(data) do
    generation = make_ref()

    case SessionAdapter.start_link(session_id: data.session_id, owner: self(), epoch: generation) do
      {:ok, pid} ->
        Process.unlink(pid)
        if data.runtime_ref, do: Process.demonitor(data.runtime_ref, [:flush])

        {:ok,
         %{data | runtime_pid: pid, runtime_ref: Process.monitor(pid), runtime_epoch: generation}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def started(data, run_id) do
    data = %{data | runtime_run_id: run_id}

    data =
      if data.reply_presentation,
        do: %{data | reply_presentation: %{data.reply_presentation | run_id: run_id}},
        else: data

    data |> PendingInputs.started(run_id) |> SuggestedTurn.started(run_id)
  end

  # The terminal event owns the one transcript write. Repeated history events
  # cannot append the same messages twice.
  def history(data, messages), do: %{data | runtime_history: messages}

  def task_result(
        %{runtime_phase: :preparing} = data,
        {:ok, context, input, history_offset, turn_offset}
      ) do
    data = %{
      data
      | agent: context.agent,
        runtime_task: nil,
        runtime_phase: :running,
        runtime_history_offset: history_offset,
        runtime_turn_offset: turn_offset
    }

    if data.runtime_cancelled do
      SessionAdapter.cancel(data.runtime_pid)
      {:ok, data}
    else
      SessionAdapter.prompt(data.runtime_pid, context, input)
      {:ok, %{data | runtime_run_id: nil}}
    end
  end

  def task_result(
        %{runtime_phase: :committing} = data,
        {:ok, terminal, history_size, count, committed_messages}
      ) do
    data = %{
      data
      | runtime_task: nil,
        runtime_phase: :running,
        runtime_history_offset: history_size,
        runtime_turn_offset: data.runtime_turn_offset + count
    }

    if data.runtime_cancelled and terminal.type != :run_cancelled do
      pending = data.runtime_pending_terminal
      data = %{data | runtime_pending_terminal: nil}
      {:ok, if(pending, do: event(data, pending), else: data)}
    else
      data =
        clear_questions(
          data,
          if(terminal.type == :run_completed, do: data.runtime_run_id, else: :all)
        )

      data = %{
        data
        | runtime_active: false,
          runtime_phase: nil,
          runtime_permissions:
            if(terminal.type == :run_completed,
              do: Enum.reject(data.runtime_permissions, &(&1[:run_id] == data.runtime_run_id)),
              else: []
            ),
          stream_acc: Synapsis.Agent.StreamAccumulator.new()
      }

      Persistence.broadcast(data.session_id, "runtime_permissions", data.runtime_permissions)

      data = settle_reply_presentation(data, terminal, committed_messages)
      data = PendingInputs.terminal(data, terminal.type)

      case terminal.type do
        :run_failed ->
          {:error,
           fail(data, error_text(terminal[:error] || terminal[:outcome] || :execution_failed))}

        :run_cancelled ->
          if terminal[:state] == :unknown_outcome do
            {:error, fail(data, error_text(terminal[:error] || :unknown_outcome))}
          else
            Persistence.broadcast(data.session_id, "done", %{})
            Persistence.broadcast(data.session_id, "session_status", %{status: "idle"})
            {:ok, data}
          end

        :run_completed ->
          Emitter.emit_session_completed(data.session_id)
          {:ok, data}
      end
    end
  end

  def task_result(data, {:error, reason}),
    do: {:error, fail(%{data | runtime_task: nil}, reason)}

  def cancel(%{runtime_phase: :preparing} = data) do
    if data.runtime_task, do: Task.shutdown(data.runtime_task, :brutal_kill)
    data = settle_reply_presentation(data, %{type: :run_cancelled}, [])
    Persistence.set_status(data.session_id, "idle")
    Persistence.broadcast(data.session_id, "done", %{})

    %{
      data
      | runtime_task: nil,
        runtime_active: false,
        runtime_phase: nil,
        runtime_cancelled: true,
        stream_acc: Synapsis.Agent.StreamAccumulator.new()
    }
  end

  def cancel(data) do
    :ok = SessionAdapter.cancel(data.runtime_pid)
    %{data | runtime_active: true, runtime_cancelled: true}
  end

  def event(%{runtime_active: false} = data, %{type: type})
      when type in [:run_completed, :run_failed, :run_cancelled],
      do: data

  def event(data, %{type: :prompt_consumed, mode: :new} = event),
    do: data |> PendingInputs.adopt(event) |> SuggestedTurn.consumed(event)

  def event(data, %{type: :content_text_delta, delta: text}) do
    data = preview_reply(data, text)

    payload =
      if data.reply_presentation,
        do: %{text: text, reply_presentation: presentation_view(data.reply_presentation)},
        else: %{text: text}

    Persistence.broadcast(data.session_id, "text_delta", payload)
    %{data | stream_acc: Map.update!(data.stream_acc, :pending_text, &(&1 <> text))}
  end

  def event(data, %{type: :response_completed, message: message}) do
    complete_reply_response(data, message)
  end

  def event(data, %{type: :content_thinking_delta, delta: text}) do
    Persistence.broadcast(data.session_id, "reasoning", %{text: text})
    data
  end

  def event(data, %{type: :tool_started, invocation: invocation}) do
    Persistence.broadcast(data.session_id, "tool_use", %{
      tool: invocation.tool_name,
      tool_use_id: invocation.tool_call_id,
      input: invocation.arguments
    })

    data
  end

  def event(data, %{type: :tool_completed, message: message}) do
    case ProviderMessages.tool_result_part(message.tool_call_id, message.result, message[:name]) do
      {:ok, part} ->
        Persistence.broadcast(data.session_id, "tool_result", %{
          tool_use_id: part.tool_use_id,
          content: part.content,
          is_error: part.is_error,
          projection: part.projection
        })

        data

      {:error, reason} ->
        fail(data, reason)
    end
  end

  def event(
        data,
        %{type: :interaction_requested, interaction_id: id, request: %{kind: :user_question}} =
          event
      ) do
    data = %{
      data
      | runtime_questions:
          Enum.reject(data.runtime_questions, &(&1.interaction_id == id)) ++ [event]
    }

    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "session:#{data.session_id}",
      {:ask_user, id, %{session_id: data.session_id}}
    )

    data
  end

  def event(data, %{type: :interaction_requested, interaction_id: id} = event) do
    permissions = Enum.reject(data.runtime_permissions, &(&1.interaction_id == id)) ++ [event]
    Persistence.broadcast(data.session_id, "runtime_permissions", permissions)
    %{data | runtime_permissions: permissions}
  end

  def event(data, %{type: :interaction_resolved, interaction_id: id}),
    do: data |> forget_permission(id) |> forget_question(id)

  def event(data, %{type: :runtime_operation_failed, error: error}) do
    Persistence.broadcast(data.session_id, "error", %{message: error_text(error)})
    data
  end

  def event(%{runtime_phase: :committing} = data, %{type: type} = event)
      when type in [:run_completed, :run_failed, :run_cancelled] do
    if type == :run_cancelled, do: %{data | runtime_pending_terminal: event}, else: data
  end

  def event(data, %{type: type} = terminal)
      when type in [:run_completed, :run_failed, :run_cancelled] do
    if type in [:run_failed, :run_cancelled] and
         not match?({:ok, %{status: :confirmed}}, terminal[:cleanup]) do
      fail(data, "Agent cleanup is unconfirmed; recovery is required")
    else
      messages = terminal[:messages] || data.runtime_history || []
      suffix = Enum.drop(messages, data.runtime_history_offset)

      case ProviderMessages.to_host(suffix) do
        {:ok, host} ->
          {data, retired} =
            if type in [:run_failed, :run_cancelled], do: detach_adapter(data), else: {data, nil}

          task =
            Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
              if retired, do: GenServer.stop(retired, :normal, 5_000)
              append_messages(data, host, terminal, length(messages))
            end)

          %{data | runtime_task: task, runtime_phase: :committing}

        {:error, reason} ->
          fail(data, reason)
      end
    end
  end

  def event(data, %{type: :storage_failed}),
    do: fail(data, "Execution storage failed; recovery is required")

  def event(data, _event), do: data

  defp append_messages(data, messages, terminal, history_size) do
    messages =
      Enum.map(messages, fn message ->
        # Host tool replies use user messages containing ToolResult parts.
        role = if message.role == :tool, do: "user", else: to_string(message.role)

        %Message{
          id: Ecto.UUID.generate(),
          session_id: data.session_id,
          inserted_at: DateTime.utc_now(),
          role: role,
          parts: message.parts,
          reply_presentation:
            if(role == "assistant" and data.reply_presentation,
              do: EventReply.stamp(data.reply_presentation.occurrence_id)
            )
        }
      end)

    turns = Enum.map(messages, &Message.encode/1)

    with {:ok, meta} <- Store.get_meta(data.session_id),
         meta =
           Map.merge(meta, %{
             status:
               if(terminal.type == :run_failed or terminal[:state] == :unknown_outcome,
                 do: "error",
                 else: "idle"
               ),
             updated_at: DateTime.utc_now()
           }),
         :ok <- Store.commit_turns(data.session_id, data.runtime_turn_offset, turns, meta) do
      committed_messages =
        messages
        |> Enum.filter(&(&1.role == "assistant" and not is_nil(&1.reply_presentation)))
        |> Enum.with_index()
        |> Enum.map(fn {message, index} ->
          message
          |> EventReply.project()
          |> Map.take([:text, :hidden, :text_parts])
          |> Map.merge(%{message_id: message.id, response_index: index})
        end)

      {:ok, terminal, history_size, length(turns), committed_messages}
    end
  end

  # This cache has no execution ownership. It derives a replaceable view from
  # already fenced native events, while the authored transcript remains raw.
  defp new_reply_presentation(_session_id, %{event: %{"completion" => _}}), do: nil

  defp new_reply_presentation(session_id, %{kind: "system_event", id: occurrence_id}) do
    %{
      version: 1,
      policy: "manual_event_message",
      session_id: session_id,
      occurrence_id: occurrence_id,
      run_id: nil,
      revision: 0,
      phase: "preview",
      responses: [],
      preview_text: "",
      preview?: false,
      committed_messages: []
    }
  end

  defp new_reply_presentation(_session_id, _input), do: nil

  @doc "The additive event display snapshot; raw in-flight text remains separate."
  def reply_presentation(%{reply_presentation: nil}), do: nil

  def reply_presentation(%{reply_presentation: state}) do
    Map.put(presentation_view(state), :committed_messages, state.committed_messages)
  end

  defp presentation_scope(state) do
    Map.take(state, [:version, :policy, :session_id, :occurrence_id, :run_id, :revision, :phase])
  end

  defp presentation_view(state) do
    responses =
      if state.preview? do
        text = EventReply.text(state.preview_text)

        state.responses ++
          [
            %{
              response_index: length(state.responses),
              text: text,
              hidden: text == "",
              text_parts: [%{index: 0, text: text}]
            }
          ]
      else
        state.responses
      end

    Map.merge(presentation_scope(state), %{
      text: responses |> Enum.map(& &1.text) |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n"),
      hidden: Enum.all?(responses, & &1.hidden),
      responses: responses
    })
  end

  defp preview_reply(%{reply_presentation: nil} = data, _text), do: data
  defp preview_reply(%{reply_presentation: %{phase: "closed"}} = data, _text), do: data

  defp preview_reply(data, text) do
    state = data.reply_presentation

    %{
      data
      | reply_presentation: %{
          state
          | preview_text: state.preview_text <> text,
            preview?: true,
            phase: "preview",
            revision: state.revision + 1
        }
    }
  end

  defp complete_reply_response(%{reply_presentation: nil} = data, _message), do: data

  defp complete_reply_response(%{reply_presentation: %{phase: "closed"}} = data, _message),
    do: data

  defp complete_reply_response(data, message) do
    with {:ok, [%{role: :assistant, parts: parts}]} <- ProviderMessages.to_host([message]) do
      state = data.reply_presentation

      projection =
        EventReply.project(%Message{
          role: "assistant",
          parts: parts,
          reply_presentation: EventReply.stamp(state.occurrence_id)
        })

      summary =
        projection
        |> Map.take([:text, :hidden, :text_parts])
        |> Map.put(:response_index, length(state.responses))

      state = %{
        state
        | responses: state.responses ++ [summary],
          preview_text: "",
          preview?: false,
          phase: "response",
          revision: state.revision + 1
      }

      Persistence.broadcast(data.session_id, "reply_presentation", presentation_view(state))
      %{data | reply_presentation: state}
    else
      {:error, reason} -> fail(data, reason)
    end
  end

  defp settle_reply_presentation(%{reply_presentation: nil} = data, _terminal, _messages),
    do: data

  defp settle_reply_presentation(data, terminal, messages) do
    state = data.reply_presentation

    state =
      if terminal.type == :run_completed do
        Enum.reduce(messages, state, fn message, state ->
          state = %{
            state
            | revision: state.revision + 1,
              phase: "committed",
              committed_messages: state.committed_messages ++ [message]
          }

          envelope = Map.merge(presentation_scope(state), message)
          Persistence.broadcast(data.session_id, "reply_presentation", envelope)
          state
        end)
      else
        state
      end

    # Closing is presentation cleanup, after the same acknowledged terminal
    # branch as done. It never claims a cancelled/failed run succeeded.
    state = %{
      state
      | phase: "closed",
        revision: state.revision + 1,
        preview_text: "",
        preview?: false
    }

    Persistence.broadcast(data.session_id, "reply_presentation", presentation_scope(state))
    %{data | reply_presentation: state}
  end

  defp detach_adapter(data) do
    if data.runtime_ref, do: Process.demonitor(data.runtime_ref, [:flush])
    {%{data | runtime_pid: nil, runtime_ref: nil, runtime_epoch: nil}, data.runtime_pid}
  end

  def roster(data, roster) do
    Persistence.broadcast(data.session_id, "subagents", roster)
    %{data | runtime_roster: roster}
  end

  def resolve(data, id, decision) when is_boolean(decision) do
    if Enum.any?(data.runtime_permissions, &(&1.interaction_id == id)) and
         is_pid(data.runtime_pid) and Process.alive?(data.runtime_pid) do
      :ok = SessionAdapter.resolve(data.runtime_pid, id, decision)
      {:ok, data}
    else
      {:error, :not_found}
    end
  end

  def resolve(_data, _id, _decision), do: {:error, :invalid_decision}

  def questions(data), do: Enum.map(data.runtime_questions, &Questions.public_question/1)

  def question_pending?(data, id),
    do: Enum.any?(data.runtime_questions, &(&1.interaction_id == id))

  def answer_question(data, id, response) do
    if question_pending?(data, id) and is_binary(response) and String.valid?(response) and
         byte_size(response) <= 32_768 and is_pid(data.runtime_pid) and
         Process.alive?(data.runtime_pid) do
      :ok = SessionAdapter.answer_question(data.runtime_pid, id, response)
      {:ok, data}
    else
      {:error, :invalid_response}
    end
  end

  defp forget_question(data, id) do
    if question_pending?(data, id) do
      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "session:#{data.session_id}",
        {:ask_user_closed, id}
      )
    end

    %{data | runtime_questions: Enum.reject(data.runtime_questions, &(&1.interaction_id == id))}
  end

  defp clear_questions(data, run_id) do
    data.runtime_questions
    |> Enum.filter(&(run_id == :all or &1.run_id == run_id))
    |> Enum.reduce(data, &forget_question(&2, &1.interaction_id))
  end

  defp forget_permission(data, id) do
    permissions = Enum.reject(data.runtime_permissions, &(&1.interaction_id == id))
    Persistence.broadcast(data.session_id, "runtime_permissions", permissions)
    %{data | runtime_permissions: permissions}
  end

  def fail(data, reason) do
    data = data |> SuggestedTurn.failed() |> PendingInputs.failed() |> clear_questions(:all)
    if data.runtime_task, do: Task.shutdown(data.runtime_task, :brutal_kill)
    if is_pid(data.runtime_pid), do: SessionAdapter.cancel(data.runtime_pid)
    Persistence.broadcast(data.session_id, "runtime_permissions", [])
    Persistence.update_session_status(data.session_id, "error")
    Emitter.emit_session_failed(data.session_id, error_text(reason))

    %{
      data
      | runtime_active: false,
        runtime_task: nil,
        runtime_phase: nil,
        runtime_permissions: [],
        runtime_history_error: reason
    }
  end

  def error_message(%{runtime_history_error: nil}), do: nil
  def error_message(%{runtime_history_error: reason}), do: error_text(reason)

  defp error_text(%Backplane.AiProtocol.Error{} = reason),
    do: Synapsis.Agent.Nodes.ProviderError.message(reason)

  defp error_text(%{message: message}) when is_binary(message), do: message
  defp error_text(message) when is_binary(message), do: message
  defp error_text(reason), do: inspect(reason)
end
