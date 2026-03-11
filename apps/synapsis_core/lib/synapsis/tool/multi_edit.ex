defmodule Synapsis.Tool.MultiEdit do
  @moduledoc "Apply multiple edits across one or more files in a single operation."
  use Synapsis.Tool

  @impl true
  def name, do: "multi_edit"

  @impl true
  def description, do: "Apply multiple edits across one or more files in a single operation."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "edits" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{"type" => "string", "description" => "Path to the file to edit"},
              "old_string" => %{
                "type" => "string",
                "description" => "The exact string to find and replace"
              },
              "new_string" => %{
                "type" => "string",
                "description" => "The replacement string"
              }
            },
            "required" => ["path", "old_string", "new_string"]
          }
        }
      },
      "required" => ["edits"]
    }
  end

  @impl true
  def permission_level, do: :write

  @impl true
  def category, do: :filesystem

  @impl true
  def side_effects, do: [:file_changed]

  @impl true
  def execute(input, context) do
    edits = input["edits"] || []
    project_path = context[:project_path]

    if edits == [] do
      {:ok, "No edits to apply."}
    else
      # Group edits by file path
      grouped = Enum.group_by(edits, & &1["path"])

      # Process each file independently
      results =
        Enum.map(grouped, fn {path, file_edits} ->
          resolved = resolve_path(path, project_path)
          apply_edits_to_file(resolved, file_edits, project_path)
        end)

      # Collect successes and failures
      {successes, failures} = Enum.split_with(results, fn {status, _} -> status == :ok end)

      case {successes, failures} do
        {_, []} ->
          msg = Enum.map_join(successes, "\n", fn {:ok, m} -> m end)
          {:ok, msg}

        {[], _} ->
          msg = Enum.map_join(failures, "\n", fn {:error, m} -> m end)
          {:error, msg}

        {_, _} ->
          ok_msg = Enum.map_join(successes, "\n", fn {:ok, m} -> m end)
          err_msg = Enum.map_join(failures, "\n", fn {:error, m} -> m end)
          {:ok, "Partial success:\n#{ok_msg}\nFailures:\n#{err_msg}"}
      end
    end
  end

  defp resolve_path(path, project_path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(project_path || ".", path)
  end

  defp apply_edits_to_file(path, edits, project_path) do
    with :ok <- Synapsis.Tool.PathValidator.validate(path, project_path),
         {:ok, original_content} <- File.read(path) do
      apply_edits_sequentially(path, original_content, edits)
    else
      {:error, :enoent} -> {:error, "File not found: #{path}"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "Error reading #{path}: #{inspect(reason)}"}
    end
  end

  defp apply_edits_sequentially(path, original_content, edits) do
    result =
      Enum.reduce_while(edits, {:ok, original_content, 0}, fn edit, {:ok, content, count} ->
        old = edit["old_string"]
        new = edit["new_string"]

        if String.contains?(content, old) do
          # Replace first occurrence
          [before | _] = :binary.split(content, old)

          rest =
            :binary.part(
              content,
              byte_size(before) + byte_size(old),
              byte_size(content) - byte_size(before) - byte_size(old)
            )

          updated = before <> new <> rest
          {:cont, {:ok, updated, count + 1}}
        else
          {:halt, {:error, "Edit #{count + 1} failed: string not found in #{path}"}}
        end
      end)

    case result do
      {:ok, final_content, count} ->
        case File.write(path, final_content) do
          :ok ->
            {:ok, "Applied #{count} edit(s) to #{path}"}

          {:error, reason} ->
            # Rollback
            File.write(path, original_content)
            {:error, "Failed to write #{path}: #{inspect(reason)}"}
        end

      {:error, msg} ->
        # Rollback - restore original
        File.write(path, original_content)
        {:error, msg}
    end
  end
end
