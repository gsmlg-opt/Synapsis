defmodule Synapsis.Agent.Tools.AutomationMutation do
  @moduledoc """
  Explicit native update and removal through the existing automation owners.

  Trusted creator identity stays separate from mutable execution routing. The
  domain serializes current configuration checks, persistence and retirement.
  Receipts distinguish acknowledged persistence from scheduler activation and
  cancellation requests; they never imply cleanup or external effects settled.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Synapsis.Agent.Routines
  alias Synapsis.Agent.Tools.CatalogBinding

  @update "synapsis::automations_update"
  @remove "synapsis::automations_remove"
  @names [@update, @remove]
  @revision 1
  @context_keys [
    :session_id,
    :creator_agent_id,
    :requester_name,
    :run_id,
    :incarnation,
    :catalog_revision
  ]
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @counts ~w(active_count queued_count submission_count producer_count pending_recovery_count pending_refill_count)a
  @projection_fields ~w(name enabled schedule timezone session_target delivery provider model agent_name deleteAfterRun max_runtime_ms no_overlap)
  @schedule_fields ~w(kind expr tz staggerMs at everyMs anchorMs)

  def names, do: @names
  def revision, do: @revision
  def revision(@update), do: 2
  def revision(@remove), do: @revision
  def revision(_name), do: nil
  def permission_level(name) when name in @names, do: :write

  def descriptors(context, selected_names \\ @names) do
    with :ok <- context_valid(context) do
      descriptors =
        for name <- @names, name in selected_names do
          %{
            tool_name: name,
            tool_revision: revision(name),
            description: description(name),
            schema: schema(name),
            safety: %{read_only: false, retry_safe: false, parallel_safe: false},
            backend: __MODULE__,
            backend_context: context
          }
        end

      {:ok, descriptors}
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  def classify(context, operation) do
    with :ok <- context_valid(context),
         :ok <-
           CatalogBinding.host(
             context,
             operation,
             __MODULE__,
             revision(operation[:tool_name]),
             @native_keys
           ),
         :ok <- input(operation) do
      resource = %{
        session_id: context.session_id,
        creator_agent_id: context.creator_agent_id,
        source: operation.arguments["source"],
        id: operation.arguments["id"]
      }

      {:ok,
       %{
         action:
           if(operation.tool_name == @update, do: "automation.update", else: "automation.remove"),
         resource: "automation:" <> Jason.encode!(resource)
       }}
    end
  end

  @impl true
  def execute(%{backend_context: enriched} = operation) do
    with {:ok, context} <- execution_context(enriched),
         {:ok, _} <-
           classify(context, CatalogBinding.classification_operation(operation, context)),
         :ok <- active_effect(enriched),
         {:ok, receipt} <- dispatch(operation, context) do
      output(receipt)
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, error(reason)}
    end
  rescue
    _ -> {:error, error(:unknown_outcome)}
  catch
    _, _ -> {:error, error(:unknown_outcome)}
  end

  def execute(_), do: {:error, error(:invalid_context)}

  @impl true
  def cancel(_operation), do: :ok

  defp dispatch(%{tool_name: @update, arguments: args}, context),
    do: Routines.update_automation({args["source"], args["id"]}, args["patch"], context)

  defp dispatch(%{tool_name: @remove, arguments: args}, context),
    do: Routines.remove_automation({args["source"], args["id"]}, context, [])

  defp description(@update),
    do:
      "Patch a source-qualified automation created by this configured Agent; another session of the same Agent may update it while its original source conversation stays fixed. Ownerless legacy jobs follow their existing execution route. Omitted fields retain values. Common fields are name, prompt, schedule, timezone, enabled, agent_name, runtime and overlap. Routine configurations accept cron/at/every objects or cron strings; legacy heartbeat schedules remain cron strings. Version-one routines additionally support current or isolated context, local announce, none or primary webhook, nullable provider/model overrides, and deleteAfterRun. Webhook awaits JSON delivery before the Run becomes terminal. delivery.to-only edits retain mode; mode-only edits retain the stored target; null to clears it when the effective mode permits. Disabling an enabled job commits the patch then requests cancellation of captured work. Repeating an already disabled state preserves later explicit force work. Returns persistence, scheduler activation and cancellation-request observations; cleanup may remain pending. Does not create, run, remove or wake jobs."

  defp description(@remove),
    do:
      "Remove an exact source-qualified automation created by this configured Agent, preserving its durable Run history. Another session of the same Agent may remove it; ownerless legacy jobs follow their existing execution route. Commits configuration removal before retiring its future timer and requesting cancellation of captured work. Returns acknowledged persistence and cancellation-request observations; acknowledgement does not mean cleanup or started external effects settled. Does not create, update, run or wake jobs."

  defp schema(@update) do
    target_schema()
    |> put_in(["properties", "patch"], patch_schema())
    |> Map.put("required", ~w(source id patch))
  end

  defp schema(@remove), do: target_schema()

  defp target_schema do
    %{
      "type" => "object",
      "properties" => %{
        "source" => %{"type" => "string", "enum" => ~w(routine heartbeat)},
        "id" => %{
          "type" => "string",
          "description" => "Canonical source-qualified automation UUID."
        }
      },
      "required" => ~w(source id),
      "additionalProperties" => false
    }
  end

  defp patch_schema do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "prompt" => %{"type" => "string", "minLength" => 1},
        "schedule" => %{
          "description" =>
            "Routine configurations accept cron/at/every objects or cron strings; legacy heartbeat schedules remain cron strings.",
          "oneOf" => [%{"type" => "string", "minLength" => 1}, typed_schedule_schema()]
        },
        "timezone" => %{"type" => "string"},
        "enabled" => %{"type" => "boolean"},
        "agent_name" => %{"type" => "string"},
        "max_runtime_ms" => %{"type" => "integer", "minimum" => 1},
        "no_overlap" => %{"type" => "boolean"},
        "session_target" => %{"type" => "string", "enum" => ~w(current isolated)},
        "delivery" => %{
          "type" => "object",
          "properties" => %{
            "mode" => %{"type" => "string", "enum" => ~w(announce none webhook)},
            "to" => %{"type" => ["string", "null"]}
          },
          "additionalProperties" => false
        },
        "provider" => %{"type" => ["string", "null"]},
        "model" => %{"type" => ["string", "null"]},
        "deleteAfterRun" => %{"type" => "boolean"}
      },
      "additionalProperties" => false
    }
  end

  defp typed_schedule_schema do
    %{
      "type" => "object",
      "properties" => %{
        "kind" => %{"type" => "string", "enum" => ~w(cron at every)},
        "expr" => %{"type" => "string"},
        "tz" => %{"type" => ["string", "null"]},
        "staggerMs" => %{"type" => "integer", "minimum" => 0},
        "at" => %{"type" => "string"},
        "everyMs" => %{"type" => "integer", "minimum" => 1},
        "anchorMs" => %{"type" => "integer", "minimum" => 0}
      },
      "required" => ["kind"],
      "additionalProperties" => false
    }
  end

  defp input(%{tool_name: name, arguments: %{"id" => id} = arguments}) when name in @names do
    with true <- uuid?(id),
         {:ok, _} <- InputSchema.validate(schema(name), arguments) do
      :ok
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp input(_), do: {:error, :invalid_input}

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         uuid?(context[:session_id]) and uuid?(context[:creator_agent_id]) and
         is_binary(context[:requester_name]) and byte_size(context.requester_name) in 1..256 and
         Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, context.requester_name) and
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

  defp active_effect(%{effect_deadline: getter}) when is_function(getter, 0) do
    case getter.() do
      {:ok, %{remaining_ms: remaining}} when remaining > 0 -> :ok
      _ -> {:error, :timeout}
    end
  end

  defp active_effect(_), do: {:error, :invalid_context}

  defp output(receipt) do
    minimum = %{
      "source" => receipt.source,
      "id" => receipt.id,
      "persisted" => receipt.persisted,
      "activation" => receipt.activation,
      "cancellation" => public_cancellation(receipt.cancellation)
    }

    minimum =
      Map.merge(minimum, Map.take(public_routine(Map.get(receipt, :routine, %{})), ["delivery"]))

    minimum =
      Enum.reduce([:removed, :changed], minimum, fn key, result ->
        case Map.fetch(receipt, key) do
          {:ok, value} when is_boolean(value) -> Map.put(result, Atom.to_string(key), value)
          _ -> result
        end
      end)

    result = Map.merge(public_routine(Map.get(receipt, :routine, %{})), minimum)
    value = %{content: Jason.encode!(result), structured: result}

    if byte_size(Jason.encode!(value)) <= 65_536 do
      {:ok, value}
    else
      minimum = Map.put(minimum, "projection_truncated", true)
      {:ok, bounded_minimum(minimum)}
    end
  end

  defp bounded_minimum(result) do
    value = %{content: Jason.encode!(result), structured: result}

    if byte_size(Jason.encode!(value)) <= 65_536 do
      value
    else
      # Only the delivery target is unbounded in the minimum receipt. Recheck
      # both encoded projections, including JSON escaping and truncation flags.
      target = result["delivery"]["to"]

      result
      |> put_in(["delivery", "to"], utf8_prefix(target, div(byte_size(target), 2)))
      |> put_in(["delivery", "to_truncated"], true)
      |> bounded_minimum()
    end
  end

  defp utf8_prefix(value, limit) do
    prefix = binary_part(value, 0, limit)
    if String.valid?(prefix), do: prefix, else: utf8_prefix(value, limit - 1)
  end

  defp public_routine(routine) do
    projection = Map.take(routine, @projection_fields)

    projection =
      case projection["delivery"] do
        delivery when is_map(delivery) ->
          Map.put(projection, "delivery", Map.take(delivery, ~w(mode to)))

        _ ->
          projection
      end

    case projection["schedule"] do
      schedule when is_map(schedule) ->
        Map.put(projection, "schedule", Map.take(schedule, @schedule_fields))

      _ ->
        projection
    end
  end

  defp public_cancellation(cancellation) do
    result = %{
      "status" => Atom.to_string(cancellation.status),
      "cleanup_pending" => cancellation.cleanup_pending
    }

    result =
      Enum.reduce(@counts, result, fn key, acc ->
        case Map.fetch(cancellation, key) do
          {:ok, count} when is_integer(count) and count >= 0 ->
            Map.put(acc, Atom.to_string(key), count)

          _ ->
            acc
        end
      end)

    case cancellation do
      %{status: :cancellation_requested, observations: [_ | _] = observations} ->
        Map.put(
          result,
          "identity_complete",
          Enum.all?(observations, &(&1.identity_complete == true))
        )

      _ ->
        result
    end
  end

  defp error(reason) do
    class =
      case reason do
        value when value in [:invalid_context, :invalid_input] -> :validation
        :scope_mismatch -> :forbidden
        :timeout -> :timeout
        :unknown_outcome -> :unknown_outcome
        :not_found -> :not_found
        {:invalid_routine, _} -> :validation
        _ -> :execution_failure
      end

    Error.new(class, "Automation mutation could not be confirmed",
      details: %{code: if(is_atom(reason), do: Atom.to_string(reason), else: "unavailable")}
    )
  end
end
