defmodule Synapsis.MCP.Transport do
  @moduledoc """
  Maps a `Synapsis.MCPConfig` to an `Anubis.Client` transport tuple.

  Single source of truth for transport option names; if anubis_mcp changes a
  key, change it here only.

  Option keys verified against `anubis_mcp` 1.6.2:

    * `:stdio` — `command` (required), `args`, `env`
      (`Anubis.Transport.STDIO` options schema).
    * `:streamable_http` — `base_url` (required), `mcp_path`, `headers`
      (`Anubis.Transport.StreamableHTTP` options schema). Anubis requests
      `URI.append_path(base_url, mcp_path)` (mcp_path default `/mcp`), so the
      configured `url` is split into host (`base_url`) + path (`mcp_path`) to
      avoid a doubled `/mcp` path.
    * `:sse` — `server: [base_url: ...]` (nested, required) and top-level
      `headers` (`Anubis.Transport.SSE` options schema).
  """
  alias Synapsis.MCPConfig

  @spec build(MCPConfig.t()) :: tuple()
  def build(%MCPConfig{transport: "stdio"} = c) do
    {:stdio, command: c.command, args: c.args || [], env: c.env || %{}}
  end

  def build(%MCPConfig{transport: "streamable_http"} = c) do
    {base_url, mcp_path} = split_url(c.url)
    {:streamable_http, base_url: base_url, mcp_path: mcp_path, headers: c.headers || %{}}
  end

  def build(%MCPConfig{transport: "sse"} = c) do
    {:sse, server: [base_url: c.url], headers: c.headers || %{}}
  end

  # Split a configured endpoint URL into the host part (`base_url`) and the
  # request path (`mcp_path`). Anubis appends `mcp_path` (default `/mcp`) to
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
end
