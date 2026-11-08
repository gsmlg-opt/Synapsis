defmodule Synapsis.Agent.Tools.SessionStatus do
  @moduledoc """
  Native read-only session observation. Auto observes the Worker first, falling
  back to durable metadata only for point-in-time unregistered absence. Live
  phase is the coarse actual statem state, not an exact provider/tool stage;
  active is the native runtime flag. Committed native usage is observed outside
  the Worker mailbox; unavailable metrics and cost remain explicit.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Synapsis.SessionStatus, as: Domain
  alias Synapsis.Agent.Runtime.SessionUsage

  @name "synapsis::session_status"
  @names [@name]
  @output_limit 65_536
  @context_keys [:session_id, :agent_id, :run_id, :incarnation, :catalog_revision]
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a

  def names, do: @names
  def permission_level(name) when name in @names, do: :read

  def descriptors(context) do
    with :ok <- context_valid(context) do
      {:ok,
       Enum.map(@names, fn name ->
         %{
           tool_name: name,
           tool_revision: 1,
           description: description(),
           schema: schema(),
           safety: %{read_only: true, retry_safe: true, parallel_safe: true},
           backend: __MODULE__,
           backend_context: context
         }
       end)}
    else
      {:error, reason} -> failure(reason)
    end
  end

  def classify(context, operation) do
    with :ok <- context_valid(context),
         :ok <- matching_scope(context, operation),
         :ok <- input(operation) do
      resource = %{
        "requester_session_id" => context.session_id,
        "requester_agent_id" => context.agent_id,
        "session_id" => Map.get(operation.arguments, "session_id", context.session_id),
        "source" => Map.get(operation.arguments, "source", "auto")
      }

      {:ok,
       %{action: "session.status.read", resource: "session_status:" <> Jason.encode!(resource)}}
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
         trusted = Map.take(context, [:session_id, :agent_id]),
         {:ok, deadline} <- read_deadline(enriched[:effect_deadline]),
         {:ok, result} <- observe(operation.arguments, trusted, deadline),
         id = Map.get(operation.arguments, "session_id", context.session_id),
         {:ok, usage} <- SessionUsage.read(id, deadline),
         result = Map.put(result, :usage, usage) do
      native = %{content: Jason.encode!(result), structured: result}

      bounded_result(native, deadline)
    else
      {:error, reason} -> failure(reason)
    end
  rescue
    _ -> failure(:unavailable)
  catch
    _, _ -> failure(:unavailable)
  end

  def execute(_), do: failure(:invalid_context)

  defp bounded_result(native, deadline) do
    with {:ok, json} <- Jason.encode(native),
         true <- byte_size(json) <= @output_limit do
      if System.monotonic_time(:millisecond) < deadline,
        do: {:ok, native},
        else: failure(:timeout)
    else
      false -> failure(:output_limit)
      _ -> failure(:malformed_metadata)
    end
  end

  defp read_deadline(nil), do: {:ok, System.monotonic_time(:millisecond) + 5_000}

  defp read_deadline(getter) when is_function(getter, 0) do
    with {:ok, %{deadline_ms: deadline, remaining_ms: remaining, paused: false}} <- getter.(),
         true <- is_integer(deadline) and is_integer(remaining) and remaining > 0,
         true <- deadline > System.monotonic_time(:millisecond) do
      {:ok, min(deadline, System.monotonic_time(:millisecond) + 5_000)}
    else
      _ -> {:error, :timeout}
    end
  end

  defp read_deadline(_), do: {:error, :invalid_context}

  defp observe(input, context, deadline) do
    id = Map.get(input, "session_id", context.session_id)

    case Map.get(input, "source", "auto") do
      "durable" ->
        Domain.read(input, context, deadline: deadline)

      "live" ->
        Synapsis.Session.Worker.public_status(id, deadline: deadline)

      "auto" ->
        case Synapsis.Session.Worker.public_status(id, deadline: deadline) do
          {:error, :not_running} ->
            with {:ok, result} <- Domain.read(input, context, deadline: deadline),
                 do: {:ok, Map.put(result, :live_observation, "unregistered")}

          result ->
            result
        end
    end
  end

  @impl true
  def cancel(_operation), do: :ok

  defp description,
    do:
      "Read session status for an exact persisted UUID, defaulting to the current session. Source auto (default) observes live Worker-owned metadata and coarse runtime status/phase/active, falling back to durable metadata only when no Worker is registered, marked live_observation=unregistered. Source live never falls back; durable reads the saved record, whose status is not liveness. Live phase is the actual coarse state machine state, not an exact tool/provider stage. Includes committed native token usage for retained runs, observed sequentially across runs; unknown metrics are null and cached/reasoning counts are subsets of input/output. This is not an instantaneous live or all-history bill. Cost is unavailable. One shared five-second deadline; no model changes."

  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "session_id" => %{
          "type" => "string",
          "minLength" => 36,
          "maxLength" => 36,
          "description" =>
            "Optional exact persisted session UUID; defaults to the current session."
        },
        "source" => %{
          "type" => "string",
          "enum" => ["auto", "live", "durable"],
          "default" => "auto"
        }
      },
      "required" => [],
      "additionalProperties" => false
    }
  end

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         uuid?(context[:session_id]) and opaque?(context[:agent_id], 255) and
         opaque?(context[:run_id], 4096) and
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

  defp input(%{tool_name: name, arguments: args}) when name in @names and is_map(args) do
    with {:ok, _} <- InputSchema.validate(schema(), args),
         :ok <- Domain.validate(args) do
      :ok
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp input(_), do: {:error, :invalid_input}
  defp uuid?(id) when is_binary(id), do: match?({:ok, ^id}, Ecto.UUID.cast(id))
  defp uuid?(_), do: false

  defp opaque?(value, limit),
    do:
      is_binary(value) and byte_size(value) in 1..limit and String.valid?(value) and
        String.trim(value) != "" and not String.contains?(value, "\0")

  defp failure(reason) do
    class =
      case reason do
        :scope_mismatch ->
          :forbidden

        reason when reason in [:invalid_input, :invalid_context] ->
          :validation

        :timeout ->
          :timeout

        :not_found ->
          :not_found

        :malformed_metadata ->
          :malformed_result

        reason when reason in [:output_limit, :scan_limit, :payload_too_large] ->
          :budget_exceeded

        _ ->
          :execution_failure
      end

    {:error,
     Error.new(class, "Session status read failed", details: %{code: Atom.to_string(reason)})}
  end
end
