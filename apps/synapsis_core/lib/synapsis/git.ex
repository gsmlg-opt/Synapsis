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
  @head_max_bytes 64
  @max_output_bytes 1_048_576

  @type ref :: %{head: String.t(), stash: String.t() | nil}
  @type status :: %{head: String.t(), dirty: boolean()}

  @doc "Reads the workspace's HEAD and working-tree status without creating git objects."
  @spec status(String.t()) :: {:ok, status()} | {:error, term()}
  def status(project_path) when is_binary(project_path) do
    with :ok <- check_repo(project_path),
         {:ok, head} <- run(project_path, ["rev-parse", "HEAD"], @head_max_bytes),
         {:ok, dirty?} <-
           output?(project_path, ["status", "--porcelain", "--untracked-files=all"]) do
      {:ok, %{head: head, dirty: dirty?}}
    end
  end

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

  defp run(dir, args, max_bytes \\ @max_output_bytes) do
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

        collect(port, "", max_bytes, deadline())
    end
  end

  defp output?(dir, args) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_not_found}

      git ->
        port =
          Port.open({:spawn_executable, git}, [
            :binary,
            :exit_status,
            {:cd, dir},
            args: args
          ])

        collect_output?(port, deadline())
    end
  end

  defp collect(port, acc, max_bytes, deadline) do
    receive do
      {^port, {:data, data}} ->
        if byte_size(acc) + byte_size(data) <= max_bytes do
          collect(port, acc <> data, max_bytes, deadline)
        else
          close_port(port)
          {:error, :output_too_large}
        end

      {^port, {:exit_status, 0}} ->
        {:ok, String.trim(acc)}

      {^port, {:exit_status, status}} ->
        {:error, {:git_failed, status, String.trim(acc)}}
    after
      remaining_ms(deadline) ->
        close_port(port)
        {:error, :timeout}
    end
  end

  defp collect_output?(port, deadline) do
    receive do
      {^port, {:data, data}} when byte_size(data) > 0 ->
        close_port(port)
        {:ok, true}

      {^port, {:data, _empty}} ->
        collect_output?(port, deadline)

      {^port, {:exit_status, 0}} ->
        {:ok, false}

      {^port, {:exit_status, status}} ->
        {:error, {:git_failed, status, ""}}
    after
      remaining_ms(deadline) ->
        close_port(port)
        {:error, :timeout}
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @timeout_ms

  defp remaining_ms(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
