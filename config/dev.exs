import Config

# Database configuration for development
# Note: socket_dir is set in runtime.exs to pick up PGHOST at startup time
config :synapsis_data, Synapsis.Repo,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :synapsis_server, SynapsisServer.Endpoint,
  http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: 4657],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "TjwSh47B1XL2p3O5I35a8EPbvKCYse5R3MPmCr+YBd72WQ8roU/ucfo1Ioir4p9P",
  watchers: [
    tailwind: {Tailwind, :install_and_run, [:synapsis_web, ~w(--watch)]},
    bun: {Bun, :install_and_run, [:synapsis_web, ~w(--sourcemap=inline --watch)]}
  ]

config :synapsis_server, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

# Auto-approve all tool risk levels in dev for uninterrupted agent loops
config :synapsis_core, default_auto_approve: [:read, :write, :execute]
