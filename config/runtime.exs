import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# application is started, so it is typically used to load production
# configuration and secrets from environment variables or elsewhere.

# ADR-006 C4: PostgreSQL removed — no Repo runtime config. Session/agent state is
# in the embedded Concord store (defaults configured in config.exs).

if concord_data_dir = System.get_env("SYNAPSIS_CONCORD_DATA_DIR") do
  config :concord,
    data_dir: concord_data_dir,
    turso: [database: Path.join(concord_data_dir, "turso.db")]
end

# Encryption key for provider API keys (AES-256-GCM)
encryption_key =
  if config_env() == :prod do
    System.get_env("SYNAPSIS_ENCRYPTION_KEY") ||
      raise """
      environment variable SYNAPSIS_ENCRYPTION_KEY is missing.
      This key encrypts provider API keys stored in the database.
      Generate a 32-byte key: :crypto.strong_rand_bytes(32) |> Base.encode64()
      """
  else
    System.get_env("SYNAPSIS_ENCRYPTION_KEY") || "dev-only-encryption-key-32bytes!"
  end

config :synapsis_data, encryption_key: encryption_key

if filesystem_node = System.get_env("SYNAPSIS_FILESYSTEM_NODE") do
  config :synapsis_agent, :filesystem_node, filesystem_node
end

diffs_endpoint_overrides =
  if config_env() == :prod do
    config :duskmoon_bundler_runtime, :synapsis_web,
      outdir: Application.app_dir(:synapsis_web, "priv/static/assets")

    secret_key_base =
      System.get_env("SECRET_KEY_BASE") ||
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """

    host = System.get_env("PHX_HOST") || "example.com"
    port = String.to_integer(System.get_env("PORT") || "4657")

    ip =
      "PHX_IP"
      |> System.get_env("127.0.0.1")
      |> String.to_charlist()
      |> :inet.parse_address()
      |> case do
        {:ok, address} -> address
        {:error, _reason} -> raise "invalid PHX_IP; expected an IPv4 or IPv6 address"
      end

    endpoint_options = [
      server: true,
      url: [host: host, port: 443, scheme: "https"],
      http: [
        ip: ip,
        port: port
      ],
      secret_key_base: secret_key_base
    ]

    config :synapsis_server, SynapsisServer.Endpoint, endpoint_options
    endpoint_options
  else
    []
  end

# Compose a plain trusted URL after effective endpoint overrides. Agent code
# receives no Phoenix dependency and never derives a public origin from Host
# headers or the generated example.com/localhost placeholders.
diffs_endpoint =
  Keyword.merge(
    Application.get_env(:synapsis_server, SynapsisServer.Endpoint, []),
    diffs_endpoint_overrides
  )

diffs_https = diffs_endpoint[:https]
diffs_listener = diffs_https || diffs_endpoint[:http] || []
diffs_listener_scheme = if diffs_https, do: "https", else: "http"
diffs_url = diffs_endpoint[:url] || []
diffs_configured_host = diffs_url[:host]

diffs_public_host =
  if is_binary(diffs_configured_host) and
       String.downcase(diffs_configured_host) not in [
         "",
         "localhost",
         "example.com",
         "0.0.0.0",
         "::",
         "[::]",
         "*"
       ] do
    diffs_configured_host
  end

diffs_scheme =
  if diffs_public_host,
    do: diffs_url[:scheme] || diffs_listener_scheme,
    else: diffs_listener_scheme

diffs_port =
  if(diffs_public_host, do: diffs_url[:port]) || diffs_listener[:port] ||
    if(diffs_listener_scheme == "https", do: 443, else: 80)

diffs_port = if is_binary(diffs_port), do: String.to_integer(diffs_port), else: diffs_port

config :synapsis_agent,
       :diffs_host_origin,
       URI.to_string(%URI{
         scheme: diffs_scheme,
         host: diffs_public_host || "127.0.0.1",
         port: diffs_port,
         path: diffs_url[:path] || ""
       })
