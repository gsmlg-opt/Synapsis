defmodule Synapsis.Agent.Tools.AutomationWake do
  @moduledoc """
  Explicit native manual events for exact existing conversations.

  Trusted source identity is retained separately from the target's configured
  Agent. A successful result acknowledges durable staging and live Worker
  ownership; event execution and completion happen in a separate turn.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Synapsis.Agent.Tools.CatalogBinding
  alias Synapsis.Config.Store
  alias Synapsis.{Sessions, SessionStatus}

  @name "synapsis::automations_wake"
  @revision 1
  @context_keys [
    :session_id,
    :source_agent_id,
    :requester_name,
    :primary?,
    :run_id,
    :incarnation,
    :catalog_revision
  ]
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a

  def names, do: [@name]
  def revision, do: @revision
  def permission_level(@name), do: :write

  def descriptors(context) do
    with :ok <- context_valid(context) do
      {:ok,
       [
         %{
           tool_name: @name,
           tool_revision: @revision,
           description:
             "Stage a manual event for an existing conversation's next exclusive turn. Defaults to this primary conversation and mode next-heartbeat; now also admits immediately and waits for the ordinary turn lane. Optional session_id selects an exact existing conversation, retaining its own Agent/provider/model; optional agent_id asserts its configured Agent UUID. Each call creates a distinct occurrence. Returns only {ok:true} after durable staging and live Worker acceptance, before execution or completion. An uncertain result must not be automatically retried. Does not create or modify scheduled jobs.",
           schema: schema(),
           safety: %{read_only: false, retry_safe: false, parallel_safe: false},
           backend: __MODULE__,
           backend_context: context
         }
       ]}
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  def classify(context, operation) do
    with :ok <- context_valid(context),
         true <- context.primary?,
         :ok <- CatalogBinding.host(context, operation, __MODULE__, @revision, @native_keys),
         :ok <- input(operation) do
      {:ok,
       %{
         action: "automation.wake",
         resource: "session:" <> Map.get(operation.arguments, "session_id", context.session_id)
       }}
    else
      false -> {:error, error(:invalid_context)}
      result -> result
    end
  end

  @impl true
  def execute(%{backend_context: enriched} = operation) do
    with {:ok, context} <- execution_context(enriched),
         {:ok, _} <-
           classify(context, CatalogBinding.classification_operation(operation, context)),
         {:ok, deadline} <- effect_deadline(enriched),
         {:ok, source} <- session(context.session_id, context, deadline),
         true <- source.agent === context.requester_name,
         {:ok, directory} <- Store.agent_directory_snapshot(context.requester_name, deadline),
         true <- directory.requester.id === context.source_agent_id,
         {:ok, target} <- target(operation.arguments, source, context, deadline),
         %{id: target_agent_id} <- Enum.find(directory.agents, &(&1.name === target.agent)),
         true <- Map.get(operation.arguments, "agent_id", target_agent_id) === target_agent_id,
         :ok <- remaining(deadline),
         {:ok, %{accepted: true}} <-
           Sessions.wake(target.id, operation.arguments["text"],
             target_agent_id: target_agent_id,
             source_session_id: context.session_id,
             source_agent_id: context.source_agent_id,
             mode: Map.get(operation.arguments, "mode", "next-heartbeat"),
             deadline: deadline
           ) do
      {:ok, %{content: Jason.encode!(%{"ok" => true}), structured: %{"ok" => true}}}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, error(reason)}
      _ -> {:error, error(:target_unavailable)}
    end
  rescue
    _ -> {:error, error(:unknown_outcome)}
  catch
    _, _ -> {:error, error(:unknown_outcome)}
  end

  def execute(_), do: {:error, error(:invalid_context)}

  @impl true
  def cancel(_operation), do: :ok

  defp session(id, context, deadline) do
    case SessionStatus.read(
           %{"session_id" => id, "source" => "durable"},
           %{session_id: context.session_id, agent_id: context.requester_name},
           deadline: deadline
         ) do
      {:ok, %{session: session}} -> {:ok, session}
      error -> error
    end
  end

  defp target(arguments, source, context, deadline) do
    case Map.get(arguments, "session_id", source.id) do
      id when id == source.id -> {:ok, source}
      id -> session(id, context, deadline)
    end
  end

  defp effect_deadline(%{effect_deadline: getter}) when is_function(getter, 0) do
    started = now()

    case getter.() do
      {:ok, %{remaining_ms: remaining} = observation}
      when is_integer(remaining) and remaining > 0 ->
        deadline = Map.get(observation, :deadline_ms, started + remaining)

        if is_integer(deadline) and Map.get(observation, :paused, false) == false do
          deadline = min(deadline, min(started + remaining, started + 5_000))
          with :ok <- remaining(deadline), do: {:ok, deadline}
        else
          {:error, :timeout}
        end

      {:error, %Error{} = error} ->
        {:error, error}

      _ ->
        {:error, :timeout}
    end
  end

  defp effect_deadline(_), do: {:error, :invalid_context}

  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "text" => %{"type" => "string", "minLength" => 1},
        "mode" => %{"type" => "string", "enum" => ~w(now next-heartbeat)},
        "session_id" => %{"type" => "string", "format" => "uuid"},
        "agent_id" => %{"type" => "string", "format" => "uuid"}
      },
      "required" => ["text"],
      "additionalProperties" => false
    }
  end

  defp input(%{tool_name: @name, arguments: arguments}) do
    with {:ok, _} <- InputSchema.validate(schema(), arguments),
         true <-
           Enum.all?(
             ~w(session_id agent_id),
             &(not Map.has_key?(arguments, &1) or uuid?(arguments[&1]))
           ) do
      :ok
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp input(_), do: {:error, :invalid_input}

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         uuid?(context[:session_id]) and uuid?(context[:source_agent_id]) and
         is_binary(context[:requester_name]) and byte_size(context.requester_name) in 1..256 and
         Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, context.requester_name) and
         is_boolean(context[:primary?]) and
         is_binary(context[:run_id]) and byte_size(context.run_id) in 1..4096 and
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
  defp uuid?(id), do: is_binary(id) and Ecto.UUID.cast(id) == {:ok, id}
  defp remaining(deadline), do: if(deadline > now(), do: :ok, else: {:error, :timeout})
  defp now, do: System.monotonic_time(:millisecond)

  defp error(reason) do
    class =
      case reason do
        value when value in [:invalid_context, :invalid_input] -> :validation
        :scope_mismatch -> :forbidden
        :timeout -> :timeout
        :unknown_outcome -> :unknown_outcome
        :not_found -> :not_found
        _ -> :execution_failure
      end

    Error.new(class, "Manual event acceptance could not be confirmed",
      details: %{code: if(is_atom(reason), do: Atom.to_string(reason), else: "unavailable")}
    )
  end
end
