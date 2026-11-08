defmodule Synapsis.Agent.Tools.HostMemory do
  @moduledoc """
  Backplane-native reads from a trusted local host's default memory partition.

  The host constructs exact `source/run_id/incarnation/catalog_revision` bindings;
  arguments cannot select source, credentials, ownership or filters. Policy uses
  `classify/2` with this same trusted context and exact native grants/revisions.
  Resource identity includes the validated endpoint and source ID, independent of
  the routing agent ID. The source's host authorization must be checked by its
  trusted constructor; literal loopback is transport validation, not authentication.
  Profiles exposes exact get only when explicitly selected.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Memory.HostAgent

  @recall "memory::recall"
  @get "memory::get"
  @context_keys [:source, :run_id, :incarnation, :catalog_revision]
  @native_context_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a

  # This slice exposes only the host-authorized default partition, without
  # project/session selectors. Exact get adopts backplane#84's canonical online
  # contract and never falls back to recall or the offline mirror.
  def descriptors(context) do
    with :ok <- context_valid(context),
         {:ok, source} <- Synapsis.Memory.Settings.host_source(),
         true <- source === context.source do
      {:ok, [descriptor(@recall, context), descriptor(@get, context)]}
    else
      {:error, :disabled} -> {:ok, []}
      false -> failure(:source_changed)
      {:error, :invalid_context} -> failure(:invalid_context)
      {:error, reason} -> failure(reason)
    end
  end

  def classify(context, operation) do
    with :ok <- context_valid(context),
         :ok <- matching_scope(context, operation),
         :ok <- input(operation) do
      resource =
        "memory:host:#{context.source.id}:#{context.source.endpoint}:partition:host_default"

      resource =
        if operation.tool_name == @get,
          do: resource <> ":record:" <> operation.arguments["id"],
          else: resource

      {:ok, %{action: "memory.read", resource: resource}}
    end
  end

  @impl true
  def execute(%{backend_context: context} = operation) do
    with {:ok, context} <- execution_context(context),
         {:ok, _} <-
           classify(
             context,
             Synapsis.Agent.Tools.CatalogBinding.classification_operation(operation, context)
           ),
         operation = %{operation | backend_context: context},
         {:ok, public} <- read(context.source, operation) do
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

  defp descriptor(name, context) do
    {description, properties, required} =
      case name do
        @recall ->
          {"Recall this host's authorized default memory partition, preserving online/offline and provisional state. No project/session isolation or filtering guarantee.",
           %{
             "query" => %{"type" => "string", "minLength" => 1, "maxLength" => 2048},
             "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 20}
           }, ["query"]}

        @get ->
          {"Read one canonical record by UUID from this host's authorized default memory partition. Requires canonical online access; no offline or recall fallback and no project/session isolation guarantee.",
           %{
             "id" => %{
               "type" => "string",
               "minLength" => 36,
               "maxLength" => 36,
               "pattern" => "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
             }
           }, ["id"]}
      end

    %{
      tool_name: name,
      tool_revision: 1,
      description: description,
      schema: %{
        "type" => "object",
        "properties" => properties,
        "required" => required,
        "additionalProperties" => false
      },
      safety: %{read_only: true, retry_safe: false, parallel_safe: true},
      backend: __MODULE__,
      backend_context: context
    }
  end

  defp context_valid(context) when is_map(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         valid_run_id?(context.run_id) and is_integer(context.incarnation) and
         context.incarnation > 0 and is_integer(context.catalog_revision) and
         context.catalog_revision > 0 and HostAgent.validate_source(context.source) == :ok,
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp context_valid(_), do: {:error, :invalid_context}

  defp valid_run_id?(id),
    do:
      is_binary(id) and byte_size(id) in 1..4096 and
        String.valid?(id) and String.trim(id) != "" and not String.contains?(id, "\0")

  defp execution_context(context) when is_map(context) do
    if Map.keys(context) -- (@context_keys ++ @native_context_keys) == [],
      do: {:ok, Map.take(context, @context_keys)},
      else: {:error, :invalid_context}
  end

  defp execution_context(_), do: {:error, :invalid_context}

  defp matching_scope(context, operation) when is_map(operation) do
    Synapsis.Agent.Tools.CatalogBinding.host(
      context,
      operation,
      __MODULE__,
      1,
      @native_context_keys
    )
  end

  defp matching_scope(_, _), do: {:error, :scope_mismatch}

  defp input(%{tool_name: @recall, arguments: %{"query" => query} = args}) do
    limit = Map.get(args, "limit", 5)

    if Map.keys(args) -- ["query", "limit"] == [] and is_binary(query) and String.valid?(query) and
         byte_size(query) in 1..2048 and is_integer(limit) and limit in 1..20,
       do: :ok,
       else: {:error, :invalid_input}
  end

  defp input(%{tool_name: @get, arguments: %{"id" => id} = args}) do
    if Map.keys(args) == ["id"] and is_binary(id) and Ecto.UUID.cast(id) == {:ok, id},
      do: :ok,
      else: {:error, :invalid_input}
  end

  defp input(_), do: {:error, :invalid_input}

  defp read(source, %{tool_name: @recall, arguments: args}),
    do:
      Synapsis.Memory.recall_host(args["query"], source: source, limit: Map.get(args, "limit", 5))

  defp read(source, %{tool_name: @get, arguments: args}),
    do: Synapsis.Memory.get_host(args["id"], source: source)

  defp text(%{record: record} = public) do
    "Host memory #{public.source.id} (#{public.mode}; authority=#{public.authority}; consistency=#{public.consistency}; stale=#{public.stale}; history_available=#{public.history_available}).\n" <>
      "#{record.content}\nSource: #{record.citation.source_id} #{record.citation.endpoint} record #{record.memory_id}"
  end

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
        reason in [:scope_mismatch, :unauthorized, :disabled, :source_changed] ->
          :forbidden

        reason in [
          :invalid_context,
          :invalid_input,
          :invalid_source,
          :invalid_arguments,
          :not_found
        ] ->
          :validation

        reason == :timeout ->
          :timeout

        reason in [:response_limit, :output_limit, :worker_limit, :payload_too_large] ->
          :budget_exceeded

        reason in [
          :unavailable,
          :redirect,
          :http_error,
          :host_error,
          :invalid_config,
          :canonical_unavailable,
          :unsupported_operation,
          :unsupported_filter
        ] ->
          :unsupported_capability

        true ->
          :malformed_result
      end

    {:error,
     Error.new(class, "host memory read failed", details: %{code: Atom.to_string(reason)})}
  end
end
