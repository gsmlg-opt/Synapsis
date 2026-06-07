import Config

# ADR-006 C4: no PostgreSQL. Concord runs node-local in test with an isolated
# per-partition data dir (see the :concord / :ra config below).

config :synapsis_server, SynapsisServer.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "TG9IIkMoPGf7vzj3p+QiUXZ0wHl0MCb+PRPa58Tw/OSQFuxSh5OhfuLfDkhQo5FO",
  server: false

config :synapsis_data, encryption_key: "test-encryption-key-32bytes!!!!!"

config :logger, level: :warning

config_store_dir =
  Path.expand("../tmp/config_store_test#{System.get_env("MIX_TEST_PARTITION")}", __DIR__)

File.rm_rf!(config_store_dir)
File.mkdir_p!(config_store_dir)
System.put_env("SYNAPSIS_CONFIG_DIR", config_store_dir)

config :phoenix, :plug_init_mode, :runtime
config :phoenix, sort_verified_routes_query_params: true

config :synapsis_core, :file_system_enabled, false

# Memory port: isolated per-partition file store for tests.
config :synapsis_core,
  memory_dir: Path.expand("../tmp/memory_test#{System.get_env("MIX_TEST_PARTITION")}", __DIR__)

# Concord: isolated per-partition data dir, clustering off (single node).
config :concord,
  clustering: false,
  data_dir: Path.expand("../tmp/concord_test#{System.get_env("MIX_TEST_PARTITION")}", __DIR__)

config :ra,
  data_dir:
    Path.expand("../tmp/ra_test#{System.get_env("MIX_TEST_PARTITION")}", __DIR__)
    |> to_charlist()
