defmodule Synapsis.Tool.ListDir do
  @moduledoc "List directory contents."
  use Synapsis.Tool

  @impl true
  def name, do: "list_dir"

  @impl true
  def description, do: "List files and directories at the given path."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Directory path to list"},
        "depth" => %{
          "type" => "integer",
          "description" => "Maximum depth to recurse (default: 1)"
        }
      },
      "required" => ["path"]
    }
  end

  @impl true
  def execute(input, context) do
    path = resolve_path(input["path"], context[:project_path])
    depth = input["depth"] || 1

    with :ok <- validate_path(path, context[:project_path]) do
      if File.dir?(path) do
        entries = list_entries(path, depth, 0)
        {:ok, Enum.join(entries, "\n")}
      else
        {:error, "Directory does not exist: #{path}"}
      end
    end
  end

  defp resolve_path(path, project_path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(project_path || ".", path)
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

  defp list_entries(dir, max_depth, current_depth) when current_depth >= max_depth do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.sort(entries)
        |> Enum.map(fn entry ->
          full = Path.join(dir, entry)
          prefix = String.duplicate("  ", current_depth)

          if File.dir?(full) do
            "#{prefix}#{entry}/"
          else
            "#{prefix}#{entry}"
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp list_entries(dir, max_depth, current_depth) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.sort(entries)
        |> Enum.flat_map(fn entry ->
          full = Path.join(dir, entry)
          prefix = String.duplicate("  ", current_depth)

          if File.dir?(full) do
            children = list_entries(full, max_depth, current_depth + 1)
            ["#{prefix}#{entry}/" | children]
          else
            ["#{prefix}#{entry}"]
          end
        end)

      {:error, _} ->
        []
    end
  end
end
