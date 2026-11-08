defmodule Synapsis.Agent.Tools.WorkspaceMemory do
  @moduledoc """
  Backplane-native read-only tools for workspace Markdown memory.

  The trusted host binds a normalized absolute workspace root and exact
  run/incarnation/catalog scope. Model arguments select only a query or allowed
  relative file and one-based line range. `classify/2` uses that same trusted
  context; native catalog admission and Execution must independently enforce
  grants and revisions. This module does not register production tools.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.Error

  @search "synapsis::workspace_memory_search"
  @get "synapsis::workspace_memory_get"
  @context_keys [:root, :run_id, :incarnation, :catalog_revision]
  # Conversation 1.10.35 enriches effect context with these runtime bindings.
  # They do not select this descriptor's resources and are never invoked here.
  @native_context_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a

  def descriptors(context) do
    with :ok <- context_valid(context) do
      {:ok, [descriptor(@search, context), descriptor(@get, context)]}
    else
      {:error, reason} -> failure(reason)
    end
  end

  def classify(context, operation) do
    with :ok <- context_valid(context),
         :ok <- matching_scope(context, operation),
         :ok <- input(operation) do
      resource = "memory:workspace:#{context.root}"

      case operation.tool_name do
        @search ->
          {:ok, %{action: "memory.search", resource: resource}}

        @get ->
          {:ok,
           %{action: "memory.read", resource: resource <> ":file:" <> operation.arguments["path"]}}
      end
    end
  end

  @impl true
  def execute(%{backend_context: context} = operation) do
    with {:ok, context} <- execution_context(context),
         {:ok, _} <-
           classify(
             context,
             Synapsis.Agent.Tools.CatalogBinding.classification_operation(operation, context)
           ),
         operation = %{operation | backend_context: context},
         {:ok, public} <- read(context.root, operation) do
      result = %{content: text(public), structured: public}

      if byte_size(Jason.encode!(result)) <= 65_536,
        do: {:ok, result},
        else: failure(:output_limit)
    else
      {:error, reason} -> failure(reason)
    end
  end

  def execute(_), do: failure(:invalid_input)

  # Native Execution terminates its effect owner; WorkspaceReader's guardian
  # then terminates the filesystem worker, including a suspended worker.
  @impl true
  def cancel(_), do: :ok

  defp descriptor(name, context) do
    {description, properties, required} =
      case name do
        @search ->
          {"Lexically search this workspace's MEMORY.md and memory/**/*.md with real file/line citations.",
           %{
             "query" => %{"type" => "string", "minLength" => 1, "maxLength" => 2048},
             "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 20}
           }, ["query"]}

        @get ->
          {"Read a bounded excerpt of workspace MEMORY.md or memory/**/*.md using one-based lines.",
           %{
             "path" => %{"type" => "string", "minLength" => 1, "maxLength" => 4096},
             "from" => %{"type" => "integer", "minimum" => 1},
             "lines" => %{"type" => "integer", "minimum" => 1, "maximum" => 120}
           }, ["path"]}
      end

    %{
      tool_name: name,
      tool_revision: 1,
      description: description,
      schema: %{
        "type" => "object",
        "properties" => properties,
        "required" => required,
        "additionalProperties" => false
      },
      safety: %{read_only: true, retry_safe: true, parallel_safe: true},
      backend: __MODULE__,
      backend_context: context
    }
  end

  # Keep descriptor construction and public classify/2 exact. Only native effect
  # execution removes the documented additions before checking the same scope.
  defp execution_context(context) when is_map(context) do
    if Map.keys(context) -- (@context_keys ++ @native_context_keys) == [],
      do: {:ok, Map.take(context, @context_keys)},
      else: {:error, :invalid_context}
  end

  defp execution_context(_), do: {:error, :invalid_context}

  defp context_valid(context) when is_map(context) do
    root = context[:root]

    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         is_binary(root) and String.valid?(root) and not String.contains?(root, "\0") and
         Path.type(root) == :absolute and Path.expand(root) == root and
         valid_run_id?(context.run_id) and is_integer(context.incarnation) and
         context.incarnation > 0 and is_integer(context.catalog_revision) and
         context.catalog_revision > 0,
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp context_valid(_), do: {:error, :invalid_context}

  # Native child run IDs are opaque scope identities, never filesystem components.
  defp valid_run_id?(run_id) do
    is_binary(run_id) and byte_size(run_id) in 1..4096 and String.valid?(run_id) and
      String.trim(run_id) != "" and not String.contains?(run_id, "\0")
  end

  defp matching_scope(context, operation) when is_map(operation) do
    Synapsis.Agent.Tools.CatalogBinding.host(
      context,
      operation,
      __MODULE__,
      1,
      @native_context_keys
    )
  end

  defp matching_scope(_, _), do: {:error, :scope_mismatch}

  defp input(%{tool_name: @search, arguments: %{"query" => query} = args}) do
    limit = Map.get(args, "limit", 5)

    if Map.keys(args) -- ["query", "limit"] == [] and is_binary(query) and String.valid?(query) and
         byte_size(query) in 1..2048 and is_integer(limit) and limit in 1..20,
       do: :ok,
       else: {:error, :invalid_input}
  end

  defp input(%{tool_name: @get, arguments: %{"path" => path} = args}) do
    from = Map.get(args, "from", 1)
    lines = Map.get(args, "lines", 120)

    if Map.keys(args) -- ["path", "from", "lines"] == [] and valid_path?(path) and
         is_integer(from) and from > 0 and is_integer(lines) and lines in 1..120,
       do: :ok,
       else: {:error, :invalid_input}
  end

  defp input(_), do: {:error, :invalid_input}

  # Classification needs a canonical file identity before any filesystem access.
  # The reader independently enforces path, ancestry, link and identity safety.
  defp valid_path?(path) when is_binary(path) do
    String.valid?(path) and byte_size(path) in 1..4096 and
      not String.contains?(path, ["\0", "\\"]) and Path.type(path) == :relative and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."])) and
      (path == "MEMORY.md" or
         (String.starts_with?(path, "memory/") and String.ends_with?(path, ".md")))
  end

  defp valid_path?(_), do: false

  defp read(root, %{tool_name: @search, arguments: args}),
    do: Synapsis.Memory.search_workspace(root, args["query"], limit: Map.get(args, "limit", 5))

  defp read(root, %{tool_name: @get, arguments: args}),
    do:
      Synapsis.Memory.read_workspace(root, args["path"],
        from: Map.get(args, "from", 1),
        lines: Map.get(args, "lines", 120)
      )

  defp text(%{results: []}), do: "No matching workspace memory lines."

  defp text(%{results: results}) do
    "Lexical workspace memory matches; snippets are bounded and may be truncated. Read the cited file for full lines.\n\n" <>
      Enum.map_join(results, "\n\n", fn hit ->
        "#{hit.snippet}\nSource: #{citation(hit)}"
      end)
  end

  defp text(%{content: ""} = page),
    do: "No source lines at or after line #{page.from} in #{page.path}."

  defp text(page) do
    notice =
      cond do
        page.partial_line -> "\nExcerpt truncated. #{page.notice}"
        page.truncated -> "\nExcerpt truncated; continue at line #{page.next_from}."
        true -> ""
      end

    "#{page.content}\nSource: #{citation(page)}#{notice}"
  end

  defp citation(%{path: path, from: first, to: last}) do
    if first == last, do: "#{path}:#{first}", else: "#{path}:#{first}-#{last}"
  end

  defp failure(reason) do
    class =
      cond do
        reason in [:scope_mismatch, :unsafe_path] -> :forbidden
        reason in [:invalid_context, :invalid_input] -> :validation
        reason == :not_found -> :not_found
        reason == :timeout -> :timeout
        reason in [:scan_limit, :file_limit, :output_limit, :worker_limit] -> :budget_exceeded
        reason == :unavailable -> :unsupported_capability
        true -> :malformed_result
      end

    {:error,
     Error.new(class, "workspace memory read failed", details: %{code: Atom.to_string(reason)})}
  end
end
