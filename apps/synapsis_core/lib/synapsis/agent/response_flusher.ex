defmodule Synapsis.Agent.ResponseFlusher do
  @moduledoc """
  Persists accumulated text/tools/reasoning parts to the database and broadcasts events.

  Extracted from Session.Worker.flush_pending/1 and build_assistant_parts/1.
  """

  alias Synapsis.{Message, ContextWindow}
  require Logger

  @type acc :: %{
          pending_text: String.t(),
          pending_reasoning: String.t(),
          pending_reasoning_signature: String.t(),
          pending_tool_use: map() | nil,
          pending_tool_input: String.t(),
          tool_uses: [Synapsis.Part.ToolUse.t()]
        }

  @doc """
  Build the list of assistant message parts from accumulated state.
  Pure function — no side effects.
  """
  @spec build_parts(acc()) :: [term()]
  def build_parts(acc) do
    # Finalize any pending tool use that wasn't closed by content_block_stop
    acc = finalize_pending_tool(acc)

    parts = []

    parts =
      if acc.pending_reasoning != "" do
        parts ++
          [
            %Synapsis.Part.Reasoning{
              content: acc.pending_reasoning,
              signature: blank_to_nil(acc.pending_reasoning_signature)
            }
          ]
      else
        parts
      end

    parts =
      if acc.pending_text != "" do
        parts ++ [%Synapsis.Part.Text{content: acc.pending_text}]
      else
        parts
      end

    Enum.reduce(acc.tool_uses, parts, fn tu, p -> p ++ [tu] end)
  end

  @doc """
  Flush accumulated state to the database as an assistant message.
  Returns the reset accumulator fields.
  """
  @spec flush(String.t(), acc()) :: acc()
  def flush(session_id, acc) do
    parts = build_parts(acc)

    if parts != [] do
      token_count =
        parts
        |> Enum.map(fn
          %Synapsis.Part.Text{content: c} -> ContextWindow.estimate_tokens(c)
          _ -> 10
        end)
        |> Enum.sum()

      safe_insert_message(session_id, %{
        session_id: session_id,
        role: "assistant",
        parts: parts,
        token_count: token_count
      })
    end

    %{
      acc
      | pending_text: "",
        pending_reasoning: "",
        pending_reasoning_signature: "",
        pending_tool_use: nil,
        pending_tool_input: ""
    }
  end

  @doc """
  Flush tool results: persist a tool_result message, update the ToolUse part
  status in the original assistant message, and broadcast the event.
  """
  @spec flush_tool_result(String.t(), String.t(), String.t(), boolean()) :: :ok
  def flush_tool_result(session_id, tool_use_id, result, is_error) do
    if tool_result_exists?(session_id, tool_use_id) do
      :ok
    else
      do_flush_tool_result(session_id, tool_use_id, result, is_error)
    end
  end

  defp do_flush_tool_result(session_id, tool_use_id, result, is_error) do
    result_part = %Synapsis.Part.ToolResult{
      tool_use_id: tool_use_id,
      content: result,
      is_error: is_error
    }

    # Keep all of a turn's tool results in the single user message adjacent to
    # the assistant message (Anthropic requires it; OpenAI-compatible providers
    # reject histories where results scatter across messages).
    case open_results_message(session_id, tool_use_id) do
      %Message{} = open ->
        Message.update_message(%{
          open
          | parts: open.parts ++ [result_part],
            token_count: (open.token_count || 0) + ContextWindow.estimate_tokens(result)
        })

      nil ->
        safe_insert_message(session_id, %{
          session_id: session_id,
          role: "user",
          parts: [result_part],
          token_count: ContextWindow.estimate_tokens(result)
        })
    end

    # Update the ToolUse part status in the original assistant message
    update_tool_use_status(session_id, tool_use_id, if(is_error, do: :error, else: :completed))

    :ok
  end

  # The trailing user message carrying the current turn's tool results, when
  # the most recent assistant message contains this tool_use_id.
  defp open_results_message(session_id, tool_use_id) do
    case session_id |> Message.list_by_session() |> Enum.reverse() do
      [%Message{role: "user", parts: parts} = user | earlier] ->
        assistant = Enum.find(earlier, &(&1.role == "assistant"))

        if assistant && tool_use_id in assistant_tool_use_ids(assistant) &&
             Enum.any?(parts || [], &match?(%Synapsis.Part.ToolResult{}, &1)) do
          user
        end

      _ ->
        nil
    end
  end

  defp tool_result_exists?(session_id, tool_use_id) do
    session_id
    |> Message.list_by_session()
    |> Enum.any?(fn message ->
      Enum.any?(message.parts || [], fn
        %Synapsis.Part.ToolResult{tool_use_id: ^tool_use_id} -> true
        _ -> false
      end)
    end)
  end

  @doc """
  Ensures every assistant tool_use is answered by exactly one user tool_result.

  This repairs turns that were interrupted before a tool result was persisted,
  and consolidates results that scattered across multiple user messages into
  the message immediately following the assistant (Anthropic requires
  adjacency; OpenAI-compatible providers reject duplicate or orphaned
  tool_call ids). Existing user text is kept after the result blocks.

  Looks for results in *all* messages up to the next assistant message — a
  result that arrived late, after a placeholder was already backfilled, wins
  over the placeholder instead of becoming a duplicate answer.
  """
  @spec ensure_tool_results(String.t(), String.t(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def ensure_tool_results(session_id, result, is_error) do
    messages = Message.list_by_session(session_id)
    {repaired, added, changed} = repair_messages(messages, session_id, result, is_error)

    if changed do
      case Message.persist_list(session_id, repaired) do
        :ok -> {:ok, added}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, 0}
    end
  rescue
    e in [Ecto.QueryError, Ecto.StaleEntryError] ->
      Logger.warning("ensure_tool_results_failed",
        session_id: session_id,
        error: Exception.message(e)
      )

      {:error, e}
  end

  defp repair_messages(messages, session_id, result, is_error) do
    do_repair(messages, session_id, result, is_error, [], 0, false)
  end

  defp do_repair([], _session_id, _result, _is_error, acc, added, changed) do
    {Enum.reverse(acc), added, changed}
  end

  defp do_repair(
         [%Message{role: "assistant"} = assistant | rest],
         session_id,
         result,
         is_error,
         acc,
         added,
         changed
       ) do
    case assistant_tool_use_ids(assistant) do
      [] ->
        do_repair(rest, session_id, result, is_error, [assistant | acc], added, changed)

      ids ->
        {window, tail} = Enum.split_while(rest, &(&1.role != "assistant"))

        {new_assistant, new_window, group_added, group_changed} =
          repair_group(assistant, window, ids, session_id, result, is_error)

        acc = Enum.reverse(new_window) ++ [new_assistant | acc]

        do_repair(
          tail,
          session_id,
          result,
          is_error,
          acc,
          added + group_added,
          changed or group_changed
        )
    end
  end

  defp do_repair([message | rest], session_id, result, is_error, acc, added, changed) do
    do_repair(rest, session_id, result, is_error, [message | acc], added, changed)
  end

  # Repairs one assistant-with-tools message and its window (the messages up
  # to the next assistant message): exactly one result per tool_use_id, all
  # results in the adjacent user message, later (real) results win over
  # earlier placeholders, emptied carrier messages are dropped.
  defp repair_group(assistant, window, ids, session_id, result, is_error) do
    id_set = MapSet.new(ids)

    collected =
      window
      |> Enum.flat_map(fn msg ->
        Enum.filter(msg.parts || [], &match?(%Synapsis.Part.ToolResult{}, &1))
      end)
      |> Enum.filter(&MapSet.member?(id_set, &1.tool_use_id))
      |> Enum.reduce(%{}, fn r, acc -> Map.put(acc, r.tool_use_id, r) end)

    missing = Enum.reject(ids, &Map.has_key?(collected, &1))

    blocks =
      Enum.map(ids, fn id ->
        Map.get(collected, id) ||
          %Synapsis.Part.ToolResult{tool_use_id: id, content: result, is_error: is_error}
      end)

    {adjacent, others} =
      case window do
        [%Message{role: "user"} = user | rest] -> {user, rest}
        other -> {nil, other}
      end

    stripped_others =
      others
      |> Enum.map(fn msg -> %{msg | parts: reject_tool_results(msg.parts || [], ids)} end)
      |> Enum.reject(&(&1.role == "user" and &1.parts == []))

    new_adjacent =
      case adjacent do
        %Message{} = user ->
          %{
            user
            | parts: blocks ++ reject_tool_results(user.parts || [], ids),
              token_count:
                (user.token_count || 0) + length(missing) * ContextWindow.estimate_tokens(result)
          }

        nil ->
          %Message{
            id: Ecto.UUID.generate(),
            session_id: session_id,
            role: "user",
            parts: blocks,
            token_count: length(ids) * ContextWindow.estimate_tokens(result),
            inserted_at: DateTime.utc_now()
          }
      end

    new_assistant = mark_assistant(assistant, missing, tool_use_status(is_error))
    new_window = [new_adjacent | stripped_others]

    group_changed =
      Enum.map(new_window, & &1.parts) != Enum.map(window, & &1.parts) or
        new_assistant.parts != assistant.parts

    {new_assistant, new_window, length(missing), group_changed}
  end

  defp mark_assistant(assistant, [], _status), do: assistant

  defp mark_assistant(assistant, missing_ids, status) do
    missing = MapSet.new(missing_ids)

    parts =
      Enum.map(assistant.parts, fn
        %Synapsis.Part.ToolUse{tool_use_id: id} = tu ->
          if MapSet.member?(missing, id), do: %{tu | status: status}, else: tu

        part ->
          part
      end)

    %{assistant | parts: parts}
  end

  defp update_tool_use_status(session_id, tool_use_id, new_status) do
    # Find the most recent assistant messages containing this tool_use_id.
    messages =
      session_id
      |> Message.list_by_session()
      |> Enum.filter(&(&1.role == "assistant"))
      |> Enum.reverse()
      |> Enum.take(5)

    Enum.find_value(messages, fn msg ->
      updated_parts =
        Enum.map(msg.parts, fn
          %Synapsis.Part.ToolUse{tool_use_id: ^tool_use_id} = tu ->
            %{tu | status: new_status}

          part ->
            part
        end)

      if updated_parts != msg.parts do
        Message.update_message(%{msg | parts: updated_parts})
        true
      end
    end)
  rescue
    e ->
      Logger.warning("update_tool_use_status_failed",
        session_id: session_id,
        tool_use_id: tool_use_id,
        error: Exception.message(e)
      )
  end

  defp safe_insert_message(session_id, attrs) do
    Message.append(session_id, attrs)
  end

  defp assistant_tool_use_ids(%Message{role: "assistant", parts: parts}) do
    parts
    |> Enum.flat_map(fn
      %Synapsis.Part.ToolUse{tool_use_id: id} when is_binary(id) -> [id]
      _ -> []
    end)
  end

  defp assistant_tool_use_ids(_message), do: []

  defp reject_tool_results(parts, ids) do
    ids = MapSet.new(ids)

    Enum.reject(parts, fn
      %Synapsis.Part.ToolResult{tool_use_id: id} -> MapSet.member?(ids, id)
      _ -> false
    end)
  end

  defp tool_use_status(true), do: :error
  defp tool_use_status(false), do: :completed

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  # Finalizes a pending tool use that wasn't closed by content_block_stop.
  # Defense-in-depth: some Anthropic-compatible proxies omit content_block_stop.
  defp finalize_pending_tool(%{pending_tool_use: nil} = acc), do: acc

  defp finalize_pending_tool(%{pending_tool_use: %{tool: name, tool_use_id: id}} = acc) do
    input =
      case Jason.decode(acc.pending_tool_input || "") do
        {:ok, parsed} -> parsed
        _ -> %{}
      end

    tool_use = %Synapsis.Part.ToolUse{
      tool: name,
      tool_use_id: id,
      input: input,
      status: :pending
    }

    %{
      acc
      | pending_tool_use: nil,
        pending_tool_input: "",
        tool_uses: (acc.tool_uses || []) ++ [tool_use]
    }
  end

  defp finalize_pending_tool(acc), do: acc
end
