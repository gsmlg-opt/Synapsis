defmodule Synapsis.Agent.Tools.Filesystem do
  @moduledoc """
  Native filesystem descriptors with separate real-file and Workspace identities.

  Scope and Workspace identity come only from trusted descriptor context. Native
  admission and host Policy establish permission; this backend independently
  checks scope, argument shape, containment and Workspace authorization. It never
  invokes the legacy tool runtime or grants shell execution.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Filesystem.{Arguments, Local}
  alias Synapsis.Workspace.ToolFiles

  @context_keys [:root, :run_id, :incarnation, :catalog_revision, :workspace]
  @canonical_names ~w(synapsis::read synapsis::write synapsis::edit synapsis::ls)
  @canonical_context_keys @context_keys ++
                            [:path_environment, :prepared_target_resolver, :execution_options]
  @identity_keys ~w(run_id incarnation catalog_revision invocation_id tool_name tool_revision turn_id step_id attempt_id tool_call_id enclosing_invocation_id)a
  @correlation_keys ~w(turn_id step_id attempt_id tool_call_id)a
  @record_keys ~w(version key correlation raw_arguments_digest prepared_arguments_digest original_path public_path source_path requested_absolute target source_prefix action resource)a
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding execution_mode headless_input)a
  def names, do: @canonical_names

  def permission_level(name) when name in ~w(synapsis::read synapsis::ls), do: :read
  def permission_level(name) when name in ~w(synapsis::write synapsis::edit), do: :write

  def descriptors(context) do
    with :ok <- canonical_context_valid(context) do
      {:ok, Enum.map(@canonical_names, &descriptor(&1, context))}
    else
      {:error, reason} -> failure(reason)
    end
  end

  @doc "Prepares canonical arguments and seals one metadata-only target before classification."
  def prepare_arguments(
        %{arguments: arguments, tool_name: name, tool_revision: 1} = invocation,
        %{backend: __MODULE__, backend_context: context, tool_name: name, tool_revision: 1},
        %{catalog_snapshot: catalog, filesystem_preparation: callbacks}
      )
      when name in @canonical_names and is_map(arguments) and not is_struct(arguments) do
    identity = Map.take(invocation, @identity_keys)

    with :ok <- canonical_context_valid(context),
         operation =
           Map.put(invocation, :backend_context, Map.put(context, :catalog_snapshot, catalog)),
         :ok <- scope(context, operation),
         true <- preparation_callbacks?(callbacks),
         {:ok, reservation} <- callbacks.reserve.(identity, catalog, arguments_digest(arguments)) do
      prepare_reserved(reservation, invocation, context, callbacks, identity, catalog)
    else
      false -> {:error, :invalid_context}
      error -> error
    end
  end

  def prepare_arguments(_, _, _), do: {:error, :invalid_input}

  @doc "Validates raw and committed argument digests against the live sealed target."
  def validate_prepared_receipt(
        raw_arguments,
        %{tool_name: name, tool_revision: 1, backend_context: enriched} = operation
      )
      when name in @canonical_names and is_map(raw_arguments) and not is_struct(raw_arguments) do
    with {:ok, context} <- canonical_execution_context(enriched),
         {:ok, record} <- prepared_target(context, operation),
         true <- record.raw_arguments_digest === arguments_digest(raw_arguments) do
      :ok
    else
      false -> {:error, :invalid_prepared_target}
      error -> error
    end
  end

  def validate_prepared_receipt(_, _), do: {:error, :invalid_input}

  @doc "Checks the pure canonical raw/prepared relationship without selecting a target."
  def canonical_arguments?(name, raw_arguments, prepared_arguments)
      when name in @canonical_names and is_map(raw_arguments) and not is_struct(raw_arguments) and
             is_map(prepared_arguments) and not is_struct(prepared_arguments) do
    case project_arguments(name, raw_arguments) do
      {:ok, projected} ->
        projected === prepared_arguments or
          canonical_literal_arguments?(projected, prepared_arguments)

      {:error, _} ->
        false
    end
  end

  def canonical_arguments?(_, _, _), do: false

  def classify(context, %{tool_name: name} = operation) when name in @canonical_names do
    with {:ok, record} <- prepared_target(context, operation),
         do: {:ok, Map.take(record, [:action, :resource])}
  end

  def classify(_, _), do: {:error, :invalid_input}

  @impl true
  def execute(%{tool_name: name, backend_context: enriched} = operation)
      when name in @canonical_names do
    with {:ok, context} <- canonical_execution_context(enriched),
         {:ok, deadline} <- effect_deadline(enriched),
         {:ok, record} <- prepared_target(context, operation),
         {:ok, result} <-
           dispatch_prepared(
             context,
             canonical_action(name),
             operation.arguments,
             record,
             deadline
           ) do
      {:ok, result}
    else
      {:error, reason} -> failure(reason)
    end
  end

  def execute(_), do: failure(:invalid_input)

  # Execution owns this effect process. Local's guardian monitors it and kills
  # the filesystem worker on cancellation, including a suspended worker.
  @impl true
  def cancel(_operation), do: :ok

  defp prepare_reserved(
         {:existing, record},
         invocation,
         _context,
         _callbacks,
         _identity,
         _catalog
       ) do
    digest = arguments_digest(invocation.arguments)

    with :ok <- record_identity(record, invocation),
         {:ok, prepared} <- retry_arguments(invocation, record, digest),
         :ok <- record_valid(record, %{invocation | arguments: prepared}) do
      {:ok, prepared}
    end
  end

  defp prepare_reserved({:new, token}, invocation, context, callbacks, identity, catalog) do
    try do
      result =
        with {:ok, arguments} <- project_arguments(invocation.tool_name, invocation.arguments),
             {:ok, candidate} <- select_target(context, invocation, arguments),
             prepared = restore_public_path(arguments, candidate.public_path),
             {:ok, record} <-
               callbacks.seal.(identity, catalog, token, candidate, arguments_digest(prepared)),
             :ok <- record_valid(record, %{invocation | arguments: prepared}) do
          {:ok, prepared}
        end

      case result do
        {:ok, _} ->
          result

        error ->
          callbacks.abandon.(identity, catalog, token)
          error
      end
    rescue
      exception ->
        callbacks.abandon.(identity, catalog, token)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        callbacks.abandon.(identity, catalog, token)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp prepare_reserved(_, _, _, _, _, _), do: {:error, :prepared_target_conflict}

  defp retry_arguments(invocation, record, digest) do
    cond do
      digest === record.prepared_arguments_digest ->
        {:ok, invocation.arguments}

      digest === record.raw_arguments_digest ->
        with {:ok, arguments} <- project_arguments(invocation.tool_name, invocation.arguments),
             do: {:ok, restore_public_path(arguments, record.public_path)}

      true ->
        {:error, :prepared_target_conflict}
    end
  end

  defp project_arguments(name, arguments) do
    projected =
      if name == "synapsis::edit", do: Arguments.prepare_edit(arguments), else: {:ok, arguments}

    with {:ok, prepared} <- projected do
      case Map.fetch(prepared, "path") do
        :error when name == "synapsis::ls" ->
          {:ok, prepared}

        {:ok, path} ->
          with {:ok, path} <- Arguments.normalize_path(path),
               do: {:ok, Map.put(prepared, "path", path)}

        _ ->
          {:error, :invalid_input}
      end
    end
  end

  defp canonical_literal_arguments?(%{"path" => path} = projected, prepared) do
    not virtual?(path) and Local.literal_target_repair_eligible?(path) and
      Map.put(projected, "path", "./" <> path) === prepared
  end

  defp canonical_literal_arguments?(_, _), do: false

  defp select_target(context, invocation, arguments) do
    public_path = Map.get(arguments, "path", :omitted)
    action = canonical_action(invocation.tool_name)
    source = if action == :ls and public_path in [:omitted, ""], do: ".", else: public_path
    original = Map.get(invocation.arguments, "path", :omitted)

    if virtual?(source) do
      path = logical(source)

      with :ok <-
             ToolFiles.authorize_source(
               context.workspace,
               action,
               domain_arguments(action, arguments, path),
               context.path_environment.workspace_root
             ) do
        {:ok,
         %{
           original_path: original,
           public_path: public_path,
           source_path: source,
           requested_absolute: nil,
           target: {:workspace, path},
           source_prefix: ""
         }}
      end
    else
      deadline = System.monotonic_time(:millisecond) + 5_000

      with {:ok, selected} <-
             Local.prepare_target(context.root, source, action, context.path_environment,
               deadline: deadline
             ) do
        public =
          if action == :ls and public_path in [:omitted, ""],
            do: public_path,
            else: selected.source_path

        {:ok,
         %{
           original_path: original,
           public_path: public,
           source_path: selected.source_path,
           requested_absolute: selected.requested_absolute,
           target: {:local, selected.absolute_path, selected.relative_path},
           source_prefix: selected.source_prefix
         }}
      end
    end
  end

  defp restore_public_path(arguments, :omitted), do: Map.delete(arguments, "path")
  defp restore_public_path(arguments, path), do: Map.put(arguments, "path", path)

  # Fetch uses the committed arguments and exact pinned descriptor. Revalidation
  # checks the selected target only; it never runs the source selector again.
  defp prepared_target(context, operation) do
    with :ok <- canonical_context_valid(context),
         :ok <- scope(context, operation),
         true <- is_map(operation[:arguments]) and not is_struct(operation.arguments),
         {:ok, catalog} <- Map.fetch(operation.backend_context, :catalog_snapshot),
         {:ok, record} <-
           context.prepared_target_resolver.(
             Map.take(operation, @identity_keys),
             catalog,
             arguments_digest(operation.arguments)
           ),
         :ok <- record_valid(record, operation),
         :ok <- authorize_target(context, operation, record) do
      {:ok, record}
    else
      false -> {:error, :invalid_input}
      :error -> {:error, :scope_mismatch}
      error -> error
    end
  end

  defp record_valid(record, invocation) do
    with :ok <- record_identity(record, invocation),
         true <- record.prepared_arguments_digest === arguments_digest(invocation.arguments),
         true <- record.public_path === Map.get(invocation.arguments, "path", :omitted),
         {:ok, namespace, path} <- record_target(record),
         verb =
           if(invocation.tool_name == "synapsis::ls",
             do: "list",
             else: Atom.to_string(canonical_action(invocation.tool_name))
           ),
         true <-
           record.action === namespace <> "." <> verb and
             record.resource === namespace <> ":" <> path,
         true <- valid_source_prefix?(record, invocation.tool_name) do
      :ok
    else
      _ -> {:error, :invalid_prepared_target}
    end
  end

  defp record_identity(record, invocation) when is_map(record) and not is_struct(record) do
    key =
      {invocation[:run_id], invocation[:incarnation], invocation[:catalog_revision],
       invocation[:invocation_id], invocation[:tool_name], invocation[:tool_revision]}

    correlation =
      invocation
      |> Map.take(@correlation_keys)
      |> Map.put(
        :enclosing_invocation_id,
        invocation[:enclosing_invocation_id] || invocation[:invocation_id]
      )

    if Enum.sort(Map.keys(record)) == Enum.sort(@record_keys) and record.version === 1 and
         record.key === key and record.correlation === correlation and
         digest?(record.raw_arguments_digest) and digest?(record.prepared_arguments_digest),
       do: :ok,
       else: {:error, :invalid_prepared_target}
  end

  defp record_identity(_, _), do: {:error, :invalid_prepared_target}

  defp record_target(%{
         target: {:local, absolute, relative},
         source_path: source,
         requested_absolute: requested
       }) do
    if absolute_path?(absolute) and is_binary(relative) and relative != "" and
         String.valid?(relative) and
         is_binary(source) and source != "" and String.valid?(source) and
         absolute_path?(requested),
       do: {:ok, "filesystem", absolute},
       else: {:error, :invalid_prepared_target}
  end

  defp record_target(%{
         target: {:workspace, logical},
         source_path: source,
         requested_absolute: nil
       }) do
    if absolute_path?(logical) and source === "@synapsis" <> logical,
      do: {:ok, "workspace", logical},
      else: {:error, :invalid_prepared_target}
  end

  defp record_target(_), do: {:error, :invalid_prepared_target}

  defp valid_source_prefix?(%{source_prefix: ""}, _), do: true

  defp valid_source_prefix?(
         %{target: {:local, selected, _}, requested_absolute: requested, source_prefix: prefix},
         "synapsis::read"
       ) do
    requested_name = Path.basename(requested)
    selected_name = Path.basename(selected)

    requested_name != selected_name and
      prefix === "[Resolved filename: #{requested_name} -> #{selected_name}.]\n"
  end

  defp valid_source_prefix?(_, _), do: false

  defp authorize_target(context, _operation, %{target: {:local, absolute, relative}}) do
    case Local.resolve(context.root, absolute) do
      {:ok, ^absolute, ^relative} -> :ok
      {:ok, _, _} -> {:error, :unsafe_path}
      error -> error
    end
  end

  defp authorize_target(context, operation, %{target: {:workspace, path}}) do
    action = canonical_action(operation.tool_name)

    ToolFiles.authorize_source(
      context.workspace,
      action,
      domain_arguments(action, operation.arguments, path),
      context.path_environment.workspace_root
    )
  end

  defp dispatch_prepared(
         context,
         action,
         arguments,
         %{target: {:local, path, _}} = record,
         deadline
       ) do
    args = domain_arguments(action, arguments, path)
    opts = effect_options(context, action, record, deadline)

    case action do
      :read -> Local.read_file(context.root, path, Map.delete(args, "path"), opts)
      :write -> Local.write_text(context.root, path, args["content"], opts)
      :edit -> Local.edit_text(context.root, path, args["edits"], opts)
      :ls -> Local.list_directory(context.root, path, Map.delete(args, "path"), opts)
    end
  end

  defp dispatch_prepared(
         context,
         action,
         arguments,
         %{target: {:workspace, path}} = record,
         deadline
       ) do
    args = domain_arguments(action, arguments, path)
    opts = effect_options(context, action, record, deadline)
    root = context.path_environment.workspace_root

    case action do
      :read -> ToolFiles.read_file(context.workspace, args, opts, root)
      :write -> ToolFiles.write_text(context.workspace, args, opts, root)
      :edit -> ToolFiles.edit_text(context.workspace, args, opts, root)
      :ls -> ToolFiles.list_directory(context.workspace, args, opts, root)
    end
  end

  defp domain_arguments(action, arguments, path) do
    keys =
      case action do
        :read -> ~w(offset cursor limit optional)
        :write -> ~w(content)
        :edit -> ~w(edits)
        :ls -> ~w(after limit)
      end

    arguments |> Map.take(keys) |> Map.put("path", path)
  end

  defp effect_options(context, action, record, deadline) do
    options =
      case action do
        :read ->
          Keyword.put(context.execution_options, :prefix, record.source_prefix)

        action when action in [:write, :edit] ->
          context.execution_options
          |> Keyword.take([:node_executable])
          |> Keyword.put(:display_path, record.source_path)

        :ls ->
          Keyword.take(context.execution_options, [:model_budget])
      end

    Keyword.put(options, :deadline, deadline)
  end

  defp effect_deadline(%{effect_deadline: getter}) when is_function(getter, 0) do
    with {:ok, %{deadline_ms: deadline, remaining_ms: remaining, paused: false}} <- getter.(),
         true <- is_integer(deadline) and is_integer(remaining) and remaining > 0 do
      {:ok, min(deadline, System.monotonic_time(:millisecond) + 5_000)}
    else
      {:error, _} = error -> error
      _ -> {:error, :timeout}
    end
  end

  defp effect_deadline(_), do: {:error, :invalid_context}

  defp canonical_action("synapsis::read"), do: :read
  defp canonical_action("synapsis::write"), do: :write
  defp canonical_action("synapsis::edit"), do: :edit
  defp canonical_action("synapsis::ls"), do: :ls

  defp arguments_digest(arguments),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(arguments, [:deterministic]))

  defp digest?(digest), do: is_binary(digest) and byte_size(digest) == 32

  defp preparation_callbacks?(callbacks) when is_map(callbacks) and not is_struct(callbacks),
    do:
      is_function(callbacks[:reserve], 3) and is_function(callbacks[:seal], 5) and
        is_function(callbacks[:fetch], 3) and is_function(callbacks[:abandon], 3)

  defp preparation_callbacks?(_), do: false

  defp canonical_execution_context(context) when is_map(context) do
    if Map.keys(context) -- (@canonical_context_keys ++ @native_keys) == [],
      do: {:ok, Map.take(context, @canonical_context_keys)},
      else: {:error, :invalid_context}
  end

  defp canonical_execution_context(_), do: {:error, :invalid_context}

  defp canonical_context_valid(context) when is_map(context) and not is_struct(context) do
    with true <- Enum.sort(Map.keys(context)) == Enum.sort(@canonical_context_keys),
         :ok <- context_valid(Map.take(context, @context_keys)),
         true <- path_environment?(context.path_environment),
         true <- is_function(context.prepared_target_resolver, 3),
         true <- execution_options?(context.execution_options) do
      :ok
    else
      _ -> {:error, :invalid_context}
    end
  end

  defp canonical_context_valid(_), do: {:error, :invalid_context}

  defp path_environment?(
         %{cwd: cwd, os_home: home, platform: platform, workspace_root: root} = environment
       ) do
    map_size(environment) == 4 and not is_struct(environment) and
      absolute_path?(cwd) and (is_nil(home) or absolute_path?(home)) and absolute_path?(root) and
      platform in [:linux, :darwin, :win32]
  end

  defp path_environment?(_), do: false

  defp absolute_path?(path),
    do:
      is_binary(path) and path != "" and String.valid?(path) and
        not String.contains?(path, "\0") and Path.type(path) == :absolute and
        Path.expand(path, "/") == path

  defp execution_options?(options) do
    Keyword.keyword?(options) and
      length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) and
      Keyword.keys(options) --
        [:node_executable, :model_budget, :model_has_vision, :auto_resize_images] == [] and
      absolute_path?(Keyword.get(options, :node_executable)) and
      Enum.all?(options, &execution_option?/1)
  end

  defp execution_option?({:node_executable, path}), do: absolute_path?(path)
  defp execution_option?({:model_budget, nil}), do: true

  defp execution_option?({:model_budget, %{maxChars: chars, maxContextChars: context} = budget}),
    do:
      map_size(budget) == 2 and not is_struct(budget) and is_number(chars) and chars >= 0 and
        is_number(context) and context >= 0

  defp execution_option?({name, value}) when name in [:model_has_vision, :auto_resize_images],
    do: is_boolean(value)

  defp execution_option?(_), do: false

  defp context_valid(context) when is_map(context) do
    valid =
      Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
        is_binary(context[:root]) and String.valid?(context.root) and
        Path.type(context.root) == :absolute and
        Path.expand(context.root) == context.root and not String.contains?(context.root, "\0") and
        opaque?(context[:run_id]) and is_integer(context[:incarnation]) and
        context.incarnation > 0 and
        is_integer(context[:catalog_revision]) and context.catalog_revision > 0 and
        is_map(context[:workspace]) and
        context.workspace[:role] in [:global, :agent, :session, :user]

    if valid, do: :ok, else: {:error, :invalid_context}
  end

  defp context_valid(_), do: {:error, :invalid_context}

  defp opaque?(value),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) in 1..4_096 and
        String.trim(value) != "" and not String.contains?(value, "\0")

  defp scope(context, operation) when is_map(operation) do
    Synapsis.Agent.Tools.CatalogBinding.host(context, operation, __MODULE__, 1, @native_keys)
  end

  defp scope(_, _), do: {:error, :scope_mismatch}

  defp virtual?("@synapsis/" <> _), do: true
  defp virtual?(_), do: false
  defp logical("@synapsis/" <> rest), do: "/" <> rest

  defp descriptor(name, context) do
    read_only = name in ~w(synapsis::read synapsis::ls)

    %{
      tool_name: name,
      tool_revision: 1,
      description: description(name),
      schema: schema(name),
      safety: %{read_only: read_only, retry_safe: read_only, parallel_safe: read_only},
      backend: __MODULE__,
      backend_context: context
    }
  end

  # Pinned OpenClaw 488631c input contracts. Its output schemas describe details,
  # not the complete native result envelope.
  defp schema("synapsis::read"),
    do: %{
      "properties" => %{
        "cursor" => %{
          "description" => "Character position within the start line; 0-based.",
          "minimum" => 0,
          "type" => "integer"
        },
        "limit" => %{
          "description" => "Max lines.",
          "type" => "number"
        },
        "offset" => %{
          "description" => "Start line; 1-based.",
          "minimum" => 1,
          "type" => "integer"
        },
        "optional" => %{
          "const" => true,
          "description" => "Missing paths return structured not_found instead of failing.",
          "type" => "boolean"
        },
        "path" => %{
          "description" => "File path; relative/absolute.",
          "type" => "string"
        }
      },
      "required" => ["path"],
      "type" => "object"
    }

  defp schema("synapsis::write"),
    do: %{
      "properties" => %{
        "content" => %{
          "description" => "File content.",
          "type" => "string"
        },
        "path" => %{
          "description" => "File path; relative/absolute.",
          "type" => "string"
        }
      },
      "required" => ["path", "content"],
      "type" => "object"
    }

  defp schema("synapsis::edit"),
    do: %{
      "properties" => %{
        "edits" => %{
          "description" =>
            "Targeted replacements against original file; no overlap/nesting. Merge nearby changes.",
          "items" => %{
            "properties" => %{
              "newText" => %{
                "description" => "Replacement text.",
                "type" => "string"
              },
              "oldText" => %{
                "description" => "Exact original text; unique and non-overlapping in this call.",
                "type" => "string"
              }
            },
            "required" => ["oldText", "newText"],
            "type" => "object"
          },
          "type" => "array"
        },
        "path" => %{
          "description" => "File path; relative/absolute.",
          "type" => "string"
        }
      },
      "required" => ["path", "edits"],
      "type" => "object"
    }

  defp schema("synapsis::ls"),
    do: %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Directory; default cwd."
        },
        "limit" => %{
          "type" => "number",
          "description" => "Max entries; default 500."
        },
        "after" => %{
          "type" => "string",
          "description" => "Filename cursor returned by the previous page."
        }
      }
    }

  defp description("synapsis::read"),
    do:
      "Read text/image file (jpg/png/gif/webp/bmp); images attach to model context. Text caps 2000 lines or 50KB. Continue with offset/limit, or cursor within a long line."

  defp description("synapsis::write"),
    do: "Write/overwrite file; creates parent directories."

  defp description("synapsis::edit"),
    do:
      "Exact single-file replacements. oldText unique/non-overlapping against original. Merge nearby changes; omit large unchanged spans."

  defp description("synapsis::ls"),
    do:
      "List directory entries in binary filename order, including dotfiles and links. Names are JSON-quoted; / marks actual directories. Pass the returned after cursor with the same path to continue."

  defp failure({:unknown_outcome, evidence}),
    do:
      {:error,
       Error.new(
         :unknown_outcome,
         "filesystem mutation outcome is unconfirmed",
         details: %{code: Map.get(evidence, :reason, "metadata_persistence"), completed: evidence}
       )}

  defp failure(reason) do
    class =
      cond do
        reason in [:scope_mismatch, :unsafe_path, :permission_denied, :domain_path] -> :forbidden
        reason in [:invalid_input, :invalid_context, :invalid_pattern] -> :validation
        reason == :not_found -> :not_found
        reason == :conflict -> :resource_conflict
        reason == :timeout -> :timeout
        reason in [:file_limit, :scan_limit, :output_limit, :worker_limit] -> :budget_exceeded
        reason == :unknown_outcome -> :unknown_outcome
        true -> :execution_failure
      end

    {:error,
     Error.new(class, "filesystem operation failed",
       details: %{code: if(is_atom(reason), do: Atom.to_string(reason), else: "unavailable")}
     )}
  end
end
