defmodule Synapsis.MCP.Server do
  @moduledoc """
  A GenServer that owns one `Backplane.McpProtocol.Client` for a configured MCP
  server.

  Responsibilities:

    * Start (and link to) a `Backplane.McpProtocol.Client` supervision tree
      built from a `Synapsis.MCPConfig` via `Synapsis.MCP.Transport.build/1`.
    * Discover and retain source-owned tool metadata for native snapshots and UI.
    * Dispatch native calls through caller-owned Backplane request handles.
    * Invalidate source catalogs on refresh, failure, and termination.

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

  @client_info %{"name" => "synapsis", "version" => "0.1.0"}
  @capabilities %{"roots" => %{}}
  @await_timeout 15_000
  @discovery_timeout 30_000
  @ready_timeout @await_timeout + @discovery_timeout + 2_000
  @runtime_lookup_timeout 1_000
  @cancellation_timeout 1_000

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

  @doc "Wait until initial source discovery has completed."
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

  @doc "Capture a credential-free native source catalog, bound to this server incarnation."
  def runtime_snapshot(server) do
    GenServer.call(server, :runtime_snapshot, @runtime_lookup_timeout)
  catch
    :exit, _reason -> {:error, :mcp_unavailable}
  end

  @doc "Call an exact tool from an unchanged source snapshot, retaining the raw MCP result."
  def runtime_call(%{server_pid: server} = snapshot, raw_name, input, timeout)
      when is_pid(server) and is_binary(raw_name) and is_map(input) and
             is_integer(timeout) and timeout > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout

    with {:ok, ticket} <- lookup_source_tool(server, snapshot, raw_name, timeout),
         {:ok, handle} <- register_source_call(ticket, raw_name, input, deadline) do
      case MCPClient.await_tool_call(handle, remaining(deadline)) do
        {:error, %ProtocolError{reason: :request_timeout}} ->
          MCPClient.cancel_tool_call(handle, "tool_timeout",
            notification_timeout: @cancellation_timeout
          )

          {:error, :timeout}

        result ->
          raw_runtime_result(result)
      end
    else
      {:error, %ProtocolError{reason: reason}} -> {:rejected, {:mcp_error, reason}}
      other -> other
    end
  end

  def runtime_call(_, _, _, _), do: {:rejected, :invalid_input}

  @doc "List one resource page from an exact source snapshot, retaining the raw result."
  def runtime_list_resources(snapshot, params, timeout),
    do: runtime_resource_request(snapshot, :list, params, timeout)

  @doc "List one resource-template page from an exact source snapshot."
  def runtime_list_resource_templates(snapshot, params, timeout),
    do: runtime_resource_request(snapshot, :templates, params, timeout)

  @doc "Read a resource URI from an exact source snapshot, retaining ordered contents."
  def runtime_read_resource(snapshot, params, timeout),
    do: runtime_resource_request(snapshot, :read, params, timeout)

  @doc """
  Start a caller-owned resource request for a native resource scope.

  Returns the public Backplane handle without awaiting it. The scope's finite
  request and registration budgets include lookup and source-lock acquisition;
  its absolute retirement deadline is forwarded unchanged.
  """
  def runtime_start_resource_request(
        %{server_pid: server} = snapshot,
        operation,
        params,
        reserved_options
      )
      when is_pid(server) and operation in [:list, :templates, :read] and is_map(params) and
             not is_struct(params) and is_list(reserved_options) do
    with true <- resource_params_valid?(operation, params),
         true <- native_resource_options_valid?(reserved_options) do
      now = System.monotonic_time(:millisecond)

      deadline =
        min(
          reserved_options[:retirement_deadline],
          now + reserved_options[:timeout]
        )

      registration_deadline = min(deadline, now + reserved_options[:registration_timeout])

      with true <- remaining(registration_deadline) > 0,
           {:ok, ticket} <-
             lookup_source_resource(server, snapshot, remaining(registration_deadline)) do
        register_source_request(
          ticket,
          deadline,
          fn client, options -> start_resource_request(client, operation, params, options) end,
          {reserved_options, registration_deadline}
        )
      else
        false -> {:rejected, :timeout}
        other -> other
      end
    else
      false -> {:rejected, :invalid_input}
    end
  end

  def runtime_start_resource_request(_, _, _, _), do: {:rejected, :invalid_input}

  defp native_resource_options_valid?(options) do
    Keyword.keyword?(options) and options[:track_retirement] == true and
      is_integer(options[:timeout]) and options[:timeout] > 0 and
      is_integer(options[:registration_timeout]) and options[:registration_timeout] > 0 and
      is_integer(options[:retirement_deadline])
  end

  defp runtime_resource_request(%{server_pid: server} = snapshot, operation, params, timeout)
       when is_pid(server) and is_map(params) and not is_struct(params) and
              is_integer(timeout) and timeout > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout

    with true <- resource_params_valid?(operation, params),
         {:ok, ticket} <- lookup_source_resource(server, snapshot, timeout),
         {:ok, handle} <-
           register_source_request(ticket, deadline, fn client, options ->
             start_resource_request(client, operation, params, options)
           end) do
      case MCPClient.await_resource_request(handle, remaining(deadline)) do
        {:error, %ProtocolError{reason: :request_timeout}} ->
          MCPClient.cancel_resource_request(handle, "resource_timeout",
            notification_timeout: @cancellation_timeout
          )

          {:error, :timeout}

        result ->
          raw_runtime_result(result)
      end
    else
      false -> {:rejected, :invalid_input}
      {:error, %ProtocolError{reason: reason}} -> {:rejected, {:mcp_error, reason}}
      other -> other
    end
  end

  defp runtime_resource_request(_, _, _, _), do: {:rejected, :invalid_input}

  defp resource_params_valid?(operation, params) do
    meta = Map.get(params, "_meta", %{})

    is_map(meta) and not is_struct(meta) and
      case operation do
        :read ->
          Map.keys(params) -- ~w(uri _meta) == [] and is_binary(params["uri"]) and
            params["uri"] != ""

        operation when operation in [:list, :templates] ->
          Map.keys(params) -- ~w(cursor _meta) == [] and
            (not Map.has_key?(params, "cursor") or is_binary(params["cursor"]))
      end
  end

  defp start_resource_request(client, operation, params, options) do
    options = Keyword.put(options, :meta, Map.get(params, "_meta", %{}))

    case operation do
      :list ->
        MCPClient.start_list_resources(client, Keyword.put(options, :cursor, params["cursor"]))

      :templates ->
        MCPClient.start_list_resource_templates(
          client,
          Keyword.put(options, :cursor, params["cursor"])
        )

      :read ->
        MCPClient.start_read_resource(client, params["uri"], options)
    end
  end

  defp lookup_source_resource(server, snapshot, timeout) do
    GenServer.call(
      server,
      {:runtime_source_resource, snapshot},
      min(timeout, @runtime_lookup_timeout)
    )
  catch
    :exit, {:timeout, _call} -> {:rejected, :timeout}
    :exit, _reason -> {:rejected, :stale_snapshot}
  end

  defp lookup_source_tool(server, snapshot, raw_name, timeout) do
    GenServer.call(
      server,
      {:runtime_source_tool, snapshot, raw_name},
      min(timeout, @runtime_lookup_timeout)
    )
  catch
    :exit, {:timeout, _call} -> {:rejected, :timeout}
    :exit, _reason -> {:rejected, :stale_snapshot}
  end

  defp register_source_call(ticket, raw_name, input, deadline) do
    register_source_request(ticket, deadline, fn client, options ->
      MCPClient.start_tool_call(client, raw_name, input, options)
    end)
  end

  defp register_source_request(ticket, deadline, start_request, native_options \\ nil) do
    # Refresh publication and persisted source changes use this same lock.
    # Do not call Server while holding it: a refresh may be waiting on it.
    # Registration still runs in the effect caller, retaining handle ownership.
    registration_deadline =
      case native_options do
        nil -> deadline
        {_options, registration_deadline} -> registration_deadline
      end

    result =
      Synapsis.Config.Store.with_write_lock(
        fn ->
          cond do
            not Process.alive?(ticket.server) or not is_pid(ticket.client) or
              not Process.alive?(ticket.client) or :atomics.get(ticket.valid, 1) != 1 or
              :atomics.get(ticket.valid, 2) != ticket.generation or
              current_transport(ticket.config) != ticket.transport or
                not current_runtime_available?(ticket.config, nil, ticket.trust_annotations) ->
              {:rejected, :stale_snapshot}

            remaining(registration_deadline) == 0 ->
              {:rejected, :timeout}

            true ->
              remaining = remaining(deadline)

              options =
                if is_nil(native_options) do
                  [
                    registration_timeout: min(remaining, @runtime_lookup_timeout),
                    timeout: remaining + @cancellation_timeout
                  ]
                else
                  {reserved_options, _registration_deadline} = native_options

                  reserved_options
                  |> Keyword.put(
                    :timeout,
                    min(min(reserved_options[:timeout], 30_000), remaining)
                  )
                  |> Keyword.put(
                    :registration_timeout,
                    min(5_000, remaining(registration_deadline))
                  )
                end

              start_request.(ticket.client, options)
          end
        end,
        deadline: registration_deadline
      )

    case result do
      {:error, :config_write_lock_unavailable} -> {:rejected, :timeout}
      other -> other
    end
  end

  @doc "Read display metadata without native call handles or legacy registrations."
  def catalog(server) do
    GenServer.call(server, :catalog, @runtime_lookup_timeout)
  catch
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
              tools: [],
              catalog_valid: :atomics.new(2, []),
              catalog_generation: 0,
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

  def handle_call(:runtime_snapshot, _from, state),
    do: {:reply, source_snapshot(state), state}

  def handle_call({:runtime_source_tool, snapshot, raw_name}, _from, state) do
    result =
      case source_snapshot(state) do
        {:ok, ^snapshot} ->
          case Enum.find(state.tools, &(&1.mcp_tool_name == raw_name)) do
            nil ->
              {:rejected, :tool_unavailable}

            tool ->
              {:ok, source_ticket(state, tool.trust_annotations)}
          end

        _ ->
          {:rejected, :stale_snapshot}
      end

    {:reply, result, state}
  end

  def handle_call({:runtime_source_resource, snapshot}, _from, state) do
    result =
      case source_snapshot(state) do
        {:ok, ^snapshot} -> {:ok, source_ticket(state, false)}
        _ -> {:rejected, :stale_snapshot}
      end

    {:reply, result, state}
  end

  def handle_call(:catalog, _from, state) do
    result =
      if catalog_available?(state) do
        {:ok,
         Enum.map(state.tools, fn tool ->
           Map.take(tool, [
             :name,
             :description,
             :parameters,
             :annotations,
             :permission_level,
             :mcp_config_id,
             :mcp_tool_name
           ])
         end)}
      else
        {:error, :mcp_unavailable}
      end

    {:reply, result, state}
  end

  # Old callers must not crash the source process or enter the native path.
  def handle_call({:runtime_tool, _name}, _from, state),
    do: {:reply, {:error, :legacy_mcp_execution_retired}, state}

  def handle_call({:execute, _name, _input, _context}, _from, state),
    do: {:reply, {:error, :legacy_mcp_execution_retired}, state}

  defp runtime_result({:error, %ProtocolError{reason: reason}})
       when reason in [:request_timeout, :registration_timeout],
       do: {:error, :timeout}

  defp runtime_result({:error, %ProtocolError{reason: reason}}),
    do: {:error, {:mcp_error, reason}}

  defp runtime_result({:error, reason}), do: {:error, reason}

  defp raw_runtime_result({:ok, response}) do
    case ProtocolResponse.unwrap(response) do
      result when is_map(result) -> {:ok, result}
      _ -> {:error, :invalid_mcp_result}
    end
  end

  defp raw_runtime_result(error), do: runtime_result(error)

  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  defp source_ticket(state, trust_annotations) do
    %{
      server: self(),
      client: GenServer.whereis(state.client),
      config: state.config,
      transport: state.transport,
      valid: state.catalog_valid,
      generation: state.catalog_generation,
      trust_annotations: trust_annotations
    }
  end

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

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{catalog_valid: _valid} = state) do
    :atomics.put(state.catalog_valid, 1, 0)
    if task = Map.get(state, :refresh_task), do: Task.shutdown(task, :brutal_kill)
    notify_catalog_changed(state, :stopped)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp start(config, initial_availability) do
    GenServer.start_link(__MODULE__, {config, initial_availability}, name: via(config.name))
  end

  defp ready_result(:ok), do: :ok
  defp ready_result({:error, reason}), do: {:error, {:discover_failed, reason}}

  defp ready_failure({:timeout, {GenServer, :call, _details}}), do: :mcp_ready_timeout
  defp ready_failure({:noproc, {GenServer, :call, _details}}), do: :mcp_not_running
  defp ready_failure({reason, {GenServer, :call, _details}}), do: reason
  defp ready_failure(reason), do: reason

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

  defp attach_source_identity(tools, config) do
    Enum.map(tools, fn tool ->
      tool
      |> Map.put(:mcp_config_id, config.id)
      |> Map.put(:mcp_tool_name, Response.raw_tool_name(tool.name))
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
               {:ok, tools, metadata} <- discover_source_tools(client, config.name) do
            {:ok, tools, metadata}
          end
        else
          {:error, :connection_changed}
        end
      end)

    Process.send_after(self(), {:refresh_timeout, task.ref}, @await_timeout + @discovery_timeout)
    %{state | refresh_task: task}
  end

  defp discover_source_tools(client, server_name) do
    case MCPClient.get_protocol_info(client, timeout: @runtime_lookup_timeout) do
      %{negotiation_status: :ready, server_capabilities: capabilities} = info
      when is_map(capabilities) ->
        result =
          if Map.has_key?(capabilities, "resources") and not Map.has_key?(capabilities, "tools"),
            do: {:ok, []},
            else: discover_pages(client, nil, MapSet.new(), [], 0)

        with {:ok, tools} <- result do
          {:ok, tools, source_metadata(info, server_name)}
        end

      _ ->
        {:error, :mcp_unavailable}
    end
  end

  defp source_metadata(info, server_name) do
    metadata = %{server_name: server_name}

    case info do
      %{era: :modern, discovery: %{"instructions" => instructions}}
      when is_binary(instructions) ->
        Map.merge(metadata, %{instructions_status: "available", instructions: instructions})

      %{era: :modern} ->
        Map.put(metadata, :instructions_status, "not_advertised")

      _ ->
        Map.put(metadata, :instructions_status, "not_retained_legacy")
    end
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
        result =
          if current_transport(state.config) == state.transport do
            prepare_refresh_result(state, result)
          else
            {:error, :connection_changed}
          end

        case result do
          {:ok, _tools} ->
            :atomics.put(state.catalog_valid, 2, state.catalog_generation + 1)
            :atomics.put(state.catalog_valid, 1, 1)

          _ ->
            :atomics.put(state.catalog_valid, 1, 0)
        end

        result
      end)

    {reply, state} =
      case result do
        {:ok, tools} ->
          {:ok,
           %{
             state
             | tools: tools,
               catalog_generation: state.catalog_generation + 1
           }}

        {:error, reason} ->
          :atomics.put(state.catalog_valid, 1, 0)
          {{:error, reason}, %{state | tools: []}}
      end

    notify_catalog_changed(state, if(reply == :ok, do: :ready, else: :unavailable))
    Enum.each(state.refresh_waiters, &GenServer.reply(&1, reply))
    Enum.each(state.ready_waiters, &GenServer.reply(&1, ready_result(reply)))
    %{state | refresh_task: nil, refresh_waiters: [], ready_waiters: [], discovery_result: reply}
  end

  defp prepare_refresh_result(state, result) do
    case result do
      {:ok, raw_tools, metadata} ->
        tools =
          %{"tools" => raw_tools}
          |> Response.tools(state.config.name,
            trust_annotations: MCPConfigs.trust_tool_annotations?(state.config)
          )
          |> runtime_available_tools(state.config, state.initial_availability)
          |> attach_source_identity(state.config)
          |> Enum.map(&Map.put(&1, :source_metadata, metadata))

        {:ok, tools}

      other ->
        other
    end
  end

  defp annotation_trust_available?(config, true),
    do: MCPConfigs.trust_tool_annotations?(config)

  defp annotation_trust_available?(_config, false), do: true

  defp notify_catalog_changed(state, status) do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "tool_registry",
      {:mcp_source_catalog_changed,
       %{source_id: state.config.id, source_name: state.config.name, status: status}}
    )
  end

  defp catalog_available?(state) do
    :atomics.get(state.catalog_valid, 1) == 1 and
      current_transport(state.config) == state.transport and
      current_runtime_available?(state.config, nil, false) and
      Enum.all?(state.tools, fn tool ->
        current_runtime_available?(state.config, tool.name, tool.trust_annotations)
      end)
  end

  defp source_snapshot(state) do
    if is_binary(state.config.id) and catalog_available?(state) do
      tools =
        Enum.map(state.tools, fn tool ->
          tool
          |> Map.take([
            :description,
            :parameters,
            :annotations,
            :permission_level,
            :output_schema,
            :source_metadata
          ])
          |> Map.put(:raw_name, tool.mcp_tool_name)
        end)

      {:ok,
       %{
         source_id: state.config.id,
         server_pid: self(),
         generation: state.catalog_generation,
         tools: tools
       }}
    else
      {:error, :mcp_unavailable}
    end
  end

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
