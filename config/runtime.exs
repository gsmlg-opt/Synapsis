import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# application is started, so it is typically used to load production
# configuration and secrets from environment variables or elsewhere.

# Use devenv-provided binaries when available
if System.get_env("MIX_BUN_PATH") do
  config :bun, path: System.get_env("MIX_BUN_PATH")
end

if System.get_env("MIX_TAILWIND_PATH") do
  config :tailwind, path: System.get_env("MIX_TAILWIND_PATH")
end

# Database connection — supports both Unix socket (devenv) and TCP (Docker/prod)
db_config = [
  username: System.get_env("PGUSER", "postgres"),
  database:
    System.get_env(
      "PGDATABASE",
      if(config_env() == :test, do: "synapsis_test", else: "synapsis_dev")
    )
]

pghost = System.get_env("PGHOST")

db_config =
  cond do
    # TCP connection when PGPASSWORD is set (Docker / remote DB)
    System.get_env("PGPASSWORD") ->
      db_config ++
        [
          hostname: pghost || "localhost",
          password: System.get_env("PGPASSWORD"),
          port: String.to_integer(System.get_env("PGPORT", "5432"))
        ]

    # Unix socket (devenv / local development)
    pghost ->
      db_config ++ [socket_dir: pghost]

    # Default: try localhost TCP
    true ->
      db_config ++ [hostname: "localhost"]
  end

config :synapsis_data, Synapsis.Repo, db_config

# Encryption key for provider API keys (AES-256-GCM)
config :synapsis_data,
  encryption_key:
    System.get_env("SYNAPSIS_ENCRYPTION_KEY") ||
      "dev-only-encryption-key-32bytes!"

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4657")

  config :synapsis_server, SynapsisServer.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base
end
