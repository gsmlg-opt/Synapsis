defmodule Synapsis.LocalAgentConfig do
  @moduledoc """
  Definition of a local agent process managed by Synapsis (`local_agents.toml`).
  Runtime state lives in `synapsis_local_agents`, not here.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ["codex"]

  @primary_key {:id, :binary_id, autogenerate: false}

  embedded_schema do
    field(:name, :string)
    field(:kind, :string)
    field(:executable, :string)
    field(:args, {:array, :string}, default: ["app-server", "--listen", "stdio://"])
    field(:cwd, :string)
    field(:codex_home, :string)
    field(:autostart, :boolean, default: false)
  end

  @type t :: %__MODULE__{}

  def kinds, do: @kinds

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:id, :name, :kind, :executable, :args, :cwd, :codex_home, :autostart])
    |> validate_required([:name, :kind, :executable])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:name, max: 255)
    |> put_default_codex_home()
  end

  defp put_default_codex_home(changeset) do
    if get_field(changeset, :kind) == "codex" and is_nil(get_field(changeset, :codex_home)),
      do: put_change(changeset, :codex_home, Path.expand("~/.codex")),
      else: changeset
  end
end
