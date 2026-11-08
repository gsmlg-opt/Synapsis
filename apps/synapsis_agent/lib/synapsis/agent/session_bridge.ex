defmodule Synapsis.Agent.SessionBridge do
  @moduledoc """
  Builds workspace file context for spawned agent sessions.
  """

  @doc """
  Builds context string for a spawned session from an agent workspace.
  """
  @spec build_spawn_context(String.t(), map()) :: String.t()
  def build_spawn_context(workspace_path, _opts \\ %{}) do
    sections = []

    sections =
      case build_file_tree(workspace_path) do
        nil -> sections
        tree -> sections ++ ["## Workspace Files\n```\n#{tree}\n```"]
      end

    case sections do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  # -- Private --

  defp build_file_tree(project_path) do
    if File.dir?(project_path) do
      lines =
        list_files_recursive(project_path, project_path, 3)
        |> Enum.take(50)
        |> Enum.join("\n")

      if lines == "", do: nil, else: lines
    end
  end

  defp list_files_recursive(_base, _dir, 0), do: []

  defp list_files_recursive(base, dir, depth) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.flat_map(fn entry ->
          full = Path.join(dir, entry)
          rel = Path.relative_to(full, base)

          if File.dir?(full) do
            [rel | list_files_recursive(base, full, depth - 1)]
          else
            [rel]
          end
        end)

      {:error, _} ->
        []
    end
  end
end
