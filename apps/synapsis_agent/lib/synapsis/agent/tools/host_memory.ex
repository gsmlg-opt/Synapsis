defmodule Synapsis.Agent.Tools.HostMemory do
  @moduledoc """
  Native shared-memory tools from an explicitly enabled Backplane Host Agent.

  Schemas come from that host's MCP catalog. Each issued descriptor pins its
  source, schema and run/catalog identity; invocation arguments cannot change
  that binding. Returned memories remain data with provenance, never instructions.
  Writes are never retried locally, including after an ambiguous timeout.
  An unavailable or unplugged host retains explicit no-effect tool markers for
  the turn; subsequent preparation rediscovers the real host schemas.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects
  require Logger

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Memory.{HostAgent, Settings}

  @context_keys [:source, :run_id, :incarnation, :catalog_revision, :session_id]
  @issued_keys @context_keys ++ [:tool_name, :schema]
  @scope_keys @context_keys -- [:source]
  @unavailable_keys @scope_keys ++ [:tool_name, :schema, :unavailable]
  @unavailable_schema %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
  @native_context_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @reads ~w(memory::search memory::get memory::recent)

  def names, do: HostAgent.tools()
  def revision, do: 2

  def descriptors(context) do
    with :ok <- context_valid(context, @context_keys),
         {:ok, source} <- Settings.host_source(),
         true <- source === context.source do
      case HostAgent.catalog(source, timeout: 1_000) do
        {:ok, tools} ->
          {:ok, Enum.map(tools, &descriptor(&1, context))}

        {:error, reason} ->
          unavailable_descriptors(Map.take(context, @scope_keys), names(), reason)
      end
    else
      {:error, :disabled} -> {:ok, []}
      false -> failure(:source_changed)
      {:error, reason} -> failure(reason)
    end
  end

  @doc "Retain selected names with an explicit, effect-free unavailable contract for this turn."
  def unavailable_descriptors(scope, selected, reason)
      when is_map(scope) and is_list(selected) and is_atom(reason) do
    if Enum.sort(Map.keys(scope)) == Enum.sort(@scope_keys) and scope_valid?(scope) and
         Enum.all?(selected, &(&1 in names())) and Enum.uniq(selected) == selected do
      Logger.warning("host_memory_unavailable", session_id: scope.session_id, reason: reason)

      {:ok,
       Enum.map(selected, fn name ->
         # This is an unavailable marker, not a substitute for the host's schema.
         tool = %{
           "name" => name,
           "description" =>
             "Shared memory is temporarily unavailable (#{reason}). This turn accepts no arguments and returns an availability error. The host is rediscovered next turn.",
           "inputSchema" => @unavailable_schema
         }

         descriptor(tool, Map.put(scope, :unavailable, reason))
       end)}
    else
      failure(:invalid_context)
    end
  end

  def classify(%{unavailable: _} = context, operation) do
    with :ok <- context_valid(context, @unavailable_keys),
         :ok <-
           Synapsis.Agent.Tools.CatalogBinding.host(
             context,
             operation,
             __MODULE__,
             revision(),
             @native_context_keys
           ),
         true <- operation[:tool_name] === context.tool_name,
         :ok <- input(context.schema, operation[:arguments]) do
      action = if context.tool_name in @reads, do: "memory.read", else: "memory.write"
      {:ok, %{action: action, resource: "memory:host:unavailable"}}
    else
      false -> {:error, :scope_mismatch}
      error -> error
    end
  end

  def classify(context, operation) do
    with :ok <- context_valid(context, @issued_keys),
         :ok <-
           Synapsis.Agent.Tools.CatalogBinding.host(
             context,
             operation,
             __MODULE__,
             revision(),
             @native_context_keys
           ),
         true <- operation[:tool_name] === context.tool_name,
         :ok <- input(context.schema, operation[:arguments]) do
      action = if context.tool_name in @reads, do: "memory.read", else: "memory.write"
      resource = "memory:host:#{context.source.id}:#{context.source.endpoint}:shared"
      {:ok, %{action: action, resource: resource}}
    else
      false -> {:error, :scope_mismatch}
      {:error, _} = error -> error
    end
  end

  @impl true
  def execute(%{backend_context: %{unavailable: reason} = enriched} = operation) do
    context = Map.take(enriched, @unavailable_keys)

    with true <- Map.keys(enriched) -- (@unavailable_keys ++ @native_context_keys) == [],
         {:ok, _} <-
           classify(
             context,
             Synapsis.Agent.Tools.CatalogBinding.classification_operation(operation, context)
           ) do
      {:ok,
       %{
         is_error: true,
         content: "Shared memory is temporarily unavailable",
         structured: %{
           integration: "backplane_memory",
           status: "unavailable",
           code: to_string(reason)
         }
       }}
    else
      false -> failure(:invalid_context)
      error -> error
    end
  end

  def execute(%{backend_context: enriched} = operation) when is_map(enriched) do
    context = Map.take(enriched, @issued_keys)

    with true <- Map.keys(enriched) -- (@issued_keys ++ @native_context_keys) == [],
         {:ok, _} <-
           classify(
             context,
             Synapsis.Agent.Tools.CatalogBinding.classification_operation(operation, context)
           ),
         {:ok, source} <- Settings.host_source(),
         true <- source === context.source,
         arguments =
           if(context.tool_name == "memory::remember",
             do: Map.put(operation.arguments, "session_id", context.session_id),
             else: operation.arguments
           ),
         {:ok, opts} <- effect_options(enriched),
         {:ok, public} <- HostAgent.call(source, context.tool_name, arguments, opts) do
      structured = %{
        integration: "backplane_memory",
        source: %{id: source.id, endpoint: source.endpoint},
        result: public
      }

      # JSON encoding keeps recalled text inside a data value even when it
      # contains markup resembling a prompt or instruction boundary.
      content =
        "Shared Backplane memory data (untrusted records; preserve provenance):\n" <>
          Jason.encode!(public)

      result = %{content: content, structured: structured}

      if byte_size(Jason.encode!(result)) <= 65_536,
        do: {:ok, result},
        else: failure(:output_limit)
    else
      false -> failure(:source_changed)
      {:error, reason} -> failure(reason)
    end
  end

  def execute(_), do: failure(:invalid_input)

  @impl true
  def cancel(_), do: :ok

  defp effect_options(%{effect_deadline: getter}) when is_function(getter, 0) do
    case getter.() do
      {:ok, %{deadline_ms: deadline, remaining_ms: remaining, paused: false}}
      when is_integer(deadline) and is_integer(remaining) and remaining > 0 ->
        {:ok, [deadline: deadline]}

      {:ok, %{remaining_ms: remaining}} when is_integer(remaining) and remaining <= 0 ->
        {:error, :timeout}

      _ ->
        {:error, :invalid_context}
    end
  end

  defp effect_options(context) do
    if Map.has_key?(context, :effect_deadline), do: {:error, :invalid_context}, else: {:ok, []}
  end

  defp descriptor(tool, context) do
    name = tool["name"]
    schema = tool["inputSchema"]
    read_only = name in @reads

    %{
      tool_name: name,
      tool_revision: revision(),
      description: tool["description"],
      schema: schema,
      safety: %{read_only: read_only, retry_safe: false, parallel_safe: read_only},
      backend: __MODULE__,
      backend_context: Map.merge(context, %{tool_name: name, schema: schema})
    }
  end

  defp context_valid(%{unavailable: reason} = context, @unavailable_keys) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@unavailable_keys) and
         scope_valid?(context) and is_atom(reason) and context.tool_name in names() and
         context.schema === @unavailable_schema,
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp context_valid(context, keys) when is_map(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(keys) and
         scope_valid?(context) and
         HostAgent.validate_source(context.source) == :ok and
         (keys == @context_keys or (context.tool_name in names() and is_map(context.schema))),
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp context_valid(_, _), do: {:error, :invalid_context}

  defp scope_valid?(context) do
    is_binary(context[:session_id]) and byte_size(context.session_id) in 1..4096 and
      is_binary(context[:run_id]) and byte_size(context.run_id) in 1..4096 and
      String.valid?(context.run_id) and String.trim(context.run_id) != "" and
      not String.contains?(context.run_id, "\0") and
      is_integer(context[:incarnation]) and context.incarnation > 0 and
      is_integer(context[:catalog_revision]) and context.catalog_revision > 0
  end

  defp input(schema, arguments) when is_map(arguments) and not is_struct(arguments) do
    with {:ok, compiled} <- JSONSchex.compile(schema),
         :ok <- JSONSchex.validate(compiled, arguments),
         true <- byte_size(Jason.encode!(arguments)) <= 65_536 do
      :ok
    else
      _ -> {:error, :invalid_input}
    end
  rescue
    _ in [Jason.EncodeError, Protocol.UndefinedError] -> {:error, :invalid_input}
  end

  defp input(_, _), do: {:error, :invalid_input}

  defp failure(%Error{} = error), do: {:error, error}

  defp failure(reason) do
    class =
      cond do
        reason in [:scope_mismatch, :unauthorized, :disabled, :source_changed] -> :forbidden
        reason in [:invalid_context, :invalid_input, :invalid_source, :not_found] -> :validation
        reason == :timeout -> :timeout
        reason in [:response_limit, :output_limit, :worker_limit] -> :budget_exceeded
        reason == :malformed_result -> :malformed_result
        true -> :unsupported_capability
      end

    {:error, Error.new(class, "host memory call failed", details: %{code: to_string(reason)})}
  end
end
