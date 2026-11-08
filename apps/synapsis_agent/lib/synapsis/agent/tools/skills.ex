defmodule Synapsis.Agent.Tools.Skills do
  @moduledoc """
  Native search/read descriptors over one frozen assigned and learned catalog.

  Model arguments select metadata queries or exact source-qualified locators.
  Skill text is returned inertly, with source-qualified acquisition guidance.
  Native admission/Execution independently enforce exact grants and revisions.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.Error
  alias Synapsis.{SkillReader, SkillSearch}
  alias Synapsis.Agent.Tools.{SkillBodyCache, SkillResultContract}

  @search "synapsis::skills_search"
  @read "synapsis::skills_read"
  @context_keys [:snapshot, :run_id, :incarnation, :catalog_revision]
  @body_context_keys [:catalog_id, :body_cache, :prepare_search]
  # Conversation 1.10.35 enriches effect context with these runtime bindings.
  # Only the actual pinned catalog and live deadline participate in body preparation.
  @native_context_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a

  def descriptors(context) do
    with :ok <- context_valid(context) do
      {:ok, [descriptor(@search, context), descriptor(@read, context)]}
    else
      {:error, reason} -> failure(reason)
    end
  end

  def classify(context, operation) do
    with :ok <- context_valid(context),
         :ok <- matching_scope(context, operation),
         :ok <- input(operation) do
      resource = "skill:agent:#{SkillReader.agent_id(context.snapshot)}"

      case operation.tool_name do
        @search ->
          {:ok, %{action: "skill.read", resource: resource <> ":catalog"}}

        @read ->
          with {:ok, binding} <-
                 SkillReader.select(context.snapshot, operation.arguments["locator"]) do
            read_target(context.snapshot, binding)
          end
      end
    end
  end

  @doc "Pure source-qualified target shared by real reads and trusted search preparation."
  def read_target(snapshot, binding) do
    if binding in SkillReader.bindings(snapshot) do
      entry = binding.entry

      identity =
        case SkillReader.binding_key(binding) do
          {:assigned, id} -> "record:" <> id
          {:workshop, _, name} -> "skill:" <> URI.encode(name, &URI.char_unreserved?/1)
        end

      {:ok,
       %{
         action: "skill.read",
         resource:
           "skill:agent:#{SkillReader.agent_id(snapshot)}:source:#{entry.authority}:#{entry.source_id}:#{identity}"
       }}
    else
      {:error, :scope_mismatch}
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
         {:ok, public} <- read(context, operation) do
      {:ok, %{content: text(public), structured: public}}
    else
      {:error, reason} -> failure(reason)
    end
  end

  def execute(_), do: failure(:invalid_input)

  # Execution owns the effect process. The domain guardian observes its loss
  # and gives the remote loader a bounded cooperative cancellation window.
  @impl true
  def cancel(_), do: :ok

  defp descriptor(name, context) do
    {description, properties, required} =
      case name do
        @search ->
          {"Search eligible assigned and Agent-private learned skill metadata and bounded instruction text when its paired reader is available. Returns metadata only; read the selected skill's whole instructions before applying it.",
           %{
             "query" => %{"type" => "string", "minLength" => 1, "maxLength" => 2048},
             "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 20}
           }, ["query"]}

        @read ->
          {"Read a complete assigned or Agent-private learned skill as inert text using its exact source-qualified locator.",
           %{"locator" => %{"type" => "string", "minLength" => 1, "maxLength" => 4096}},
           ["locator"]}
      end

    %{
      tool_name: name,
      tool_revision: 2,
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
    if Map.keys(context) -- (@context_keys ++ @body_context_keys ++ @native_context_keys) == [],
      do: {:ok, Map.take(context, @context_keys ++ @body_context_keys)},
      else: {:error, :invalid_context}
  end

  defp execution_context(_), do: {:error, :invalid_context}

  defp context_valid(context) when is_map(context) do
    if context_shape?(context) and
         SkillReader.valid_snapshot?(context[:snapshot]) and
         valid_run_id?(context[:run_id]) and is_integer(context[:incarnation]) and
         context.incarnation > 0 and
         is_integer(context[:catalog_revision]) and context.catalog_revision > 0,
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp context_valid(_), do: {:error, :invalid_context}

  defp context_shape?(context) do
    keys = Enum.sort(Map.keys(context))

    keys == Enum.sort(@context_keys) or
      (keys == Enum.sort(@context_keys ++ @body_context_keys) and
         is_reference(context[:catalog_id]) and is_function(context[:prepare_search], 2) and
         is_map(context[:body_cache]) and is_pid(context.body_cache[:pid]) and
         context.body_cache[:catalog_id] === context.catalog_id)
  end

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
      2,
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

  defp input(%{tool_name: @read, arguments: %{"locator" => locator} = args}) do
    if Map.keys(args) == ["locator"] and is_binary(locator) and String.valid?(locator) and
         byte_size(locator) in 1..4096,
       do: :ok,
       else: {:error, :invalid_input}
  end

  defp input(_), do: {:error, :invalid_input}

  defp read(context, %{tool_name: @search} = operation), do: search(context, operation)

  defp read(context, %{tool_name: @read, arguments: args} = operation) do
    with {:ok, opts} <- read_options(operation),
         do: SkillReader.read(context.snapshot, args["locator"], opts)
  end

  @doc false
  def read_options(%{backend_context: %{effect_deadline: _} = native}) do
    with {:ok, deadline} <- effect_deadline(native), do: {:ok, [deadline: deadline]}
  end

  # Direct execute-only callers retain Core's own bounded read timeout. Native
  # effects always supply their original, nonrenewable effect deadline above.
  def read_options(%{backend_context: _}), do: {:ok, []}

  defp search(
         %{prepare_search: prepare} = context,
         %{backend_context: %{catalog_snapshot: catalog} = native, arguments: args} = operation
       )
       when is_function(prepare, 2) do
    with {:ok, deadline} <- effect_deadline(native),
         {:ok, prepared} <- prepare.(operation, catalog),
         true <- prepared.catalog_id === context.catalog_id do
      recheck = fn ->
        with {:ok, _} <- effect_deadline(native),
             {:ok, current} <- prepare.(operation, catalog),
             true <- current === prepared do
          :ok
        else
          false -> {:error, :stale_snapshot}
          error -> error
        end
      end

      with {:ok, view} <- search_view(context, prepared, deadline, recheck),
           :ok <- recheck.(),
           {:ok, result} <-
             SkillReader.search(context.snapshot, args["query"],
               limit: Map.get(args, "limit", 5),
               deadline: deadline,
               body_view: view
             ),
           :ok <- recheck.() do
        {:ok, result}
      end
    else
      false -> {:error, :scope_mismatch}
      error -> error
    end
  end

  defp search(context, %{arguments: args}),
    do: SkillReader.search(context.snapshot, args["query"], limit: Map.get(args, "limit", 5))

  defp effect_deadline(%{effect_deadline: getter}) when is_function(getter, 0) do
    with {:ok, %{deadline_ms: deadline, remaining_ms: remaining, paused: false}} <- getter.(),
         true <- is_integer(deadline) and is_integer(remaining) and remaining > 0 do
      {:ok, deadline}
    else
      {:error, _} = error -> error
      _ -> {:error, :timeout}
    end
  end

  defp effect_deadline(_), do: {:error, :invalid_context}

  defp search_view(context, %{availability: :metadata_only}, _deadline, recheck) do
    with :ok <- recheck.() do
      {:ok, finished_view(context.snapshot, [], 0)}
    end
  end

  defp search_view(context, prepared, deadline, recheck) do
    with :ok <- recheck.() do
      case SkillBodyCache.claim(context.body_cache, context.catalog_id) do
        {:ready, view} ->
          checked_view(context, view, recheck)

        {:join, ref} ->
          with {:ok, view} <-
                 SkillBodyCache.await(
                   context.body_cache,
                   ref,
                   max(1, deadline - System.monotonic_time(:millisecond))
                 ) do
            checked_view(context, view, recheck)
          end

        {:owner, claim} ->
          try do
            with {:ok, view} <- build_view(context.snapshot, prepared.targets, deadline, recheck),
                 :ok <- recheck.(),
                 :ok <- SkillBodyCache.complete(context.body_cache, claim, view) do
              {:ok, view}
            end
          after
            abandon(context.body_cache, claim)
          end

        error ->
          error
      end
    end
  end

  defp abandon(cache, claim) do
    SkillBodyCache.abandon(cache, claim)
  catch
    :exit, _ -> :ok
  end

  defp checked_view(context, %{snapshot: snapshot} = view, recheck) do
    with true <- snapshot === context.snapshot,
         :ok <- recheck.() do
      {:ok, view}
    else
      false -> {:error, :stale_snapshot}
      error -> error
    end
  end

  defp checked_view(_, _, _), do: {:error, :stale_snapshot}

  defp search_bindings(snapshot) do
    Enum.filter(SkillReader.bindings(snapshot), fn %{entry: entry} ->
      entry.enabled and entry.prompt_visible and
        (entry.authority != :backplane or (is_binary(entry.revision) and entry.revision != ""))
    end)
  end

  defp build_view(snapshot, targets, deadline, recheck) do
    selected =
      snapshot
      |> search_bindings()
      |> Enum.with_index()
      |> Enum.sort_by(fn {binding, position} ->
        {:unicode.characters_to_binary(binding.entry.name, :utf8, {:utf16, :big}), position}
      end)
      |> Enum.take(1_024)

    body_bytes = min(16_384, div(4 * 1_024 * 1_024, max(1, length(selected))))

    result =
      selected
      |> Enum.chunk_every(4)
      |> Enum.reduce_while({:ok, [], 0}, fn batch, {:ok, documents, truncated} ->
        # Start the entire batch before joining any result. IO belongs to these
        # linked children of the actual originating effect, never the cache.
        tasks =
          Enum.map(batch, fn {binding, position} ->
            Task.async(fn ->
              try do
                if Map.get(targets, SkillReader.binding_key(binding)) == :allow do
                  case SkillReader.search_body(snapshot, binding, body_bytes,
                         deadline: deadline,
                         recheck: recheck
                       ) do
                    {:ok, body} ->
                      {:ok, %{position: position, content: body.content}, body.truncated}

                    {:metadata_only, _} ->
                      :metadata_only

                    error ->
                      error
                  end
                else
                  with :ok <- recheck.(), do: :metadata_only
                end
              rescue
                _ -> {:error, :unavailable}
              catch
                _, _ -> {:error, :unavailable}
              end
            end)
          end)

        # Source guardians join their bounded cleanup before returning failures.
        # Join every task before deciding whether a batch can contribute a view.
        results = Enum.map(tasks, &Task.await(&1, :infinity))

        case Enum.find(results, &match?({:error, _}, &1)) do
          nil ->
            bodies = for {:ok, document, _} <- results, do: document
            cut = Enum.count(results, &match?({:ok, _, true}, &1))
            {:cont, {:ok, documents ++ bodies, truncated + cut}}

          error ->
            {:halt, error}
        end
      end)

    with {:ok, documents, truncated} <- result,
         :ok <- recheck.() do
      view = finished_view(snapshot, documents, truncated)
      with :ok <- recheck.(), do: {:ok, view}
    end
  end

  defp finished_view(snapshot, documents, truncated) do
    %{
      snapshot: snapshot,
      index: SkillSearch.prepare_bodies(documents),
      coverage: %{
        bodyIndexed: length(documents),
        metadataOnly: length(search_bindings(snapshot)) - length(documents),
        truncatedBodies: truncated
      }
    }
  end

  defp text(%{coverage: coverage} = result) do
    text(Map.delete(result, :coverage)) <>
      "\nInstruction search coverage: #{coverage.bodyIndexed} body indexed, " <>
      "#{coverage.metadataOnly} metadata only, #{coverage.truncatedBodies} truncated bodies."
  end

  defp text(%{results: []}), do: "No matching eligible skills."

  defp text(%{results: results, truncated: truncated}) do
    entries =
      Enum.map_join(results, "\n", fn hit ->
        "#{hit.name}: #{hit.description}\nSource: #{hit.locator}"
      end)

    entries <>
      if(truncated, do: "\nMore matching skills omitted by the requested result limit.", else: "")
  end

  defp text(page), do: SkillResultContract.format_instructions(page)

  defp failure(%Error{} = error), do: {:error, error}

  defp failure(reason) do
    class =
      cond do
        reason in [:scope_mismatch, :stale_snapshot, :unsafe_path, :digest_mismatch] ->
          :forbidden

        reason in [:invalid_context, :invalid_input] ->
          :validation

        reason == :not_found ->
          :not_found

        reason == :timeout ->
          :timeout

        reason in [:candidate_limit, :file_limit, :output_limit, :worker_limit] ->
          :budget_exceeded

        reason == :unavailable ->
          :unsupported_capability

        true ->
          :malformed_result
      end

    {:error, Error.new(class, "skill read failed", details: %{code: Atom.to_string(reason)})}
  end
end
