defmodule Synapsis.Git.Branch do
  @moduledoc "Git branch operations: create, delete, list, check existence."

  alias Synapsis.Git.Runner

  @doc """
  Creates a new branch at the given base ref.
  """
  @spec create(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def create(bare_path, name, base) do
    case Runner.run(bare_path, ["branch", name, base]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Deletes a branch. Pass `force: true` to use `-D` (force delete).
  """
  @spec delete(String.t(), String.t(), boolean()) :: :ok | {:error, String.t()}
  def delete(bare_path, name, force \\ false) do
    flag = if force, do: "-D", else: "-d"

    case Runner.run(bare_path, ["branch", flag, name]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Lists all local branches, returning their short names.
  """
  @spec list(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def list(bare_path) do
    case Runner.run(bare_path, ["branch", "--format=%(refname:short)"]) do
      {:ok, output} ->
        branches =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, branches}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Returns `true` if the branch exists, `false` otherwise.
  """
  @spec exists?(String.t(), String.t()) :: boolean()
  def exists?(bare_path, name) do
    case Runner.run(bare_path, ["rev-parse", "--verify", "refs/heads/#{name}"]) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
end
