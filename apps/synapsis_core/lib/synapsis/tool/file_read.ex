defmodule Synapsis.Tool.FileRead do
  @moduledoc "Read file contents."
  use Synapsis.Tool

  @impl true
  def name, do: "file_read"

  @impl true
  def description, do: "Read the contents of a file at the given path."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Absolute or relative path to the file"},
        "offset" => %{
          "type" => "integer",
          "description" => "Line number to start reading from (0-indexed)"
        },
        "limit" => %{"type" => "integer", "description" => "Maximum number of lines to read"}
      },
      "required" => ["path"]
    }
  end

  @impl true
  def execute(input, context) do
    path = resolve_path(input["path"], context[:project_path])

    with :ok <- Synapsis.Tool.PathValidator.validate(path, context[:project_path]),
         {:ok, content} <- File.read(path) do
      content =
        content
        |> maybe_offset(input["offset"])
        |> maybe_limit(input["limit"])

      {:ok, content}
    else
      {:error, :enoent} -> {:error, "File not found: #{path}"}
      {:error, :eacces} -> {:error, "Permission denied: #{path}"}
      {:error, reason} -> {:error, "Error reading file: #{inspect(reason)}"}
    end
  end

  defp resolve_path(path, project_path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(project_path || ".", path)
    end
  end

  defp maybe_offset(content, nil), do: content

  defp maybe_offset(content, offset) when is_integer(offset) and offset > 0 do
    content
    |> String.split("\n")
    |> Enum.drop(offset)
    |> Enum.join("\n")
  end

  defp maybe_offset(content, _), do: content

  defp maybe_limit(content, nil), do: content

  defp maybe_limit(content, limit) when is_integer(limit) and limit > 0 do
    content
    |> String.split("\n")
    |> Enum.take(limit)
    |> Enum.join("\n")
  end

  defp maybe_limit(content, _), do: content
end
