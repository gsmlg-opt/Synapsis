defmodule Synapsis.LocalAgentConfig do
  @moduledoc """
  Definition of a local agent process managed by Synapsis (`local_agents.toml`).
  Runtime state lives in `synapsis_local_agents`, not here.

  Kinds:

    * `"codex"` — a Codex app-server Synapsis spawns (`executable`, `args`, `cwd`, `codex_home`)
    * `"sigma"` — a running Sigma samgita_protocol host Synapsis connects to (`url`,
      `repository` for new threads). Its Bearer token is stored encrypted
      (`token_encrypted`) and set only through `Synapsis.LocalAgentConfigs.rotate_token/1`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ["codex", "sigma"]

  @primary_key {:id, :binary_id, autogenerate: false}

  embedded_schema do
    field(:name, :string)
    field(:kind, :string)
    field(:executable, :string)
    field(:args, {:array, :string}, default: ["app-server", "--listen", "stdio://"])
    field(:cwd, :string)
    field(:codex_home, :string)
    field(:url, :string)
    field(:repository, :string)
    field(:token_encrypted, :string, redact: true)
    field(:autostart, :boolean, default: false)
  end

  @type t :: %__MODULE__{}

  def kinds, do: @kinds

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :id,
      :name,
      :kind,
      :executable,
      :args,
      :cwd,
      :codex_home,
      :url,
      :repository,
      :autostart
    ])
    |> validate_required([:name, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:name, max: 255)
    |> validate_kind()
    |> put_default_codex_home()
  end

  defp validate_kind(changeset) do
    case get_field(changeset, :kind) do
      "codex" ->
        validate_required(changeset, [:executable])

      "sigma" ->
        changeset
        |> validate_required([:url, :repository])
        |> validate_change(:url, fn :url, url ->
          case URI.parse(url) do
            %URI{scheme: scheme, host: host}
            when scheme in ["ws", "wss"] and host not in [nil, ""] ->
              []

            _ ->
              [url: "must be a ws:// or wss:// URL"]
          end
        end)
        |> validate_change(:repository, fn :repository, path ->
          if Path.type(path) == :absolute, do: [], else: [repository: "must be an absolute path"]
        end)

      _ ->
        changeset
    end
  end

  defp put_default_codex_home(changeset) do
    if get_field(changeset, :kind) == "codex" and is_nil(get_field(changeset, :codex_home)),
      do: put_change(changeset, :codex_home, Path.expand("~/.codex")),
      else: changeset
  end
end
