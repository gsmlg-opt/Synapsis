defmodule Synapsis.Tool.PathValidator do
  @moduledoc "Shared path validation to prevent directory traversal attacks."

  @doc """
  Returns :ok if `path` is within `project_path`, or an error tuple.

  Requires a trailing slash comparison to prevent sibling-directory attacks
  (e.g. `/tmp/foo-evil` must not match project root `/tmp/foo`).
  """
  def validate(_path, nil), do: :ok

  def validate(path, project_path) do
    abs_path = Path.expand(path)
    abs_project = Path.expand(project_path)

    if abs_path == abs_project or String.starts_with?(abs_path, abs_project <> "/") do
      :ok
    else
      {:error, "Path is outside project root"}
    end
  end
end
