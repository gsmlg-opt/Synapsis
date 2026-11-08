defmodule Synapsis.Agent.Tools.MemoryDomain do
  @moduledoc """
  Native source-aware memory search and existing shared/agent semantic mutations.

  Session and author identities, plus any optional project ID, are trusted domain
  IDs. The native run
  ID is an opaque execution binding and is never used as a stored identity or
  path. Workspace Markdown remains the default read source; semantic mutations
  use the existing file-backed domain port. Host memory is read-only and binds
  the opt-in source observed at descriptor construction; changes require fresh
  descriptors. No legacy tool dispatcher is invoked.

  Semantic access checks at most 128 entries and 64 KiB per file in visible
  scope directories, rejecting links and ownership drift. Checks do not provide
  atomic openat/no-follow protection against hostile concurrent renames. Native
  Execution owns timeout/cancellation; completed writes are not rolled back.
  Save batches validate completely before writing but are not transactions.
  Mutation events use the existing node-local event log after file persistence,
  followed by PubSub/cache invalidation; they are not a durable audit journal.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Memory, as: Domain
  alias Synapsis.Memory.{Adapter, FileAdapter, HostAgent, ScopedReader, Settings}

  @search "synapsis::memory_source_search"
  @save "synapsis::memory_save"
  @update "synapsis::memory_update"
  @kinds ~w(fact decision lesson preference pattern warning)
  @keys ~w(project_path project_id session_id agent_id agent_scope records_root host_source
    run_id incarnation catalog_revision)a
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a

  def descriptors(context) when is_map(context) and not is_struct(context) do
    with true <- Map.keys(context) -- @keys == [],
         {:ok, source} <- configured_host(),
         context =
           context
           |> Map.put_new(:project_id, nil)
           |> Map.put_new(:agent_scope, :agent)
           |> Map.put_new(:records_root, Path.expand(ScopedReader.root()))
           |> Map.put(:host_source, source),
         :ok <- valid_context(context) do
      {:ok, Enum.map([@search, @save, @update], &descriptor(&1, context))}
    else
      false -> failure(:invalid_context)
      {:error, reason} -> failure(reason)
    end
  end

  def descriptors(_), do: failure(:invalid_context)

  def classify(context, operation) do
    with :ok <- valid_context(context),
         :ok <- matching_scope(context, operation),
         :ok <- input(operation) do
      case operation.tool_name do
        @search ->
          search_resource(context, operation.arguments)

        @save ->
          {:ok, %{action: "memory.write", resource: record_resource(context)}}

        @update ->
          {:ok,
           %{
             action: "memory.write",
             resource: record_resource(context) <> ":record:" <> operation.arguments["memory_id"]
           }}
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
         {:ok, public, text} <- run(context, operation) do
      errored =
        operation.tool_name == @save and Enum.any?(public.results, &(&1.status != "saved"))

      result = %{content: text, structured: public, is_error: errored}

      if byte_size(text) <= 32_768 and byte_size(Jason.encode!(result)) <= 65_536,
        do: {:ok, result},
        else: failure(:output_limit)
    else
      {:error, reason} when is_atom(reason) -> failure(reason)
      {:error, %Error{}} = error -> error
    end
  rescue
    _ ->
      failure(
        if(operation[:tool_name] in [@save, @update],
          do: :unknown_outcome,
          else: :malformed_result
        )
      )
  catch
    :exit, _ ->
      failure(
        if(operation[:tool_name] in [@save, @update], do: :unknown_outcome, else: :unavailable)
      )
  end

  def execute(_), do: failure(:invalid_input)

  @impl true
  def cancel(_), do: :ok

  defp descriptor(name, context) do
    {description, properties, required} =
      case name do
        @search ->
          {"Search workspace Markdown by default; explicitly select opt-in host_agent or existing shared/agent records. Record filters require source=records.",
           %{
             "source" => enum(~w(workspace host_agent records)),
             "query" => string(2048),
             "scope" => enum(~w(shared agent)),
             "kinds" => array(enum(@kinds), 6),
             "tags" => array(string(128), 20),
             "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 20}
           }, ["query"]}

        @save ->
          {"Save existing semantic shared/agent records with the trusted persisted agent as author. Does not write workspace Markdown or host memory.",
           %{
             "memories" =>
               Map.put(
                 array(object(memory_properties(), ~w(kind title summary)), 20),
                 "minItems",
                 1
               )
           }, ["memories"]}

        @update ->
          {"Update, archive or restore an existing shared or own-agent semantic record, recording previous state after confirmed persistence.",
           %{
             "action" => enum(~w(update archive restore)),
             "memory_id" => string(128),
             "changes" =>
               object(
                 Map.take(memory_properties(), ~w(title summary kind tags importance))
                 |> Map.put("confidence", score()),
                 []
               )
           }, ~w(action memory_id)}
      end

    %{
      tool_name: name,
      tool_revision: 1,
      description: description,
      schema: object(properties, required),
      backend: __MODULE__,
      backend_context: context,
      safety: %{read_only: name == @search, retry_safe: false, parallel_safe: name == @search}
    }
  end

  defp memory_properties,
    do: %{
      "scope" => enum(~w(shared agent)),
      "kind" => enum(@kinds),
      "title" => string(512),
      "summary" => string(8192),
      "tags" => array(string(128), 20),
      "importance" => score()
    }

  defp string(max), do: %{"type" => "string", "minLength" => 1, "maxLength" => max}
  defp enum(values), do: %{"type" => "string", "enum" => values}
  defp array(items, max), do: %{"type" => "array", "items" => items, "maxItems" => max}

  defp object(properties, required),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }

  defp score, do: %{"type" => "number", "minimum" => 0, "maximum" => 1}

  defp valid_context(context) when is_map(context) and not is_struct(context) do
    if Map.keys(context) -- @keys == [] and
         Enum.all?([:session_id, :agent_id], &ScopedReader.valid_id?(context[&1])) and
         (is_nil(context[:project_id]) or ScopedReader.valid_id?(context[:project_id])) and
         context[:agent_scope] in [:agent, :shared] and absolute?(context[:project_path]) and
         absolute?(context[:records_root]) and valid_run?(context[:run_id]) and
         Enum.all?(
           [:incarnation, :catalog_revision],
           &(is_integer(context[&1]) and context[&1] > 0)
         ) and
         (is_nil(context[:host_source]) or HostAgent.validate_source(context.host_source) == :ok),
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp valid_context(_), do: {:error, :invalid_context}

  defp absolute?(path),
    do:
      text?(path, 4096) and not String.contains?(path, "\0") and
        Path.type(path) == :absolute and Path.expand(path) == path

  defp valid_run?(id), do: text?(id, 4096) and not String.contains?(id, "\0")

  defp execution_context(context) when is_map(context) do
    if Map.keys(context) -- (@keys ++ @native_keys) == [],
      do: {:ok, Map.take(context, @keys)},
      else: {:error, :invalid_context}
  end

  defp execution_context(_), do: {:error, :invalid_context}

  defp matching_scope(context, operation) when is_map(operation) do
    Synapsis.Agent.Tools.CatalogBinding.host(context, operation, __MODULE__, 1, @native_keys)
  end

  defp matching_scope(_, _), do: {:error, :scope_mismatch}

  defp input(%{tool_name: @search, arguments: %{"query" => query} = args}) do
    source = Map.get(args, "source", "workspace")

    if Map.keys(args) -- ~w(source query scope kinds tags limit) == [] and text?(query, 2048) and
         source in ~w(workspace host_agent records) and Map.get(args, "limit", 5) in 1..20 and
         is_integer(Map.get(args, "limit", 5)) and
         (source == "records" or not Enum.any?(~w(scope kinds tags), &Map.has_key?(args, &1))) and
         optional?(args, "scope", &(&1 in ~w(shared agent))) and
         optional?(args, "kinds", &list?(&1, 6, fn kind -> kind in @kinds end)) and
         optional?(args, "tags", &list?(&1, 20, fn tag -> text?(tag, 128) end)),
       do: :ok,
       else: {:error, :invalid_input}
  end

  defp input(%{tool_name: @save, arguments: %{"memories" => memories} = args}) do
    if map_size(args) == 1 and list?(memories, 20, &valid_memory?/1) and memories != [] and
         byte_size(Jason.encode!(args)) <= 32_768,
       do: :ok,
       else: {:error, :invalid_input}
  end

  defp input(%{tool_name: @update, arguments: %{"action" => action, "memory_id" => id} = args}) do
    changes = Map.get(args, "changes", %{})

    if Map.keys(args) -- ~w(action memory_id changes) == [] and
         action in ~w(update archive restore) and
         ScopedReader.valid_id?(id) and (action == "update" or not Map.has_key?(args, "changes")) and
         valid_changes?(changes),
       do: :ok,
       else: {:error, :invalid_input}
  end

  defp input(_), do: {:error, :invalid_input}

  defp valid_memory?(value) when is_map(value) and not is_struct(value) do
    Map.keys(value) -- ~w(scope kind title summary tags importance) == [] and
      Enum.all?(~w(kind title summary), &Map.has_key?(value, &1)) and
      optional?(value, "scope", &(&1 in ~w(shared agent))) and
      valid_changes?(Map.delete(value, "scope"))
  end

  defp valid_memory?(_), do: false

  defp valid_changes?(value) when is_map(value) and not is_struct(value) do
    Map.keys(value) -- ~w(title summary kind tags importance confidence) == [] and
      optional?(value, "title", &(text?(&1, 512) and not String.contains?(&1, ["\n", "\r"]))) and
      optional?(value, "summary", &text?(&1, 8192)) and optional?(value, "kind", &(&1 in @kinds)) and
      optional?(
        value,
        "tags",
        &list?(&1, 20, fn tag -> text?(tag, 128) and not String.contains?(tag, ["\n", "\r"]) end)
      ) and
      Enum.all?(~w(importance confidence), fn key ->
        optional?(value, key, &(is_number(&1) and &1 >= 0 and &1 <= 1))
      end)
  end

  defp valid_changes?(_), do: false
  defp optional?(map, key, check), do: not Map.has_key?(map, key) or check.(map[key])

  defp text?(value, max),
    do:
      is_binary(value) and byte_size(value) in 1..max and
        String.valid?(value) and String.trim(value) != "" and not String.contains?(value, "\0")

  defp list?(value, max, check),
    do: is_list(value) and length(value) <= max and Enum.all?(value, check)

  defp search_resource(context, args) do
    case Map.get(args, "source", "workspace") do
      "workspace" ->
        {:ok, %{action: "memory.search", resource: "memory:workspace:#{context.project_path}"}}

      "records" ->
        {:ok, %{action: "memory.search", resource: record_resource(context)}}

      "host_agent" ->
        with {:ok, source} <- current_host(context),
             do:
               {:ok,
                %{
                  action: "memory.read",
                  resource: "memory:host:#{source.id}:#{source.endpoint}:partition:host_default"
                }}
    end
  end

  defp record_resource(context),
    do:
      "memory:records:#{context.records_root}:agent:#{context.agent_id}:shared:session:#{context.session_id}"

  defp configured_host do
    case Settings.host_source() do
      {:ok, source} -> {:ok, source}
      {:error, :disabled} -> {:ok, nil}
      error -> error
    end
  end

  defp current_host(context) do
    with {:ok, source} <- Settings.host_source(),
         true <- source === context[:host_source] do
      {:ok, source}
    else
      false -> {:error, :source_changed}
      error -> error
    end
  end

  defp run(context, %{tool_name: @search, arguments: args}) do
    case Map.get(args, "source", "workspace") do
      "workspace" ->
        with {:ok, public} <-
               Domain.search_workspace(context.project_path, args["query"],
                 limit: Map.get(args, "limit", 5)
               ),
             do:
               {:ok, public,
                if(public.results == [],
                  do: "No matching workspace memory.",
                  else:
                    Enum.map_join(
                      public.results,
                      "\n\n",
                      &"#{&1.path}:#{&1.from}-#{&1.to}\n#{&1.snippet}"
                    )
                )}

      "host_agent" ->
        with {:ok, source} <- current_host(context),
             {:ok, public} <-
               Domain.recall_host(args["query"], source: source, limit: Map.get(args, "limit", 5)),
             do: {:ok, public, host_text(public)}

      "records" ->
        scope =
          case Map.get(args, "scope") do
            "shared" -> :shared
            "agent" -> :agent
            nil -> context.agent_scope
          end

        with :ok <- records_ready(context, visible_scopes(context, scope)) do
          results =
            Domain.retrieve_semantic(%{
              query: args["query"],
              scope: scope,
              agent_id: context.agent_id,
              kinds: args["kinds"],
              tags: args["tags"],
              limit: Map.get(args, "limit", 5)
            })

          results =
            Enum.filter(results, &({&1.scope, &1.scope_id} in visible_scopes(context, scope)))

          public = %{source: "records", results: results}

          text =
            if results == [],
              do: "No matching semantic memory records.",
              else:
                Enum.map_join(
                  results,
                  "\n\n",
                  &"#{&1.title}\n#{&1.summary}\nSource: semantic memory #{&1.scope}/#{&1.scope_id}/#{&1.id}"
                )

          {:ok, public, text}
        end
    end
  end

  defp run(context, %{tool_name: @save, arguments: %{"memories" => memories}}) do
    scopes = visible_scopes(context, :agent)

    with :ok <- records_ready(context, scopes, length(memories)) do
      results =
        Enum.map(memories, fn memory ->
          {scope, scope_id} = memory_scope(context, memory)

          attrs = %{
            id: Ecto.UUID.generate(),
            scope: scope,
            scope_id: scope_id,
            kind: memory["kind"],
            title: memory["title"],
            summary: memory["summary"],
            tags: Map.get(memory, "tags", []),
            importance: Map.get(memory, "importance", 0.7),
            confidence: 0.8,
            freshness: 1.0,
            source: "agent",
            contributed_by: context.agent_id
          }

          with :ok <- records_ready(context, scopes),
               {:ok, saved} <- Domain.store_semantic(attrs) do
            with :ok <- records_ready(context, scopes),
                 {:ok, persisted} <-
                   Domain.get_semantic(saved.id, scope: scope, scope_id: scope_id),
                 true <-
                   persisted.title == attrs.title and
                     persisted.summary == String.trim(attrs.summary) and
                     persisted.contributed_by == context.agent_id do
              publish(context, persisted, "memory_promoted", %{memory_id: persisted.id})
              %{id: persisted.id, title: persisted.title, status: "saved"}
            else
              _ ->
                %{
                  id: saved.id,
                  title: memory["title"],
                  status: "unknown_outcome",
                  error: "Memory persistence could not be confirmed"
                }
            end
          else
            {:error, _} ->
              %{title: memory["title"], status: "error", error: "Memory persistence failed"}
          end
        end)

      {:ok, %{results: results},
       Enum.map_join(results, "\n", fn result ->
         case result.status do
           "saved" -> "Saved #{result.id}: #{result.title}"
           "unknown_outcome" -> "Save outcome unknown: #{result.id}"
           "error" -> "Save failed: #{result.title}"
         end
       end)}
    end
  end

  defp run(context, %{tool_name: @update, arguments: args}) do
    with :ok <- records_ready(context, visible_scopes(context, :agent)),
         {:ok, original} <- visible_record(context, args["memory_id"]),
         filters = [scope: original.scope, scope_id: original.scope_id],
         :ok <- mutate(original, args, filters),
         :ok <- records_ready(context, [{original.scope, original.scope_id}]),
         {:ok, updated} <- Domain.get_semantic(original.id, filters),
         true <- changes_persisted?(updated, Map.get(args, "changes", %{})),
         true <-
           not is_nil(updated.archived_at) ==
             (args["action"] == "archive" or
                (args["action"] == "update" and not is_nil(original.archived_at))) do
      previous =
        Map.take(original, [
          :title,
          :summary,
          :kind,
          :tags,
          :importance,
          :confidence,
          :archived_at
        ])

      publish(context, updated, "memory_updated", %{
        memory_id: updated.id,
        action: args["action"],
        previous: previous
      })

      {:ok, %{id: updated.id, action: args["action"], status: "success"},
       "Memory #{updated.id}: #{args["action"]} succeeded"}
    else
      false -> {:error, :unknown_outcome}
      error -> error
    end
  end

  defp mutate(record, %{"action" => "archive"}, filters),
    do: Domain.archive_semantic(record, filters)

  defp mutate(record, %{"action" => "restore"}, filters) do
    with {:ok, _} <- Domain.restore_semantic(record, filters), do: :ok
  end

  defp mutate(record, %{"action" => "update"} = args, filters) do
    with {:ok, _} <- Domain.update_semantic(record, Map.get(args, "changes", %{}), filters),
         do: :ok
  end

  defp changes_persisted?(record, changes) do
    Enum.all?(changes, fn {key, value} ->
      expected = if key == "summary", do: String.trim(value), else: value
      Map.fetch!(record, String.to_existing_atom(key)) == expected
    end)
  end

  defp publish(context, record, type, payload) do
    {:ok, _} =
      Domain.append_event(%{
        scope: record.scope,
        scope_id: record.scope_id,
        agent_id: context.agent_id,
        type: type,
        importance: 0.6,
        payload:
          Map.merge(payload, %{project_id: context[:project_id], session_id: context.session_id})
      })

    message =
      if type == "memory_promoted",
        do: {:memory_promoted, record.id},
        else: {:memory_updated, record.id}

    :ok =
      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "memory:#{record.scope}:#{record.scope_id}",
        message
      )

    Synapsis.Memory.Cache.invalidate(record.scope, record.scope_id)
  end

  defp visible_record(context, id) do
    Enum.reduce_while(visible_scopes(context, :agent), {:error, :ownership_mismatch}, fn {scope,
                                                                                          scope_id},
                                                                                         _ ->
      case Domain.get_semantic(id, scope: scope, scope_id: scope_id) do
        {:ok, record} -> {:halt, {:ok, record}}
        {:error, :not_found} -> {:cont, {:error, :ownership_mismatch}}
        error -> {:halt, error}
      end
    end)
  end

  defp visible_scopes(context, :agent), do: [{"agent", context.agent_id}, {"shared", ""}]
  defp visible_scopes(_, :shared), do: [{"shared", ""}]

  defp memory_scope(context, memory) do
    scope = Map.get(memory, "scope", Atom.to_string(context.agent_scope))
    {scope, if(scope == "shared", do: "", else: context.agent_id)}
  end

  defp records_ready(context, scopes, additional_records \\ 0) do
    cond do
      Adapter.active() != FileAdapter ->
        {:error, :unsupported_adapter}

      Path.expand(ScopedReader.root()) != context.records_root ->
        {:error, :source_changed}

      true ->
        Enum.reduce_while(scopes, {:ok, additional_records}, fn {scope, scope_id}, {:ok, count} ->
          directory =
            Path.join([
              context.records_root,
              scope,
              if(scope_id == "", do: "_global", else: scope_id)
            ])

          with :ok <- safe_ancestry(directory),
               {:ok, entries} <- directory_entries(directory),
               true <- count + length(entries) <= 128,
               :ok <- safe_entries(directory, entries) do
            {:cont, {:ok, count + length(entries)}}
          else
            false -> {:halt, {:error, :scan_limit}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, _} -> :ok
          error -> error
        end
    end
  end

  defp safe_ancestry(path) do
    [root | parts] = Path.split(path)

    Enum.reduce_while([root | parts], {:ok, nil}, fn part, {:ok, parent} ->
      current = if is_nil(parent), do: part, else: Path.join(parent, part)

      case File.lstat(current) do
        {:ok, %{type: :directory}} -> {:cont, {:ok, current}}
        {:error, :enoent} -> {:cont, {:ok, current}}
        {:ok, _} -> {:halt, {:error, :unsafe_path}}
        {:error, _} -> {:halt, {:error, :unavailable}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp directory_entries(path) do
    case File.ls(path) do
      {:error, :enoent} -> {:ok, []}
      other -> other
    end
  end

  defp safe_entries(directory, entries) do
    Enum.reduce_while(entries, :ok, fn name, :ok ->
      case File.lstat(Path.join(directory, name)) do
        {:ok, %{type: :regular, links: 1, size: size}} when size <= 65_536 -> {:cont, :ok}
        {:ok, %{type: :regular, links: 1}} -> {:halt, {:error, :file_limit}}
        {:ok, _} -> {:halt, {:error, :unsafe_path}}
        {:error, _} -> {:halt, {:error, :unavailable}}
      end
    end)
  end

  defp host_text(public) do
    state =
      "Host memory #{public.source.id} (#{public.mode}; authority=#{public.authority}; consistency=#{public.consistency}; stale=#{public.stale}; history_available=#{public.history_available}; pending_operations=#{public.pending_operations})."

    state <>
      "\n" <>
      if(public.hits == [],
        do: "No matching host memory records.",
        else:
          Enum.map_join(public.hits, "\n\n", fn hit ->
            marker = if Map.get(hit, :provisional, false), do: " (provisional)", else: ""

            "#{hit.content}\nSource: #{hit.citation.source_id} #{hit.citation.endpoint} record #{hit.memory_id}#{marker}"
          end)
      )
  end

  defp failure(reason) do
    {class, code} =
      cond do
        reason in [:unsafe_path, :ownership_mismatch, :scope_mismatch, :disabled, :source_changed] ->
          {:forbidden, reason}

        reason in [:invalid_context, :invalid_input] ->
          {:validation, reason}

        reason in [:file_limit, :scan_limit, :output_limit] ->
          {:budget_exceeded, reason}

        reason == :unknown_outcome ->
          {:unknown_outcome, reason}

        reason == :timeout ->
          {:timeout, reason}

        reason == :not_found ->
          {:not_found, reason}

        reason in [:unsupported_adapter, :unavailable, :invalid_config] ->
          {:unsupported_capability, reason}

        true ->
          {:malformed_result, :malformed_result}
      end

    {:error, Error.new(class, "Memory operation failed", details: %{code: Atom.to_string(code)})}
  end
end
