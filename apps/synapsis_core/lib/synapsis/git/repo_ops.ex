defmodule Synapsis.Git.RepoOps do
  @moduledoc "Git repository operations: clone, remote management, fetch."

  alias Synapsis.Git.Runner

  @doc """
  Clones a repository as a bare clone to `bare_path`.

  Creates parent directories as needed.
  """
  @spec clone_bare(String.t(), String.t()) :: :ok | {:error, String.t()}
  def clone_bare(url, bare_path) do
    File.mkdir_p!(Path.dirname(bare_path))

    case Runner.run(System.tmp_dir!(), ["clone", "--bare", url, bare_path]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Adds a named remote to the bare repository.
  """
  @spec add_remote(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def add_remote(bare_path, name, url) do
    case Runner.run(bare_path, ["remote", "add", name, url]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Removes a named remote from the bare repository.
  """
  @spec remove_remote(String.t(), String.t()) :: :ok | {:error, String.t()}
  def remove_remote(bare_path, name) do
    case Runner.run(bare_path, ["remote", "remove", name]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Sets the push URL for a remote.
  """
  @spec set_push_url(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def set_push_url(bare_path, remote, url) do
    case Runner.run(bare_path, ["remote", "set-url", "--push", remote, url]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Fetches all remotes, pruning stale tracking references.
  """
  @spec fetch_all(String.t()) :: :ok | {:error, String.t()}
  def fetch_all(bare_path) do
    case Runner.run(bare_path, ["fetch", "--all", "--prune"]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Fetches a specific remote.
  """
  @spec fetch_remote(String.t(), String.t()) :: :ok | {:error, String.t()}
  def fetch_remote(bare_path, remote) do
    case Runner.run(bare_path, ["fetch", remote]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end
end
