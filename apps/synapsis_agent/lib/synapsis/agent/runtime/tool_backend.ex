defmodule Synapsis.Agent.Runtime.ToolBackend do
  @moduledoc """
  Backplane module-tool backend using the host Gateway and scoped grants.

  Runs inside a bounded Conversation effect task. `interact` is supplied by the
  runtime; only an authenticated host resolver may answer it with
  `%{approval_id: request.approval_id, grant: %Grant{}}`. Booleans never grant
  permission. The grant must be operator-minted for the exact run, session,
  tool and arguments. The runtime correlates the separate interaction ID.

  Approval waits are bounded by Conversation's effect/run deadline; an earlier
  approval expiry is also checked before dispatch. The host UI is not wired yet.
  Module tasks are linked to this effect owner, retries are disabled, and a
  timeout/crash is an unknown outcome rather than proof of no side effects.
  """
  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Synapsis.Tool.{Gateway, Registry}
  alias Synapsis.Tool.Capability.Grant

  def execute(%{tool_name: name, arguments: input, backend_context: bound} = operation) do
    host =
      bound.host_context
      |> Map.drop([:operator_approval, :capability_grant, :input])
      |> Map.merge(
        Map.take(operation, [:invocation_id, :turn_id, :step_id, :attempt_id, :incarnation])
      )
      |> Map.merge(%{
        tool_task_link: true,
        tool_max_retries: 0,
        tool_timeout_ms: bound.tool_timeout_ms
      })

    with true <-
           operation.run_id == host.run_id and name == bound.tool_name and
             operation.tool_revision == bound.revision,
         :ok <- current(name, bound.registration),
         {:ok, input} <- InputSchema.validate(bound.schema, input),
         {:ok, grant} <- authorize(name, input, host, bound, operation),
         :ok <- current(name, bound.registration) do
      Gateway.execute_authorized(name, input, host, grant, bound.registration)
      |> result()
    else
      false -> error(:forbidden, "Tool operation does not match admitted authority")
      {:error, %Error{}} = error -> error
      {:error, reason} -> denied(reason)
    end
  end

  defp authorize(name, input, host, bound, operation) do
    case Gateway.authorize(name, input, host.policy_snapshot, host) do
      {:ok, grant} -> {:ok, grant}
      {:error, :requires_approval} -> request_approval(name, input, host, bound, operation)
      error -> error
    end
  end

  defp request_approval(name, input, host, bound, operation) do
    approval_id = Ecto.UUID.generate()
    expires = DateTime.add(DateTime.utc_now(), bound.approval_timeout_ms, :millisecond)

    request = %{
      kind: :tool_permission,
      approval_id: approval_id,
      tool_name: name,
      arguments: input,
      run_id: host.run_id,
      session_id: host[:session_id],
      invocation_id: operation.invocation_id,
      expires_at: DateTime.to_iso8601(expires)
    }

    with interact when is_function(interact, 1) <- bound[:interact],
         {:ok, %{approval_id: ^approval_id, grant: %Grant{} = grant}} <- interact.(request),
         true <- DateTime.compare(DateTime.utc_now(), expires) == :lt,
         true <-
           grant.source == :operator_approval and grant.run_id == host.run_id and
             grant.session_id == host[:session_id] and not is_nil(grant.argument_digest),
         :ok <- Grant.validate(grant, name, Map.put(host, :input, input)),
         :ok <- current(name, bound.registration),
         # Approval cannot override a deny in the admitted policy. Only this
         # trusted, already verified host grant permits the approval branch.
         {:ok, _} <-
           Gateway.authorize(
             name,
             input,
             host.policy_snapshot,
             Map.put(host, :operator_approval, true)
           ) do
      {:ok, grant}
    else
      {:error, %Error{}} = error -> error
      {:error, reason} -> denied(reason)
      _ -> error(:forbidden, "Approval missing, expired, mismatched or invalid")
    end
  end

  defp current(name, {:module, _module, opts} = entry) do
    cond do
      Registry.lookup(name) != {:ok, entry} ->
        error(:resource_conflict, "Tool registration changed")

      opts[:deferred] == true or not Registry.runtime_available?(entry) ->
        error(:forbidden, "Tool is unavailable")

      true ->
        :ok
    end
  end

  defp current(_, _),
    do: error(:unsupported_capability, "Only admitted module tools are supported")

  defp result({:ok, content}), do: {:ok, %{content: content, is_error: false}}

  defp result({:error, :timeout}),
    do: error(:unknown_outcome, "Tool timed out; side effects may have occurred")

  defp result({:error, {:exit, _}}),
    do: error(:unknown_outcome, "Tool exited; side effects may have occurred")

  defp result({:error, _}), do: error(:execution_failure, "Host tool execution failed")
  defp result(_), do: error(:malformed_result, "Host tool returned an invalid result")

  defp denied(reason) when is_atom(reason),
    do:
      {:error,
       Error.new(:forbidden, "Host tool authorization rejected", details: %{reason: reason})}

  defp denied(_), do: error(:forbidden, "Host tool authorization rejected")
  defp error(class, message), do: {:error, Error.new(class, message)}
end
