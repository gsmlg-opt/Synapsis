defmodule Synapsis.Session.WorkspaceManager do
  @moduledoc """
  Manages isolated git worktrees for agent sessions.

  Provides the lifecycle for scratch workspaces where agents can test
  patches in isolation before applying to the main tree. Integrates
  with `Synapsis.GitWorktree` for git operations and `Synapsis.Patch`
  for tracking applied patches.

  ## Workflow

  1. `setup/2` — creates a worktree for a session
  2. `apply_and_test/4` — applies a patch, runs tests, records result
  3. `promote/2` — copies tested patch to main tree
  4. `revert_and_learn/3` — reverts a patch and records the failure reason
  5. `teardown/2` — removes the worktree when session ends
  """

  require Logger

  alias Synapsis.{GitWorktree, Patch, Repo}
  import Ecto.Query

  @trees_dir ".trees"

  @doc """
  Creates a git worktree for the given session.

  The worktree is placed at `<project_path>/.trees/<session_id_prefix>`.
  Returns the worktree path on success.
  """
  @spec setup(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def setup(project_path, session_id) do
    branch = "synapsis/#{short_id(session_id)}"
    worktree_path = worktree_path(project_path, session_id)

    case GitWorktree.add(project_path, worktree_path, branch) do
      {:ok, _} ->
        Logger.info("workspace_created",
          session_id: session_id,
          worktree_path: worktree_path
        )

        {:ok, worktree_path}

      {:error, reason} ->
        {:error, "Failed to create worktree: #{reason}"}
    end
  end

  @doc """
  Applies a patch in the worktree, runs the test command, and records
  the result as a `Synapsis.Patch` record.

  Returns `{:ok, patch}` with test_status set, or `{:error, reason}`.
  """
  @spec apply_and_test(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Patch.t()} | {:error, String.t()}
  def apply_and_test(project_path, session_id, diff_text, test_command \\ "mix test") do
    worktree_path = worktree_path(project_path, session_id)

    with {:ok, _} <- GitWorktree.apply_patch(worktree_path, diff_text),
         {test_output, test_exit} <- run_test(worktree_path, test_command) do
      test_status = if test_exit == 0, do: "passed", else: "failed"

      {:ok, patch} =
        %Patch{}
        |> Patch.changeset(%{
          session_id: session_id,
          file_path: extract_file_path(diff_text),
          diff_text: diff_text,
          test_status: test_status,
          test_output: truncate(test_output, 10_000)
        })
        |> Repo.insert()

      Logger.info("patch_tested",
        session_id: session_id,
        patch_id: patch.id,
        test_status: test_status
      )

      {:ok, patch}
    else
      {:error, reason} -> {:error, "Patch apply failed: #{reason}"}
    end
  end

  @doc """
  Records a revert with a failure reason for learning.

  Updates the patch record with `reverted_at` and `revert_reason`,
  then resets the worktree to a clean state.
  """
  @spec revert_and_learn(String.t(), String.t(), String.t()) ::
          {:ok, Patch.t()} | {:error, term()}
  def revert_and_learn(patch_id, reason, project_path) do
    case Repo.get(Patch, patch_id) do
      nil ->
        {:error, :not_found}

      patch ->
        worktree_path = worktree_path(project_path, patch.session_id)

        # Reset the worktree to clean state
        case run_in_dir(worktree_path, ["checkout", "."]) do
          {:ok, _} ->
            patch
            |> Patch.changeset(%{
              reverted_at: DateTime.utc_now(),
              revert_reason: reason
            })
            |> Repo.update()

          {:error, git_err} ->
            {:error, "Git reset failed: #{git_err}"}
        end
    end
  end

  @doc """
  Lists patches for a session, optionally filtered by test status.
  """
  @spec list_patches(String.t(), keyword()) :: [Patch.t()]
  def list_patches(session_id, opts \\ []) do
    query =
      Patch
      |> where([p], p.session_id == ^session_id)
      |> order_by([p], asc: p.inserted_at)

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [p], p.test_status == ^status)
      end

    Repo.all(query)
  end

  @doc """
  Promotes a tested patch from the worktree to the main project tree.

  Applies the patch's `diff_text` directly to `project_path` using `git apply`.
  The patch must have `test_status: "passed"` to be promoted.

  Returns `:ok` on success or `{:error, reason}` if the apply fails.
  """
  @spec promote(String.t(), String.t()) :: :ok | {:error, String.t()}
  def promote(patch_id, project_path) do
    case Repo.get(Patch, patch_id) do
      nil ->
        {:error, :not_found}

      %Patch{test_status: status} when status != "passed" ->
        {:error, "Cannot promote patch with status: #{status}"}

      patch ->
        # Write diff to a temp file and apply to main tree
        tmp_path = System.tmp_dir!() |> Path.join("synapsis-patch-#{patch.id}.diff")

        try do
          File.write!(tmp_path, patch.diff_text)

          case run_in_dir(project_path, ["apply", "--check", tmp_path]) do
            {:ok, _} ->
              case run_in_dir(project_path, ["apply", tmp_path]) do
                {:ok, _} ->
                  Logger.info("patch_promoted",
                    patch_id: patch_id,
                    project_path: project_path
                  )

                  :ok

                {:error, reason} ->
                  {:error, "git apply failed: #{reason}"}
              end

            {:error, reason} ->
              {:error, "Patch does not apply cleanly: #{reason}"}
          end
        after
          File.rm(tmp_path)
        end
    end
  end

  @doc """
  Removes the worktree for a session. Called during session cleanup.
  """
  @spec teardown(String.t(), String.t()) :: :ok | {:error, String.t()}
  def teardown(project_path, session_id) do
    worktree_path = worktree_path(project_path, session_id)

    case GitWorktree.remove(project_path, worktree_path) do
      {:ok, _} ->
        Logger.info("workspace_removed", session_id: session_id)
        :ok

      {:error, reason} ->
        {:error, "Failed to remove worktree: #{reason}"}
    end
  end

  # -- Private --

  defp worktree_path(project_path, session_id) do
    Path.join([project_path, @trees_dir, short_id(session_id)])
  end

  defp short_id(session_id) do
    session_id |> String.split("-") |> List.first()
  end

  defp extract_file_path(diff_text) do
    case Regex.run(~r/^--- a\/(.+)$/m, diff_text) do
      [_, path] -> path
      _ -> "unknown"
    end
  end

  defp run_test(worktree_path, command) do
    case System.find_executable("sh") do
      nil ->
        {"sh not found", 1}

      sh ->
        port =
          Port.open({:spawn_executable, sh}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: ["-c", command],
            cd: worktree_path
          ])

        collect_port_output(port, "")
    end
  rescue
    e -> {"Test execution error: #{Exception.message(e)}", 1}
  end

  defp run_in_dir(dir, git_args) do
    case System.find_executable("git") do
      nil ->
        {:error, "git not found"}

      git ->
        port =
          Port.open({:spawn_executable, git}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: git_args,
            cd: dir
          ])

        case collect_port_output(port, "") do
          {output, 0} -> {:ok, output}
          {output, code} -> {:error, "git exited #{code}: #{output}"}
        end
    end
  rescue
    e -> {:error, "git error: #{Exception.message(e)}"}
  end

  defp collect_port_output(port, acc) do
    receive do
      {^port, {:data, data}} -> collect_port_output(port, acc <> data)
      {^port, {:exit_status, code}} -> {acc, code}
    after
      60_000 ->
        Port.close(port)
        {acc <> "\n[timeout after 60s]", 1}
    end
  end

  defp truncate(text, max) when byte_size(text) > max do
    String.slice(text, 0, max) <> "\n...[truncated]"
  end

  defp truncate(text, _max), do: text
end
