defmodule Synapsis.Tool.DevlogWrite do
  @moduledoc "Append a structured entry to the project dev log."
  use Synapsis.Tool

  @impl true
  def name, do: "devlog_write"

  @impl true
  def description,
    do:
      "Append a structured entry to the project dev log at /projects/<id>/logs/devlog.md. " <>
        "Valid categories: decision, progress, blocker, insight, error, completion, user-note."

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :workflow

  @impl true
  def side_effects, do: [:workspace_changed]

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "category" => %{
          "type" => "string",
          "enum" => ["decision", "progress", "blocker", "insight", "error", "completion",
                     "user-note"],
          "description" => "Entry category"
        },
        "content" => %{
          "type" => "string",
          "description" => "The log entry content"
        }
      },
      "required" => ["category", "content"]
    }
  end

  @impl true
  def execute(input, context) do
    project_id = Map.get(context, :project_id)

    case project_id do
      nil ->
        {:error, "project_id is required in context"}

      project_id ->
        category = Map.get(input, "category")
        content = Map.get(input, "content")
        author = Map.get(context, :author, "assistant")
        path = "/projects/#{project_id}/logs/devlog.md"

        existing_content =
          case Synapsis.WorkspaceDocuments.get_by_path(path) do
            nil -> "# Dev Log\n"
            doc -> doc.content_body || "# Dev Log\n"
          end

        entry = %{
          timestamp: DateTime.utc_now(),
          category: category,
          author: author,
          content: content
        }

        updated_content = Synapsis.DevLog.append(existing_content, entry)

        case persist_devlog(path, updated_content, project_id) do
          {:ok, _doc} ->
            {:ok, "Dev log entry appended (#{category})."}

          {:error, reason} ->
            {:error, "Failed to persist dev log: #{inspect(reason)}"}
        end
    end
  end

  defp persist_devlog(path, content, project_id) do
    case Synapsis.WorkspaceDocuments.get_by_path(path) do
      nil ->
        %Synapsis.WorkspaceDocument{}
        |> Synapsis.WorkspaceDocument.changeset(%{
          path: path,
          content_body: content,
          content_format: :markdown,
          kind: :document,
          project_id: project_id,
          created_by: "system",
          updated_by: "system"
        })
        |> Synapsis.WorkspaceDocuments.insert()

      doc ->
        doc
        |> Synapsis.WorkspaceDocument.changeset(%{
          content_body: content,
          updated_by: "system"
        })
        |> Synapsis.WorkspaceDocuments.update()
    end
  end
end
