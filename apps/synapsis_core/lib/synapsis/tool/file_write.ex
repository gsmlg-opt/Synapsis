defmodule Synapsis.Tool.FileWrite do
  @moduledoc "Write new files."
  @behaviour Synapsis.Tool.Behaviour

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
  def call(input, context) do
    path = resolve_path(input["path"], context[:project_path])

    with :ok <- validate_path(path, context[:project_path]) do
      dir = Path.dirname(path)
      File.mkdir_p!(dir)
      File.write!(path, input["content"])
      {:ok, "Successfully wrote #{byte_size(input["content"])} bytes to #{path}"}
    end
  end

  defp resolve_path(path, project_path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(project_path || ".", path)
  end

  defp validate_path(_path, nil), do: :ok

  defp validate_path(path, project_path) do
    abs_path = Path.expand(path)
    abs_project = Path.expand(project_path)

    if String.starts_with?(abs_path, abs_project),
      do: :ok,
      else: {:error, "Path outside project root"}
  end
end
