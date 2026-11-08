defmodule Synapsis.Agent.Tools.SessionPresence do
  @moduledoc """
  Native read-only session registration observations and unsupported build status.

  Trusted host context separates configured Agent identity, persisted session
  UUID and opaque native run identity. The core domain owns bounded reads and
  projects no PIDs, Registry metadata, configuration or inferred lifecycle.
  Native grants, exact revisions and the host permission gate remain required,
  including overrides of the legacy `:none` permission level.

  Discovery get, cursors and optional status selectors are session UUIDs. Bounded
  list/find pages observe registered live workers from persisted candidates;
  continuations can yield no matches and do not promise snapshot consistency.
  Execution owns cancellation; the domain cleans up its linked read task. There
  are no writes, worker calls, indexes or standalone observers.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Synapsis.SessionPresence, as: Domain

  @discover "synapsis::agent_discover"
  @status "synapsis::agent_status"
  @names [@discover, @status]
  @context_keys [:session_id, :agent_id, :run_id, :incarnation, :catalog_revision]
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a

  def names, do: @names
  def permission_level(name) when name in @names, do: :none

  def descriptors(context) do
    with :ok <- context_valid(context) do
      {:ok,
       Enum.map(@names, fn name ->
         %{
           tool_name: name,
           tool_revision: 1,
           description: description(name),
           schema: schema(name),
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
      action = if operation.tool_name == @discover, do: args["action"], else: "status"
      resource = %{"observer_session_id" => context.session_id}

      selected =
        if operation.tool_name == @discover, do: args["agent_id"], else: args["session_id"]

      resource = if selected, do: Map.put(resource, "session_id", selected), else: resource
      resource = Map.merge(resource, Map.take(args, ~w(type owner_agent_id limit cursor)))

      {:ok,
       %{
         action: "session.presence." <> action,
         resource: "session_presence:" <> Jason.encode!(resource)
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
         trusted = Map.take(context, [:session_id, :agent_id]),
         {:ok, result} <- dispatch(operation.tool_name, operation.arguments, trusted) do
      {:ok, %{content: Jason.encode!(result), structured: result}}
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

  defp dispatch(@discover, input, context), do: Domain.discover(input, context)
  defp dispatch(@status, input, context), do: Domain.status(input, context)

  defp description(@discover),
    do:
      "Observe a session worker by UUID or use bounded list/find pages of registered live workers. Owner filters name configured Agents; continuation may yield no matches."

  defp description(@status),
    do:
      "Build Agent system not yet implemented. Optionally observe session registration by UUID without inferring build or native lifecycle."

  defp schema(@discover) do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ~w(list get find_by_agent)},
        "agent_id" =>
          uuid_schema("Persisted session UUID for get; not a configured Agent or native task ID."),
        "owner_agent_id" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => 256,
          "description" => "Exact configured Agent string for find_by_agent."
        },
        "type" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => 64,
          "description" => "Exact session_worker type; other types have no matches."
        },
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
        "cursor" =>
          uuid_schema("Exclusive session UUID cursor over examined persisted candidates.")
      },
      "required" => ["action"],
      "additionalProperties" => false
    }
  end

  defp schema(@status),
    do: %{
      "type" => "object",
      "properties" => %{
        "session_id" => uuid_schema("Optional persisted session UUID registration observation.")
      },
      "required" => [],
      "additionalProperties" => false
    }

  defp uuid_schema(description),
    do: %{"type" => "string", "minLength" => 36, "maxLength" => 36, "description" => description}

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

  defp matching_scope(context, operation) when is_map(operation) do
    Synapsis.Agent.Tools.CatalogBinding.host(context, operation, __MODULE__, 1, @native_keys)
  end

  defp matching_scope(_, _), do: {:error, :scope_mismatch}

  defp input(%{tool_name: name, arguments: args}) when name in @names and is_map(args) do
    action = if name == @discover, do: "discover", else: "status"

    with {:ok, _} <- InputSchema.validate(schema(name), args),
         :ok <- Domain.validate(action, args) do
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
        :scope_mismatch -> :forbidden
        reason when reason in [:invalid_input, :invalid_context] -> :validation
        :timeout -> :timeout
        :malformed_metadata -> :malformed_result
        reason when reason in [:output_limit, :scan_limit] -> :budget_exceeded
        _ -> :execution_failure
      end

    {:error,
     Error.new(class, "Session presence observation failed",
       details: %{code: Atom.to_string(reason)}
     )}
  end
end
