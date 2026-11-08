defmodule Synapsis.Agent.Tools.AgentDirectory do
  @moduledoc """
  Native read-only directory of enabled configured Agents.

  Trusted context separates configured requester name, persisted session UUID
  and opaque native run identity. The directory describes configuration, not a
  child roster or a grant to spawn any Agent. Native grants, exact revisions and
  the host read-permission gate remain required.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Synapsis.AgentDirectory, as: Domain

  @name "synapsis::agents_list"
  @context_keys [:session_id, :requester_name, :run_id, :incarnation, :catalog_revision]
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @errors ~w(invalid_input invalid_context scope_mismatch timeout requester_unavailable
    storage_unavailable invalid_config invalid_cursor stale_cursor scan_limit output_too_large)a
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
             "List bounded pages of enabled configured Agents with public IDs, names and display labels. This directory does not describe native children or grant spawn eligibility.",
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

  def classify(context, operation) do
    with :ok <- context_valid(context),
         :ok <- matching_scope(context, operation),
         :ok <- input(operation) do
      resource = %{
        "session_id" => context.session_id,
        "requester_name" => context.requester_name,
        "limit" => Map.get(operation.arguments, "limit", 100)
      }

      resource =
        if Map.has_key?(operation.arguments, "cursor"),
          do: Map.put(resource, "cursor", operation.arguments["cursor"]),
          else: resource

      {:ok,
       %{
         action: "agent.directory.list",
         resource: "agent_directory:" <> Jason.encode!(resource)
       }}
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
         trusted = Map.take(context, [:session_id, :requester_name]),
         {:ok, result} <- Domain.list(operation.arguments, trusted) do
      output(%{content: Jason.encode!(result), structured: result})
    else
      {:error, reason} -> failure(reason)
    end
  rescue
    _ -> failure(:storage_unavailable)
  catch
    _, _ -> failure(:storage_unavailable)
  end

  def execute(_), do: failure(:invalid_context)

  @impl true
  def cancel(_operation), do: :ok

  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
        "cursor" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => 4_096,
          "description" => "Opaque continuation cursor returned for this configured requester."
        }
      },
      "required" => [],
      "additionalProperties" => false
    }
  end

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         uuid?(context[:session_id]) and name?(context[:requester_name]) and
         opaque?(context[:run_id]) and
         is_integer(context[:incarnation]) and context.incarnation > 0 and
         is_integer(context[:catalog_revision]) and context.catalog_revision > 0,
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

  defp input(%{tool_name: @name, arguments: args}) do
    with :ok <- Domain.validate(args),
         {:ok, _} <- InputSchema.validate(schema(), args) do
      :ok
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp input(_), do: {:error, :invalid_input}

  defp output(result) do
    case Jason.encode(result) do
      {:ok, encoded} when byte_size(encoded) <= @output_limit -> {:ok, result}
      _ -> failure(:output_too_large)
    end
  end

  defp name?(name),
    do:
      is_binary(name) and byte_size(name) in 1..256 and String.valid?(name) and
        Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, name)

  defp opaque?(value),
    do:
      is_binary(value) and byte_size(value) in 1..4_096 and String.valid?(value) and
        String.trim(value) != "" and not String.contains?(value, "\0")

  defp uuid?(id) when is_binary(id), do: match?({:ok, ^id}, Ecto.UUID.cast(id))
  defp uuid?(_), do: false

  defp failure(reason) do
    reason = if reason in @errors, do: reason, else: :storage_unavailable

    class =
      case reason do
        :scope_mismatch ->
          :forbidden

        reason
        when reason in [:invalid_input, :invalid_context, :invalid_cursor, :stale_cursor] ->
          :validation

        :timeout ->
          :timeout

        :requester_unavailable ->
          :not_found

        :invalid_config ->
          :malformed_result

        reason when reason in [:scan_limit, :output_too_large] ->
          :budget_exceeded

        _ ->
          :execution_failure
      end

    {:error,
     Error.new(class, "Configured Agent directory read failed",
       details: %{code: Atom.to_string(reason)}
     )}
  end
end
