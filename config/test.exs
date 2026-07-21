import Config

# ADR-006 C4: no PostgreSQL. Concord runs node-local in test with an isolated
# per-partition data dir.

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

# Concord: isolated per-partition data dir, node-local Turso engine.
concord_test_partition = System.get_env("MIX_TEST_PARTITION") || "default"
concord_test_generation = "concord-3.0"

concord_test_data_dir =
  Path.expand("../tmp/concord_test/#{concord_test_generation}/#{concord_test_partition}", __DIR__)

File.rm_rf!(concord_test_data_dir)

config :concord,
  cluster_enabled: false,
  data_dir: concord_test_data_dir,
  turso: [
    enabled: true,
    database: Path.join(concord_test_data_dir, "turso.db"),
    pool_size: 1
  ]
