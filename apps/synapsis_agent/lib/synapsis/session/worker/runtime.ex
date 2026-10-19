defmodule Synapsis.Session.Worker.Runtime do
  @moduledoc "Projects a subagent-enabled Conversation into the existing session shell."

  alias Synapsis.Agent.Runtime.{ProviderMessages, SessionAdapter}
  alias Synapsis.Agent.Events.Emitter
  alias Synapsis.Session.Worker.{Config, Persistence}
  alias Synapsis.Session.Store
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

  def enabled?(%{session: session}), do: Session.subagents_enabled?(session)

  def start_turn(data, content, image_parts) do
    with {:ok, data} <- Config.refresh_agent_defaults(data),
         {:ok, data} <- ensure_adapter(data) do
      task =
        Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
          prepare_turn(data, content, image_parts)
        end)

      Persistence.broadcast(data.session_id, "session_status", %{status: "streaming"})

      {:ok,
       %{
         data
         | runtime_active: true,
           runtime_task: task,
           runtime_phase: :preparing,
           runtime_history: nil,
           runtime_history_error: nil,
           runtime_cancelled: false,
           runtime_pending_terminal: nil,
           stream_acc: Synapsis.Agent.StreamAccumulator.new()
       }}
    end
  end

  defp prepare_turn(data, content, image_parts) do
    agent = Config.refresh_turn_tools(data.agent)

    system_prompt =
      Synapsis.Agent.ContextBuilder.build_system_prompt(:coding,
        agent_id: data.session.agent,
        session_id: data.session_id,
        user_message: content,
        agent_config: agent
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
      parts: user_parts(content, image_parts),
      token_count: Synapsis.ContextWindow.estimate_tokens(content) + length(image_parts) * 1_000
    }

    with {:ok, history} <- ProviderMessages.from_host(messages),
         {:ok, [input]} <- ProviderMessages.from_host([user]),
         {:ok, offset} <- Store.count_turns(data.session_id),
         {:ok, meta} <- Store.get_meta(data.session_id),
         :ok <-
           Store.commit_turns(
             data.session_id,
             offset,
             [Message.encode(user)],
             Map.merge(meta, %{status: "streaming", updated_at: DateTime.utc_now()})
           ) do
      context = %{
        session: data.session,
        agent: agent,
        provider_config: data.provider_config,
        project_path: data.project_path,
        messages: messages,
        system_prompt: system_prompt
      }

      {:ok, context, input.content, length(history) + 1, offset + 1}
    end
  end

  defp user_parts(content, images) do
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

  def started(data, run_id), do: %{data | runtime_run_id: run_id}

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

  def task_result(%{runtime_phase: :committing} = data, {:ok, terminal, history_size, count}) do
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
      data = %{
        data
        | runtime_active: false,
          runtime_phase: nil,
          runtime_permissions:
            if(terminal.type == :run_completed,
              do:
                Enum.reject(data.runtime_permissions, &(&1.request.run_id == data.runtime_run_id)),
              else: []
            ),
          stream_acc: Synapsis.Agent.StreamAccumulator.new()
      }

      Persistence.broadcast(data.session_id, "runtime_permissions", data.runtime_permissions)

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

  def event(data, %{type: :content_text_delta, delta: text}) do
    Persistence.broadcast(data.session_id, "text_delta", %{text: text})
    %{data | stream_acc: Map.update!(data.stream_acc, :pending_text, &(&1 <> text))}
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
    Persistence.broadcast(data.session_id, "tool_result", %{
      tool_use_id: message.tool_call_id,
      content: result_text(message.result),
      is_error: message.result[:is_error] == true
    })

    data
  end

  def event(data, %{type: :interaction_requested, interaction_id: id} = event) do
    permissions = Enum.reject(data.runtime_permissions, &(&1.interaction_id == id)) ++ [event]
    Persistence.broadcast(data.session_id, "runtime_permissions", permissions)
    %{data | runtime_permissions: permissions}
  end

  def event(data, %{type: :interaction_resolved, interaction_id: id}),
    do: forget_permission(data, id)

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
    turns =
      Enum.map(messages, fn message ->
        # Host tool replies use user messages containing ToolResult parts.
        role = if message.role == :tool, do: "user", else: to_string(message.role)

        Message.encode(%Message{
          id: Ecto.UUID.generate(),
          session_id: data.session_id,
          inserted_at: DateTime.utc_now(),
          role: role,
          parts: message.parts
        })
      end)

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
      {:ok, terminal, history_size, length(turns)}
    end
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
      {:ok, forget_permission(data, id)}
    else
      {:error, :not_found}
    end
  end

  def resolve(_data, _id, _decision), do: {:error, :invalid_decision}

  defp forget_permission(data, id) do
    permissions = Enum.reject(data.runtime_permissions, &(&1.interaction_id == id))
    Persistence.broadcast(data.session_id, "runtime_permissions", permissions)
    %{data | runtime_permissions: permissions}
  end

  def fail(data, reason) do
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

  defp result_text(value) do
    case ProviderMessages.tool_result_text(value) do
      {:ok, text} -> text
      {:error, _} -> "Tool result unavailable"
    end
  end

  defp error_text(%Backplane.AiProtocol.Error{} = reason),
    do: Synapsis.Agent.Nodes.ProviderError.message(reason)

  defp error_text(%{message: message}) when is_binary(message), do: message
  defp error_text(message) when is_binary(message), do: message
  defp error_text(reason), do: inspect(reason)
end
