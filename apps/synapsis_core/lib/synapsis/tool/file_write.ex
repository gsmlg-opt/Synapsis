defmodule Synapsis.Tool.FileWrite do
  @moduledoc "Write new files."
  use Synapsis.Tool

  @impl true
  def name, do: "file_write"

  @impl true
  def description, do: "Write content to a file, creating it if it doesn't exist."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to write the file"},
        "content" => %{"type" => "string", "description" => "Content to write to the file"}
      },
      "required" => ["path", "content"]
    }
  end

  @impl true
  def execute(input, context) do
    path = resolve_path(input["path"], context[:project_path])

    with :ok <- Synapsis.Tool.PathValidator.validate(path, context[:project_path]),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, input["content"]) do
      {:ok, "Successfully wrote #{byte_size(input["content"])} bytes to #{path}"}
    else
      {:error, reason} -> {:error, "Failed to write #{path}: #{inspect(reason)}"}
    end
  end

  @impl true
  def side_effects, do: [:file_changed]

  defp resolve_path(path, project_path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(project_path || ".", path)
  end
end
