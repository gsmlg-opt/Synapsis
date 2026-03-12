defmodule Synapsis.Workspace.Tools.WorkspaceRead do
  @moduledoc "Read content from the shared workspace by path or ID."
  use Synapsis.Tool

  @impl true
  def name, do: "workspace_read"

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :workspace

  @impl true
  def description do
    "Read a workspace document by path or ID. Returns the content and metadata of plans, todos, notes, handoffs, and other workspace artifacts."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" =>
            "Workspace path (e.g. /projects/myapp/plans/auth.md) or document ID (ULID/UUID)"
        }
      },
      "required" => ["path"]
    }
  end

  @impl true
  def execute(input, _context) do
    path = input["path"]

    case Synapsis.Workspace.read(path) do
      {:ok, resource} ->
        result =
          Jason.encode!(%{
            id: resource.id,
            path: resource.path,
            kind: resource.kind,
            content: resource.content,
            metadata: resource.metadata,
            visibility: resource.visibility,
            lifecycle: resource.lifecycle,
            version: resource.version
          })

        {:ok, result}

      {:error, :not_found} ->
        {:error, "Workspace document not found: #{path}"}
    end
  end
end
