defmodule Synapsis.RepoRemote do
  @moduledoc "Remote URL configuration for a git repository."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @url_format ~r/^(https?:\/\/.+|git@.+:.+)$/

  schema "repo_remotes" do
    field(:name, :string)
    field(:url, :string)
    field(:push_url, :string)
    field(:is_primary, :boolean, default: false)

    belongs_to(:repo, Synapsis.RepoRecord)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(remote, attrs) do
    remote
    |> cast(attrs, [:repo_id, :name, :url, :push_url, :is_primary])
    |> validate_required([:repo_id, :name, :url])
    |> validate_format(:url, @url_format, message: "must be a valid HTTPS or SSH URL")
    |> foreign_key_constraint(:repo_id)
    |> unique_constraint([:repo_id, :name])
  end
end
