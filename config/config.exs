# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
import Config

# General application configuration
config :synapsis_server,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :synapsis_server, SynapsisServerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: SynapsisServerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SynapsisServer.PubSub

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :session_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
