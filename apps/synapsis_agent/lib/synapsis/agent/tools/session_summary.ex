defmodule Synapsis.Agent.Tools.SessionSummary do
  @moduledoc """
  Native read-only session summary candidates, without legacy tool dispatch.

  A trusted persisted session UUID is independent of the opaque native run ID.
  When Conversation supplies its resource-owner capability, its scope-checked
  live transcript includes the current turn. A missing capability deliberately
  uses the labelled durable transcript; an invalid supplied owner fails closed.

  Slow provider collection runs inside the native effect process. Execution
  owns cancellation, and the core summary domain cleans up its linked provider
  stream when that process dies. Candidates are never automatically saved.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Memory.SessionSummary, as: Domain
  alias Synapsis.Session.Store

  @name "synapsis::session_summarize"
  @context_keys [:session_id, :run_id, :incarnation, :catalog_revision]
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
             "Summarize current session context into candidate memories for review. Never saves candidates.",
           schema: Domain.schema(),
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
      {:ok, %{action: "session.summarize", resource: "session:#{context.session_id}:summary"}}
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
         :ok <- persisted_session(context.session_id),
         {:ok, opts} <- transcript_options(enriched, operation),
         {:ok, summary} <- Domain.summarize(context.session_id, operation.arguments, opts) do
      result = %{
        content:
          "Generated #{length(summary.candidates)} memory candidate(s) for review; candidates were not saved.\n" <>
            Jason.encode!(summary),
        structured: summary
      }

      if byte_size(Jason.encode!(result)) <= @output_limit,
        do: {:ok, result},
        else: failure(:output_limit)
    else
      {:error, reason} -> failure(reason)
    end
  rescue
    _ -> failure(:summary_failed)
  catch
    :exit, _ -> failure(:summary_failed)
    :throw, _ -> failure(:summary_failed)
  end

  def execute(_), do: failure(:invalid_input)

  @impl true
  def cancel(_operation), do: :ok

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         uuid?(context[:session_id]) and opaque?(context[:run_id]) and
         is_integer(context[:incarnation]) and context.incarnation > 0 and
         is_integer(context[:catalog_revision]) and context.catalog_revision > 0,
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp context_valid(_), do: {:error, :invalid_context}

  defp uuid?(id) when is_binary(id), do: match?({:ok, ^id}, Ecto.UUID.cast(id))
  defp uuid?(_), do: false

  defp opaque?(value),
    do:
      is_binary(value) and byte_size(value) in 1..4096 and String.valid?(value) and
        String.trim(value) != "" and not String.contains?(value, "\0")

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
    with {:ok, _} <- InputSchema.validate(Domain.schema(), args),
         :ok <- Domain.validate(args),
         do: :ok
  end

  defp input(_), do: {:error, :invalid_input}

  defp persisted_session(id) do
    case Store.get_meta(id) do
      {:ok, %{id: ^id}} -> :ok
      {:error, :not_found} -> {:error, :not_found}
      _ -> {:error, :storage_failed}
    end
  end

  defp transcript_options(enriched, operation) do
    case Map.fetch(enriched, :resource_owner_pid) do
      :error -> {:ok, []}
      {:ok, owner} when is_pid(owner) -> live_messages(owner, operation)
      _ -> {:error, :scope_mismatch}
    end
  end

  defp live_messages(owner, operation) do
    # Same status request as Conversation.status/1, with an explicit bound.
    # No call to Session.Worker or provider wire-format conversion is needed.
    case GenServer.call(owner, :status, 1_000) do
      %{
        run: %{run_id: run_id, incarnation: incarnation},
        catalog_revision: revision,
        messages: messages
      }
      when run_id === operation.run_id and incarnation === operation.incarnation and
             revision === operation.catalog_revision ->
        convert_snapshot(messages, operation.arguments)

      _ ->
        {:error, :scope_mismatch}
    end
  catch
    :exit, _ -> {:error, :scope_mismatch}
  end

  defp convert_snapshot(messages, arguments) when is_list(messages) do
    # Keep the selected snapshot chronological here; the domain preserves the
    # legacy reverse chronology when it applies recent selection. Old history
    # must not prevent a bounded recent summary or undergo unused conversion.
    selected =
      if arguments["scope"] == "recent", do: Enum.take(messages, -10), else: messages

    cond do
      length(Enum.take(selected, 201)) > 200 ->
        {:error, :message_limit}

      :erlang.external_size(selected) > 262_144 ->
        {:error, :transcript_limit}

      true ->
        case ProviderMessages.to_host(selected) do
          {:ok, host} -> {:ok, [messages: host]}
          {:error, _} -> {:error, :malformed_transcript}
        end
    end
  end

  defp convert_snapshot(_, _), do: {:error, :malformed_transcript}

  defp failure(%Error{}), do: failure(:invalid_input)

  defp failure(reason) do
    class =
      case reason do
        :scope_mismatch ->
          :forbidden

        reason when reason in [:invalid_context, :invalid_input] ->
          :validation

        :not_found ->
          :not_found

        :timeout ->
          :timeout

        reason when reason in [:output_limit, :transcript_limit, :message_limit, :worker_limit] ->
          :budget_exceeded

        _ ->
          :execution_failure
      end

    {:error, Error.new(class, "Session summary failed", details: %{code: Atom.to_string(reason)})}
  end
end
