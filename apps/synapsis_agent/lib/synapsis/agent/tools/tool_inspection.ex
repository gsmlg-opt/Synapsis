defmodule Synapsis.Agent.Tools.ToolInspection do
  @moduledoc """
  Explicit read-only inspection of a run's selected, issued public tool metadata.

  The frozen view includes selected deferred tools. It carries no target backend
  or execution callback and never publishes or invokes the described tool.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema, ToolCatalog}
  alias Backplane.AgentRuntime.Codex.Session
  alias Backplane.AiProtocol.Validation
  alias Synapsis.Agent.Tools.{CatalogBinding, MCP}

  @name "synapsis::tool_describe"
  @context_keys [:identity, :session_binding, :inventory, :mcp_sources]
  @identity_keys [:caller, :session_id, :run_id, :incarnation, :catalog_revision]
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @output_limit 65_536

  def names, do: [@name]
  def permission_level(@name), do: :read

  def descriptors(context) do
    with :ok <- context_valid(context) do
      {:ok,
       [
         %{
           tool_name: @name,
           tool_revision: 1,
           description:
             "Read complete frozen public metadata by exact canonical name for an already selected tool, including explicitly deferred tools. Does not publish or execute the target.",
           schema: schema(),
           safety: %{read_only: true, retry_safe: true, parallel_safe: true},
           backend: __MODULE__,
           backend_context: context
         }
       ]}
    else
      {:error, reason} -> failure(reason)
    end
  end

  @doc "Freezes the complete issued selection before native deferred publication."
  def prepare(bundle, names, identity, binding) do
    if @name in names do
      tools = bundle.registry.tools
      inventory = Map.new(names, &{&1, public_document(Map.fetch!(tools, &1))})

      sources =
        Map.new(
          for name <- names,
              %{backend: MCP, backend_context: %{source: source}} <- [Map.fetch!(tools, name)],
              do: {name, source}
        )

      context = %{
        identity: identity,
        session_binding: binding,
        inventory: inventory,
        mcp_sources: sources
      }

      with :ok <- context_valid(context) do
        descriptors =
          Enum.map(names, fn name ->
            descriptor = Map.fetch!(tools, name)
            if name == @name, do: %{descriptor | backend_context: context}, else: descriptor
          end)

        ToolCatalog.admit_batch(descriptors, mode: :strict, authority: bundle.authority)
      else
        {:error, reason} -> failure(reason)
      end
    else
      {:ok, bundle}
    end
  end

  def classify(context, operation) do
    with :ok <- context_valid(context),
         :ok <-
           CatalogBinding.host(context, operation, __MODULE__, 1, @native_keys, context.identity),
         true <- is_map(operation.backend_context[:catalog_snapshot]),
         {:ok, _} <- Session.validate(context.session_binding, operation),
         {:ok, _} <- InputSchema.validate(schema(), operation[:arguments]),
         true <- operation[:tool_name] === @name,
         {:ok, _} <- lookup(context, operation.arguments["tool_name"]) do
      {:ok,
       %{
         action: "tools.describe",
         resource:
           "catalog:session:#{context.identity.session_id}:tool:#{operation.arguments["tool_name"]}",
         permission_level: :read
       }}
    else
      false -> {:error, :scope_mismatch}
      error -> error
    end
  end

  @impl true
  def execute(%{backend_context: enriched} = operation) do
    with {:ok, context} <- execution_context(enriched),
         {:ok, _} <- classify(context, operation),
         {:ok, document} <- lookup(context, operation.arguments["tool_name"]),
         :ok <- Validation.term(document),
         {:ok, encoded} <- Jason.encode_to_iodata(document),
         true <- IO.iodata_length(encoded) <= @output_limit do
      {:ok, %{content: IO.iodata_to_binary(encoded)}}
    else
      false -> failure(:output_too_large)
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} when is_atom(reason) -> failure(reason)
      _ -> failure(:malformed_result)
    end
  catch
    :exit, _ -> failure(:source_unavailable)
  end

  def execute(_), do: failure(:invalid_context)

  @impl true
  def cancel(_), do: :ok

  defp public_document(descriptor) do
    document = %{
      "tool_name" => descriptor.tool_name,
      "tool_revision" => descriptor.tool_revision,
      "description" => Map.get(descriptor, :description, "")
    }

    document =
      if descriptor[:codex_input_kind] == :custom,
        do: Map.merge(document, %{"input_kind" => "custom", "format" => descriptor.codex_format}),
        else: Map.merge(document, %{"input_kind" => "function", "schema" => descriptor.schema})

    document =
      case descriptor[:codex_output_schema] do
        nil -> document
        output -> Map.put(document, "output_schema", output)
      end

    case descriptor do
      %{backend: MCP, backend_context: %{source: source}} ->
        tool =
          Enum.find(
            source.tools,
            &("mcp::#{source.source_id}::#{&1.raw_name}" == descriptor.tool_name)
          )

        case tool do
          %{source_metadata: metadata} ->
            public_source = %{
              "kind" => "mcp",
              "source_id" => source.source_id,
              "raw_name" => tool.raw_name,
              "server_name" => metadata.server_name,
              "instructions_status" => metadata.instructions_status
            }

            public_source =
              if metadata.instructions_status == "available",
                do: Map.put(public_source, "instructions", metadata.instructions),
                else: public_source

            Map.put(document, "source", public_source)

          _ ->
            document
        end

      _ ->
        document
    end
  end

  defp lookup(context, name) do
    with {:ok, document} <- Map.fetch(context.inventory, name),
         :ok <- source_current(context.mcp_sources[name]) do
      {:ok, document}
    else
      :error -> {:error, :tool_unavailable}
      error -> error
    end
  end

  defp source_current(nil), do: :ok
  defp source_current(source), do: MCP.source_current(source)

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    with true <- Enum.sort(Map.keys(context)) == Enum.sort(@context_keys),
         %{
           identity: identity,
           session_binding: binding,
           inventory: inventory,
           mcp_sources: sources
         } <- context,
         true <- is_map(identity) and not is_struct(identity),
         true <- Enum.sort(Map.keys(identity)) == Enum.sort(@identity_keys),
         true <- Enum.all?([:caller, :session_id, :run_id], &opaque?(identity[&1])),
         true <- is_integer(identity.incarnation) and identity.incarnation > 0,
         true <- is_integer(identity.catalog_revision) and identity.catalog_revision > 0,
         true <- is_map(binding) and is_pid(binding[:session]),
         true <-
           binding[:run_id] === identity.run_id and
             binding[:run_incarnation] === identity.incarnation,
         true <- is_map(inventory) and not is_struct(inventory),
         true <- is_map(sources) and not is_struct(sources),
         true <-
           Enum.all?(inventory, fn {name, doc} ->
             is_binary(name) and is_map(doc) and not is_struct(doc)
           end),
         true <-
           Enum.all?(sources, fn {name, source} ->
             Map.has_key?(inventory, name) and is_map(source)
           end) do
      :ok
    else
      _ -> {:error, :invalid_context}
    end
  end

  defp context_valid(_), do: {:error, :invalid_context}

  defp execution_context(context) when is_map(context) and not is_struct(context) do
    if Map.keys(context) -- (@context_keys ++ @native_keys) == [],
      do: {:ok, Map.take(context, @context_keys)},
      else: {:error, :invalid_context}
  end

  defp execution_context(_), do: {:error, :invalid_context}

  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "tool_name" => %{"type" => "string", "minLength" => 1, "maxLength" => 4_096}
      },
      "required" => ["tool_name"],
      "additionalProperties" => false
    }
  end

  defp opaque?(value),
    do:
      is_binary(value) and byte_size(value) in 1..4_096 and String.valid?(value) and
        String.trim(value) != "" and not String.contains?(value, "\0")

  defp failure(reason) do
    class =
      case reason do
        :scope_mismatch -> :forbidden
        :tool_unavailable -> :not_found
        :stale_source -> :forbidden
        :source_unavailable -> :unsupported_capability
        :output_too_large -> :budget_exceeded
        :malformed_result -> :malformed_result
        _ -> :validation
      end

    {:error,
     Error.new(class, "Tool metadata inspection failed", details: %{code: Atom.to_string(reason)})}
  end
end
