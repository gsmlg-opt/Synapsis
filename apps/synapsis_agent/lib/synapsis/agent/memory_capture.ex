defmodule Synapsis.Agent.MemoryCapture do
  @moduledoc false
  alias Synapsis.Memory.Capture

  def started(data), do: emit(data, "session-start", %{})

  def ended(data, reason) when reason in [:normal, :shutdown],
    do: emit(data, "session-end", %{"reason" => Atom.to_string(reason)})

  def ended(data, {:shutdown, _}), do: ended(data, :shutdown)
  def ended(_, _), do: :ok

  def accepted(data, id, content) when is_binary(id) and is_binary(content) do
    text = if String.trim(content) == "", do: "[Image-only prompt]", else: content
    emit(data, "user-prompt-submit", %{"message_id" => id, "content" => text})
  end

  def accepted(_, _, _), do: :ok

  def consumed(data, %{message: message}) do
    input =
      case Map.get(data, :pending_inputs) do
        %{current: %{input: input}} -> input
        _ -> nil
      end

    case input do
      %{kind: "system_event"} -> :ok
      %{id: id, content: content} -> accepted(data, id, content)
      _ -> accepted(data, message[:id], content(message[:content]))
    end
  end

  def tool_completed(data, message, part) do
    case message[:name] do
      name when is_binary(name) ->
        # Native tool call IDs are scoped to a run; keep that scope in the
        # host's logical hook ID so two turns can legitimately reuse a call ID.
        id = to_string(Map.get(data, :runtime_run_id)) <> ":" <> part.tool_use_id
        public = if part.projection, do: part.projection, else: %{"content" => part.content}

        emit(data, "post-tool-use", %{
          "tool_call_id" => id,
          "tool_name" => name,
          "is_error" => part.is_error,
          "result" => public
        })

      _ ->
        :ok
    end
  end

  defp content(text) when is_binary(text), do: text

  defp content(blocks) when is_list(blocks) do
    Enum.map_join(blocks, "\n", fn
      %{type: :text, text: text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp content(_), do: nil

  defp emit(data, hook, payload) do
    agent = Map.get(data, :agent) || %{}
    session = Map.get(data, :session) || %{}

    Capture.emit(
      %{
        session_id: Map.get(data, :session_id),
        cwd: Map.get(data, :project_path),
        agent_id: Map.get(agent, :id) || Map.get(session, :agent)
      },
      hook,
      payload
    )
  end
end
