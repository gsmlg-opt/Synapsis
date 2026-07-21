# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
import Config

# ADR-006 C4: PostgreSQL removed — no Ecto Repo. Session/agent state lives in
# Concord (below); configs are files; memory is the memory port.

# Concord embedded KV store (ADR-006 session storage).
# Synapsis uses Concord 3.x's node-local Turso engine, not the VSR cluster
# runtime. Keep the local store under a new generation segment.
concord_store_generation = "concord-3.0"
concord_node = node()
concord_project = Path.basename(Path.expand("..", __DIR__))

concord_data_dir =
  System.get_env("SYNAPSIS_CONCORD_DATA_DIR") ||
    Path.join([
      System.tmp_dir!(),
      concord_project,
      "concord",
      concord_store_generation,
      Atom.to_string(concord_node)
    ])

config :concord,
  cluster_enabled: false,
  # Disable value compression: it provides no benefit for a node-local
  # single-member store, and older Concord 2.x state machines crashed on
  # compressed values during apply.
  # See gsmlg-dev/concord#23 (prefix_scan) and the apply/state-machine crash.
  # TODO(upstream): gsmlg-dev/concord — remove once compression is crash-safe.
  compression: [enabled: false],
  data_dir: concord_data_dir,
  turso: [
    enabled: true,
    database: Path.join(concord_data_dir, "turso.db"),
    pool_size: 1
  ]

# General application configuration
config :synapsis_server,
  generators: [timestamp_type: :utc_datetime_usec]

# Configure the endpoint
config :synapsis_server, SynapsisServer.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SynapsisServer.ErrorHTML, json: SynapsisServer.ErrorJSON],
    layout: false
  ],
  pubsub_server: Synapsis.PubSub,
  live_view: [signing_salt: "GJORt-a_O8D4qyGG"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :session_id, :reason]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure bun for JS bundling
config :bun,
  version: "1.3.4",
  synapsis_web: [
    args: ~w(build assets/js/app.ts --outdir=priv/static/assets
             --format=esm --external=/fonts/* --external=/images/*),
    cd: Path.expand("../apps/synapsis_web", __DIR__),
    env: %{}
  ]

# Configure tailwind for CSS bundling
config :tailwind,
  version: "4.1.18",
  synapsis_web: [
    args: ~w(--input=assets/css/app.css --output=priv/static/assets/app.css),
    cd: Path.expand("../apps/synapsis_web", __DIR__)
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
