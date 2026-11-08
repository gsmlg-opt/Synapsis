defmodule Synapsis.Agent.Tools.SessionHistory do
  @moduledoc "Native bounded durable session history; never reads a live Worker."
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Synapsis.SessionHistory, as: Domain

  @name "synapsis::sessions_history"
  @names [@name]
  @revision 2
  @output_limit 1_048_576
  @context_keys [:session_id, :agent_id, :run_id, :incarnation, :catalog_revision]
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a

  def names, do: @names
  def revision, do: @revision
  def permission_level(name) when name in @names, do: :read

  def descriptors(context) do
    with :ok <- context_valid(context) do
      {:ok,
       Enum.map(@names, fn name ->
         %{
           tool_name: name,
           tool_revision: @revision,
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
      args = operation.arguments
      target = Map.get(args, "session_id", context.session_id)

      resource =
        Map.merge(
          %{"session_id" => target},
          Map.take(args, ~w(offset message_id pending_before limit include_tools))
        )

      {:ok,
       %{action: "session.history.read", resource: "session_history:" <> Jason.encode!(resource)}}
    end
  end

  @impl true
  def execute(%{backend_context: enriched} = operation) do
    ceiling = System.monotonic_time(:millisecond) + 5_000

    with {:ok, context} <- execution_context(enriched),
         {:ok, deadline} <- effect_deadline(enriched, ceiling),
         {:ok, _} <-
           classify(
             context,
             Synapsis.Agent.Tools.CatalogBinding.classification_operation(operation, context)
           ),
         operation = %{operation | backend_context: context},
         trusted = Map.take(context, [:session_id, :agent_id]),
         {:ok, %{text: text, page: page}} <-
           Domain.read_rendered(operation.arguments, trusted, domain_options(deadline)) do
      native = %{content: text, structured: page}

      if byte_size(Jason.encode!(native)) <= @output_limit and
           :erlang.external_size(native) <= @output_limit and
           deadline > System.monotonic_time(:millisecond),
         do: {:ok, native},
         else: failure(:output_limit)
    else
      {:error, reason} -> failure(reason)
    end
  rescue
    _ -> failure(:unavailable)
  catch
    _, _ -> failure(:unavailable)
  end

  def execute(_), do: failure(:invalid_context)

  @impl true
  def cancel(_operation), do: :ok

  defp description,
    do:
      "Read a durable session history window with pending input context. Defaults to the current persisted session and the recent 200 messages; limit is at most 1000. Offset counts backwards over durable rows. message_id selects a centered window and ignores offset. pending_before continues the independent pending page. include_tools defaults false. Reads one captured revision; uncommitted assistant deltas and live tool calls are absent."

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
        "offset" => %{
          "type" => "integer",
          "minimum" => 0,
          "description" => "Offset backwards from the durable tail; ignored with message_id."
        },
        "message_id" => %{
          "type" => "string",
          "minLength" => 36,
          "maxLength" => 36,
          "description" => "Exact durable message UUID for a centered history window."
        },
        "pending_before" => %{
          "type" => "integer",
          "minimum" => 1,
          "description" =>
            "Exclusive original append-position cursor from pendingInputs.nextBefore."
        },
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 1000, "default" => 200},
        "include_tools" => %{"type" => "boolean", "default" => false}
      },
      "required" => [],
      "additionalProperties" => false
    }
  end

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         uuid?(context[:session_id]) and opaque?(context[:agent_id], 256) and
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

  defp effect_deadline(%{effect_deadline: getter}, ceiling) when is_function(getter, 0) do
    with {:ok, %{deadline_ms: deadline, remaining_ms: remaining, paused: false}} <- getter.(),
         true <- is_integer(deadline) and is_integer(remaining) and remaining > 0 do
      {:ok, min(deadline, ceiling)}
    else
      {:error, _} = error -> error
      _ -> {:error, :timeout}
    end
  end

  defp effect_deadline(%{effect_deadline: _}, _), do: {:error, :invalid_context}
  defp effect_deadline(_, ceiling), do: {:ok, ceiling}

  defp domain_options(deadline) do
    case Application.get_env(:synapsis_agent, :filesystem_node) do
      node when is_binary(node) -> [deadline: deadline, node_executable: node]
      _ -> [deadline: deadline]
    end
  end

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

  defp input(%{tool_name: name, arguments: args}) when name in @names and is_map(args) do
    with {:ok, _} <- InputSchema.validate(schema(), args),
         :ok <- Domain.validate_window(args) do
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

  defp failure(%Error{} = error), do: {:error, error}

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

        reason
        when reason in [
               :malformed_metadata,
               :malformed_history,
               :unsupported_projection,
               :invalid_record
             ] ->
          :malformed_result

        reason when reason in [:output_limit, :scan_limit, :payload_too_large] ->
          :budget_exceeded

        _ ->
          :execution_failure
      end

    {:error,
     Error.new(class, "Session history read failed", details: %{code: Atom.to_string(reason)})}
  end
end
