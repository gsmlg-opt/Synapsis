defmodule Synapsis.Agent.Tools.MCP do
  @moduledoc """
  Native MCP tools bound to an exact live source catalog and run scope.

  Source identity, generation, schema and persisted annotation trust come from
  `Synapsis.MCP.Server`. Neither model arguments nor MCP hints grant authority.
  Native catalog admission and host policy remain required. The effect caller
  owns the runtime call handle; terminating it cancels that handle without
  stopping the shared source or promising remote rollback.

  Ordered MCP blocks are retained as received, with structured content and
  remaining public fields. This boundary does not adapt media for providers.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema, ToolEffects}
  alias Backplane.AiProtocol.Validation
  alias Synapsis.MCP.Server

  @context_keys [:source, :run_id, :incarnation, :catalog_revision]
  @source_keys [:source_id, :server_pid, :generation, :tools]
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @timeout 30_000

  def descriptors(context) do
    with :ok <- context_valid(context),
         :ok <- source_current(context.source) do
      {:ok, Enum.map(context.source.tools, &descriptor(&1, context))}
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  def permission_level(context, native_name) do
    with :ok <- context_valid(context),
         :ok <- source_current(context.source),
         {:ok, tool} <- selected_tool(context.source, native_name) do
      {:ok, tool.permission_level}
    end
  end

  def classify(context, operation) do
    with :ok <- context_valid(context),
         :ok <- matching_scope(context, operation),
         :ok <- source_current(context.source),
         {:ok, tool} <- selected_tool(context.source, operation[:tool_name]),
         :ok <- arguments_valid(tool.parameters, operation[:arguments]) do
      {:ok,
       %{
         action: "mcp.tool.call",
         resource: "mcp:source:#{context.source.source_id}:tool:#{tool.raw_name}"
       }}
    end
  end

  @impl true
  def execute(%{backend_context: backend_context} = original) do
    with {:ok, context} <- execution_context(backend_context),
         {:ok, _} <-
           classify(
             context,
             Synapsis.Agent.Tools.CatalogBinding.classification_operation(original, context)
           ),
         operation = %{original | backend_context: context},
         {:ok, tool} <- selected_tool(context.source, operation.tool_name) do
      dispatch(context.source, tool.raw_name, operation.arguments, original)
    else
      {:error, reason} -> ToolEffects.reject(original, error(reason))
    end
  end

  def execute(operation) when is_map(operation),
    do: ToolEffects.reject(operation, error(:invalid_context))

  def execute(_), do: {:error, error(:invalid_context)}

  @impl true
  def cancel(_), do: :ok

  defp descriptor(tool, context) do
    %{
      tool_name: native_name(context.source, tool.raw_name),
      tool_revision: context.source.generation,
      description: tool.description,
      schema: tool.parameters,
      safety: %{
        read_only: tool.permission_level == :read,
        retry_safe: false,
        parallel_safe: false
      },
      backend: __MODULE__,
      backend_context: context
    }
    |> public_metadata(tool, context.source)
  end

  defp public_metadata(descriptor, tool, source) do
    descriptor =
      if Map.has_key?(tool, :output_schema),
        do: Map.put(descriptor, :codex_output_schema, tool.output_schema),
        else: descriptor

    case tool do
      %{source_metadata: %{server_name: server_name}} ->
        Map.put(descriptor, :codex_source, %{
          kind: "mcp",
          source_id: source.source_id,
          raw_name: tool.raw_name,
          server_name: server_name
        })

      _ ->
        descriptor
    end
  end

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         valid_run_id?(context.run_id) and is_integer(context.incarnation) and
         context.incarnation > 0 and is_integer(context.catalog_revision) and
         context.catalog_revision > 0 and valid_source?(context.source),
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp context_valid(_), do: {:error, :invalid_context}

  defp valid_source?(source) when is_map(source) and not is_struct(source) do
    Enum.sort(Map.keys(source)) == Enum.sort(@source_keys) and
      is_binary(source.source_id) and Ecto.UUID.cast(source.source_id) == {:ok, source.source_id} and
      is_pid(source.server_pid) and is_integer(source.generation) and source.generation > 0 and
      is_list(source.tools) and Enum.all?(source.tools, &valid_tool?/1) and
      length(source.tools) == length(Enum.uniq_by(source.tools, & &1.raw_name))
  end

  defp valid_source?(_), do: false

  defp valid_tool?(
         %{
           raw_name: name,
           description: description,
           parameters: parameters,
           permission_level: level
         } = tool
       ) do
    is_binary(name) and String.valid?(name) and String.trim(name) != "" and
      not String.contains?(name, "\0") and is_binary(description) and String.valid?(description) and
      is_map(parameters) and level in [:read, :write] and
      (not Map.has_key?(tool, :output_schema) or
         (is_map(tool.output_schema) and not is_struct(tool.output_schema))) and
      (not Map.has_key?(tool, :source_metadata) or valid_source_metadata?(tool.source_metadata))
  end

  defp valid_tool?(_), do: false

  defp valid_source_metadata?(%{server_name: name, instructions_status: status} = metadata) do
    base = [:server_name, :instructions_status]

    is_binary(name) and String.valid?(name) and
      case status do
        "available" ->
          Enum.sort(Map.keys(metadata)) == Enum.sort([:instructions | base]) and
            is_binary(metadata.instructions) and String.valid?(metadata.instructions)

        status when status in ["not_advertised", "not_retained_legacy"] ->
          Enum.sort(Map.keys(metadata)) == Enum.sort(base)

        _ ->
          false
      end
  end

  defp valid_source_metadata?(_), do: false

  defp valid_run_id?(id),
    do:
      is_binary(id) and byte_size(id) in 1..4096 and String.valid?(id) and
        String.trim(id) != "" and not String.contains?(id, "\0")

  defp execution_context(context) when is_map(context) and not is_struct(context) do
    if Map.keys(context) -- (@context_keys ++ @native_keys) == [],
      do: {:ok, Map.take(context, @context_keys)},
      else: {:error, :invalid_context}
  end

  defp execution_context(_), do: {:error, :invalid_context}

  defp matching_scope(context, operation) when is_map(operation) do
    Synapsis.Agent.Tools.CatalogBinding.host(
      context,
      operation,
      __MODULE__,
      context.source.generation,
      @native_keys
    )
  end

  defp matching_scope(_, _), do: {:error, :scope_mismatch}

  @doc false
  def source_current(source) do
    case Server.runtime_snapshot(source.server_pid) do
      {:ok, current} when current === source -> :ok
      {:ok, _} -> {:error, :stale_source}
      _ -> {:error, :source_unavailable}
    end
  end

  defp selected_tool(source, name) do
    case Enum.find(source.tools, &(native_name(source, &1.raw_name) === name)) do
      nil -> {:error, :tool_unavailable}
      tool -> {:ok, tool}
    end
  end

  defp native_name(source, raw_name), do: "mcp::#{source.source_id}::#{raw_name}"

  defp arguments_valid(schema, arguments) when is_map(arguments) and not is_struct(arguments) do
    case InputSchema.validate(schema, arguments) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :invalid_arguments}
    end
  end

  defp arguments_valid(_, _), do: {:error, :invalid_arguments}

  defp dispatch(source, raw_name, arguments, original) do
    case runtime_call(source, raw_name, arguments) do
      {:ok, raw} -> completed(raw)
      {:rejected, reason} -> ToolEffects.reject(original, error(rejection_reason(reason)))
      {:error, :invalid_mcp_result} -> completed_error(:malformed_result)
      {:error, _} -> {:error, error(:unknown_outcome)}
    end
  end

  defp runtime_call(source, raw_name, arguments) do
    Server.runtime_call(source, raw_name, arguments, @timeout)
  rescue
    _ -> {:error, :unknown_outcome}
  catch
    :exit, _ -> {:error, :unknown_outcome}
  end

  defp completed(raw) when is_map(raw) and not is_struct(raw) do
    with true <- valid_content?(raw["content"]) and is_boolean(Map.get(raw, "isError", false)),
         true <- not Map.has_key?(raw, "structuredContent") or is_map(raw["structuredContent"]),
         {:ok, _} <- ToolEffects.validate_output(%{payload: raw}),
         :ok <- Validation.term(raw) do
      extras = Map.drop(raw, ["content", "structuredContent", "isError"])

      result = %{content: raw["content"], is_error: Map.get(raw, "isError", false)}

      result =
        if Map.has_key?(raw, "structuredContent"),
          do: Map.put(result, :structured, raw["structuredContent"]),
          else: result

      result =
        if map_size(extras) > 0, do: Map.put(result, :metadata, %{mcp: extras}), else: result

      case ToolEffects.validate_output(%{payload: result}) do
        {:ok, _} -> {:ok, result}
        {:error, _} -> completed_error(:budget_exceeded)
      end
    else
      {:error, %Error{}} -> completed_error(:budget_exceeded)
      _ -> completed_error(:malformed_result)
    end
  rescue
    _ -> completed_error(:malformed_result)
  end

  defp completed(_), do: completed_error(:malformed_result)

  defp valid_content?(content) when is_list(content),
    do: Enum.all?(content, &valid_block?/1)

  defp valid_content?(_), do: false

  defp valid_block?(%{"type" => type} = block) do
    valid =
      case type do
        "text" ->
          is_binary(block["text"])

        media when media in ["image", "audio"] ->
          is_binary(block["data"]) and is_binary(block["mimeType"])

        "resource" ->
          valid_resource?(block["resource"])

        "resource_link" ->
          is_binary(block["uri"]) and is_binary(block["name"]) and
            optional_string?(block, "mimeType") and optional_string?(block, "description")

        _ ->
          false
      end

    valid and optional_map?(block, "annotations") and optional_map?(block, "_meta")
  end

  defp valid_block?(_), do: false

  defp valid_resource?(resource) when is_map(resource) and not is_struct(resource) do
    is_binary(resource["uri"]) and
      (Map.has_key?(resource, "text") or Map.has_key?(resource, "blob")) and
      optional_string?(resource, "text") and optional_string?(resource, "blob") and
      optional_string?(resource, "mimeType") and optional_map?(resource, "_meta")
  end

  defp valid_resource?(_), do: false

  defp optional_string?(map, key), do: not Map.has_key?(map, key) or is_binary(map[key])

  defp optional_map?(map, key),
    do: not Map.has_key?(map, key) or (is_map(map[key]) and not is_struct(map[key]))

  defp completed_error(class) do
    {:ok,
     %{is_error: true, error: Error.new(class, "MCP returned an invalid or oversized result")}}
  end

  defp rejection_reason(reason) when is_atom(reason), do: reason
  defp rejection_reason(_), do: :source_unavailable

  defp error(reason) do
    class =
      cond do
        reason in [:invalid_context, :invalid_arguments, :invalid_input] ->
          :validation

        reason in [:scope_mismatch, :stale_source, :stale_snapshot, :tool_unavailable] ->
          :forbidden

        reason == :timeout ->
          :timeout

        reason == :unknown_outcome ->
          :unknown_outcome

        true ->
          :unsupported_capability
      end

    Error.new(class, "MCP tool call failed", details: %{code: Atom.to_string(reason)})
  end
end
