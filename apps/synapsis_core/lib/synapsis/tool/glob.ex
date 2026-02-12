defmodule Synapsis.Tool.Glob do
  @moduledoc "File pattern matching."
  @behaviour Synapsis.Tool.Behaviour

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
  def call(input, context) do
    pattern = input["pattern"]
    base_path = input["path"] || context[:project_path] || "."

    full_pattern = Path.join(base_path, pattern)
    files = Path.wildcard(full_pattern)

    if Enum.empty?(files) do
      {:ok, "No files matched pattern: #{pattern}"}
    else
      result = Enum.join(files, "\n")
      {:ok, result}
    end
  end
end
