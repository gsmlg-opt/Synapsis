defmodule Synapsis.Git.Status do
  @moduledoc "Git status queries."

  alias Synapsis.Git.Runner

  @doc """
  Returns a summary of the working tree status in the given path.

  Parses `git status --porcelain` output into:
  `%{staged: [file], modified: [file], untracked: [file]}`
  """
  @spec summary(String.t()) :: {:ok, map()} | {:error, String.t()}
  def summary(worktree_path) do
    case Runner.run(worktree_path, ["status", "--porcelain"]) do
      {:ok, output} ->
        result = parse_status(output)
        {:ok, result}

      {:error, _} = err ->
        err
    end
  end

  defp parse_status(output) do
    lines =
      output
      |> String.split("\n", trim: true)
      |> Enum.reject(&(&1 == ""))

    Enum.reduce(lines, %{staged: [], modified: [], untracked: []}, fn line, acc ->
      case line do
        "?? " <> file ->
          Map.update!(acc, :untracked, &[String.trim(file) | &1])

        <<xy::binary-size(2), " ", file::binary>> ->
          x = String.at(xy, 0)
          y = String.at(xy, 1)
          file = String.trim(file)

          acc =
            if x != " " and x != "?" do
              Map.update!(acc, :staged, &[file | &1])
            else
              acc
            end

          if y != " " and y != "?" do
            Map.update!(acc, :modified, &[file | &1])
          else
            acc
          end

        _ ->
          acc
      end
    end)
    |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)
  end
end
