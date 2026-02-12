defmodule SynapsisWeb.SessionController do
  use SynapsisWeb, :controller

  alias Synapsis.Sessions

  def index(conn, params) do
    project_path = params["project_path"] || "."

    {:ok, sessions} = Sessions.list(project_path)
    json(conn, %{data: Enum.map(sessions, &serialize_session/1)})
  end

  def show(conn, %{"id" => id}) do
    case Sessions.get(id) do
      {:ok, session} ->
        json(conn, %{data: serialize_session_with_messages(session)})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Session not found"})
    end
  end

  def create(conn, params) do
    project_path = params["project_path"] || "."

    opts =
      %{
        provider: params["provider"],
        model: params["model"],
        agent: params["agent"],
        title: params["title"]
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Sessions.create(project_path, opts) do
      {:ok, session} ->
        conn
        |> put_status(201)
        |> json(%{data: serialize_session(session)})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(422)
        |> json(%{errors: format_changeset_errors(changeset)})

      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{error: inspect(reason)})
    end
  end

  def delete(conn, %{"id" => id}) do
    case Sessions.delete(id) do
      {:ok, _} ->
        conn |> put_status(204) |> text("")

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Session not found"})
    end
  end

  def send_message(conn, %{"id" => id, "content" => content}) do
    case Sessions.send_message(id, content) do
      :ok ->
        json(conn, %{status: "ok"})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def send_message(conn, %{"id" => _}) do
    conn |> put_status(400) |> json(%{error: "content is required"})
  end

  def fork(conn, %{"id" => id} = params) do
    opts =
      case params["at_message"] do
        nil -> []
        msg_id -> [at_message: msg_id]
      end

    case Sessions.fork(id, opts) do
      {:ok, new_session} ->
        conn |> put_status(201) |> json(%{data: serialize_session(new_session)})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def export_session(conn, %{"id" => id}) do
    case Sessions.export(id) do
      {:ok, json_data} ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("content-disposition", "attachment; filename=\"session-#{id}.json\"")
        |> send_resp(200, json_data)

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def compact(conn, %{"id" => id}) do
    case Sessions.compact(id) do
      :ok ->
        json(conn, %{status: "ok", compacted: false})

      :compacted ->
        json(conn, %{status: "ok", compacted: true})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  defp serialize_session(session) do
    %{
      id: session.id,
      title: session.title,
      agent: session.agent,
      provider: session.provider,
      model: session.model,
      status: session.status,
      project_id: session.project_id,
      project_path: if(Ecto.assoc_loaded?(session.project), do: session.project.path),
      inserted_at: session.inserted_at,
      updated_at: session.updated_at
    }
  end

  defp serialize_session_with_messages(session) do
    base = serialize_session(session)

    messages =
      if Ecto.assoc_loaded?(session.messages) do
        Enum.map(session.messages, &serialize_message/1)
      else
        []
      end

    Map.put(base, :messages, messages)
  end

  defp serialize_message(message) do
    %{
      id: message.id,
      role: message.role,
      parts: Enum.map(message.parts, &serialize_part/1),
      token_count: message.token_count,
      inserted_at: message.inserted_at
    }
  end

  defp serialize_part(%Synapsis.Part.Text{content: content}) do
    %{type: "text", content: content}
  end

  defp serialize_part(%Synapsis.Part.ToolUse{} = p) do
    %{
      type: "tool_use",
      tool: p.tool,
      tool_use_id: p.tool_use_id,
      input: p.input,
      status: p.status
    }
  end

  defp serialize_part(%Synapsis.Part.ToolResult{} = p) do
    %{type: "tool_result", tool_use_id: p.tool_use_id, content: p.content, is_error: p.is_error}
  end

  defp serialize_part(%Synapsis.Part.Reasoning{content: content}) do
    %{type: "reasoning", content: content}
  end

  defp serialize_part(%Synapsis.Part.File{path: path, content: content}) do
    %{type: "file", path: path, content: content}
  end

  defp serialize_part(%Synapsis.Part.Agent{agent: agent, message: message}) do
    %{type: "agent", agent: agent, message: message}
  end

  defp serialize_part(part) do
    %{type: "unknown", data: inspect(part)}
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
