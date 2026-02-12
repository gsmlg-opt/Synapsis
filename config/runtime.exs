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

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :synapsis_web, SynapsisWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base
end
