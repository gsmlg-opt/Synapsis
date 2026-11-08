defmodule Synapsis.Agent.Tools.AutomationConfiguration do
  @moduledoc """
  Explicit version-one automation creation through the existing configuration
  store and scheduler. Creator UUIDs are pinned host context; execution routing
  is a separate mutable field. Persistence acknowledgement is not execution.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Synapsis.Agent.Routines
  alias Synapsis.Agent.Tools.CatalogBinding

  @name "synapsis::automations_create"
  @revision 2
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
             "Create a stored agent-turn automation with cron, at or every scheduling. Uses a fresh detached session; current prepends recent context from this creation session, isolated omits it. Defaults: enabled, current, local announce, native_agent, and deleteAfterRun for at. Authored prompt bytes are retained. provider/model optionally override execution. agent_name changes execution routing, while the creating Agent and source session stay fixed. Returns the generated UUID, acknowledged persistence and scheduler reload observation; this does not mean the automation ran. Local announce appends a completed result to the original conversation; none suppresses it. Webhook requires delivery.to as an absolute HTTP(S) URL and awaits primary JSON delivery before the Run becomes terminal. Does not update, disable, remove or wake existing jobs.",
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
      {:ok,
       %{
         action: "automation.create",
         resource:
           "automation:" <>
             Jason.encode!(%{session_id: context.session_id, agent_id: context.creator_agent_id})
       }}
    end
  end

  @impl true
  def execute(%{backend_context: enriched} = operation) do
    with {:ok, context} <- execution_context(enriched),
         {:ok, _} <-
           classify(context, CatalogBinding.classification_operation(operation, context)),
         :ok <- active_effect(enriched),
         {:ok, receipt} <- Routines.create_automation(operation.arguments, context) do
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

  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "prompt" => %{"type" => "string", "minLength" => 1},
        "schedule" => %{
          "type" => "object",
          "properties" => %{
            "kind" => %{"type" => "string", "enum" => ~w(cron at every)},
            "expr" => %{"type" => "string"},
            "tz" => %{"type" => "string"},
            "staggerMs" => %{"type" => "integer", "minimum" => 0},
            "at" => %{"type" => "string"},
            "everyMs" => %{"type" => "integer", "minimum" => 1},
            "anchorMs" => %{"type" => "integer", "minimum" => 0}
          },
          "required" => ["kind"],
          "additionalProperties" => false
        },
        "timezone" => %{"type" => "string"},
        "enabled" => %{"type" => "boolean"},
        "session_target" => %{"type" => "string", "enum" => ~w(current isolated)},
        "delivery" => %{
          "type" => "object",
          "properties" => %{
            "mode" => %{"type" => "string", "enum" => ~w(announce none webhook)},
            "to" => %{"type" => "string"}
          },
          "required" => ["mode"],
          "additionalProperties" => false
        },
        "provider" => %{"type" => "string"},
        "model" => %{"type" => "string"},
        "agent_name" => %{"type" => "string"},
        "deleteAfterRun" => %{"type" => "boolean"},
        "max_runtime_ms" => %{"type" => "integer", "minimum" => 1},
        "no_overlap" => %{"type" => "boolean"}
      },
      "required" => ~w(prompt schedule),
      "additionalProperties" => false
    }
  end

  defp input(%{tool_name: @name, arguments: arguments}) do
    case InputSchema.validate(schema(), arguments) do
      {:ok, _} -> :ok
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
    result =
      receipt.routine
      |> Map.take(
        ~w(name enabled schedule timezone session_target delivery provider model agent_name deleteAfterRun)
      )
      |> public_delivery()
      |> Map.merge(%{
        "source" => receipt.source,
        "id" => receipt.id,
        "persisted" => receipt.persisted,
        "activation" => receipt.activation
      })

    value = %{content: Jason.encode!(result), structured: result}

    value =
      if byte_size(Jason.encode!(value)) <= 65_536 do
        value
      else
        minimum =
          result
          |> Map.take(~w(source id persisted activation delivery))
          |> Map.put("projection_truncated", true)

        bounded_minimum(minimum)
      end

    {:ok, value}
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

  defp public_delivery(result) do
    case result["delivery"] do
      delivery when is_map(delivery) ->
        Map.put(result, "delivery", Map.take(delivery, ~w(mode to)))

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
        {:invalid_routine, _} -> :validation
        _ -> :execution_failure
      end

    Error.new(class, "Automation creation could not be confirmed",
      details: %{code: if(is_atom(reason), do: Atom.to_string(reason), else: "unavailable")}
    )
  end
end
