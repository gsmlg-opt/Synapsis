defmodule Synapsis.Agent.Tools.Swarm do
  @moduledoc """
  Native saved teammate metadata and session PubSub notification tools.

  These capabilities are independent of native child collaboration. Session UUID
  and configured sender come only from trusted host context; opaque run IDs do
  not become domain identities. Saved tool names never admit native tools.
  Host policy must enforce exact overrides even for the `:none` permission level.
  Native Execution owns effect cancellation; completed metadata changes or
  published notifications cannot be rolled back.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema, ToolEffects}
  alias Synapsis.Swarm, as: Domain

  @message "synapsis::swarm_message"
  @teammate "synapsis::teammate"
  @delete "synapsis::team_delete"
  @names [@message, @teammate, @delete]
  @context_keys [:session_id, :sender, :run_id, :incarnation, :catalog_revision]
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a

  def names, do: @names
  def permission_level(name) when name in @names, do: :none

  def descriptors(context) do
    with :ok <- context_valid(context) do
      {:ok, Enum.map(@names, &descriptor(&1, context))}
    else
      {:error, reason} -> failure(reason)
    end
  end

  def classify(context, operation) do
    with :ok <- context_valid(context),
         :ok <- matching_scope(context, operation),
         :ok <- input(operation) do
      {action, suffix} =
        case operation.tool_name do
          @message ->
            {"swarm.message", "messages:" <> operation.arguments["to"]}

          @teammate ->
            suffix =
              if Map.has_key?(operation.arguments, "name"),
                do: "teammates:" <> operation.arguments["name"],
                else: "teammates"

            {"swarm.teammate." <> operation.arguments["action"], suffix}

          @delete ->
            {"swarm.team.delete", "teammates"}
        end

      {:ok, %{action: action, resource: "session:#{context.session_id}:swarm:#{suffix}"}}
    end
  end

  @impl true
  def execute(%{backend_context: enriched} = operation) do
    with {:ok, context} <- execution_context(enriched),
         {:ok, _} <-
           classify(
             context,
             Synapsis.Agent.Tools.CatalogBinding.classification_operation(operation, context)
           ),
         operation = %{operation | backend_context: context},
         {:ok, public} <- run(context, operation) do
      result = %{content: text(operation, public), structured: public}

      case ToolEffects.validate_output(%{payload: result}) do
        {:ok, _} -> {:ok, result}
        {:error, _} -> failure(:output_limit)
      end
    else
      {:error, reason} -> failure(reason)
    end
  rescue
    _ -> failure(:unknown_outcome)
  catch
    :exit, _ -> failure(:unknown_outcome)
  end

  def execute(_), do: failure(:invalid_input)

  @impl true
  def cancel(_), do: :ok

  defp descriptor(name, context) do
    %{
      tool_name: name,
      tool_revision: 1,
      description: description(name),
      schema: schema(name),
      safety: %{read_only: false, retry_safe: false, parallel_safe: false},
      backend: __MODULE__,
      backend_context: context
    }
  end

  defp description(@message),
    do:
      "Publish a session swarm notification; delivery, durability and turn activation are not guaranteed."

  defp description(@teammate),
    do: "Create, list, get or update saved teammate metadata; no agent process is started."

  defp description(@delete),
    do: "Delete saved teammate metadata for this session; no agent process is terminated."

  defp schema(name) do
    {properties, required} =
      case name do
        @message ->
          {%{
             "to" => string(256, 1),
             "content" => string(32768),
             "type" => %{"type" => "string", "enum" => ~w(request response notify)},
             "in_reply_to" => string(256, 1)
           }, ["to", "content"]}

        @teammate ->
          {%{
             "action" => %{"type" => "string", "enum" => ~w(create list get update)},
             "name" => string(256, 1),
             "prompt" => string(8192),
             "model" => string(256, 1),
             "tools" => %{"type" => "array", "maxItems" => 32, "items" => string(256, 1)}
           }, ["action"]}

        @delete ->
          {%{}, []}
      end

    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp string(max, min \\ 0), do: %{"type" => "string", "minLength" => min, "maxLength" => max}

  defp input(%{tool_name: name, arguments: args}) when name in @names and is_map(args) do
    with {:ok, _} <- InputSchema.validate(schema(name), args) do
      case name do
        @message -> Domain.validate_message(args)
        @teammate -> Domain.validate_teammate(args)
        @delete -> :ok
      end
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp input(_), do: {:error, :invalid_input}

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         uuid?(context.session_id) and opaque?(context.sender, 256) and
         opaque?(context.run_id, 4096) and is_integer(context.incarnation) and
         context.incarnation > 0 and is_integer(context.catalog_revision) and
         context.catalog_revision > 0,
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp context_valid(_), do: {:error, :invalid_context}

  defp execution_context(context) when is_map(context) and not is_struct(context) do
    if Map.keys(context) -- (@context_keys ++ @native_keys) == [],
      do: {:ok, Map.take(context, @context_keys)},
      else: {:error, :invalid_context}
  end

  defp execution_context(_), do: {:error, :invalid_context}

  defp matching_scope(context, operation) when is_map(operation) do
    Synapsis.Agent.Tools.CatalogBinding.host(context, operation, __MODULE__, 1, @native_keys)
  end

  defp matching_scope(_, _), do: {:error, :scope_mismatch}

  defp run(context, %{tool_name: @message, arguments: args}),
    do: Domain.message(context.session_id, context.sender, args)

  defp run(context, %{tool_name: @teammate, arguments: args}),
    do: Domain.teammate(context.session_id, args)

  defp run(context, %{tool_name: @delete}), do: Domain.delete_team(context.session_id)

  defp text(%{tool_name: @message}, public),
    do: "Published session notification #{public.message_id} to #{public.to}."

  defp text(%{tool_name: @delete}, public),
    do: "Deleted #{public.count} saved teammate metadata record(s)."

  defp text(%{tool_name: @teammate}, public), do: Jason.encode!(public)

  defp uuid?(id) when is_binary(id), do: Ecto.UUID.cast(id) == {:ok, id}
  defp uuid?(_), do: false

  defp opaque?(value, limit),
    do:
      is_binary(value) and byte_size(value) in 1..limit and
        String.valid?(value) and String.trim(value) != "" and not String.contains?(value, "\0")

  defp failure(reason) do
    class =
      case reason do
        :scope_mismatch -> :forbidden
        value when value in [:invalid_input, :invalid_context, :invalid_scope] -> :validation
        :not_found -> :not_found
        :timeout -> :timeout
        :unavailable -> :unsupported_capability
        :output_limit -> :budget_exceeded
        :unknown_outcome -> :unknown_outcome
        _ -> :malformed_result
      end

    {:error,
     Error.new(class, "Swarm metadata or notification operation failed",
       details: %{code: Atom.to_string(reason)}
     )}
  end
end
