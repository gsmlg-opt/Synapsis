# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
import Config

# Cron occurrence resolution uses the IANA data bundled with the locked package.
config :tzdata, :autoupdate, :disabled

# LiveView logs nested form values too; credential keys must remain redacted.
config :phoenix, :filter_parameters, ["password", "token", "key", "secret", "authorization"]

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

# Inject source metadata without making core depend on the MCP application.
config :synapsis_core, :mcp_source_catalog, {Synapsis.MCP, :source_catalog, []}

# General application configuration
config :synapsis_server,
  generators: [timestamp_type: :utc_datetime_usec]

# Configure the endpoint
config :synapsis_server, SynapsisServer.Endpoint,
  url: [host: "localhost"],
  adapter: Gaoxy.PhoenixAdapter,
  # WORKAROUND(upstream): gsmlg-dev/gaoxy#16
  # Gaoxy caps WebSocket messages at one quarter of this shared byte budget.
  # Leave room for Phoenix's default 10 MB frames and concurrent HTTP responses.
  http: [limits: %{max_bytes: 64 * 1_024 * 1_024}],
  render_errors: [
    formats: [html: SynapsisServer.ErrorHTML, json: SynapsisServer.ErrorJSON],
    layout: false
  ],
  pubsub_server: Synapsis.PubSub,
  live_view: [signing_salt: "GJORt-a_O8D4qyGG"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :session_id, :provider_id, :provider_ids, :reason]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# DuskmoonBundler — JS/TS + Tailwind v4 (replaces bun + Tailwind CLI)
config :duskmoon_bundler,
  target: :es2020,
  sourcemap: :hidden,
  format: :esm

config :duskmoon_bundler, :synapsis_web,
  root: Path.expand("../apps/synapsis_web/assets", __DIR__),
  entry: Path.expand("../apps/synapsis_web/assets/js/app.ts", __DIR__),
  outdir: Path.expand("../apps/synapsis_web/priv/static/assets", __DIR__),
  resolve_dirs: [
    Path.expand("..", __DIR__),
    Path.expand("../apps", __DIR__),
    Path.expand("../deps", __DIR__)
  ],
  external: ~w(/fonts/* /images/*),
  tailwind: [
    css: Path.expand("../apps/synapsis_web/assets/css/app.css", __DIR__),
    sources: [
      %{
        base: Path.expand("../apps/synapsis_web/lib", __DIR__),
        pattern: "**/*.{ex,exs,heex}"
      },
      %{
        base: Path.expand("../apps/synapsis_web/assets", __DIR__),
        pattern: "**/*.{css,js,ts,jsx,tsx}"
      },
      %{
        base: Path.expand("../deps/phoenix_duskmoon/lib", __DIR__),
        pattern: "**/*.{ex,heex}"
      },
      # Required by phoenix_duskmoon's setup guide: React Chat markup uses Tailwind
      # utilities (e.g. `bottom-3 end-3`) and deps/ is never scanned automatically.
      %{
        base: Path.expand("../deps/phoenix_duskmoon/assets/js", __DIR__),
        pattern: "**/*.js"
      }
    ]
  ],
  server: [
    prefix: "/assets",
    watch_dirs: [
      Path.expand("../apps/synapsis_web/lib", __DIR__),
      Path.expand("../apps/synapsis_web/assets", __DIR__),
      Path.expand("../deps/phoenix_duskmoon/lib", __DIR__),
      Path.expand("../deps/phoenix_duskmoon/assets/js", __DIR__)
    ]
  ]

config :duskmoon_bundler, :format,
  print_width: 100,
  semi: false,
  single_quote: true,
  trailing_comma: :none,
  arrow_parens: :always

config :duskmoon_bundler, :lint,
  plugins: [:typescript],
  rules: %{
    "no-debugger" => :deny,
    "eqeqeq" => :deny
  }

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
