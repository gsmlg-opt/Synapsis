# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
import Config

# Ecto Repo configuration
config :synapsis_data, ecto_repos: [Synapsis.Repo]

config :synapsis_data, Synapsis.Repo,
  migration_primary_key: [type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec]

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
  version: "1.3.3",
  synapsis_web: [
    args: ~w(build assets/js/app.ts --outdir=priv/static/assets
             --external=/fonts/* --external=/images/*),
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
