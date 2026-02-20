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
    path = resolve_path(input["path"], context[:project_path])

    with :ok <- Synapsis.Tool.PathValidator.validate(path, context[:project_path]) do
      if File.exists?(path) do
        File.rm!(path)
        {:ok, "Successfully deleted #{path}"}
      else
        {:error, "File does not exist: #{path}"}
      end
    end
  end

  @impl true
  def side_effects, do: [:file_changed]

  defp resolve_path(path, project_path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(project_path || ".", path)
  end
end
