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
        parts ++ [%Synapsis.Part.Reasoning{content: acc.pending_reasoning}]
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
        msg
        |> Ecto.Changeset.change(parts: updated_parts)
        |> Repo.update()
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
end
