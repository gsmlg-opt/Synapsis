defmodule Synapsis.Agent.Tools.SessionState do
  @moduledoc """
  Native bounded session todo and planning-intent effects.

  The persisted session UUID comes from trusted host context, independently of
  opaque native run IDs. Native admission and the host per-tool permission gate
  remain required, including overrides for the `:none` permission level.
  Execution owns cancellation; this module creates no processes or journal.

  Todo replacement writes one Concord value before broadcasting. Both planning
  tools retain the existing `agent: "main"` metadata behavior; they mark or submit
  intent and do not enforce planning restrictions or change tool authority.
  Completed writes are not rolled back by cancellation or broadcast failure.

  A real session metadata read is required before reading or changing state.
  Store.get_value/3 defaults on all read errors, so a storage failure between
  that check and the todo read remains indistinguishable from an absent list.
  Mutating store errors are returned without broadcasting success events.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Synapsis.Session.Store

  @read "synapsis::todo_read"
  @write "synapsis::todo_write"
  @enter "synapsis::enter_plan_mode"
  @exit "synapsis::exit_plan_mode"
  @names [@read, @write, @enter, @exit]
  @context_keys [:session_id, :run_id, :incarnation, :catalog_revision]
  # Conversation 1.10.35 adds these runtime capabilities to effect context.
  # They cannot select a different session and are never invoked here.
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @statuses ~w(pending in_progress completed)
  @max_todos 100
  @max_content 8192
  @max_plan 32768
  @output_limit 1_048_576

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
          @read -> {"session.todo.read", "todos"}
          @write -> {"session.todo.write", "todos"}
          @enter -> {"session.plan.enter", "plan"}
          @exit -> {"session.plan.exit", "plan"}
        end

      {:ok, %{action: action, resource: "session:#{context.session_id}:#{suffix}"}}
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
         {:ok, meta} <- session(context.session_id),
         {:ok, result} <- run(context.session_id, meta, operation) do
      if byte_size(Jason.encode!(result)) <= @output_limit,
        do: {:ok, result},
        else: failure(:output_limit)
    else
      {:error, reason} -> failure(reason)
    end
  rescue
    _ -> unexpected(operation)
  catch
    :exit, _ -> unexpected(operation)
    :throw, _ -> unexpected(operation)
  end

  def execute(_), do: failure(:invalid_input)

  # Native Execution owns and terminates the effect process. A completed store
  # write remains durable; no standalone worker or rollback is introduced here.
  @impl true
  def cancel(_operation), do: :ok

  defp descriptor(name, context) do
    %{
      tool_name: name,
      tool_revision: 1,
      description: description(name),
      schema: schema(name),
      safety: %{
        read_only: name == @read,
        retry_safe: name == @read,
        parallel_safe: name == @read
      },
      backend: __MODULE__,
      backend_context: context
    }
  end

  defp description(@read), do: "Read the current session todo list in its stored order."

  defp description(@write),
    do:
      "Atomically replace the current session todo list, preserving supplied IDs and list order."

  defp description(@enter),
    do: "Mark planning intent using the existing main agent metadata and mode event."

  defp description(@exit),
    do:
      "Submit optional planning intent and retain the existing main agent metadata and mode event."

  defp schema(name) do
    {properties, required} =
      case name do
        @write ->
          {%{
             "todos" => %{
               "type" => "array",
               "maxItems" => @max_todos,
               "items" => %{
                 "type" => "object",
                 "properties" => %{
                   "id" => %{"type" => "string", "minLength" => 1, "maxLength" => 256},
                   "content" => %{"type" => "string", "maxLength" => @max_content},
                   "status" => %{"type" => "string", "enum" => @statuses}
                 },
                 "required" => ["id", "content", "status"],
                 "additionalProperties" => false
               }
             }
           }, ["todos"]}

        @exit ->
          {%{"plan" => %{"type" => "string", "maxLength" => @max_plan}}, []}

        _ ->
          {%{}, []}
      end

    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         uuid?(context[:session_id]) and opaque?(context[:run_id], 4096) and
         is_integer(context[:incarnation]) and context.incarnation > 0 and
         is_integer(context[:catalog_revision]) and context.catalog_revision > 0,
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp context_valid(_), do: {:error, :invalid_context}

  defp uuid?(id) when is_binary(id), do: match?({:ok, ^id}, Ecto.UUID.cast(id))
  defp uuid?(_), do: false

  defp opaque?(value, limit),
    do:
      text?(value, limit) and byte_size(value) > 0 and String.trim(value) != "" and
        not String.contains?(value, "\0")

  defp text?(value, limit),
    do: is_binary(value) and byte_size(value) <= limit and String.valid?(value)

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
    # The schema is fixed by the name; no invocation-provided schema or backend
    # can relax it. Byte bounds and unique IDs supplement native schema checks.
    with {:ok, _} <- InputSchema.validate(schema(name), args),
         true <- bounded_input?(name, args) do
      :ok
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp input(_), do: {:error, :invalid_input}

  defp bounded_input?(@write, %{"todos" => todos}) do
    Enum.all?(todos, fn todo ->
      opaque?(todo["id"], 256) and text?(todo["content"], @max_content)
    end) and length(Enum.uniq_by(todos, & &1["id"])) == length(todos)
  end

  defp bounded_input?(@exit, args),
    do: not Map.has_key?(args, "plan") or text?(args["plan"], @max_plan)

  defp bounded_input?(_, _), do: true

  defp session(id) do
    case Store.get_meta(id) do
      {:ok, meta} when is_map(meta) and not is_struct(meta) -> {:ok, meta}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} -> {:error, :storage_failed}
      _ -> {:error, :malformed_state}
    end
  end

  defp run(id, _meta, %{tool_name: @read}) do
    records = Store.get_value(id, "todos", [])

    if is_list(records) and length(records) <= @max_todos and Enum.all?(records, &record?/1) do
      todos =
        records
        |> Enum.sort_by(&(&1["sort_order"] || 0))
        |> Enum.map(fn record ->
          %{
            id: record["todo_id"],
            content: record["content"],
            status: record["status"] || "pending",
            sort_order: record["sort_order"] || 0
          }
        end)

      public = %{todos: todos}
      {:ok, %{content: Jason.encode!(public), structured: public}}
    else
      {:error, :malformed_state}
    end
  end

  defp run(id, _meta, %{tool_name: @write, arguments: %{"todos" => todos}}) do
    records =
      todos
      |> Enum.with_index()
      |> Enum.map(fn {todo, index} ->
        %{
          "todo_id" => todo["id"],
          "content" => todo["content"],
          "status" => todo["status"],
          "sort_order" => index
        }
      end)

    with :ok <- persisted(Store.put_value(id, "todos", records)) do
      broadcast(id, {:todo_update, id, records})

      {:ok,
       %{content: "Updated #{length(records)} todo(s).", structured: %{count: length(records)}}}
    end
  end

  defp run(id, meta, %{tool_name: name, arguments: args}) when name in [@enter, @exit] do
    with :ok <- persisted(Store.put_meta(id, Map.put(meta, :agent, "main"))) do
      plan = Map.get(args, "plan")
      if name == @exit, do: broadcast(id, {:plan_submitted, plan})
      broadcast(id, {:agent_mode_changed, :main})
      public = if name == @exit, do: %{agent: "main", plan: plan}, else: %{agent: "main"}
      content = if name == @exit, do: "Exited plan mode", else: "Entered plan mode"
      {:ok, %{content: content, structured: public}}
    end
  end

  defp record?(record) when is_map(record) and not is_struct(record) do
    opaque?(record["todo_id"], 256) and text?(record["content"], @max_content) and
      (record["status"] || "pending") in @statuses and
      is_integer(record["sort_order"] || 0) and (record["sort_order"] || 0) >= 0
  end

  defp record?(_), do: false

  defp persisted(:ok), do: :ok
  defp persisted(_), do: {:error, :storage_failed}

  defp broadcast(id, event) do
    :ok = Phoenix.PubSub.broadcast(Synapsis.PubSub, "session:#{id}", event)
  end

  defp unexpected(operation),
    do: failure(if(operation[:tool_name] == @read, do: :storage_failed, else: :unknown_outcome))

  defp failure(reason) do
    class =
      case reason do
        :scope_mismatch -> :forbidden
        reason when reason in [:invalid_context, :invalid_input] -> :validation
        :not_found -> :not_found
        :storage_failed -> :execution_failure
        :output_limit -> :budget_exceeded
        :unknown_outcome -> :unknown_outcome
        _ -> :malformed_result
      end

    {:error,
     Error.new(class, "Session state operation failed", details: %{code: Atom.to_string(reason)})}
  end
end
