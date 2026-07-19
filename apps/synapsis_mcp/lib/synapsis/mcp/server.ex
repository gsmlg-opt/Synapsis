defmodule Synapsis.MCP.Server do
  @moduledoc """
  A GenServer that owns one `Backplane.McpProtocol.Client` for a configured MCP
  server.

  Responsibilities:

    * Start (and link to) a `Backplane.McpProtocol.Client` supervision tree
      built from a `Synapsis.MCPConfig` via `Synapsis.MCP.Transport.build/1`.
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
  underlying Backplane client is named with a unique atom derived from the
  config name so its API functions (`await_ready/1`, `list_tools/1`,
  `call_tool/4`) can address it.
  """

  use GenServer

  require Logger

  alias Backplane.McpProtocol.Client, as: MCPClient
  alias Backplane.McpProtocol.MCP.Response, as: ProtocolResponse
  alias Synapsis.MCP.Response
  alias Synapsis.MCP.Transport
  alias Synapsis.MCPConfig
  alias Synapsis.Tool.Registry

  @client_info %{"name" => "synapsis", "version" => "0.1.0"}
  @capabilities %{"roots" => %{}}
  @await_timeout 15_000
  @tool_timeout 30_000
  @registry_retry_ms 100

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
      # TODO(upstream): gsmlg-opt/backplane#19 validator cache keys collide across clients.
      client_info: @client_info,
      capabilities: @capabilities,
      protocol_version: Transport.protocol_version(config)
    ]

    case MCPClient.start_link(opts) do
      {:ok, supervisor} ->
        state = %{
          config: config,
          client: client_name,
          supervisor: supervisor,
          tool_registry_ref: monitor_tool_registry(),
          tools: [],
          tool_names: []
        }

        {:ok, state, {:continue, :discover}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:discover, %{client: client, config: config} = state) do
    with :ok <- MCPClient.await_ready(client, timeout: @await_timeout),
         {:ok, response} <- MCPClient.list_tools(client) do
      tools = Response.tools(ProtocolResponse.unwrap(response), config.name)

      case register_tools(tools) do
        {:ok, names} ->
          {:noreply, %{state | tools: tools, tool_names: names}}

        {:error, reason} ->
          {:stop, {:tool_registration_failed, reason}, state}
      end
    else
      {:error, reason} ->
        {:stop, {:discover_failed, reason}, state}
    end
  end

  @impl true
  def handle_call({:execute, full_tool_name, input, _ctx}, _from, %{client: client} = state) do
    raw = Response.raw_tool_name(full_tool_name)

    case MCPClient.call_tool(client, raw, input, timeout: @tool_timeout) do
      {:ok, response} ->
        {:reply, {:ok, Response.content(ProtocolResponse.unwrap(response))}, state}

      {:error, error} ->
        {:reply, {:error, inspect(error)}, state}
    end
  end

  @impl true
  def handle_info({:EXIT, supervisor, reason}, %{supervisor: supervisor} = state) do
    {:stop, {:client_exited, reason}, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{tool_registry_ref: ref} = state) do
    Process.send_after(self(), :reregister_tools, @registry_retry_ms)
    {:noreply, %{state | tool_registry_ref: nil, tool_names: []}}
  end

  def handle_info(:reregister_tools, %{tools: tools} = state) do
    with :ok <- tool_registry_ready(),
         {:ok, names} <- register_tools(tools),
         {:ok, ref} <- monitor_tool_registry_ready() do
      Logger.info("mcp_tools_reregistered", server: state.config.name, count: length(names))
      {:noreply, %{state | tool_registry_ref: ref, tool_names: names}}
    else
      {:error, _reason} ->
        Process.send_after(self(), :reregister_tools, @registry_retry_ms)
        {:noreply, state}
    end
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

  defp register_tools(tools) do
    {:ok, Enum.map(tools, &register_tool/1)}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp register_tool(%{name: name, description: description, parameters: parameters}) do
    Registry.register_process(name, self(),
      description: description,
      parameters: parameters,
      timeout: @tool_timeout,
      plugin: :mcp
    )

    name
  end

  defp monitor_tool_registry do
    case Process.whereis(Registry) do
      nil -> nil
      pid -> Process.monitor(pid)
    end
  end

  defp tool_registry_ready do
    if Process.whereis(Registry), do: :ok, else: {:error, :registry_not_started}
  end

  defp monitor_tool_registry_ready do
    case Process.whereis(Registry) do
      nil -> {:error, :registry_not_started}
      pid -> {:ok, Process.monitor(pid)}
    end
  end

  defp client_name(%MCPConfig{name: name}) do
    Module.concat(__MODULE__, "Client_#{name}_#{System.unique_integer([:positive])}")
  end
end
