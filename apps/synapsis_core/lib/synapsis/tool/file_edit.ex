defmodule Synapsis.Tool.FileEdit do
  @moduledoc "Edit file contents via search/replace."
  use Synapsis.Tool

  @impl true
  def name, do: "file_edit"

  @impl true
  def description, do: "Edit a file by replacing a specific string with new content."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to the file to edit"},
        "old_string" => %{
          "type" => "string",
          "description" => "The exact string to find and replace"
        },
        "new_string" => %{"type" => "string", "description" => "The replacement string"}
      },
      "required" => ["path", "old_string", "new_string"]
    }
  end

  @impl true
  def execute(input, context) do
    path = resolve_path(input["path"], context[:project_path])

    with :ok <- Synapsis.Tool.PathValidator.validate(path, context[:project_path]),
         {:ok, content} <- File.read(path) do
      old_string = input["old_string"]
      new_string = input["new_string"]

      case String.split(content, old_string) do
        [_only] ->
          {:error, "String not found in file: #{inspect(String.slice(old_string, 0..50))}"}

        [before, after_part] ->
          new_content = before <> new_string <> after_part

          case File.write(path, new_content) do
            :ok ->
              {:ok,
               Jason.encode!(%{
                 status: "ok",
                 path: path,
                 message: "Successfully edited #{path}",
                 diff: %{old: old_string, new: new_string}
               })}

            {:error, reason} ->
              {:error, "Failed to write #{path}: #{inspect(reason)}"}
          end

        _multiple ->
          # Multiple occurrences - replace only the first
          [before | _] = :binary.split(content, old_string)

          rest =
            :binary.part(
              content,
              byte_size(before) + byte_size(old_string),
              byte_size(content) - byte_size(before) - byte_size(old_string)
            )

          new_content = before <> new_string <> rest

          case File.write(path, new_content) do
            :ok ->
              {:ok,
               Jason.encode!(%{
                 status: "ok",
                 path: path,
                 message: "Successfully edited #{path} (replaced first occurrence)",
                 diff: %{old: old_string, new: new_string}
               })}

            {:error, reason} ->
              {:error, "Failed to write #{path}: #{inspect(reason)}"}
          end
      end
    else
      {:error, :enoent} -> {:error, "File not found: #{path}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @impl true
  def side_effects, do: [:file_changed]

  defp resolve_path(path, project_path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(project_path || ".", path)
  end
end
