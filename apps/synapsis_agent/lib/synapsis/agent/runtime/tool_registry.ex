defmodule Synapsis.Agent.Runtime.ToolRegistry do
  @moduledoc """
  Admits a fixed set of approved host registrations for one Backplane run.

  Pass the bound entries from the host's tool selection (for example,
  `Daemon.Toolsets.resolve_for_query_loop/1`), never model-provided descriptors.
  One positive catalog revision binds every descriptor and the run authority.
  Admission is all-or-nothing. Process-backed tools and dynamic discovery remain
  unsupported until their cancellation/catalog contracts are implemented.
  """
  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Backplane.AgentRuntime.ToolRegistry, as: Registry
  alias Synapsis.Agent.Runtime.ToolBackend

  @safety %{read_only: false, retry_safe: false, parallel_safe: false}

  def admit(tools, context, opts) when is_list(tools) and is_map(context) and is_list(opts) do
    revision = Keyword.get(opts, :revision)
    caller = Keyword.get(opts, :caller)
    timeout = Keyword.get(opts, :tool_timeout_ms, 30_000)
    approval_timeout = Keyword.get(opts, :approval_timeout_ms, 30_000)

    with :ok <- validate_context(context, revision, caller, timeout, approval_timeout),
         {:ok, snapshot} <- Synapsis.Tool.Gateway.resolve_snapshot(context),
         :ok <- snapshot_scope(snapshot, context),
         host =
           context
           |> Map.drop([:operator_approval, :capability_grant, :input])
           |> Map.put(:policy_snapshot, snapshot),
         {:ok, registry} <- build(tools, host, revision, timeout, approval_timeout) do
      {:ok,
       %{
         registry: registry,
         tools: Enum.map(tools, &Map.take(&1, [:name, :description, :parameters])),
         authority: %{
           caller: caller,
           run_id: context.run_id,
           grants: Enum.map(tools, & &1.name),
           tool_revision: revision
         }
       }}
    end
  end

  def admit(_, _, _), do: error(:validation, "Invalid tool catalog or host context")

  defp build(tools, host, revision, timeout, approval_timeout) do
    Enum.reduce_while(tools, {:ok, %Registry{}}, fn tool, {:ok, registry} ->
      with %{name: name, parameters: schema, registration: entry} when is_binary(name) <- tool,
           false <- Map.has_key?(registry.tools, name),
           :ok <- admissible(name, entry),
           :ok <- bound_definition(tool, entry),
           :ok <- schema_supported(schema),
           {:ok, safety} <- safety(tool),
           {:ok, registry} <-
             Registry.register(registry, %{
               tool_name: name,
               tool_revision: revision,
               backend: ToolBackend,
               schema: schema,
               safety: safety,
               backend_context: %{
                 host_context: host,
                 registration: entry,
                 schema: schema,
                 tool_name: name,
                 revision: revision,
                 tool_timeout_ms: timeout,
                 approval_timeout_ms: approval_timeout
               }
             }) do
        {:cont, {:ok, registry}}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, error(:validation, "Unbound or duplicate tool registration")}
      end
    end)
  end

  # TODO: Wire host discovery policy to the published #42 catalog API before admission.
  defp admissible("tool_search", _),
    do:
      error(
        :unsupported_capability,
        "Dynamic tool discovery requires a runtime catalog update contract"
      )

  # TODO: Wire host per-invocation ownership to the published #43 MCP handles before admission.
  defp admissible(_name, {:process, _, _}),
    do: error(:unsupported_capability, "Process-backed tools require a cancellation contract")

  defp admissible(name, {:module, module, opts} = entry) when is_atom(module) and is_list(opts) do
    cond do
      opts[:deferred] == true ->
        error(:unsupported_capability, "Deferred tools are not admitted")

      Synapsis.Tool.Registry.lookup(name) != {:ok, entry} ->
        error(:resource_conflict, "Tool registration changed")

      not Synapsis.Tool.Registry.runtime_available?(entry) ->
        error(:forbidden, "Tool is unavailable")

      true ->
        :ok
    end
  end

  defp admissible(_, _), do: error(:validation, "Invalid host registration")

  defp bound_definition(tool, {:module, module, opts}) do
    if tool.parameters == (opts[:parameters] || module.parameters()) and
         tool[:description] == (opts[:description] || module.description()),
       do: :ok,
       else: error(:resource_conflict, "Tool definition differs from its host registration")
  end

  # The pinned validator checks the whole schema before input validation. A
  # root argument error means the schema was accepted; schema errors have no
  # argument path. No keyword is removed or rewritten here.
  defp schema_supported(schema) do
    case InputSchema.validate(schema, %{}) do
      {:ok, _} -> :ok
      {:error, %Error{class: :validation, details: %{path: "$arguments"}}} -> :ok
      {:error, _} = error -> error
    end
  end

  defp safety(tool) do
    case Map.get(tool, :safety, %{}) do
      metadata when is_map(metadata) ->
        values = Map.merge(@safety, metadata) |> Map.take(Map.keys(@safety))

        if Enum.all?(values, fn {_, v} -> is_boolean(v) end),
          do: {:ok, values},
          else: error(:validation, "Safety metadata must contain booleans")

      _ ->
        error(:validation, "Safety metadata must be a map")
    end
  end

  defp validate_context(context, revision, caller, timeout, approval_timeout) do
    if is_binary(context[:run_id]) and context.run_id != "" and
         is_binary(context[:project_path]) and Path.type(context.project_path) == :absolute and
         is_integer(revision) and revision > 0 and is_binary(caller) and caller != "" and
         is_integer(timeout) and timeout > 0 and is_integer(approval_timeout) and
         approval_timeout > 0,
       do: :ok,
       else:
         error(
           :validation,
           "Run, project root, catalog revision, caller and finite timeouts are required"
         )
  end

  defp snapshot_scope(snapshot, context) do
    if (is_nil(snapshot.run_id) or snapshot.run_id == context.run_id) and
         (is_nil(snapshot.session_id) or snapshot.session_id == context[:session_id]),
       do: :ok,
       else: error(:forbidden, "Policy snapshot belongs to another session or run")
  end

  defp error(class, message), do: {:error, Error.new(class, message)}
end
