defmodule SynapsisData.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :synapsis_data,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SynapsisData.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    # ADR-006 C4: Postgres removed. `ecto` stays for data modeling only
    # (Ecto.Type/changeset used by Part/Encrypted.Binary); no ecto_sql/postgrex,
    # no Repo. Session/agent state lives in Concord; configs in files; memory in
    # the memory port.
    [
      {:ecto, "~> 3.12"},
      {:jason, "~> 1.4"},
      {:concord, "~> 3.0.0-beta.5"},
      {:toml, "~> 0.7"},
      {:file_system, "~> 1.0"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
