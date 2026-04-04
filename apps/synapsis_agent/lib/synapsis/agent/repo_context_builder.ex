defmodule Synapsis.Agent.RepoContextBuilder do
  @moduledoc "Assembles context for a Build Agent at spawn time."

  @type repo_context :: %{
          repo: %{name: String.t(), default_branch: String.t(), remotes: [map()]},
          worktree: %{branch: String.t(), base_branch: String.t() | nil, path: String.t()},
          git_status: map()
        }

  @spec build(binary()) :: {:ok, repo_context()} | {:error, term()}
  def build(worktree_id) do
    with %{} = worktree <- Synapsis.Worktrees.get(worktree_id),
         %{} = repo <- Synapsis.Repos.get_with_remotes(worktree.repo_id) do
      remotes =
        (repo.remotes || [])
        |> Enum.map(fn r ->
          %{name: r.name, url: r.url, is_primary: r.is_primary}
        end)

      git_status = fetch_git_status(worktree.local_path)

      context = %{
        repo: %{
          name: repo.name,
          default_branch: repo.default_branch,
          remotes: remotes
        },
        worktree: %{
          branch: worktree.branch,
          base_branch: worktree.base_branch,
          path: worktree.local_path
        },
        git_status: git_status
      }

      {:ok, context}
    else
      nil -> {:error, :not_found}
    end
  end

  defp fetch_git_status(path) do
    if path && File.dir?(path) do
      case System.cmd("git", ["-C", path, "status", "--porcelain=v1"], stderr_to_stdout: true) do
        {output, 0} ->
          parse_git_status(output)

        {error_output, _code} ->
          %{error: error_output, files: []}
      end
    else
      %{files: []}
    end
  rescue
    _ -> %{files: []}
  end

  defp parse_git_status(output) do
    files =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        <<status::binary-size(2), " ", filename::binary>> = line
        %{status: String.trim(status), path: filename}
      end)
      |> Enum.reject(fn %{path: p} -> p == "" end)

    %{files: files}
  rescue
    _ -> %{files: []}
  end
end
