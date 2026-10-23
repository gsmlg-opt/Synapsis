defmodule Synapsis.Agent.Tools.Memory do
  @moduledoc """
  Backplane-native host descriptors for real scoped project semantic memory.

  The trusted host binds run/incarnation/catalog, project, session and a resolved
  storage root at construction. Project/session association is host authority;
  model arguments cannot select ownership or paths. Session semantic records,
  file excerpts, vectors and OpenClaw corpora remain unsupported. Policy bindings
  should use `classify/2` with the same trusted context. This module does not
  install descriptors or switch the production dispatcher.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Memory.ScopedReader

  @search "synapsis::memory_search"
  @read "synapsis::memory_read"

  def descriptors(context) do
    with :ok <- context_valid(context) do
      context = Map.put_new(context, :root, Path.expand(ScopedReader.root()))
      {:ok, [descriptor(@search, context), descriptor(@read, context)]}
    else
      _ ->
        {:error,
         Error.new(:validation, "memory descriptors require trusted project/session/run scope")}
    end
  end

  def classify(context, operation) do
    with :ok <- context_valid(context),
         :ok <- matching_scope(context, operation),
         :ok <- input(operation) do
      resource = "memory:project:#{context.project_id}:session:#{context.session_id}"

      case operation.tool_name do
        @search ->
          {:ok, %{action: "memory.search", resource: resource}}

        @read ->
          {:ok,
           %{
             action: "memory.read",
             resource: resource <> ":record:" <> operation.arguments["memory_id"]
           }}
      end
    end
  end

  @impl true
  def execute(%{backend_context: context} = operation) do
    with {:ok, _} <- classify(context, operation) do
      scope = Map.take(context, [:project_id, :session_id]) |> Map.put(:selector, :project)
      opts = [root: context.root]

      result =
        case operation.tool_name do
          @search ->
            ScopedReader.search(
              scope,
              operation.arguments["query"],
              Keyword.put(opts, :limit, Map.get(operation.arguments, "limit", 5))
            )

          @read ->
            ScopedReader.read(scope, operation.arguments["memory_id"], opts)
        end

      case result do
        {:ok, public} ->
          result = %{content: text(public), structured: public}

          if byte_size(Jason.encode!(result)) <= 65_536,
            do: {:ok, result},
            else: failure(:output_limit)

        {:error, reason} ->
          failure(reason)
      end
    else
      {:error, :scope_mismatch} -> failure(:scope_mismatch)
      {:error, _} -> failure(:invalid_input)
    end
  end

  def execute(_), do: failure(:invalid_input)

  @impl true
  def cancel(_), do: :ok

  defp descriptor(name, context) do
    {description, properties, required} =
      case name do
        @search ->
          {"Lexically search this project's semantic memory records; no session/shared fallback.",
           %{
             "query" => %{"type" => "string", "minLength" => 1, "maxLength" => 2048},
             "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 20}
           }, ["query"]}

        @read ->
          {"Read a project semantic memory record by ID; citations are record IDs, not file lines.",
           %{"memory_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 128}},
           ["memory_id"]}
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

  defp context_valid(context) when is_map(context) do
    if Enum.all?([:project_id, :session_id, :run_id], &ScopedReader.valid_id?(context[&1])) and
         Enum.all?(
           [:incarnation, :catalog_revision],
           &(is_integer(context[&1]) and context[&1] > 0)
         ) and
         (not Map.has_key?(context, :root) or
            (is_binary(context.root) and Path.type(context.root) == :absolute)),
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp context_valid(_), do: {:error, :invalid_context}

  defp matching_scope(context, operation) when is_map(operation) do
    if Enum.all?(
         [:run_id, :incarnation, :catalog_revision],
         &(Map.get(operation, &1) === context[&1])
       ) and operation[:tool_revision] === 1,
       do: :ok,
       else: {:error, :scope_mismatch}
  end

  defp matching_scope(_, _), do: {:error, :scope_mismatch}

  defp input(%{tool_name: @search, arguments: %{"query" => query} = args}) do
    limit = Map.get(args, "limit", 5)

    if Map.keys(args) -- ["query", "limit"] == [] and is_binary(query) and String.valid?(query) and
         byte_size(query) in 1..2048 and is_integer(limit) and limit in 1..20,
       do: :ok,
       else: {:error, :invalid_input}
  end

  defp input(%{tool_name: @read, arguments: %{"memory_id" => id} = args}) do
    if map_size(args) == 1 and ScopedReader.valid_id?(id), do: :ok, else: {:error, :invalid_input}
  end

  defp input(_), do: {:error, :invalid_input}

  defp text(%{record: record}), do: record_text(record)
  defp text(%{results: []}), do: "No matching project semantic memory records."
  defp text(%{results: records}), do: Enum.map_join(records, "\n\n", &record_text/1)

  defp record_text(record),
    do:
      "#{record.title}\n#{record.summary}\nSource: semantic memory #{record.citation.scope}/#{record.citation.scope_id}/#{record.memory_id}#{if record.truncated, do: " (summary truncated)", else: ""}"

  defp failure(reason) do
    class =
      cond do
        reason in [:unsafe_path, :ownership_mismatch, :scope_mismatch] -> :forbidden
        reason == :not_found -> :not_found
        reason == :timeout -> :timeout
        reason in [:scan_limit, :file_limit, :output_limit, :worker_limit] -> :budget_exceeded
        reason in [:unavailable, :unsupported_scope] -> :unsupported_capability
        reason in [:invalid_input, :invalid_scope, :invalid_memory_id] -> :validation
        true -> :malformed_result
      end

    {:error,
     Error.new(class, "project semantic memory read failed",
       details: %{code: Atom.to_string(reason)}
     )}
  end
end
