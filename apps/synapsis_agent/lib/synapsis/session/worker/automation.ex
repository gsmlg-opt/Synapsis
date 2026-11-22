defmodule Synapsis.Session.Worker.Automation do
  @moduledoc """
  Session-owned automation context reads and completed assistant-result appends.

  Reads and writes run in supervised tasks. Completed messages are admitted to
  durable pending custody before acknowledgement. The session owner serializes
  completion inserts and receipts before preparing another provider turn.
  """

  alias Synapsis.Agent.Runtime.SessionAdapter
  alias Synapsis.Automation.Context
  alias Synapsis.Session.{PendingInputStore, Store}
  alias Synapsis.Session.Worker.Persistence
  alias Synapsis.{Message, Part, Session}

  @raw_limit 220
  @read_bytes 256 * 1024

  def start_context(data, from, deadline) do
    capture =
      Map.take(data, [
        :session_id,
        :runtime_pid,
        :runtime_epoch,
        :runtime_run_id,
        :runtime_phase,
        :runtime_history,
        :runtime_history_offset,
        :runtime_turn_offset,
        :stream_acc
      ])

    task =
      Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
        live_context(capture, deadline)
      end)

    %{
      data
      | automation_reads: Map.put(data.automation_reads, task.ref, %{task: task, from: from})
    }
  end

  def context_result(data, ref, result) do
    {%{from: from}, reads} = Map.pop(data.automation_reads, ref)
    {%{data | automation_reads: reads}, [{:reply, from, result}]}
  end

  def durable_context(id, deadline) do
    with {:ok, _meta} <- Store.get_meta(id, timeout: remaining(deadline)),
         {:ok, messages} <- read_window(id, deadline) do
      {:ok, %{source: :durable, context: Context.format(messages)}}
    end
  rescue
    _ -> {:error, :context_unavailable}
  catch
    _, _ -> {:error, :context_unavailable}
  end

  defp live_context(capture, deadline) do
    with {:ok, messages} <- live_messages(capture, deadline) do
      {:ok, %{source: :live, context: Context.format(messages)}}
    end
  rescue
    _ -> {:error, :context_unavailable}
  catch
    _, _ -> {:error, :context_unavailable}
  end

  defp live_messages(%{runtime_phase: :committing, runtime_history: history}, _deadline)
       when is_list(history),
       do: {:ok, history}

  defp live_messages(%{runtime_phase: :running, runtime_pid: pid} = capture, deadline)
       when is_pid(pid) do
    snapshot = SessionAdapter.automation_snapshot(pid, remaining(deadline))

    if snapshot.epoch == capture.runtime_epoch and snapshot.run_id == capture.runtime_run_id and
         is_pid(snapshot.root) do
      # Conversation.status is the public native read. It runs in this task,
      # never in the Worker or adapter callback. The returned history is already
      # resident; only its newest bounded projection enters automation context.
      %{messages: messages} = Backplane.AgentRuntime.Conversation.status(snapshot.root)
      {:ok, with_visible_text(messages, capture)}
    else
      {:error, :context_unavailable}
    end
  end

  defp live_messages(capture, deadline), do: read_window(capture.session_id, deadline)

  defp with_visible_text(messages, capture) do
    completed_text =
      messages
      |> Enum.drop(capture.runtime_history_offset)
      |> Enum.filter(&(field(&1, :role) in [:assistant, "assistant"]))
      |> Enum.map_join("", &text_content/1)

    visible_text = capture.stream_acc.pending_text

    pending =
      cond do
        String.starts_with?(visible_text, completed_text) ->
          binary_part(
            visible_text,
            byte_size(completed_text),
            byte_size(visible_text) - byte_size(completed_text)
          )

        String.starts_with?(completed_text, visible_text) ->
          ""

        true ->
          ""
      end

    if pending == "", do: messages, else: messages ++ [%{role: :assistant, content: pending}]
  end

  defp text_content(message) do
    case field(message, :content) do
      text when is_binary(text) ->
        text

      blocks when is_list(blocks) ->
        Enum.map_join(blocks, "", fn block ->
          if field(block, :type) in [:text, "text"], do: field(block, :text) || "", else: ""
        end)

      _ ->
        ""
    end
  end

  defp field(value, key) when is_map(value),
    do: Map.get(value, key, Map.get(value, Atom.to_string(key)))

  defp field(_, _), do: nil

  defp read_window(id, deadline), do: read_window(id, deadline, nil, @raw_limit, @read_bytes, [])

  defp read_window(id, deadline, cursor, rows, bytes, messages) do
    with {:ok, page} <-
           Store.list_turn_page(id,
             cursor: cursor,
             limit: min(rows, 100),
             max_bytes: bytes,
             deadline: deadline
           ) do
      turns = Enum.map(page.turns, & &1.turn)
      next_messages = messages ++ turns
      next_rows = rows - length(turns)
      next_bytes = bytes - Enum.reduce(turns, 0, &(:erlang.external_size(&1) + &2))

      cond do
        not page.has_more ->
          {:ok, next_messages}

        next_rows > 0 and next_bytes > 0 ->
          read_window(id, deadline, page.next_cursor, next_rows, next_bytes, next_messages)

        true ->
          {:error, :context_unavailable}
      end
    end
  end

  def admitted(data, %{status: "consumed"} = input, from),
    do: {data, [{:reply, from, {:ok, %{status: :delivered, message_id: input.id}}}]}

  def admitted(data, %{status: "inflight", id: input_id}, from) do
    if data.automation_task != nil and data.automation_task.entry.message.id == input_id do
      {data, [{:reply, from, {:ok, %{status: :deferred, message_id: input_id}}}]}
    else
      {%{data | automation_uncertain: true}, [{:reply, from, {:error, :unknown_outcome}}]}
    end
  end

  def admitted(data, input, from) do
    already_pending =
      Enum.any?(data.automation_pending, &(&1.message.id == input.id)) or
        (data.automation_task != nil and data.automation_task.entry.message.id == input.id)

    deferred =
      data.runtime_active or not is_nil(data.automation_task) or data.automation_pending != []

    entry = entry(data, input, if(deferred, do: nil, else: from))

    data =
      if already_pending,
        do: data,
        else: %{data | automation_pending: data.automation_pending ++ [entry]}

    actions =
      if deferred,
        do: [{:reply, from, {:ok, %{status: :deferred, message_id: input.id}}}],
        else: []

    {start_next(data), actions}
  end

  def restore(data, %{status: "inflight"}), do: %{data | automation_uncertain: true}

  def restore(data, input) do
    %{data | automation_pending: data.automation_pending ++ [entry(data, input, nil)]}
  end

  defp entry(data, input, from) do
    {:ok, inserted_at, _} = DateTime.from_iso8601(input.inserted_at)

    message = %Message{
      id: input.id,
      session_id: data.session_id,
      role: "assistant",
      parts: [%Part.Text{content: input.content}],
      inserted_at: inserted_at,
      token_count: Synapsis.ContextWindow.estimate_tokens(input.content)
    }

    %{message: message, from: from}
  end

  def start_next(%{pending_inputs: %{blocked: true}} = data), do: data

  def start_next(
        %{
          runtime_active: false,
          automation_task: nil,
          automation_uncertain: false,
          automation_pending: [entry | rest]
        } = data
      ) do
    task =
      Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
        PendingInputStore.complete_assistant(
          data.session_id,
          entry.message.id,
          Message.encode(entry.message)
        )
      end)

    %{data | automation_task: %{task: task, entry: entry}, automation_pending: rest}
  end

  def start_next(data), do: data

  def append_result(data, {:ok, offset, meta}) do
    entry = data.automation_task.entry
    Persistence.broadcast(data.session_id, "done", %{automation_result: entry.message.id})
    actions = reply(entry, {:ok, %{status: :delivered, message_id: entry.message.id}})

    data = %{
      data
      | automation_task: nil,
        runtime_turn_offset: offset + 1,
        runtime_history: nil,
        session: Session.from_meta(meta)
    }

    {data, actions}
  end

  def append_result(data, {:error, reason}) do
    entry = data.automation_task.entry
    uncertain = reason in [:unknown_outcome, :timeout, :conflict]

    Persistence.broadcast(data.session_id, "automation_result", %{
      status: if(uncertain, do: :unknown_outcome, else: :failed),
      message_id: entry.message.id,
      reason: reason
    })

    {%{data | automation_task: nil, automation_uncertain: uncertain},
     reply(entry, {:error, reason})}
  end

  def append_result(data, _), do: append_result(data, {:error, :unknown_outcome})
  defp reply(%{from: nil}, _result), do: []
  defp reply(%{from: from}, result), do: [{:reply, from, result}]

  def stop(data) do
    if data.automation_task, do: Task.shutdown(data.automation_task.task, :brutal_kill)
    for {_ref, read} <- data.automation_reads, do: Task.shutdown(read.task, :brutal_kill)
    :ok
  end

  defp remaining(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> remaining
      _ -> throw(:context_deadline)
    end
  end
end
