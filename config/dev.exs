import Config

# Database configuration for development
config :synapsis_core, Synapsis.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "synapsis_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :synapsis_server, SynapsisServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "TjwSh47B1XL2p3O5I35a8EPbvKCYse5R3MPmCr+YBd72WQ8roU/ucfo1Ioir4p9P",
  watchers: []

config :synapsis_server, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
