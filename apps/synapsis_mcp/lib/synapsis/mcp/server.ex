defmodule Synapsis.MCP.Server do
  @moduledoc """
  A GenServer that owns one `Anubis.Client` for a configured MCP server.

  Responsibilities:

    * Start (and link to) an `Anubis.Client` supervision tree built from a
      `Synapsis.MCPConfig` via `Synapsis.MCP.Transport.build/1`.
    * Discover the server's tools and register each into
      `Synapsis.Tool.Registry` as a process-dispatch tool pointing at this
      GenServer.
    * Route `{:execute, tool_name, input, ctx}` calls to the client.
    * Unregister all tools on terminate (the registry also auto-purges when the
      owner pid dies, but we unregister eagerly for promptness).

  ## Process naming

  `start_link/1` starts this GenServer *unnamed* and returns `{:ok, pid}`. The
  caller (and, in Task 9, the `Synapsis.MCP.DynamicSupervisor` /
  `Synapsis.MCP.Registry`) is responsible for any name registration. The
  underlying `Anubis.Client` is named with a unique atom derived from the
  config name so its API functions (`await_ready/1`, `list_tools/1`,
  `call_tool/4`) can address it.
  """

  use GenServer

  require Logger

  alias Synapsis.MCP.Response
  alias Synapsis.MCP.Transport
  alias Synapsis.MCPConfig
  alias Synapsis.Tool.Registry

  @client_info %{"name" => "synapsis", "version" => "0.1.0"}
  @capabilities %{"roots" => %{}}
  @protocol_version "2025-06-18"
  @await_timeout 15_000
  @tool_timeout 30_000

  # --------------------------------------------------------------------------
  # Public API
  # --------------------------------------------------------------------------

  @spec start_link(MCPConfig.t()) :: GenServer.on_start()
  def start_link(%MCPConfig{} = config) do
    GenServer.start_link(__MODULE__, config, name: via(config.name))
  end

  defp via(name), do: {:via, Elixir.Registry, {Synapsis.MCP.Registry, name}}

  # --------------------------------------------------------------------------
  # Callbacks
  # --------------------------------------------------------------------------

  @impl true
  def init(%MCPConfig{} = config) do
    Process.flag(:trap_exit, true)

    client_name = client_name(config)

    opts = [
      name: client_name,
      transport: Transport.build(config),
      client_info: @client_info,
      capabilities: @capabilities,
      protocol_version: @protocol_version
    ]

    case Anubis.Client.start_link(opts) do
      {:ok, supervisor} ->
        state = %{
          config: config,
          client: client_name,
          supervisor: supervisor,
          tool_names: []
        }

        {:ok, state, {:continue, :discover}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:discover, %{client: client, config: config} = state) do
    with :ok <- Anubis.Client.await_ready(client, timeout: @await_timeout),
         {:ok, response} <- Anubis.Client.list_tools(client) do
      tools = Response.tools(Anubis.MCP.Response.unwrap(response), config.name)
      names = Enum.map(tools, &register_tool/1)
      {:noreply, %{state | tool_names: names}}
    else
      {:error, reason} ->
        {:stop, {:discover_failed, reason}, state}
    end
  end

  @impl true
  def handle_call({:execute, full_tool_name, input, _ctx}, _from, %{client: client} = state) do
    raw = Response.raw_tool_name(full_tool_name)

    case Anubis.Client.call_tool(client, raw, input, timeout: @tool_timeout) do
      {:ok, response} ->
        {:reply, {:ok, Response.content(Anubis.MCP.Response.unwrap(response))}, state}

      {:error, error} ->
        {:reply, {:error, inspect(error)}, state}
    end
  end

  @impl true
  def handle_info({:EXIT, supervisor, reason}, %{supervisor: supervisor} = state) do
    {:stop, {:client_exited, reason}, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{tool_names: names}) do
    Enum.each(names, &Registry.unregister/1)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp register_tool(%{name: name, description: description, parameters: parameters}) do
    Registry.register_process(name, self(),
      description: description,
      parameters: parameters,
      timeout: @tool_timeout,
      plugin: :mcp
    )

    name
  end

  defp client_name(%MCPConfig{name: name}) do
    Module.concat(__MODULE__, "Client_#{name}_#{System.unique_integer([:positive])}")
  end
end
