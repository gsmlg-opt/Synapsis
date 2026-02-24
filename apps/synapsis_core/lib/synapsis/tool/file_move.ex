defmodule Synapsis.Tool.FileMove do
  @moduledoc "Move/rename a file."
  use Synapsis.Tool

  @impl true
  def name, do: "file_move"

  @impl true
  def description, do: "Move or rename a file from source to destination."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "source" => %{"type" => "string", "description" => "Source file path"},
        "destination" => %{"type" => "string", "description" => "Destination file path"}
      },
      "required" => ["source", "destination"]
    }
  end

  @impl true
  def execute(input, context) do
    source = resolve_path(input["source"], context[:project_path])
    dest = resolve_path(input["destination"], context[:project_path])

    with :ok <- Synapsis.Tool.PathValidator.validate(source, context[:project_path]),
         :ok <- Synapsis.Tool.PathValidator.validate(dest, context[:project_path]) do
      if File.exists?(source) do
        with :ok <- File.mkdir_p(Path.dirname(dest)),
             :ok <- File.rename(source, dest) do
          {:ok, "Moved #{source} to #{dest}"}
        else
          {:error, reason} -> {:error, "Failed to move #{source} to #{dest}: #{inspect(reason)}"}
        end
      else
        {:error, "Source file does not exist: #{source}"}
      end
    end
  end

  @impl true
  def side_effects, do: [:file_changed]

  defp resolve_path(path, project_path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(project_path || ".", path)
  end
end
