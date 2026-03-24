defmodule Synapsis.Tool.FileDelete do
  @moduledoc "Delete a file."
  use Synapsis.Tool

  @impl true
  def name, do: "file_delete"

  @impl true
  def description, do: "Delete a file at the given path."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to the file to delete"}
      },
      "required" => ["path"]
    }
  end

  @impl true
  def execute(input, context) do
    path = input["path"]

    if Synapsis.Tool.VFS.virtual?(path) do
      case Synapsis.Tool.VFS.delete(path) do
        :ok -> {:ok, "Successfully deleted #{path}"}
        {:error, reason} -> {:error, reason}
      end
    else
      resolved = resolve_path(path, context[:project_path])

      with :ok <- Synapsis.Tool.PathValidator.validate(resolved, context[:project_path]) do
        if File.exists?(resolved) do
          case File.rm(resolved) do
            :ok -> {:ok, "Successfully deleted #{resolved}"}
            {:error, reason} -> {:error, "Failed to delete #{resolved}: #{inspect(reason)}"}
          end
        else
          {:error, "File does not exist: #{resolved}"}
        end
      end
    end
  end

  @impl true
  def permission_level, do: :destructive

  @impl true
  def category, do: :filesystem

  @impl true
  def side_effects, do: [:file_changed]

  defp resolve_path(path, project_path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(project_path || ".", path)
  end
end
