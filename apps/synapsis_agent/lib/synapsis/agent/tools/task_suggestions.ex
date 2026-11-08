defmodule Synapsis.Agent.Tools.TaskSuggestions do
  @moduledoc "Native ephemeral follow-up proposals; recording never starts execution."
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Synapsis.TaskSuggestions, as: Domain

  @create "synapsis::suggest_task"
  @dismiss "synapsis::dismiss_task"
  @names [@create, @dismiss]
  @context_keys [:session_id, :agent_id, :cwd, :run_id, :incarnation, :catalog_revision]
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @output_limit 65_536

  def names, do: @names
  def permission_level(name) when name in @names, do: :write

  def descriptors(context) do
    with :ok <- context_valid(context) do
      {:ok,
       Enum.map(@names, fn name ->
         %{
           tool_name: name,
           tool_revision: 1,
           description: description(name),
           schema: schema(name),
           safety: %{read_only: false, retry_safe: name == @dismiss, parallel_safe: false},
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
         {:ok, action, normalized} <- input(operation, context) do
      target = Map.take(context, [:session_id, :agent_id])

      resource =
        case action do
          :create -> Map.put(target, :candidate, Map.drop(normalized, [:session_id, :agent_id]))
          :dismiss -> Map.put(target, :task_id, normalized.task_id)
        end

      {:ok,
       %{
         action: "task_suggestion." <> Atom.to_string(action),
         resource: "task_suggestion:" <> Jason.encode!(resource)
       }}
    end
  end

  @impl true
  def execute(%{backend_context: enriched} = operation) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    with {:ok, context} <- execution_context(enriched),
         {:ok, _} <-
           classify(
             context,
             Synapsis.Agent.Tools.CatalogBinding.classification_operation(operation, context)
           ),
         operation = %{operation | backend_context: context},
         {:ok, action, _} <- input(operation, context),
         {:ok, result} <-
           apply(Domain, action, [operation.arguments, trusted(context), [deadline: deadline]]) do
      native = %{content: Jason.encode!(result), structured: result}

      if byte_size(Jason.encode!(native)) <= @output_limit and
           System.monotonic_time(:millisecond) < deadline,
         do: {:ok, native},
         else: failure(:unknown_outcome)
    else
      {:error, reason} -> failure(reason)
    end
  rescue
    _ -> failure(:unknown_outcome)
  catch
    _, _ -> failure(:unknown_outcome)
  end

  def execute(_), do: failure(:invalid_context)

  @impl true
  def cancel(_operation), do: :ok

  defp description(@create),
    do:
      "Record a pending suggestion for a concrete follow-up, without starting work or creating a session. Supply a stand-alone prompt. cwd defaults to the current project folder and must be absolute. Suggestions are process-local and disappear on restart. The operator can start it in a new session in this folder from the host UI; this tool records a proposal only."

  defp description(@dismiss),
    do:
      "Dismiss a pending suggestion from this source session and agent. Repeated or missing task IDs return dismissed=false. Optional reason explains the request but is not retained. Does not execute work."

  defp schema(@create) do
    %{
      "type" => "object",
      "properties" => %{
        "title" => string(1, 60),
        "prompt" => string(1, 32_768),
        "tldr" => string(1, 1_024),
        "cwd" =>
          Map.put(
            string(1, 4_096),
            "description",
            "Absolute follow-up folder; defaults to current project cwd."
          )
      },
      "required" => ~w(title prompt tldr),
      "additionalProperties" => false
    }
  end

  defp schema(@dismiss) do
    %{
      "type" => "object",
      "properties" => %{"task_id" => string(1, 128), "reason" => string(0, 1_024)},
      "required" => ["task_id"],
      "additionalProperties" => false
    }
  end

  defp string(min, max), do: %{"type" => "string", "minLength" => min, "maxLength" => max}
  defp trusted(context), do: Map.take(context, [:session_id, :agent_id, :cwd])

  defp input(%{tool_name: name, arguments: args}, context) when name in @names and is_map(args) do
    action = if name == @create, do: :create, else: :dismiss

    with {:ok, _} <- InputSchema.validate(schema(name), args),
         {:ok, normalized} <- Domain.prepare(action, args, trusted(context)),
         do: {:ok, action, normalized}
  end

  defp input(_, _), do: {:error, :invalid_input}

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         uuid?(context[:session_id]) and opaque?(context[:agent_id], 256) and
         opaque?(context[:cwd], 16_384) and Path.type(context.cwd) == :absolute and
         opaque?(context[:run_id], 4_096) and
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
        :scope_mismatch -> :forbidden
        reason when reason in [:invalid_input, :invalid_context] -> :validation
        :timeout -> :timeout
        :unknown_outcome -> :unknown_outcome
        :capacity -> :budget_exceeded
        :not_found -> :not_found
        _ -> :execution_failure
      end

    {:error,
     Error.new(class, "Task suggestion operation failed",
       details: %{code: Atom.to_string(reason)}
     )}
  end
end
