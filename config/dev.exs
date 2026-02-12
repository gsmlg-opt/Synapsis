import Config

# Database configuration for development
config :synapsis_core, Synapsis.Repo,
  username: System.get_env("PGUSER", "postgres"),
  database: System.get_env("PGDATABASE", "synapsis_dev"),
  socket_dir: System.get_env("PGHOST"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :synapsis_web, SynapsisWeb.Endpoint,
  http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "TjwSh47B1XL2p3O5I35a8EPbvKCYse5R3MPmCr+YBd72WQ8roU/ucfo1Ioir4p9P",
  watchers: [
    tailwind: {Tailwind, :install_and_run, [:synapsis_web, ~w(--watch)]},
    bun: {Bun, :install_and_run, [:synapsis_web, ~w(--sourcemap=inline --watch)]}
  ]

config :synapsis_web, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
