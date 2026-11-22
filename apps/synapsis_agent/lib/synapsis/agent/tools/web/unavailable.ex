defmodule Synapsis.Agent.Tools.Web.Unavailable do
  @moduledoc false
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Backplane.AgentRuntime.Codex.Session
  alias Synapsis.Agent.Tools.CatalogBinding

  @context_keys [:identity, :session_binding, :tool_name, :revision, :message]
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @schema %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  def descriptor(name, revision, message, identity, binding) do
    %{
      tool_name: name,
      tool_revision: revision,
      description: "Web tool unavailable. " <> message,
      schema: @schema,
      safety: %{read_only: true, retry_safe: true, parallel_safe: true},
      backend: __MODULE__,
      backend_context: %{
        identity: identity,
        session_binding: binding,
        tool_name: name,
        revision: revision,
        message: message
      }
    }
  end

  def classify(%{backend_context: %{identity: identity} = context}, identity, operation) do
    with :ok <- validate(context, operation) do
      action = if context.tool_name == "web::fetch", do: "web.fetch", else: "web.search"
      {:ok, %{action: action, resource: "web:unavailable"}}
    end
  end

  def classify(_, _, _), do: {:error, :scope_mismatch}

  @impl true
  def execute(%{backend_context: enriched} = operation) when is_map(enriched) do
    context = Map.take(enriched, @context_keys)

    case validate(context, operation) do
      :ok ->
        {:ok, %{content: context.message, is_error: true, structured: %{status: "unavailable"}}}

      _ ->
        {:error, Error.new(:forbidden, "Unavailable web tool scope changed")}
    end
  end

  def execute(_), do: {:error, Error.new(:forbidden, "Unavailable web tool scope changed")}

  @impl true
  def cancel(_operation), do: :ok

  defp validate(
         %{identity: identity, session_binding: binding, revision: revision, tool_name: name} =
           context,
         %{tool_name: name, arguments: args} = operation
       ) do
    with :ok <-
           CatalogBinding.host(context, operation, __MODULE__, revision, @native_keys, identity),
         {:ok, _} <- Session.validate(binding, operation),
         {:ok, _} <- InputSchema.validate(@schema, args),
         do: :ok
  end

  defp validate(_, _), do: {:error, :scope_mismatch}
end
