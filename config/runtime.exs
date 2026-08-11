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

# ADR-006 C4: PostgreSQL removed — no Repo runtime config. Session/agent state is
# in the embedded Concord store (configured in config.exs).

# Encryption key for provider API keys (AES-256-GCM)
encryption_key =
  if config_env() == :prod do
    System.get_env("SYNAPSIS_ENCRYPTION_KEY") ||
      raise """
      environment variable SYNAPSIS_ENCRYPTION_KEY is missing.
      This key encrypts provider API keys stored in the database.
      Generate a 32-byte key: :crypto.strong_rand_bytes(32) |> Base.encode64()
      """
  else
    System.get_env("SYNAPSIS_ENCRYPTION_KEY") || "dev-only-encryption-key-32bytes!"
  end

config :synapsis_data, encryption_key: encryption_key

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4657")

  ip =
    "PHX_IP"
    |> System.get_env("127.0.0.1")
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, address} -> address
      {:error, _reason} -> raise "invalid PHX_IP; expected an IPv4 or IPv6 address"
    end

  config :synapsis_server, SynapsisServer.Endpoint,
    server: true,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: ip,
      port: port
    ],
    secret_key_base: secret_key_base
end

if System.get_env("MIX_BUN_PATH") do
  config :bun, path: System.get_env("MIX_BUN_PATH")
end

if System.get_env("MIX_TAILWIND_PATH") do
  config :tailwind, path: System.get_env("MIX_TAILWIND_PATH")
end
