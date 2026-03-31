defmodule Synapsis.Tool.PathValidator do
  @moduledoc "Shared path validation to prevent directory traversal attacks."

  @doc """
  Returns :ok if `path` is within `project_path`, or an error tuple.

  Requires a trailing slash comparison to prevent sibling-directory attacks
  (e.g. `/tmp/foo-evil` must not match project root `/tmp/foo`).

  Also resolves symlinks to prevent symlink-based escapes where a symlink
  inside the project root points to a target outside it.
  """
  def validate(_path, nil), do: :ok

  def validate(path, project_path) do
    abs_path = resolve_path(Path.expand(path))
    abs_project = resolve_path(Path.expand(project_path))

    if abs_path == abs_project or String.starts_with?(abs_path, abs_project <> "/") do
      :ok
    else
      {:error, "Path is outside project root"}
    end
  end

  # Resolve symlinks by walking path components from root.
  # For each component, if it's a symlink, follow it and continue.
  # Falls back to the lexical path if the file doesn't exist yet (new file writes).
  defp resolve_path(path) do
    parts = Path.split(path)
    resolve_components(parts, "")
  end

  defp resolve_components([], acc), do: acc

  defp resolve_components([part | rest], acc) do
    current = Path.join(acc, part)

    case :file.read_link(current) do
      {:ok, target} ->
        resolved =
          if :filename.pathtype(target) == :absolute do
            to_string(target)
          else
            Path.expand(to_string(target), acc)
          end

        resolve_components(rest, resolved)

      {:error, _} ->
        resolve_components(rest, current)
    end
  end
end
