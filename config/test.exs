import Config

# Database configuration for test
# Note: socket_dir is set in runtime.exs to pick up PGHOST at startup time
config :synapsis_data, Synapsis.Repo,
  database: "synapsis_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :synapsis_server, SynapsisServer.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "TG9IIkMoPGf7vzj3p+QiUXZ0wHl0MCb+PRPa58Tw/OSQFuxSh5OhfuLfDkhQo5FO",
  server: false

config :synapsis_data, encryption_key: "test-encryption-key-32bytes!!!!!"

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime
config :phoenix, sort_verified_routes_query_params: true

config :synapsis_core, :file_system_enabled, false
