import Config

# ADR-006 C4: no PostgreSQL. Concord runs node-local in test with an isolated
# per-partition data dir.

config :synapsis_server, SynapsisServer.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "TG9IIkMoPGf7vzj3p+QiUXZ0wHl0MCb+PRPa58Tw/OSQFuxSh5OhfuLfDkhQo5FO",
  server: false

config :synapsis_data, encryption_key: "test-encryption-key-32bytes!!!!!"

config :logger, level: :warning

# Every BEAM that loads test config (a test run, or an editor language server
# compiling with MIX_ENV=test) gets its own data root, so loading config can
# never wipe the stores of a suite that is already running. Roots left by
# processes that no longer exist are removed here.
test_partition = System.get_env("MIX_TEST_PARTITION") || "default"
test_runs_dir = Path.expand("../tmp/test_runs", __DIR__)
test_run_dir = Path.join(test_runs_dir, "#{test_partition}-#{System.pid()}")

for stale <- Path.wildcard(Path.join(test_runs_dir, "*-*")),
    pid = stale |> Path.basename() |> String.split("-") |> List.last(),
    pid != System.pid(),
    match?({_, status} when status != 0, System.cmd("kill", ["-0", pid], stderr_to_stdout: true)) do
  File.rm_rf!(stale)
end

File.rm_rf!(test_run_dir)

config_store_dir = Path.join(test_run_dir, "config_store_test")
File.mkdir_p!(config_store_dir)
System.put_env("SYNAPSIS_CONFIG_DIR", config_store_dir)

# Workspace documents default to the current directory; keep tests out of the
# source tree.
workspace_root = Path.join(test_run_dir, "workspace")
File.mkdir_p!(workspace_root)
System.put_env("SYNAPSIS_WORKSPACE_ROOT", workspace_root)

config :phoenix, :plug_init_mode, :runtime
config :phoenix, sort_verified_routes_query_params: true

config :phoenix_live_view, :test_warnings, missing_form_id: :raise

config :synapsis_core, :file_system_enabled, false

# Memory port: isolated per-run file store for tests.
config :synapsis_core, memory_dir: Path.join(test_run_dir, "memory_test")

# Concord: isolated per-run data dir, node-local Turso engine.
concord_test_data_dir = Path.join([test_run_dir, "concord_test", "concord-3.0"])

config :concord,
  cluster_enabled: false,
  data_dir: concord_test_data_dir,
  turso: [
    enabled: true,
    database: Path.join(concord_test_data_dir, "turso.db"),
    pool_size: 1
  ]
