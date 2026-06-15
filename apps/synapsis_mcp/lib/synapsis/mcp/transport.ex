defmodule Synapsis.MCP.Transport do
  @moduledoc """
  Maps a `Synapsis.MCPConfig` to an `Anubis.Client` transport tuple.

  Single source of truth for transport option names; if anubis_mcp changes a
  key, change it here only.

  Option keys verified against `anubis_mcp` 1.6.2:

    * `:stdio` — `command` (required), `args`, `env`
      (`Anubis.Transport.STDIO` options schema).
    * `:streamable_http` — `base_url` (required), `headers`
      (`Anubis.Transport.StreamableHTTP` options schema). Note: the URL key is
      `base_url`, not `url`.
    * `:sse` — `server: [base_url: ...]` (nested, required) and top-level
      `headers` (`Anubis.Transport.SSE` options schema).
  """
  alias Synapsis.MCPConfig

  @spec build(MCPConfig.t()) :: tuple()
  def build(%MCPConfig{transport: "stdio"} = c) do
    {:stdio, command: c.command, args: c.args || [], env: c.env || %{}}
  end

  def build(%MCPConfig{transport: "streamable_http"} = c) do
    {:streamable_http, base_url: c.url, headers: c.headers || %{}}
  end

  def build(%MCPConfig{transport: "sse"} = c) do
    {:sse, server: [base_url: c.url], headers: c.headers || %{}}
  end
end
