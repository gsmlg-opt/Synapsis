# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
import Config

# ADR-006 C4: PostgreSQL removed — no Ecto Repo. Session/agent state lives in
# Concord (below); configs are files; memory is the memory port.

# Concord embedded KV store (ADR-006 session storage).
# Node-local mode: clustering off means no libcluster/leader-election gating
# in the session path — a single-member Ra cluster on this node. The Prometheus
# exporter (default-on, binds :9568) and HTTP API are off — this is an embedded
# in-process store, not a standalone server.
config :concord,
  clustering: false,
  prometheus_enabled: false,
  http: [enabled: false],
  data_dir: Path.expand("../tmp/concord/#{node()}", __DIR__)

# Concord 1.1.0 does not start the :ra default system itself, so give :ra an
# explicit on-disk home; the host boot starts the default system before the
# node-local store is used (see Synapsis.Session.Store.ensure_started/1).
config :ra, data_dir: Path.expand("../tmp/ra/#{node()}", __DIR__) |> to_charlist()

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
  metadata: [:request_id, :session_id]

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
