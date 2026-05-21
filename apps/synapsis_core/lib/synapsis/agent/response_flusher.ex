defmodule Synapsis.Agent.ResponseFlusher do
  @moduledoc """
  Persists accumulated text/tools/reasoning parts to the database and broadcasts events.

  Extracted from Session.Worker.flush_pending/1 and build_assistant_parts/1.
  """

  alias Synapsis.{Repo, Message, ContextWindow}
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

    safe_insert_message(session_id, %{
      session_id: session_id,
      role: "user",
      parts: [result_part],
      token_count: ContextWindow.estimate_tokens(result)
    })

    # Update the ToolUse part status in the original assistant message
    update_tool_use_status(session_id, tool_use_id, if(is_error, do: :error, else: :completed))

    :ok
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
  Ensures every assistant tool_use is followed by a user tool_result block.

  This repairs turns that were interrupted before a tool result was persisted.
  For Anthropic, the matching tool_result must be in the immediately following
  user message, so existing user text is kept after the inserted result blocks.
  """
  @spec ensure_tool_results(String.t(), String.t(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def ensure_tool_results(session_id, result, is_error) do
    messages = Message.list_by_session(session_id)

    repaired =
      messages
      |> Enum.with_index()
      |> Enum.reduce(0, fn {message, index}, count ->
        tool_use_ids = assistant_tool_use_ids(message)

        if tool_use_ids == [] do
          count
        else
          next_message = Enum.at(messages, index + 1)

          case ensure_next_tool_results(message, next_message, tool_use_ids, result, is_error) do
            {:ok, added} -> count + added
            {:error, _reason} -> count
          end
        end
      end)

    {:ok, repaired}
  rescue
    e in [Ecto.QueryError, Ecto.StaleEntryError, DBConnection.ConnectionError] ->
      Logger.warning("ensure_tool_results_failed",
        session_id: session_id,
        error: Exception.message(e)
      )

      {:error, e}
  end

  defp update_tool_use_status(session_id, tool_use_id, new_status) do
    import Ecto.Query, only: [from: 2]

    # Find the assistant message containing this tool_use_id
    query =
      from(m in Message,
        where: m.session_id == ^session_id and m.role == "assistant",
        order_by: [desc: m.inserted_at],
        limit: 5
      )

    messages = Repo.all(query)

    Enum.find_value(messages, fn msg ->
      updated_parts =
        Enum.map(msg.parts, fn
          %Synapsis.Part.ToolUse{tool_use_id: ^tool_use_id} = tu ->
            %{tu | status: new_status}

          part ->
            part
        end)

      if updated_parts != msg.parts do
        case msg |> Ecto.Changeset.change(parts: updated_parts) |> Repo.update() do
          {:ok, _} -> true
          {:error, _} -> nil
        end
      end
    end)
  rescue
    e in [Ecto.QueryError, Ecto.StaleEntryError, DBConnection.ConnectionError] ->
      Logger.warning("update_tool_use_status_failed",
        session_id: session_id,
        tool_use_id: tool_use_id,
        error: Exception.message(e)
      )
  end

  defp safe_insert_message(session_id, attrs) do
    case %Message{} |> Message.changeset(attrs) |> Repo.insert() do
      {:ok, msg} ->
        {:ok, msg}

      {:error, changeset} ->
        Logger.warning("message_insert_failed",
          session_id: session_id,
          errors: inspect(changeset.errors)
        )

        {:error, changeset}
    end
  end

  defp ensure_next_tool_results(_assistant, %{role: "user"} = user, ids, result, is_error) do
    existing = existing_tool_results(user.parts, ids)
    missing_ids = Enum.reject(ids, &Map.has_key?(existing, &1))
    prefix_ids = tool_result_prefix_ids(user.parts, length(ids))
    status = tool_use_status(is_error)

    if missing_ids == [] and prefix_ids == ids do
      {:ok, 0}
    else
      result_parts = tool_result_blocks(ids, existing, result, is_error)
      remaining_parts = reject_tool_results(user.parts, ids)
      extra_tokens = length(missing_ids) * ContextWindow.estimate_tokens(result)

      case user
           |> Ecto.Changeset.change(
             parts: result_parts ++ remaining_parts,
             token_count: (user.token_count || 0) + extra_tokens
           )
           |> Repo.update() do
        {:ok, _} ->
          mark_tool_uses(user.session_id, missing_ids, status)
          {:ok, length(missing_ids)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ensure_next_tool_results(assistant, _next, ids, result, is_error) do
    result_parts = tool_result_blocks(ids, %{}, result, is_error)
    status = tool_use_status(is_error)

    case safe_insert_message(assistant.session_id, %{
           session_id: assistant.session_id,
           role: "user",
           parts: result_parts,
           token_count: length(ids) * ContextWindow.estimate_tokens(result)
         }) do
      {:ok, _} ->
        mark_tool_uses(assistant.session_id, ids, status)
        {:ok, length(ids)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assistant_tool_use_ids(%Message{role: "assistant", parts: parts}) do
    parts
    |> Enum.flat_map(fn
      %Synapsis.Part.ToolUse{tool_use_id: id} when is_binary(id) -> [id]
      _ -> []
    end)
  end

  defp assistant_tool_use_ids(_message), do: []

  defp existing_tool_results(parts, ids) do
    allowed = MapSet.new(ids)

    parts
    |> Enum.flat_map(fn
      %Synapsis.Part.ToolResult{tool_use_id: id} = result ->
        if MapSet.member?(allowed, id), do: [{id, result}], else: []

      _ ->
        []
    end)
    |> Map.new()
  end

  defp tool_result_prefix_ids(parts, count) do
    parts
    |> Enum.take(count)
    |> Enum.map(fn
      %Synapsis.Part.ToolResult{tool_use_id: id} -> id
      _ -> nil
    end)
  end

  defp tool_result_blocks(ids, existing, result, is_error) do
    Enum.map(ids, fn id ->
      Map.get(existing, id) ||
        %Synapsis.Part.ToolResult{
          tool_use_id: id,
          content: result,
          is_error: is_error
        }
    end)
  end

  defp reject_tool_results(parts, ids) do
    ids = MapSet.new(ids)

    Enum.reject(parts, fn
      %Synapsis.Part.ToolResult{tool_use_id: id} -> MapSet.member?(ids, id)
      _ -> false
    end)
  end

  defp mark_tool_uses(session_id, ids, new_status) do
    import Ecto.Query, only: [from: 2]

    ids = MapSet.new(ids)

    query =
      from(m in Message,
        where: m.session_id == ^session_id and m.role == "assistant"
      )

    query
    |> Repo.all()
    |> Enum.each(fn msg ->
      updated_parts =
        Enum.map(msg.parts, fn
          %Synapsis.Part.ToolUse{tool_use_id: id} = tu ->
            if MapSet.member?(ids, id), do: %{tu | status: new_status}, else: tu

          part ->
            part
        end)

      if updated_parts != msg.parts do
        msg
        |> Ecto.Changeset.change(parts: updated_parts)
        |> Repo.update()
      end
    end)
  end

  defp tool_use_status(true), do: :error
  defp tool_use_status(false), do: :completed

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
