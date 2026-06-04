defmodule Synapsis.Session.Sharing do
  @moduledoc "Export session as a shareable JSON file."

  alias Synapsis.{Message, Session, Sessions}
  alias Synapsis.Session.Store

  def export(session_id) do
    case Sessions.get(session_id) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, session} ->
        messages = load_messages(session_id)

        data = %{
          version: "1.0",
          exported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          session: %{
            title: session.title,
            agent: session.agent,
            provider: session.provider,
            model: session.model,
            created_at: iso8601(session.inserted_at)
          },
          messages: Enum.map(messages, &export_message/1)
        }

        case Jason.encode(data, pretty: true) do
          {:ok, json} -> {:ok, json}
          {:error, _reason} -> {:error, "Failed to encode session data"}
        end
    end
  end

  def export_to_file(session_id, path) do
    if String.contains?(path, "..") do
      {:error, "path traversal not allowed"}
    else
      expanded = Path.expand(path)

      case export(session_id) do
        {:ok, json} -> File.write(expanded, json)
        error -> error
      end
    end
  end

  def import_session(json_string, agent_name \\ nil) do
    case Jason.decode(json_string) do
      {:ok, %{"session" => session_data, "messages" => messages_data}} ->
        do_import(session_data, messages_data, agent_name)

      {:ok, _} ->
        {:error, "invalid session export format"}

      {:error, _reason} ->
        {:error, "invalid JSON format"}
    end
  end

  defp do_import(session_data, messages_data, agent_name) do
    now = DateTime.utc_now()

    session = %Session{
      id: Ecto.UUID.generate(),
      provider: session_data["provider"] || "anthropic",
      model: session_data["model"] || Synapsis.Providers.default_model("anthropic"),
      agent: agent_name || session_data["agent"] || "main",
      title: "[Imported] #{session_data["title"] || "session"}",
      config: %{},
      status: "idle",
      inserted_at: now,
      updated_at: now
    }

    messages =
      Enum.map(messages_data, fn msg_data ->
        %Message{
          session_id: session.id,
          role: msg_data["role"] || "user",
          parts: import_parts(msg_data["parts"] || []),
          token_count: msg_data["token_count"] || 0
        }
      end)

    Store.put_meta(session.id, Session.to_meta(session))
    :ok = Message.persist_list(session.id, messages)
    {:ok, session}
  end

  defp export_message(message) do
    %{
      role: message.role,
      parts: Enum.map(message.parts, &export_part/1),
      token_count: message.token_count,
      timestamp: iso8601(message.inserted_at)
    }
  end

  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(_), do: nil

  defp export_part(%Synapsis.Part.Text{content: c}), do: %{type: "text", content: c}

  defp export_part(%Synapsis.Part.ToolUse{} = p),
    do: %{type: "tool_use", tool: p.tool, input: p.input}

  defp export_part(%Synapsis.Part.ToolResult{} = p),
    do: %{type: "tool_result", content: p.content, is_error: p.is_error}

  defp export_part(%Synapsis.Part.Reasoning{content: c, signature: signature}) do
    %{type: "reasoning", content: c, signature: signature}
  end

  defp export_part(%Synapsis.Part.File{path: p, content: c}),
    do: %{type: "file", path: p, content: c}

  defp export_part(_), do: %{type: "unknown"}

  defp import_parts(parts_data) do
    Enum.map(parts_data, fn
      %{"type" => "text", "content" => c} ->
        %Synapsis.Part.Text{content: c}

      %{"type" => "reasoning", "content" => c} = part ->
        %Synapsis.Part.Reasoning{content: c, signature: part["signature"]}

      %{"type" => "file", "path" => p, "content" => c} ->
        %Synapsis.Part.File{path: p, content: c}

      _ ->
        %Synapsis.Part.Text{content: "[imported content]"}
    end)
  end

  defp load_messages(session_id), do: Message.list_by_session(session_id)
end
