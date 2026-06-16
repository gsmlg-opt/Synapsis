defmodule Synapsis.Git do
  @moduledoc """
  Minimal git helpers for workspace checkpoints.

  `capture_ref/1` is non-destructive: it records HEAD plus a `git stash
  create` commit when the tree is dirty, leaving the working tree untouched.
  `restore_ref/2` is destructive by design — it resets tracked files to the
  captured state. Untracked files are not captured and never deleted.

  Commands run through a `Port` with an explicit timeout per guardrails.
  """

  require Logger

  @timeout_ms 10_000

  @type ref :: %{head: String.t(), stash: String.t() | nil}

  @doc "Captures the workspace's current git state without modifying it."
  @spec capture_ref(String.t()) :: {:ok, ref()} | {:error, term()}
  def capture_ref(project_path) when is_binary(project_path) do
    with :ok <- check_repo(project_path),
         {:ok, head} <- run(project_path, ["rev-parse", "HEAD"]) do
      stash =
        case run(project_path, ["stash", "create", "synapsis checkpoint"]) do
          {:ok, ""} -> nil
          {:ok, sha} -> sha
          {:error, _} -> nil
        end

      {:ok, %{head: head, stash: stash}}
    end
  end

  @doc """
  Restores tracked files to a captured ref: hard-reset to the recorded HEAD,
  then re-apply the dirty state captured at checkpoint time (if any).
  """
  @spec restore_ref(String.t(), ref()) :: :ok | {:error, term()}
  def restore_ref(project_path, %{head: head} = ref) when is_binary(project_path) do
    with :ok <- check_repo(project_path),
         {:ok, _} <- run(project_path, ["reset", "--hard", head]) do
      case ref[:stash] do
        nil ->
          :ok

        stash ->
          with {:ok, _} <- run(project_path, ["stash", "apply", stash]), do: :ok
      end
    end
  end

  defp check_repo(project_path) do
    # Plain repos have a `.git` directory; worktrees have a `.git` file.
    if File.exists?(Path.join(project_path, ".git")),
      do: :ok,
      else: {:error, :not_a_git_repo}
  end

  defp run(dir, args) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_not_found}

      git ->
        port =
          Port.open({:spawn_executable, git}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:cd, dir},
            args: args
          ])

        collect(port, "")
    end
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect(port, acc <> data)

      {^port, {:exit_status, 0}} ->
        {:ok, String.trim(acc)}

      {^port, {:exit_status, status}} ->
        {:error, {:git_failed, status, String.trim(acc)}}
    after
      @timeout_ms ->
        Port.close(port)
        {:error, :timeout}
    end
  end
end
