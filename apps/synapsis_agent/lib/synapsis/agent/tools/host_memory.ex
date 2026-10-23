defmodule Synapsis.Agent.Tools.HostMemory do
  @moduledoc """
  Backplane-native recall from a trusted local host's default memory partition.

  The host constructs exact `source/run_id/incarnation/catalog_revision` bindings;
  arguments cannot select source, credentials, ownership or filters. Policy uses
  `classify/2` with this same trusted context and exact native grants/revisions.
  Resource identity includes the validated endpoint and source ID, independent of
  the routing agent ID. The source's host authorization must be checked by its
  trusted constructor; literal loopback is transport validation, not authentication.
  This module does not register tools or change the production dispatcher.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Memory.{HostAgent, ScopedReader}

  @tool "memory::recall"
  @context_keys [:source, :run_id, :incarnation, :catalog_revision]

  # TODO(upstream): gsmlg-opt/backplane#83 - offline recall cannot guarantee
  # project/session filters; expose only the host-authorized default partition.
  # TODO(upstream): gsmlg-opt/backplane#84 - exact get/read is unsupported;
  # only the real upstream recall descriptor is advertised.
  def descriptors(context) do
    with :ok <- context_valid(context) do
      {:ok,
       [
         %{
           tool_name: @tool,
           tool_revision: 1,
           description:
             "Recall this host's authorized default memory partition, preserving online/offline and provisional state. No project/session isolation or filtering guarantee; no exact record read.",
           schema: %{
             "type" => "object",
             "properties" => %{
               "query" => %{"type" => "string", "minLength" => 1, "maxLength" => 2048},
               "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 20}
             },
             "required" => ["query"],
             "additionalProperties" => false
           },
           safety: %{read_only: true, retry_safe: false, parallel_safe: true},
           backend: __MODULE__,
           backend_context: context
         }
       ]}
    else
      _ -> failure(:invalid_context)
    end
  end

  def classify(context, operation) do
    with :ok <- context_valid(context),
         :ok <- matching_scope(context, operation),
         :ok <- input(operation) do
      {:ok,
       %{
         action: "memory.read",
         resource:
           "memory:host:#{context.source.id}:#{context.source.endpoint}:partition:host_default"
       }}
    end
  end

  @impl true
  def execute(%{backend_context: context} = operation) do
    with {:ok, _} <- classify(context, operation),
         {:ok, public} <-
           HostAgent.recall(context.source, operation.arguments["query"],
             limit: Map.get(operation.arguments, "limit", 5)
           ) do
      result = %{content: text(public), structured: public}

      if byte_size(Jason.encode!(result)) <= 65_536,
        do: {:ok, result},
        else: failure(:output_limit)
    else
      {:error, reason} -> failure(reason)
    end
  end

  def execute(_), do: failure(:invalid_input)

  # Native Execution terminates the caller-owned effect process; HostAgent's
  # guardian then cleans its HTTP reader. Remote trace rollback is not promised.
  @impl true
  def cancel(_), do: :ok

  defp context_valid(context) when is_map(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         ScopedReader.valid_id?(context.run_id) and is_integer(context.incarnation) and
         context.incarnation > 0 and is_integer(context.catalog_revision) and
         context.catalog_revision > 0 and HostAgent.validate_source(context.source) == :ok,
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp context_valid(_), do: {:error, :invalid_context}

  defp matching_scope(context, operation) when is_map(operation) do
    if Enum.all?(
         [:run_id, :incarnation, :catalog_revision],
         &(Map.get(operation, &1) === context[&1])
       ) and
         operation[:tool_revision] === 1 and operation[:backend_context] === context,
       do: :ok,
       else: {:error, :scope_mismatch}
  end

  defp matching_scope(_, _), do: {:error, :scope_mismatch}

  defp input(%{tool_name: @tool, arguments: %{"query" => query} = args}) do
    limit = Map.get(args, "limit", 5)

    if Map.keys(args) -- ["query", "limit"] == [] and is_binary(query) and String.valid?(query) and
         byte_size(query) in 1..2048 and is_integer(limit) and limit in 1..20,
       do: :ok,
       else: {:error, :invalid_input}
  end

  defp input(_), do: {:error, :invalid_input}

  defp text(public) do
    state =
      "Host memory #{public.source.id} (#{public.mode}; authority=#{public.authority}; consistency=#{public.consistency}; stale=#{public.stale}; history_available=#{public.history_available}; pending_operations=#{public.pending_operations})."

    records =
      case public.hits do
        [] ->
          "No matching host memory records."

        hits ->
          Enum.map_join(hits, "\n\n", fn hit ->
            marker = if Map.get(hit, :provisional, false), do: " (provisional)", else: ""

            "#{hit.content}\nSource: #{hit.citation.source_id} #{hit.citation.endpoint} record #{hit.memory_id}#{marker}"
          end)
      end

    state <> "\n" <> records
  end

  defp failure(reason) do
    class =
      cond do
        reason in [:scope_mismatch, :unauthorized] -> :forbidden
        reason in [:invalid_context, :invalid_input, :invalid_source] -> :validation
        reason == :timeout -> :timeout
        reason in [:response_limit, :output_limit, :worker_limit] -> :budget_exceeded
        reason in [:unavailable, :redirect, :http_error, :host_error] -> :unsupported_capability
        true -> :malformed_result
      end

    {:error,
     Error.new(class, "host memory recall failed", details: %{code: Atom.to_string(reason)})}
  end
end
