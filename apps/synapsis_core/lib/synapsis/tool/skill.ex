defmodule Synapsis.Tool.Skill do
  @moduledoc "Load a skill definition for injection into conversation."
  use Synapsis.Tool

  @impl true
  def name, do: "skill"

  @impl true
  def description, do: "Search for and load a skill by name."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "description" => "Skill name to search for"}
      },
      "required" => ["name"]
    }
  end

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :orchestration

  @impl true
  def execute(input, context) do
    skill_name = input["name"]
    project_path = context[:project_path] || "."

    search_paths = [
      Path.join(project_path, ".synapsis/skills"),
      Path.expand("~/.config/synapsis/skills")
    ]

    case find_skill(skill_name, search_paths) do
      {:ok, content} -> {:ok, content}
      :not_found -> {:error, "Skill '#{skill_name}' not found"}
    end
  end

  defp find_skill(name, paths) do
    # Sanitize: strip path separators and traversal sequences
    safe_name = name |> Path.basename() |> String.replace(~r/[^a-zA-Z0-9_\-.]/, "")
    filename = "#{safe_name}.md"

    Enum.find_value(paths, :not_found, fn dir ->
      path = Path.join(dir, filename)

      case File.read(path) do
        {:ok, content} -> {:ok, content}
        {:error, _} -> nil
      end
    end)
  end
end
