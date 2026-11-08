defmodule Synapsis.Agent.Tools.SessionDirectory do
  @moduledoc "Native bounded durable directory with optional source title/preview/history; never reads a live Worker."
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Synapsis.SessionDirectory, as: Domain

  @name "synapsis::sessions_list"
  @names [@name]
  @revision 3
  # Public pretty JSON remains 64 KiB. The native envelope contains both that
  # JSON string and its structured tree, so it has a separate transport bound.
  @output_limit 262_144
  @context_keys [:session_id, :agent_id, :run_id, :incarnation, :catalog_revision]
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a

  def names, do: @names
  def revision, do: @revision
  def permission_level(name) when name in @names, do: :read

  def descriptors(context) do
    with :ok <- context_valid(context) do
      {:ok,
       Enum.map(@names, fn name ->
         %{
           tool_name: name,
           tool_revision: @revision,
           description: description(),
           schema: schema(),
           safety: %{read_only: true, retry_safe: true, parallel_safe: true},
           backend: __MODULE__,
           backend_context: context
         }
       end)}
    else
      {:error, reason} -> failure(reason)
    end
  end

  def classify(context, operation) do
    with :ok <- context_valid(context),
         :ok <- matching_scope(context, operation),
         :ok <- input(operation) do
      resource =
        Map.merge(operation.arguments, %{
          "session_id" => context.session_id,
          "agent_id" => context.agent_id
        })

      {:ok,
       %{
         action: "session.directory.list",
         resource: "session_directory:" <> Jason.encode!(resource)
       }}
    end
  end

  @impl true
  def execute(%{backend_context: enriched} = operation) do
    ceiling = System.monotonic_time(:millisecond) + 5_000

    with {:ok, context} <- execution_context(enriched),
         {:ok, deadline} <- effect_deadline(enriched, ceiling),
         {:ok, _} <-
           classify(
             context,
             Synapsis.Agent.Tools.CatalogBinding.classification_operation(operation, context)
           ),
         operation = %{operation | backend_context: context},
         trusted = Map.take(context, [:session_id, :agent_id]),
         {:ok, %{text: text, page: page}} <-
           Domain.list_rendered(
             operation.arguments,
             trusted,
             domain_options(operation.arguments, deadline)
           ),
         native = %{content: text, structured: page},
         true <- byte_size(Jason.encode!(native)) <= @output_limit,
         :ok <- remaining(deadline) do
      {:ok, native}
    else
      false -> failure(:output_limit)
      {:error, reason} -> failure(reason)
    end
  rescue
    _ -> failure(:unavailable)
  catch
    _, _ -> failure(:unavailable)
  end

  def execute(_), do: failure(:invalid_context)

  @impl true
  def cancel(_operation), do: :ok

  defp description,
    do:
      "List durable sessions for the trusted operator, including inactive sessions. Optional include_derived_titles and include_last_message default false; the first 100 selected rows can derive source titles and plain-text last-message previews from bounded fixed-revision durable pages. Optional message_limit defaults to 0 (no history); positive values are capped at 20 source-projected recent messages for every selected row. Saved title remains unchanged. Filter by configured Agent, public metadata substring, or durable updated_at activity; this is not liveness. Sort updated_at descending then id ascending, missing timestamps last. Defaults limit 100, offset 0; rejects limits above 200. Scans at most 1,000 candidate keys in pages of 100, returning scan_limit if more exist. Calls have no cross-page or in-flight guarantee. Public pretty JSON fits 64 KiB by prefix, reporting optional enrichment omission or byte truncation."

  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 200, "default" => 100},
        "offset" => %{"type" => "integer", "minimum" => 0, "maximum" => 1000, "default" => 0},
        "include_derived_titles" => %{"type" => "boolean", "default" => false},
        "include_last_message" => %{"type" => "boolean", "default" => false},
        "message_limit" => %{"type" => "integer", "minimum" => 0, "default" => 0},
        "agent" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => 255,
          "description" => "Optional configured Agent name; no ownership filter by default."
        },
        "search" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => 256,
          "description" =>
            "Case-insensitive substring of public id, title, agent, provider, model or status metadata."
        },
        "active_minutes" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 525_600,
          "description" =>
            "Durable updated_at within this many minutes at request time; does not indicate live activity."
        }
      },
      "required" => [],
      "additionalProperties" => false
    }
  end

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         uuid?(context[:session_id]) and opaque?(context[:agent_id], 255) and
         opaque?(context[:run_id], 4096) and
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

  defp effect_deadline(%{effect_deadline: getter}, ceiling) when is_function(getter, 0) do
    with {:ok, %{deadline_ms: deadline, remaining_ms: remaining, paused: false}} <- getter.(),
         true <- is_integer(deadline) and is_integer(remaining) and remaining > 0 do
      {:ok, min(deadline, ceiling)}
    else
      {:error, _} = error -> error
      _ -> {:error, :timeout}
    end
  end

  defp effect_deadline(%{effect_deadline: _}, _), do: {:error, :invalid_context}
  defp effect_deadline(_, ceiling), do: {:ok, ceiling}

  defp remaining(deadline),
    do: if(deadline > System.monotonic_time(:millisecond), do: :ok, else: {:error, :timeout})

  defp matching_scope(context, operation) when is_map(operation) do
    Synapsis.Agent.Tools.CatalogBinding.host(
      context,
      operation,
      __MODULE__,
      @revision,
      @native_keys
    )
  end

  defp matching_scope(_, _), do: {:error, :scope_mismatch}

  defp domain_options(input, deadline) do
    if input["include_derived_titles"] == true or input["include_last_message"] == true or
         Map.get(input, "message_limit", 0) > 0 do
      case Application.get_env(:synapsis_agent, :filesystem_node) do
        node when is_binary(node) -> [deadline: deadline, node_executable: node]
        _ -> [deadline: deadline]
      end
    else
      [deadline: deadline]
    end
  end

  defp input(%{tool_name: name, arguments: args}) when name in @names and is_map(args) do
    with {:ok, _} <- InputSchema.validate(schema(), args),
         :ok <- Domain.validate(args) do
      :ok
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp input(_), do: {:error, :invalid_input}
  defp uuid?(id) when is_binary(id), do: match?({:ok, ^id}, Ecto.UUID.cast(id))
  defp uuid?(_), do: false

  defp opaque?(value, limit),
    do:
      is_binary(value) and byte_size(value) in 1..limit and String.valid?(value) and
        String.trim(value) != "" and not String.contains?(value, "\0")

  defp failure(%Error{} = error), do: {:error, error}

  defp failure(reason) do
    class =
      case reason do
        :scope_mismatch ->
          :forbidden

        reason when reason in [:invalid_input, :invalid_context] ->
          :validation

        :timeout ->
          :timeout

        :malformed_metadata ->
          :malformed_result

        reason when reason in [:output_limit, :scan_limit, :payload_too_large] ->
          :budget_exceeded

        _ ->
          :execution_failure
      end

    {:error,
     Error.new(class, "Session directory read failed", details: %{code: Atom.to_string(reason)})}
  end
end
