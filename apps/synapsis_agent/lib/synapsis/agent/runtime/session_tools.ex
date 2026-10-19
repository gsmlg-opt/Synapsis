defmodule Synapsis.Agent.Runtime.SessionTools do
  @moduledoc false
  alias Synapsis.Agent.Runtime.ToolBackend
  alias Synapsis.Tool.Gateway
  alias Synapsis.Tool.Capability.Grant
  alias Backplane.AgentRuntime.{Error, ToolEffects}
  alias Backplane.AgentRuntime.Codex.Backend

  # MultiAgent owns child subscribers. Capture the genuine Conversation owner
  # while retaining its native interaction and paused effect deadlines.
  def execute(%{backend_context: bound} = operation) do
    original = bound.interact
    observer = bound[:interaction_observer]

    interact = fn request ->
      if observer,
        do: send(observer, {:runtime_permission_owner, bound.resource_owner_pid, request})

      original.(request)
    end

    bound = Map.put(bound, :interact, interact)
    operation = %{operation | backend_context: bound}

    cond do
      bound[:bounded_discovery] ->
        with :ok <- authorize(operation) do
          query = String.downcase(operation.arguments["query"])
          limit = operation.arguments["limit"] || 5

          matches =
            bound.bounded_discovery
            |> Enum.filter(
              &String.contains?(String.downcase(&1.name <> " " <> &1.description), query)
            )
            |> Enum.take(max(0, min(limit, 20)))

          {:ok, %{content: Jason.encode!(matches), is_error: false}}
        end

      bound[:family] == :collaboration ->
        with :ok <- authorize(operation), do: Backend.execute(operation)

      true ->
        ToolBackend.execute(operation)
    end
  end

  defp authorize(%{backend_context: bound} = operation) do
    host = bound.host_context

    result =
      case Gateway.authorize(operation.tool_name, operation.arguments, host.policy_snapshot, host) do
        {:ok, _grant} -> :ok
        {:error, :requires_approval} -> approve(operation, host)
        {:error, _} -> {:error, Error.new(:forbidden, "Tool is not permitted by this run policy")}
      end

    case result do
      :ok -> :ok
      {:error, %Error{} = error} -> ToolEffects.reject(operation, error)
    end
  end

  defp approve(operation, host) do
    approval_id = Ecto.UUID.generate()
    expires = DateTime.add(DateTime.utc_now(), 30_000, :millisecond)

    request = %{
      kind: :tool_permission,
      approval_id: approval_id,
      tool_name: operation.tool_name,
      arguments: operation.arguments,
      run_id: operation.run_id,
      session_id: host.session_id,
      invocation_id: operation.invocation_id,
      expires_at: DateTime.to_iso8601(expires)
    }

    with {:ok, %{approval_id: ^approval_id, grant: %Grant{source: :operator_approval} = grant}} <-
           operation.backend_context.interact.(request),
         true <- DateTime.compare(DateTime.utc_now(), expires) == :lt,
         :ok <-
           Grant.validate(grant, operation.tool_name, Map.put(host, :input, operation.arguments)),
         {:ok, _} <-
           Gateway.authorize(
             operation.tool_name,
             operation.arguments,
             host.policy_snapshot,
             Map.put(host, :operator_approval, true)
           ) do
      :ok
    else
      _ -> {:error, Error.new(:forbidden, "Approval missing, expired or invalid")}
    end
  end
end
