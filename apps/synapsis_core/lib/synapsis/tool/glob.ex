defmodule Synapsis.Tool.Glob do
  @moduledoc "File pattern matching."
  use Synapsis.Tool

  @impl true
  def name, do: "glob"

  @impl true
  def description, do: "Find files matching a glob pattern."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" => "Glob pattern (e.g. '**/*.ex', 'lib/**/*.exs')"
        },
        "path" => %{"type" => "string", "description" => "Base directory (default: project root)"}
      },
      "required" => ["pattern"]
    }
  end

  @impl true
  def execute(input, context) do
    pattern = input["pattern"]
    base_path = input["path"] || context[:project_path] || "."
    project_path = context[:project_path]

    with :ok <- validate_path(base_path, project_path) do
      full_pattern = Path.join(base_path, pattern)
      files = Path.wildcard(full_pattern)

      # Filter results to stay within project root
      files = filter_within_project(files, project_path)

      if Enum.empty?(files) do
        {:ok, "No files matched pattern: #{pattern}"}
      else
        result = Enum.join(files, "\n")
        {:ok, result}
      end
    end
  end

  defp validate_path(_path, nil), do: :ok

  defp validate_path(path, project_path) do
    abs_path = Path.expand(path)
    abs_project = Path.expand(project_path)

    if String.starts_with?(abs_path, abs_project) do
      :ok
    else
      {:error, "Path #{path} is outside project root"}
    end
  end

  defp filter_within_project(files, nil), do: files

  defp filter_within_project(files, project_path) do
    abs_project = Path.expand(project_path)

    Enum.filter(files, fn file ->
      String.starts_with?(Path.expand(file), abs_project)
    end)
  end
end
