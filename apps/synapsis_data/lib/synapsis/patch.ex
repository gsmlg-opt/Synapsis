defmodule Synapsis.Patch do
  @moduledoc "Tracks file patches applied during an agent session for revert-and-learn."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "patches" do
    field(:file_path, :string)
    field(:diff_text, :string)
    field(:git_commit_hash, :string)
    field(:test_status, :string, default: "pending")
    field(:test_output, :string)
    field(:reverted_at, :utc_datetime_usec)
    field(:revert_reason, :string)

    belongs_to(:session, Synapsis.Session)
    belongs_to(:failed_attempt, Synapsis.FailedAttempt)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(patch, attrs) do
    patch
    |> cast(attrs, [
      :session_id,
      :failed_attempt_id,
      :file_path,
      :diff_text,
      :git_commit_hash,
      :test_status,
      :test_output,
      :reverted_at,
      :revert_reason
    ])
    |> validate_required([:session_id, :file_path, :diff_text])
    |> validate_inclusion(:test_status, ~w(pending passed failed))
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:failed_attempt_id)
  end
end
