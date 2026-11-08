defmodule Synapsis.Agent.Tools.AutomationManagement do
  @moduledoc """
  Explicit native run capability for source-qualified visible automations.

  The scheduler owns due eligibility and occurrence reservation. Daemon owns Run
  creation and execution through Sessions and Worker. This adapter acknowledges
  actual Runs and optionally observes their terminal state from its effect task;
  it never waits in the scheduler or active session callback. Dispatch uncertainty
  is not a rejection, and cancellation does not cancel the scheduler-owned Run.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema, ToolEffects}
  alias Synapsis.Agent.{Daemon, Routines, Runs}
  alias Synapsis.Agent.Tools.CatalogBinding
  alias Synapsis.AutomationDirectory

  @name "synapsis::automations_manage"
  @revision 1
  @context_keys [:session_id, :requester_name, :run_id, :incarnation, :catalog_revision]
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @terminal ~w(completed failed cancelled interrupted timed_out unknown_outcome)
  @maximum_wait 60_000

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
             "Run a visible source-qualified routine or heartbeat. runMode defaults to due: disabled or future jobs return a successful non-enqueued result. Explicit force runs immediately, including disabled jobs, preserving a future scheduled occurrence. Observe actual terminal Run state for at most timeoutMs (default 60000), bounded by this tool's native deadline. A job queued behind this session is acknowledged immediately and starts after this turn. Acknowledgement is not completion. Does not create, update, remove, or wake jobs.",
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
         :ok <- CatalogBinding.host(context, operation, __MODULE__, @revision, @native_keys),
         :ok <- input(operation) do
      resource = %{
        session_id: context.session_id,
        requester_name: context.requester_name,
        source: operation.arguments["source"],
        id: operation.arguments["id"],
        runMode: Map.get(operation.arguments, "runMode", "due")
      }

      {:ok, %{action: "automation.run", resource: "automation:" <> Jason.encode!(resource)}}
    end
  end

  @impl true
  def execute(%{backend_context: enriched} = operation) do
    with {:ok, context} <- execution_context(enriched),
         {:ok, _} <-
           classify(context, CatalogBinding.classification_operation(operation, context)),
         {:ok, deadline} <- deadline(enriched),
         {:ok, _visible} <-
           AutomationDirectory.read(
             Map.put(Map.take(operation.arguments, ~w(source id)), "action", "get"),
             Map.take(context, [:session_id, :requester_name]),
             deadline: deadline
           ) do
      dispatch(operation.arguments, context, enriched, deadline)
    else
      {:error, reason} -> ToolEffects.reject(operation, error(reason))
    end
  rescue
    _ -> {:error, error(:unknown_outcome)}
  catch
    _, _ -> {:error, error(:unknown_outcome)}
  end

  def execute(operation) when is_map(operation),
    do: ToolEffects.reject(operation, error(:invalid_context))

  def execute(_), do: {:error, error(:invalid_context)}

  @impl true
  def cancel(_operation), do: :ok

  defp dispatch(arguments, context, enriched, deadline) do
    mode = if Map.get(arguments, "runMode", "due") == "force", do: :force, else: :due

    case Routines.run({arguments["source"], arguments["id"]}, mode) do
      {:ok, %{enqueued: false, reason: reason}} ->
        output(%{
          source: arguments["source"],
          id: arguments["id"],
          runMode: Atom.to_string(mode),
          enqueued: false,
          finished: false,
          reason: Atom.to_string(reason),
          run: nil
        })

      {:ok, %{enqueued: true, run: %Synapsis.AgentRun{} = run}} ->
        observation_deadline =
          min(deadline, now() + Map.get(arguments, "timeoutMs", @maximum_wait))

        with {:ok, observed} <- observe(run, context, enriched, observation_deadline) do
          finished = observed.status in @terminal

          result = %{
            source: arguments["source"],
            id: arguments["id"],
            runMode: Atom.to_string(mode),
            enqueued: true,
            finished: finished,
            run: public_run(observed)
          }

          result =
            if finished,
              do: result,
              else:
                Map.put(
                  result,
                  :note,
                  "Not finished yet: this Run is queued or running. A Run queued behind this session starts after this turn; acknowledgement does not establish completion."
                )

          output(result)
        end

      _ ->
        {:error, error(:unknown_outcome)}
    end
  end

  defp observe(run, context, enriched, deadline) do
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, Daemon.topic())

    try do
      if run.status in @terminal or owns_active_session?(context.session_id, deadline),
        do: {:ok, run},
        else: await_run(run, enriched, deadline)
    after
      Phoenix.PubSub.unsubscribe(Synapsis.PubSub, Daemon.topic())
    end
  end

  defp owns_active_session?(session_id, deadline) do
    case GenServer.call(Daemon, :status, max(min(deadline - now(), 1_000), 1)) do
      %{active_run: %{session_id: ^session_id}} -> true
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  defp await_run(run, enriched, deadline) do
    cond do
      now() >= deadline ->
        {:ok, run}

      not active_effect?(enriched) ->
        {:error, error(:unknown_outcome, run.id)}

      true ->
        case read_run(run.id, deadline) do
          {:ok, current} when current.status in @terminal -> {:ok, current}
          {:ok, current} -> wait_for_observation(current, enriched, deadline)
          :observation_timeout -> {:ok, run}
          _ -> {:error, error(:unknown_outcome, run.id)}
        end
    end
  end

  defp wait_for_observation(run, enriched, deadline) do
    receive do
      {:agent_daemon_event, %{run_id: id}} when id == run.id ->
        await_run(run, enriched, deadline)
    after
      max(min(deadline - now(), 100), 0) -> await_run(run, enriched, deadline)
    end
  end

  defp read_run(id, deadline) do
    task = Task.async(fn -> Runs.fetch(id) end)

    case Task.yield(task, max(deadline - now(), 0)) do
      {:ok, result} ->
        result

      _ ->
        Task.shutdown(task, :brutal_kill)
        :observation_timeout
    end
  end

  defp active_effect?(%{effect_deadline: getter}) when is_function(getter, 0),
    do: match?({:ok, %{remaining_ms: remaining}} when remaining > 0, getter.())

  defp active_effect?(_), do: false

  defp deadline(%{effect_deadline: getter}) when is_function(getter, 0) do
    case getter.() do
      {:ok, %{remaining_ms: remaining}} when is_integer(remaining) and remaining > 0 ->
        # Leave a small settlement allowance inside the native effect deadline.
        {:ok, now() + max(min(@maximum_wait, remaining) - 25, 0)}

      _ ->
        {:error, :timeout}
    end
  end

  defp deadline(_), do: {:error, :invalid_context}

  defp public_run(run) do
    %{
      id: run.id,
      status: run.status,
      session_id: run.session_id,
      started_at: timestamp(run.started_at),
      finished_at: timestamp(run.finished_at),
      scheduled_for: timestamp(run.scheduled_for)
    }
  end

  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp(nil), do: nil

  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ["run"]},
        "source" => %{"type" => "string", "enum" => ~w(routine heartbeat)},
        "id" => %{
          "type" => "string",
          "description" => "Canonical source-qualified automation UUID."
        },
        "runMode" => %{"type" => "string", "enum" => ~w(due force), "default" => "due"},
        "timeoutMs" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => @maximum_wait,
          "default" => @maximum_wait
        }
      },
      "required" => ~w(action source id),
      "additionalProperties" => false
    }
  end

  defp input(%{tool_name: @name, arguments: %{"action" => "run", "id" => id} = arguments}) do
    with true <- uuid?(id),
         {:ok, _} <- InputSchema.validate(schema(), arguments) do
      :ok
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp input(_), do: {:error, :invalid_input}

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and uuid?(context[:session_id]) and
         is_binary(context[:requester_name]) and byte_size(context.requester_name) in 1..256 and
         Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, context.requester_name) and
         is_binary(context[:run_id]) and byte_size(context.run_id) in 1..4_096 and
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
  defp now, do: System.monotonic_time(:millisecond)

  defp output(result) do
    value = %{content: Jason.encode!(result), structured: result}

    if byte_size(Jason.encode!(value)) <= 65_536,
      do: {:ok, value},
      else: {:error, error(:unknown_outcome)}
  end

  defp error(reason, run_id \\ nil) do
    class =
      case reason do
        reason when reason in [:invalid_input, :invalid_context] -> :validation
        :scope_mismatch -> :forbidden
        :timeout -> :timeout
        reason when reason in [:not_found, :requester_unavailable] -> :not_found
        :unknown_outcome -> :unknown_outcome
        _ -> :execution_failure
      end

    code = if is_atom(reason), do: Atom.to_string(reason), else: "unavailable"
    details = if run_id, do: %{code: code, run_id: run_id, enqueued: true}, else: %{code: code}
    Error.new(class, "Automation run could not be confirmed", details: details)
  end
end
