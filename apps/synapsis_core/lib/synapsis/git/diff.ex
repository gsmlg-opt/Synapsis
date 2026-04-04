defmodule Synapsis.Git.Diff do
  @moduledoc "Git diff queries."

  alias Synapsis.Git.Runner

  @doc """
  Returns the diff between `base_branch` and HEAD in the given worktree path.

  Uses three-dot (`...`) range syntax so only commits unique to HEAD are shown.
  """
  @spec from_base(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def from_base(worktree_path, base_branch) do
    Runner.run(worktree_path, ["diff", "#{base_branch}...HEAD"])
  end

  @doc """
  Returns a summary of the diff between `base_branch` and HEAD.

  Parses `--numstat` output into `%{files_changed: n, insertions: n, deletions: n}`.
  """
  @spec stat(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def stat(worktree_path, base_branch) do
    case Runner.run(worktree_path, ["diff", "--numstat", "#{base_branch}...HEAD"]) do
      {:ok, output} ->
        lines =
          output
          |> String.split("\n", trim: true)
          |> Enum.reject(&(&1 == ""))

        {insertions, deletions} =
          Enum.reduce(lines, {0, 0}, fn line, {ins_acc, del_acc} ->
            case String.split(line, "\t", parts: 3) do
              [ins_str, del_str, _file] ->
                ins = parse_int(ins_str)
                del = parse_int(del_str)
                {ins_acc + ins, del_acc + del}

              _ ->
                {ins_acc, del_acc}
            end
          end)

        {:ok, %{files_changed: length(lines), insertions: insertions, deletions: deletions}}

      {:error, _} = err ->
        err
    end
  end

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end
end
