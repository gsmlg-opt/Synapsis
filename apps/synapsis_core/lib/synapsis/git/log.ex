defmodule Synapsis.Git.Log do
  @moduledoc "Git log queries."

  alias Synapsis.Git.Runner

  @default_limit 20

  @doc """
  Returns recent commits from the repository at `path`.

  Options:
  - `:limit` — number of commits to return (default 20)
  - `:branch` — restrict log to a specific branch

  Returns `{:ok, [%{hash: hash, subject: subject, author: author, date: date}]}`.
  """
  @spec recent(String.t(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def recent(path, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    branch = Keyword.get(opts, :branch, nil)

    args =
      ["log", "--format=%H\t%s\t%an\t%aI", "-n", to_string(limit)] ++
        if branch, do: [branch], else: []

    case Runner.run(path, args) do
      {:ok, output} ->
        commits =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_log_line/1)
          |> Enum.reject(&is_nil/1)

        {:ok, commits}

      {:error, _} = err ->
        err
    end
  end

  defp parse_log_line(line) do
    case String.split(line, "\t", parts: 4) do
      [hash, subject, author, date] ->
        %{hash: hash, subject: subject, author: author, date: date}

      _ ->
        nil
    end
  end
end
