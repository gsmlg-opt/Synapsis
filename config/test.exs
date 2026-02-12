import Config

# Database configuration for test
config :synapsis_core, Synapsis.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "synapsis_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :synapsis_server, SynapsisServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "TG9IIkMoPGf7vzj3p+QiUXZ0wHl0MCb+PRPa58Tw/OSQFuxSh5OhfuLfDkhQo5FO",
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime
config :phoenix, sort_verified_routes_query_params: true
