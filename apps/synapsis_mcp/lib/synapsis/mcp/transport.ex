defmodule Synapsis.MCP.Transport do
  @moduledoc """
  Maps a `Synapsis.MCPConfig` to a `Backplane.McpProtocol.Client` transport tuple.

  Single source of truth for transport option names and protocol-version
  compatibility; if `backplane_mcp_protocol` changes a key, change it here only.

  Option keys verified against `backplane_mcp_protocol` 1.6.3:

    * `:stdio` — `command` (required), `args`, `env`
      (`Backplane.McpProtocol.Transport.STDIO` options schema).
    * `:streamable_http` — `base_url` (required), `mcp_path`, `headers`
      (`Backplane.McpProtocol.Transport.StreamableHTTP` options schema).
      Backplane requests `URI.append_path(base_url, mcp_path)` (mcp_path
      default `/mcp`), so the configured `url` is split into host (`base_url`)
      + path (`mcp_path`) to avoid a doubled `/mcp` path.
    * `:sse` — `server: [base_url: ...]` (nested, required) and top-level
      `headers` (`Backplane.McpProtocol.Transport.SSE` options schema).
  """
  alias Synapsis.MCPConfig

  @credential_encrypted_key "backplane_credential_encrypted"
  @credential_mode_key "backplane_credential_mode"
  @current_protocol_version "2025-06-18"
  @legacy_sse_protocol_version "2024-11-05"

  @spec build(MCPConfig.t()) :: tuple()
  def build(%MCPConfig{transport: "stdio"} = c) do
    {:stdio, command: c.command, args: c.args || [], env: c.env || %{}}
  end

  def build(%MCPConfig{transport: "streamable_http"} = c) do
    {base_url, mcp_path} = split_url(c.url)

    {:streamable_http, base_url: base_url, mcp_path: mcp_path, headers: resolved_headers(c)}
  end

  def build(%MCPConfig{transport: "sse"} = c) do
    {:sse, server: [base_url: c.url], headers: c.headers || %{}}
  end

  @spec protocol_version(MCPConfig.t()) :: String.t()
  def protocol_version(%MCPConfig{transport: "sse"}), do: @legacy_sse_protocol_version
  def protocol_version(%MCPConfig{}), do: @current_protocol_version

  # Split a configured endpoint URL into the host part (`base_url`) and the
  # request path (`mcp_path`). Backplane appends `mcp_path` (default `/mcp`) to
  # `base_url`, so passing the full URL as `base_url` would double the path.
  defp split_url(url) do
    uri = URI.parse(url)
    base = URI.to_string(%URI{scheme: uri.scheme, host: uri.host, port: uri.port})

    path =
      case uri.path do
        nil -> "/mcp"
        "" -> "/mcp"
        p -> p
      end

    {base, path}
  end

  defp resolved_headers(%MCPConfig{} = config) do
    Map.merge(config.headers || %{}, source_headers(config.config || %{}))
  end

  defp source_headers(%{"backplane_source_id" => source_id} = config) do
    with {:ok, %{enabled: true} = connection} <-
           Synapsis.Backplane.Connection.get(source_id),
         {:ok, credential} <- applied_credential(config, connection),
         true <- is_binary(credential) do
      %{"authorization" => "Bearer " <> credential}
    else
      _missing_or_keyless -> %{}
    end
  end

  defp source_headers(_config), do: %{}

  defp applied_credential(config, connection) do
    case Map.get(config, @credential_mode_key) do
      "keyless" ->
        {:ok, nil}

      "encrypted" ->
        unseal_applied_credential(config)

      nil ->
        if Map.has_key?(config, @credential_encrypted_key),
          do: unseal_applied_credential(config),
          else: {:ok, connection.credential}

      _invalid ->
        {:error, :invalid_backplane_credential_mode}
    end
  end

  defp unseal_applied_credential(config) do
    config
    |> Map.get(@credential_encrypted_key)
    |> Synapsis.Backplane.Connection.unseal_credential()
  end
end
