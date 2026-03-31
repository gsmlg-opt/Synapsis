defmodule Synapsis.Session.Sharing do
  @moduledoc "Export session as a shareable JSON file."

  alias Synapsis.{Repo, Session, Message}
  import Ecto.Query

  def export(session_id) do
    case Repo.get(Session, session_id) do
      nil ->
        {:error, :not_found}

      session ->
        session = Repo.preload(session, :project)
        messages = load_messages(session_id)

        data = %{
          version: "1.0",
          exported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          session: %{
            title: session.title,
            agent: session.agent,
            provider: session.provider,
            model: session.model,
            project_path: (session.project && session.project.path) || "__global__",
            created_at: session.inserted_at |> DateTime.to_iso8601()
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

  def import_session(json_string, project_path) do
    case Jason.decode(json_string) do
      {:ok, %{"session" => session_data, "messages" => messages_data}} ->
        do_import(session_data, messages_data, project_path)

      {:ok, _} ->
        {:error, "invalid session export format"}

      {:error, _reason} ->
        {:error, "invalid JSON format"}
    end
  end

  defp do_import(session_data, messages_data, project_path) do
    slug = Synapsis.Project.slug_from_path(project_path)

    project =
      case Repo.get_by(Synapsis.Project, path: project_path) do
        nil ->
          case %Synapsis.Project{}
               |> Synapsis.Project.changeset(%{path: project_path, slug: slug})
               |> Repo.insert() do
            {:ok, p} -> p
            {:error, _} -> nil
          end

        p ->
          p
      end

    if is_nil(project) do
      {:error, "Failed to create project for import"}
    else
      attrs = %{
        project_id: project.id,
        provider: session_data["provider"] || "anthropic",
        model: session_data["model"] || Synapsis.Providers.default_model("anthropic"),
        agent: session_data["agent"] || "build",
        title: "[Imported] #{session_data["title"] || "session"}"
      }

      Repo.transaction(fn ->
        session =
          case %Session{}
               |> Session.changeset(attrs)
               |> Repo.insert() do
            {:ok, s} -> s
            {:error, changeset} -> Repo.rollback(changeset)
          end

        for msg_data <- messages_data do
          parts = import_parts(msg_data["parts"] || [])

          case %Message{}
               |> Message.changeset(%{
                 session_id: session.id,
                 role: msg_data["role"] || "user",
                 parts: parts,
                 token_count: msg_data["token_count"] || 0
               })
               |> Repo.insert() do
            {:ok, _} -> :ok
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end

        Repo.preload(session, :project)
      end)
    end
  end

  defp export_message(message) do
    %{
      role: message.role,
      parts: Enum.map(message.parts, &export_part/1),
      token_count: message.token_count,
      timestamp: message.inserted_at |> DateTime.to_iso8601()
    }
  end

  defp export_part(%Synapsis.Part.Text{content: c}), do: %{type: "text", content: c}

  defp export_part(%Synapsis.Part.ToolUse{} = p),
    do: %{type: "tool_use", tool: p.tool, input: p.input}

  defp export_part(%Synapsis.Part.ToolResult{} = p),
    do: %{type: "tool_result", content: p.content, is_error: p.is_error}

  defp export_part(%Synapsis.Part.Reasoning{content: c}), do: %{type: "reasoning", content: c}

  defp export_part(%Synapsis.Part.File{path: p, content: c}),
    do: %{type: "file", path: p, content: c}

  defp export_part(_), do: %{type: "unknown"}

  defp import_parts(parts_data) do
    Enum.map(parts_data, fn
      %{"type" => "text", "content" => c} -> %Synapsis.Part.Text{content: c}
      %{"type" => "reasoning", "content" => c} -> %Synapsis.Part.Reasoning{content: c}
      %{"type" => "file", "path" => p, "content" => c} -> %Synapsis.Part.File{path: p, content: c}
      _ -> %Synapsis.Part.Text{content: "[imported content]"}
    end)
  end

  defp load_messages(session_id) do
    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
  end
end
