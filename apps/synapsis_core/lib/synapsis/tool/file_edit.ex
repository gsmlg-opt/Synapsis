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
    path = input["path"]

    if Synapsis.Tool.VFS.virtual?(path) do
      execute_vfs_edit(path, input, context)
    else
      execute_fs_edit(path, input, context)
    end
  end

  defp execute_vfs_edit(path, input, _context) do
    old_string = input["old_string"]
    new_string = input["new_string"]

    case Synapsis.Tool.VFS.read(path) do
      {:ok, content} ->
        if String.contains?(content, old_string) do
          [before | _] = :binary.split(content, old_string)

          rest =
            :binary.part(
              content,
              byte_size(before) + byte_size(old_string),
              byte_size(content) - byte_size(before) - byte_size(old_string)
            )

          new_content = before <> new_string <> rest

          case Synapsis.Tool.VFS.write(path, new_content) do
            {:ok, _} ->
              {:ok,
               Jason.encode!(%{
                 status: "ok",
                 path: path,
                 message: "Successfully edited #{path}",
                 diff: %{old: old_string, new: new_string}
               })}

            {:error, reason} ->
              {:error, reason}
          end
        else
          {:error, "String not found in file"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_fs_edit(path, input, context) do
    resolved = resolve_path(path, context[:project_path])

    with :ok <- Synapsis.Tool.PathValidator.validate(resolved, context[:project_path]),
         {:ok, content} <- File.read(resolved) do
      old_string = input["old_string"]
      new_string = input["new_string"]

      case String.split(content, old_string) do
        [_only] ->
          {:error, "String not found in file"}

        [before, after_part] ->
          new_content = before <> new_string <> after_part

          case File.write(resolved, new_content) do
            :ok ->
              result_map = %{
                status: "ok",
                path: resolved,
                message: "Successfully edited #{resolved}",
                diff: %{old: old_string, new: new_string}
              }

              case Jason.encode(result_map) do
                {:ok, json} ->
                  {:ok, json}

                {:error, _} ->
                  {:ok, ~s({"status":"error","message":"Failed to encode response"})}
              end

            {:error, reason} ->
              {:error, "Failed to write file: #{inspect(reason)}"}
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

          case File.write(resolved, new_content) do
            :ok ->
              result_map = %{
                status: "ok",
                path: resolved,
                message: "Successfully edited #{resolved} (replaced first occurrence)",
                diff: %{old: old_string, new: new_string}
              }

              case Jason.encode(result_map) do
                {:ok, json} ->
                  {:ok, json}

                {:error, _} ->
                  {:ok, ~s({"status":"error","message":"Failed to encode response"})}
              end

            {:error, reason} ->
              {:error, "Failed to write file: #{inspect(reason)}"}
          end
      end
    else
      {:error, :enoent} -> {:error, "File not found"}
      {:error, reason} -> {:error, "File read failed: #{inspect(reason)}"}
    end
  end

  @impl true
  def permission_level, do: :write

  @impl true
  def category, do: :filesystem

  @impl true
  def side_effects, do: [:file_changed]

  defp resolve_path(path, project_path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(project_path || ".", path)
  end
end
