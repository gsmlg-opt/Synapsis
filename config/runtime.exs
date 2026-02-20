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

# Database connection — read PGHOST/PGUSER at runtime so devenv socket paths work
config :synapsis_data, Synapsis.Repo,
  username: System.get_env("PGUSER", "postgres"),
  database: System.get_env("PGDATABASE", if(config_env() == :test, do: "synapsis_test", else: "synapsis_dev")),
  socket_dir: System.get_env("PGHOST")

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
