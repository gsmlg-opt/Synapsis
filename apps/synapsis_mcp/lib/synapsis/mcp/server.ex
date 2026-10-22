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

  `start_link/1` registers the GenServer by config name. Persisted configs also
  register a config-id key so renames cannot create duplicate runtimes. The
  underlying Backplane client is named with a unique atom derived from the config
  name so its API functions (`await_ready/1`, `list_tools/1`, `call_tool/4`) can
  address it.
  """

  use GenServer

  require Logger

  alias Backplane.McpProtocol.Client, as: MCPClient
  alias Backplane.McpProtocol.MCP.Error, as: ProtocolError
  alias Backplane.McpProtocol.MCP.Response, as: ProtocolResponse
  alias Synapsis.MCP.Response
  alias Synapsis.MCP.Transport
  alias Synapsis.MCPConfig
  alias Synapsis.MCPConfigs
  alias Synapsis.Tool.Registry

  @client_info %{"name" => "synapsis", "version" => "0.1.0"}
  @capabilities %{"roots" => %{}}
  @await_timeout 15_000
  @discovery_timeout 30_000
  @ready_timeout @await_timeout + @discovery_timeout + 2_000
  @tool_timeout 30_000
  @runtime_lookup_timeout 1_000
  @cancellation_timeout 1_000
  @registry_retry_ms 100

  # --------------------------------------------------------------------------
  # Public API
  # --------------------------------------------------------------------------

  @spec start_link(MCPConfig.t()) :: GenServer.on_start()
  def start_link(%MCPConfig{} = config) do
    start(config, :runtime)
  end

  @doc false
  @spec start_reconciliation_link(MCPConfig.t()) :: GenServer.on_start()
  def start_reconciliation_link(%MCPConfig{} = config) do
    start(config, :reconciliation)
  end

  @doc "Wait until initial discovery and tool registration have completed."
  @spec await_ready(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def await_ready(server, timeout \\ @ready_timeout)
      when is_integer(timeout) and timeout > 0 do
    GenServer.call(server, :await_ready, timeout)
  catch
    :exit, reason -> {:error, ready_failure(reason)}
  end

  @doc "Fetch a complete live tool catalog, coalescing concurrent callers."
  def refresh(server, timeout \\ @ready_timeout) do
    GenServer.call(server, :refresh, timeout)
  catch
    :exit, reason -> {:error, ready_failure(reason)}
  end

  @doc "Executes a native runtime tool call owned by the calling effect process."
  @spec execute_runtime(GenServer.server(), String.t(), map(), map(), pos_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def execute_runtime(server, tool_name, input, _context, timeout)
      when is_integer(timeout) and timeout > 0 do
    with {:ok, client, raw_name} <-
           GenServer.call(
             server,
             {:runtime_tool, tool_name},
             min(timeout, @runtime_lookup_timeout)
           ),
         {:ok, handle} <-
           MCPClient.start_tool_call(client, raw_name, input,
             registration_timeout: min(timeout, @runtime_lookup_timeout),
             # Keep the handle live until its owner can cancel on await timeout.
             timeout: timeout + @cancellation_timeout
           ) do
      case MCPClient.await_tool_call(handle, timeout) do
        {:error, %ProtocolError{reason: :request_timeout}} ->
          MCPClient.cancel_tool_call(handle, "tool_timeout",
            notification_timeout: @cancellation_timeout
          )

          {:error, :timeout}

        result ->
          runtime_result(result)
      end
    else
      result -> runtime_result(result)
    end
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :mcp_unavailable}
  end

  defp via(name), do: {:via, Elixir.Registry, {Synapsis.MCP.Registry, name}}

  # --------------------------------------------------------------------------
  # Callbacks
  # --------------------------------------------------------------------------

  @impl true
  def init({%MCPConfig{} = config, initial_availability}) do
    Process.flag(:trap_exit, true)

    case initial_transport(config) do
      {:ok, connection} ->
        client_name = client_name(config)

        opts = [
          name: client_name,
          transport: elem(connection, 0),
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
              initial_availability: initial_availability,
              tool_registry_ref: monitor_tool_registry(),
              tools: [],
              tool_names: [],
              catalog_valid: :atomics.new(1, []),
              refresh_task: nil,
              refresh_waiters: [],
              ready_waiters: [],
              discovery_result: nil,
              transport: connection
            }

            {:ok, state, {:continue, :discover}}

          {:error, reason} ->
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:discover, state), do: {:noreply, begin_refresh(state)}

  @impl true
  def handle_call(:await_ready, from, %{discovery_result: nil} = state),
    do: {:noreply, %{state | ready_waiters: [from | state.ready_waiters]}}

  def handle_call(:await_ready, _from, state),
    do: {:reply, ready_result(state.discovery_result), state}

  def handle_call(:refresh, from, state) do
    state = %{state | refresh_waiters: [from | state.refresh_waiters]}
    {:noreply, if(state.refresh_task, do: state, else: begin_refresh(state))}
  end

  def handle_call({:runtime_tool, full_tool_name}, _from, state) do
    case discovered_tool(state.tools, full_tool_name) do
      %{trust_annotations: trust_annotations} ->
        if :atomics.get(state.catalog_valid, 1) == 1 and
             current_transport(state.config) == state.transport and
             current_runtime_available?(state.config, full_tool_name, trust_annotations) do
          {:reply, {:ok, state.client, Response.raw_tool_name(full_tool_name)}, state}
        else
          {:reply, {:error, :mcp_unavailable}, state}
        end

      nil ->
        {:reply, {:error, :mcp_unavailable}, state}
    end
  end

  def handle_call({:execute, full_tool_name, input, _ctx}, _from, state) do
    case discovered_tool(state.tools, full_tool_name) do
      %{trust_annotations: trust_annotations} ->
        if :atomics.get(state.catalog_valid, 1) == 1 and
             current_transport(state.config) == state.transport and
             current_runtime_available?(state.config, full_tool_name, trust_annotations) do
          execute_tool(state.client, full_tool_name, input, state)
        else
          {:reply, {:error, :mcp_unavailable}, state}
        end

      nil ->
        {:reply, {:error, :mcp_unavailable}, state}
    end
  end

  defp execute_tool(client, full_tool_name, input, state) do
    raw = Response.raw_tool_name(full_tool_name)

    case MCPClient.call_tool(client, raw, input, timeout: @tool_timeout) do
      {:ok, response} ->
        {:reply, {:ok, Response.content(ProtocolResponse.unwrap(response))}, state}

      {:error, error} ->
        {:reply, {:error, inspect(error)}, state}
    end
  end

  defp runtime_result({:ok, response}),
    do: {:ok, Response.content(ProtocolResponse.unwrap(response))}

  defp runtime_result({:error, %ProtocolError{reason: reason}})
       when reason in [:request_timeout, :registration_timeout],
       do: {:error, :timeout}

  defp runtime_result({:error, %ProtocolError{reason: reason}}),
    do: {:error, {:mcp_error, reason}}

  defp runtime_result({:error, reason}), do: {:error, reason}

  @impl true
  def handle_info({ref, result}, %{refresh_task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_refresh(state, result)}
  end

  def handle_info({:refresh_timeout, ref}, %{refresh_task: %{ref: ref} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    {:noreply, finish_refresh(state, {:error, :mcp_refresh_timeout})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{refresh_task: %{ref: ref}} = state) do
    {:noreply, finish_refresh(state, {:error, {:mcp_refresh_failed, reason}})}
  end

  def handle_info({:EXIT, supervisor, reason}, %{supervisor: supervisor} = state) do
    # The client tree already exhausted its own retries; require an explicit reconnect.
    {:stop, {:shutdown, {:client_exited, reason}}, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{tool_registry_ref: ref} = state) do
    Process.send_after(self(), :reregister_tools, @registry_retry_ms)
    {:noreply, %{state | tool_registry_ref: nil, tool_names: []}}
  end

  def handle_info(:reregister_tools, %{tools: tools} = state) do
    with true <- current_transport(state.config) == state.transport,
         true <- :atomics.get(state.catalog_valid, 1) == 1,
         :ok <- tool_registry_ready(),
         {:ok, names} <- register_tools(tools),
         {:ok, ref} <- monitor_tool_registry_ready() do
      Logger.info("mcp_tools_reregistered", server: state.config.name, count: length(names))
      {:noreply, %{state | tool_registry_ref: ref, tool_names: names}}
    else
      false ->
        {:noreply, state}

      {:error, _reason} ->
        Process.send_after(self(), :reregister_tools, @registry_retry_ms)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{tool_names: names} = state) do
    if task = Map.get(state, :refresh_task), do: Task.shutdown(task, :brutal_kill)
    Enum.each(names, &Registry.unregister(&1, self()))
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp start(config, initial_availability) do
    GenServer.start_link(__MODULE__, {config, initial_availability}, name: via(config.name))
  end

  defp register_tools(tools) do
    {:ok, Enum.map(tools, &register_tool/1)}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp ready_result(:ok), do: :ok
  defp ready_result({:error, reason}), do: {:error, {:discover_failed, reason}}

  defp ready_failure({:timeout, {GenServer, :call, _details}}), do: :mcp_ready_timeout
  defp ready_failure({:noproc, {GenServer, :call, _details}}), do: :mcp_not_running
  defp ready_failure({reason, {GenServer, :call, _details}}), do: reason
  defp ready_failure(reason), do: reason

  defp register_tool(%{
         name: name,
         description: description,
         parameters: parameters,
         annotations: annotations,
         trust_annotations: trust_annotations,
         availability_check: availability_check,
         permission_level: permission_level,
         mcp_config_id: config_id,
         mcp_tool_name: raw_name
       }) do
    Registry.register_process(name, self(),
      description: description,
      parameters: parameters,
      timeout: @tool_timeout,
      runtime_dispatch: __MODULE__,
      plugin: :mcp,
      mcp_config_id: config_id,
      mcp_tool_name: raw_name,
      category: :mcp,
      permission_level: permission_level,
      trust_annotations: trust_annotations,
      availability_check: availability_check,
      annotations: annotations
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

  defp current_runtime_available?(
         %MCPConfig{id: nil} = config,
         _full_tool_name,
         trust_annotations
       ) do
    MCPConfigs.runtime_available?(config) and
      annotation_trust_available?(config, trust_annotations)
  end

  defp current_runtime_available?(%MCPConfig{id: id}, _full_tool_name, trust_annotations) do
    case MCPConfigs.get(id) do
      nil ->
        false

      config ->
        MCPConfigs.runtime_available?(config) and
          annotation_trust_available?(config, trust_annotations)
    end
  end

  defp runtime_available_tools(tools, config, initial_availability) do
    available? =
      case initial_availability do
        :runtime -> MCPConfigs.runtime_available?(config)
        :reconciliation -> MCPConfigs.reconciliation_available?(config)
      end

    if available? do
      tools
    else
      []
    end
  end

  defp attach_availability_checks(tools, config, valid, transport) do
    Enum.map(tools, fn tool ->
      tool
      |> Map.put(:mcp_config_id, config.id)
      |> Map.put(:mcp_tool_name, Response.raw_tool_name(tool.name))
      |> Map.put(:availability_check, fn ->
        :atomics.get(valid, 1) == 1 and
          current_runtime_available?(config, tool.name, tool.trust_annotations) and
          current_transport(config) == transport
      end)
    end)
  end

  defp current_transport(%MCPConfig{id: nil} = config), do: connection_transport(config)

  defp current_transport(%MCPConfig{id: id}) do
    case MCPConfigs.get(id) do
      nil -> nil
      current -> connection_transport(current)
    end
  end

  defp connection_transport(config) do
    generation =
      case config.provider_id do
        nil ->
          nil

        id ->
          case Synapsis.Providers.get(id) do
            {:ok, provider} -> Synapsis.Providers.authentication_generation(provider)
            _ -> :provider_unavailable
          end
      end

    {Transport.build(config), generation}
  end

  defp begin_refresh(state) do
    client = state.client
    config = state.config
    transport = state.transport

    task =
      Task.Supervisor.async_nolink(Synapsis.MCP.TaskSupervisor, fn ->
        if current_transport(config) == transport do
          with :ok <- MCPClient.await_ready(client, timeout: @await_timeout),
               {:ok, tools} <- discover_pages(client, nil, MapSet.new(), [], 0) do
            {:ok, tools}
          end
        else
          {:error, :connection_changed}
        end
      end)

    Process.send_after(self(), {:refresh_timeout, task.ref}, @await_timeout + @discovery_timeout)
    %{state | refresh_task: task}
  end

  defp discover_pages(_client, _cursor, _seen, _tools, 100), do: {:error, :mcp_page_limit}

  defp discover_pages(client, cursor, seen, tools, count) do
    opts =
      if cursor,
        do: [cursor: cursor, timeout: @discovery_timeout],
        else: [timeout: @discovery_timeout]

    with {:ok, response} <- MCPClient.list_tools(client, opts),
         %{"tools" => page} = result when is_list(page) <- ProtocolResponse.unwrap(response) do
      case result["nextCursor"] do
        nil ->
          {:ok, Enum.reverse([page | tools]) |> List.flatten()}

        next when is_binary(next) and next != "" and byte_size(next) <= 4_096 ->
          if MapSet.member?(seen, next),
            do: {:error, :mcp_cursor_cycle},
            else: discover_pages(client, next, MapSet.put(seen, next), [page | tools], count + 1)

        _ ->
          {:error, :invalid_mcp_cursor}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_tools_response}
    end
  end

  defp finish_refresh(state, result) do
    result =
      Synapsis.Config.Store.with_write_lock(fn ->
        if current_transport(state.config) == state.transport do
          register_refresh_result(state, result)
        else
          {:error, :connection_changed}
        end
      end)

    {reply, state} =
      case result do
        {:ok, tools, names} ->
          :atomics.put(state.catalog_valid, 1, 1)
          {:ok, %{state | tools: tools, tool_names: names}}

        {:error, reason} ->
          :atomics.put(state.catalog_valid, 1, 0)
          Enum.each(state.tool_names, &Registry.unregister(&1, self()))
          {{:error, reason}, %{state | tools: [], tool_names: []}}
      end

    Enum.each(state.refresh_waiters, &GenServer.reply(&1, reply))
    Enum.each(state.ready_waiters, &GenServer.reply(&1, ready_result(reply)))
    %{state | refresh_task: nil, refresh_waiters: [], ready_waiters: [], discovery_result: reply}
  end

  defp register_refresh_result(state, result) do
    case result do
      {:ok, raw_tools} ->
        tools =
          %{"tools" => raw_tools}
          |> Response.tools(state.config.name,
            trust_annotations: MCPConfigs.trust_tool_annotations?(state.config)
          )
          |> runtime_available_tools(state.config, state.initial_availability)
          |> attach_availability_checks(state.config, state.catalog_valid, state.transport)

        Enum.each(state.tool_names, &Registry.unregister(&1, self()))

        case register_tools(tools) do
          {:ok, names} -> {:ok, tools, names}
          {:error, reason} -> {:error, reason}
        end

      other ->
        other
    end
  end

  defp annotation_trust_available?(config, true),
    do: MCPConfigs.trust_tool_annotations?(config)

  defp annotation_trust_available?(_config, false), do: true

  defp discovered_tool(tools, full_tool_name),
    do: Enum.find(tools, &(&1.name == full_tool_name))

  defp initial_transport(config) do
    Synapsis.Config.Store.with_write_lock(fn ->
      with :ok <- register_available_config(config), do: {:ok, connection_transport(config)}
    end)
  end

  defp register_available_config(%MCPConfig{provider_id: nil} = config),
    do: register_config_id(config)

  defp register_available_config(config) do
    with {:ok, _} <- Synapsis.Backplane.ProviderSource.get(config.provider_id),
         do: register_config_id(config)
  end

  defp register_config_id(%MCPConfig{id: nil}), do: :ok

  defp register_config_id(%MCPConfig{id: id}) do
    case Elixir.Registry.register(Synapsis.MCP.Registry, {:config_id, id}, nil) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, pid}} -> {:error, {:already_started, pid}}
    end
  end

  defp client_name(%MCPConfig{name: name}) do
    Module.concat(__MODULE__, "Client_#{name}_#{System.unique_integer([:positive])}")
  end
end
