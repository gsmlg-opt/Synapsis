defmodule Synapsis.Agent.Tools.MCPResources do
  @moduledoc """
  Native MCP resource tools routed to independently selected source snapshots.

  One Session-owned DynamicRuntime carries the native request scope. Source
  UUIDs and exact generations are immutable descriptor data for each turn; they
  never become runtime configuration or durable request handles. Omitted-server
  lists request one page per selected UUID in saved order, forwarding an opaque
  cursor unchanged. Explicit UUIDs route continuation and exact URI reads.
  """

  alias Backplane.AiProtocol.Validation
  alias Backplane.AgentRuntime.{Codex, Error, InputSchema, ToolCatalog}
  alias Backplane.AgentRuntime.Codex.{Backend, DynamicRuntime, ResourceRegistry, Session}
  alias Backplane.McpProtocol.MCP.Error, as: ProtocolError
  alias Backplane.McpProtocol.MCP.Response, as: ProtocolResponse
  alias Synapsis.Agent.Tools.{CatalogBinding, MCPSources}
  alias Synapsis.MCP

  @names ~w(list_mcp_resources list_mcp_resource_templates read_mcp_resource)
  @cache_limit 64

  def names, do: @names
  def permission_level(name) when name in @names, do: :read

  def bundles(context, identity, authority, selection, binding, cache) do
    cache = prune(cache)
    selected = Enum.filter(@names, &(&1 in selection))

    if selected == [] do
      {:ok, [], cache}
    else
      with true <- Enum.all?(selected, &(&1 in authority.grants)),
           {:ok, ids} <- MCPSources.resource_source_ids(context.agent),
           {:ok, sources} <- snapshots(context.agent, ids),
           {:ok, record} <- resource_record(binding, cache),
           ceiling = %{
             authority
             | grants: selected,
               tool_revisions: Map.take(authority.tool_revisions, selected)
           },
           {:ok, native} <-
             Codex.profile(
               :dynamic,
               %{dynamic_runtime: record.pid, session_binding: binding},
               ceiling,
               tools: selected
             ),
           trusted = %{identity: identity, source_ids: ids, sources: sources, record: record},
           descriptors =
             Enum.map(selected, fn name ->
               descriptor = Map.fetch!(native.registry.tools, name)
               backend = Map.put(descriptor.backend_context, :mcp_resource_context, trusted)
               %{descriptor | backend_context: backend}
             end),
           {:ok, bundle} <-
             ToolCatalog.admit_batch(descriptors, authority: native.authority, mode: :strict) do
        {:ok, [bundle], Map.put(cache, owner_key(binding), record)}
      else
        false -> failure(:forbidden, "MCP resources exceed the parent authority ceiling")
        error -> error
      end
    end
  end

  def classify(
        %{backend: Backend, backend_context: %{mcp_resource_context: trusted}} = descriptor,
        identity,
        operation
      ) do
    with true <- trusted.identity === identity,
         {:ok, arguments, sources} <- invocation(descriptor, operation) do
      digest =
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary(
            {descriptor.tool_name, Enum.map(sources, &elem(&1, 0)), arguments},
            [:deterministic]
          )
        )
        |> Base.encode16(case: :lower)

      {:ok,
       %{action: "mcp.resource", resource: "mcp-resource:" <> digest, permission_level: :read}}
    else
      false -> failure(:forbidden, "MCP resource invocation scope changed")
      error -> error
    end
  end

  def classify(_, _, _), do: failure(:validation, "MCP resource descriptor is unavailable")

  def list_resources(arguments, operation), do: request(arguments, operation, :list)

  def list_resource_templates(arguments, operation), do: request(arguments, operation, :templates)

  def read_resource(arguments, operation), do: request(arguments, operation, :read)

  defp request(arguments, operation, kind) do
    with {:ok, descriptor} <- pinned_descriptor(operation),
         {:ok, ^arguments, sources} <- invocation(descriptor, operation) do
      params = Map.delete(arguments, "server")

      DynamicRuntime.resource_request_scope(operation, fn scope ->
        Enum.reduce_while(sources, {:ok, []}, fn {id, snapshot}, {:ok, pages} ->
          result =
            DynamicRuntime.resource_request(scope, fn reserved ->
              MCP.runtime_start_resource_request(snapshot, kind, params, reserved)
            end)

          case resource_result(result, id) do
            {:ok, raw} ->
              {:cont, {:ok, [%{"server" => id, "result" => raw} | pages]}}

            error ->
              {:halt, error}
          end
        end)
        |> case do
          {:ok, pages} -> output(%{"sources" => Enum.reverse(pages)})
          error -> error
        end
      end)
    end
  end

  defp invocation(descriptor, operation) do
    trusted = descriptor.backend_context.mcp_resource_context

    with :ok <- CatalogBinding.descriptor(descriptor, trusted.identity, operation),
         {:ok, _owner} <- Session.validate(trusted.record.binding, operation),
         :ok <- fetch_record(trusted.record.binding, trusted.record),
         {:ok, arguments} <- InputSchema.validate(descriptor.schema, operation.arguments),
         {:ok, ids} <- requested_sources(arguments, trusted.source_ids),
         :ok <- current_snapshots(ids, trusted.sources) do
      {:ok, arguments, Enum.map(ids, &{&1, Map.fetch!(trusted.sources, &1)})}
    else
      {:error, %Error{}} = error -> error
      _ -> failure(:forbidden, "MCP resource source or invocation changed; prepare a new run")
    end
  end

  defp pinned_descriptor(%{tool_name: name, backend_context: backend}) when name in @names do
    with %{registry: %{tools: tools}} <- backend[:catalog_snapshot],
         %{backend: Backend, backend_context: context} = descriptor <- tools[name],
         true <- context[:mcp_resource_context] === backend[:mcp_resource_context],
         true <- context[:runtime] === backend[:runtime] do
      {:ok, descriptor}
    else
      _ -> failure(:validation, "MCP resource pinned descriptor is unavailable")
    end
  end

  defp pinned_descriptor(_),
    do: failure(:validation, "MCP resource pinned descriptor is unavailable")

  defp requested_sources(%{"server" => id}, ids) do
    if id in ids,
      do: {:ok, [id]},
      else: failure(:unsupported_capability, "MCP resource source is not selected")
  end

  defp requested_sources(_arguments, ids), do: {:ok, ids}

  defp snapshots(agent, ids) do
    sources = Map.get(agent, :mcp_resource_sources, %{})

    if is_map(sources) and
         Enum.all?(ids, fn id -> match?(%{source_id: ^id}, sources[id]) end) do
      {:ok, Map.take(sources, ids)}
    else
      failure(:unsupported_capability, "Selected MCP resource snapshots are unavailable")
    end
  end

  defp current_snapshots(ids, sources) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      expected = Map.fetch!(sources, id)

      case MCP.runtime_snapshot(id) do
        {:ok, ^expected} -> {:cont, :ok}
        _ -> {:halt, failure(:unsupported_capability, "Selected MCP resource snapshot changed")}
      end
    end)
  end

  defp resource_result({:ok, %ProtocolResponse{result: raw, is_error: false}}, _id)
       when is_map(raw) and not is_struct(raw),
       do: {:ok, raw}

  defp resource_result({:error, %Error{} = error}, id),
    do: {:error, %{error | details: Map.put(error.details, :source_id, id)}}

  defp resource_result({:error, %ProtocolError{reason: :request_timeout} = error}, id),
    do:
      {:error,
       Error.new(:timeout, "MCP resource request timed out",
         details: %{source_id: id},
         cause: error
       )}

  defp resource_result({:rejected, reason}, id),
    do:
      {:error,
       Error.new(:unsupported_capability, "MCP resource request could not start",
         details: %{source_id: id},
         cause: reason
       )}

  defp resource_result(other, id),
    do:
      {:error,
       Error.new(:execution_failure, "MCP resource request failed",
         details: %{source_id: id},
         cause: other
       )}

  defp output(public) do
    with :ok <- Validation.term(public),
         {:ok, text} <- Jason.encode(public),
         result = %{content: text, structured: public},
         :ok <- Validation.term(result) do
      {:ok, result}
    else
      {:error, _} ->
        failure(:budget_exceeded, "MCP resource result exceeds the public result budget")
    end
  end

  defp resource_record(binding, cache) do
    case cache[owner_key(binding)] do
      nil ->
        if map_size(cache) < @cache_limit,
          do: create_record(binding),
          else:
            failure(:overloaded, "MCP resource runtime cache is full; reconcile closed Sessions")

      record ->
        with :ok <- fetch_record(binding, record), do: {:ok, %{record | binding: binding}}
    end
  end

  defp fetch_record(binding, %{pid: pid, handle: handle}) do
    case ResourceRegistry.fetch(binding.resource_registry, handle, binding.owner_id) do
      {:ok, ^pid} -> :ok
      _ -> failure(:unknown_outcome, "MCP resource runtime requires confirmed cleanup")
    end
  end

  defp create_record(binding) do
    with {:ok, supervisor} <- ResourceRegistry.worker_supervisor(binding.resource_registry),
         {:ok, pid} <-
           DynamicSupervisor.start_child(
             supervisor,
             Supervisor.child_spec({DynamicRuntime, mcp_adapter: __MODULE__},
               restart: :temporary,
               shutdown: 1_000
             )
           ) do
      case ResourceRegistry.register(
             binding.resource_registry,
             binding.owner_id,
             :mcp_resources,
             pid,
             incarnation: binding.incarnation,
             owner_pid: binding.owner_pid,
             cleanup: fn -> cleanup(supervisor, pid) end
           ) do
        {:ok, handle} ->
          {:ok, %{binding: binding, pid: pid, handle: handle}}

        error ->
          cleanup(supervisor, pid)
          error
      end
    end
  end

  defp cleanup(supervisor, pid) do
    case DynamicSupervisor.terminate_child(supervisor, pid) do
      :ok -> :ok
      _ -> {:uncertain, :mcp_resource_runtime_cleanup_unconfirmed}
    end
  catch
    :exit, _ -> {:uncertain, :mcp_resource_runtime_cleanup_unconfirmed}
  end

  defp prune(cache) do
    Map.reject(cache, fn {_key, record} ->
      try do
        case Session.status(record.binding.session) do
          %{phase: :closed, cleanup: {:ok, %{status: :confirmed}}} -> true
          _ -> confirmed_dead_record?(record)
        end
      catch
        :exit, _ -> confirmed_dead_record?(record)
      end
    end)
  end

  defp confirmed_dead_record?(%{binding: binding, handle: handle}) do
    not Process.alive?(binding.owner_pid) and
      match?(
        {:ok, %{status: :confirmed}},
        ResourceRegistry.cleanup_status(binding.resource_registry, handle, binding.owner_id)
      )
  catch
    :exit, _ -> false
  end

  defp owner_key(binding), do: {binding.owner_id, binding.incarnation}
  defp failure(class, message), do: {:error, Error.new(class, message)}
end
