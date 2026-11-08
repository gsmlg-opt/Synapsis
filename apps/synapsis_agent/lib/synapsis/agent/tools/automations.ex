defmodule Synapsis.Agent.Tools.Automations do
  @moduledoc """
  Native scheduler status, automation configuration and attributed terminal history.

  Trusted configured execution route, persisted session and opaque native run
  identity stay distinct. Revision, scope, native grants and host read permission
  remain required. Status observes only the node-local scheduler process and its
  last reload outcome; it does not establish configuration health, execution
  readiness, or an individual job's status. No mutations or triggers are exposed.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.AutomationDirectory, as: Domain

  @name "synapsis::automations"
  @revision 2
  @context_keys [:session_id, :requester_name, :run_id, :incarnation, :catalog_revision]
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @errors ~w(invalid_input invalid_context scope_mismatch timeout requester_unavailable
    storage_unavailable scheduler_unavailable invalid_config invalid_cursor stale_cursor scan_limit output_too_large not_found)a
  @output_limit 65_536

  def names, do: [@name]
  def revision, do: @revision
  def permission_level(@name), do: :read

  def descriptors(context) do
    with :ok <- context_valid(context) do
      {:ok,
       [
         %{
           tool_name: @name,
           tool_revision: @revision,
           description:
             "Read-only status of the node-local scheduler process and its last reload outcome; list/get public routine and legacy heartbeat configuration visible to the configured execution route, including disabled entries. Read source-attributed terminal run history with runs. Older records lacking source cannot be assigned or returned; empty pages do not establish complete historical emptiness. Status is not job or configuration health. No mutations or triggers.",
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
      resource =
        %{
          "session_id" => context.session_id,
          "requester_name" => context.requester_name,
          "action" => operation.arguments["action"]
        }
        |> Map.merge(resource_arguments(operation.arguments))

      {:ok,
       %{
         action: "automation." <> operation.arguments["action"],
         resource: "automation:" <> Jason.encode!(resource)
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
         {:ok, result} <- read(operation.arguments, trusted) do
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

  defp read(%{"action" => "status"}, _trusted) do
    with {:ok, scheduler} <- LocalScheduler.public_status(),
         do: {:ok, %{scheduler: scheduler}}
  end

  defp read(arguments, trusted), do: Domain.read(arguments, trusted)

  defp resource_arguments(%{"action" => "status"}), do: %{"engine" => "node_local"}

  defp resource_arguments(%{"action" => "list"} = args) do
    page = %{"limit" => Map.get(args, "limit", 20)}
    if Map.has_key?(args, "cursor"), do: Map.put(page, "cursor", args["cursor"]), else: page
  end

  defp resource_arguments(%{"action" => "runs"} = args),
    do: Map.take(args, ~w(source id limit cursor run_id)) |> Map.put_new("limit", 20)

  defp resource_arguments(%{"action" => "get"} = args), do: Map.take(args, ~w(source id))

  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ["status", "list", "get", "runs"]},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
        "cursor" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => 4_096,
          "description" =>
            "Opaque continuation for this requester and the selected list or runs query."
        },
        "source" => %{"type" => "string", "enum" => ["routine", "heartbeat"]},
        "id" => %{
          "type" => "string",
          "description" => "Canonical source-qualified automation UUID."
        },
        "run_id" => %{
          "type" => "string",
          "description" => "Optional exact canonical terminal run UUID for runs."
        }
      },
      "required" => ["action"],
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
    Synapsis.Agent.Tools.CatalogBinding.host(
      context,
      operation,
      __MODULE__,
      @revision,
      @native_keys
    )
  end

  defp matching_scope(_, _), do: {:error, :scope_mismatch}

  defp input(%{tool_name: @name, arguments: args}) do
    with :ok <- validate_arguments(args),
         {:ok, _} <- InputSchema.validate(schema(), args) do
      :ok
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp input(_), do: {:error, :invalid_input}

  defp validate_arguments(%{"action" => "status"} = args) when map_size(args) == 1, do: :ok
  defp validate_arguments(args), do: Domain.validate(args)

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

        reason when reason in [:requester_unavailable, :not_found] ->
          :not_found

        :invalid_config ->
          :malformed_result

        reason when reason in [:scan_limit, :output_too_large] ->
          :budget_exceeded

        _ ->
          :execution_failure
      end

    {:error,
     Error.new(class, "Automation configuration read failed",
       details: %{code: Atom.to_string(reason)}
     )}
  end
end
