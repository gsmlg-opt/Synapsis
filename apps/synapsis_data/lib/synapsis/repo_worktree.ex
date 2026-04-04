defmodule Synapsis.RepoWorktree do
  @moduledoc "Git worktree entity for tracking agent-managed working trees."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "repo_worktrees" do
    field(:branch, :string)
    field(:base_branch, :string)
    field(:local_path, :string)
    field(:status, Ecto.Enum, values: [:active, :completed, :failed, :cleaning], default: :active)
    field(:agent_session_id, :string)
    field(:task_id, :string)
    field(:metadata, :map, default: %{})
    field(:completed_at, :utc_datetime_usec)
    field(:cleaned_at, :utc_datetime_usec)

    belongs_to(:repo, Synapsis.RepoRecord)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(worktree, attrs) do
    worktree
    |> cast(attrs, [
      :repo_id,
      :branch,
      :base_branch,
      :local_path,
      :status,
      :agent_session_id,
      :task_id,
      :metadata,
      :completed_at,
      :cleaned_at
    ])
    |> validate_required([:repo_id, :branch, :local_path])
    |> foreign_key_constraint(:repo_id)
    |> unique_constraint([:repo_id, :branch],
      name: :repo_worktrees_repo_id_branch_active_index
    )
  end
end
