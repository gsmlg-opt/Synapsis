defmodule Synapsis.Workspace.Tools.WorkspaceDelete do
  @moduledoc "Delete a workspace document by path or ID."
  use Synapsis.Tool

  @impl true
  def name, do: "workspace_delete"

  @impl true
  def permission_level, do: :write

  @impl true
  def category, do: :workspace

  @impl true
  def description do
    "Delete a workspace document by path or ID. Performs a soft delete — the document can be recovered."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" =>
            "Workspace path (e.g. /projects/myapp/notes/old.md) or document ID"
        }
      },
      "required" => ["path"]
    }
  end

  @impl true
  def execute(input, context) do
    path = input["path"]

    agent_ctx = %{
      role: context[:role] || :user,
      project_id: context[:project_id],
      session_id: context[:session_id]
    }

    with :allowed <- Synapsis.Workspace.Permissions.check(agent_ctx, path, :write) do
      case Synapsis.Workspace.delete(path) do
        :ok ->
          {:ok, Jason.encode!(%{deleted: path, status: "ok"})}

        {:error, :not_found} ->
          {:error, "Workspace document not found: #{path}"}
      end
    else
      :denied -> {:error, "Permission denied: cannot delete #{path}"}
    end
  end
end
