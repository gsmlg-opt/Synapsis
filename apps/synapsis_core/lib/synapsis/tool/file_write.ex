defmodule Synapsis.Tool.FileWrite do
  @moduledoc "Write new files."
  use Synapsis.Tool

  @impl true
  def name, do: "file_write"

  @impl true
  def permission_level, do: :write

  @impl true
  def category, do: :filesystem

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

  # 10 MB — prevents disk exhaustion from unbounded writes
  @max_content_bytes 10 * 1024 * 1024

  @impl true
  def execute(input, context) do
    content = input["content"]

    if byte_size(content) > @max_content_bytes do
      {:error, "Content exceeds maximum size of 10 MB"}
    else
      execute_write(input, context)
    end
  end

  defp execute_write(input, context) do
    path = input["path"]

    if Synapsis.Tool.VFS.virtual?(path) do
      Synapsis.Tool.VFS.write(path, input["content"], %{
        author: context[:agent_id] || context[:session_id] || "system"
      })
    else
      resolved = resolve_path(path, context[:project_path])

      with :ok <- Synapsis.Tool.PathValidator.validate(resolved, context[:project_path]),
           :ok <- File.mkdir_p(Path.dirname(resolved)),
           :ok <- File.write(resolved, input["content"]) do
        {:ok, "Successfully wrote #{byte_size(input["content"])} bytes to #{resolved}"}
      else
        {:error, reason} -> {:error, "Failed to write file: #{inspect(reason)}"}
      end
    end
  end

  @impl true
  def side_effects, do: [:file_changed]

  defp resolve_path(path, project_path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(project_path || ".", path)
  end
end
