defmodule Synapsis.Agent.Tools.SkillWorkshop do
  @moduledoc """
  Foreground native authoring over one persisted Agent's private learned source.

  Core owns files, versions and acknowledged change facts. This adapter retains
  its issued scope, asks the host to prepare an exact successor after a committed
  mutation, and stages it through the executing native effect. Conversation owns
  producer settlement, publication and resource retirement.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Agent.Tools.CatalogBinding
  alias Synapsis.SkillWorkshop, as: Workshop
  alias Synapsis.SkillWorkshop.Scope

  @name "synapsis::skill_workshop"
  @actions ~w(list view create patch write_file remove_file archive restore)
  @mutations ~w(create patch write_file remove_file archive restore)
  @fields ~w(action name file_path content old_text new_text absorbed_into reason version)
  @support_roots ~w(references templates scripts assets examples)
  @context_keys [
    :scope,
    :session_id,
    :run_id,
    :incarnation,
    :catalog_revision,
    :prepare_successor
  ]
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a

  def names, do: [@name]
  def permission_level(@name), do: :destructive

  def descriptors(context) do
    with :ok <- context_valid(context) do
      {:ok,
       [
         %{
           tool_name: @name,
           tool_revision: 1,
           description:
             "List, view, create, patch, write supporting files, archive and restore this Agent's private learned skills. Skill content remains inert text; mutations retain complete previous versions and a visible change reason.",
           schema: schema(),
           safety: %{read_only: false, retry_safe: false, parallel_safe: false},
           backend: __MODULE__,
           backend_context: context
         }
       ]}
    else
      {:error, reason} -> failure(reason)
    end
  end

  def classify(context, operation) do
    with :ok <- context_valid(context),
         :ok <- CatalogBinding.host(context, operation, __MODULE__, 1, @native_keys),
         {:ok, action, name, file} <- input(operation) do
      resource = "skill:agent:#{context.scope.agent_id}:source:workshop:#{context.scope.agent_id}"
      resource = if name, do: resource <> ":skill:" <> encode(name), else: resource
      resource = if file, do: resource <> ":file:" <> encode(file), else: resource

      resource =
        Enum.reduce(["version", "absorbed_into"], resource, fn key, resource ->
          case operation.arguments[key] do
            value when is_binary(value) -> resource <> ":#{key}:" <> encode(String.trim(value))
            _ -> resource
          end
        end)

      {verb, level} =
        cond do
          action in ["list", "view"] -> {"skill.read", :read}
          action in ["archive", "remove_file", "restore"] -> {"skill.#{action}", :destructive}
          true -> {"skill.write", :write}
        end

      {:ok, %{action: verb, resource: resource, permission_level: level}}
    end
  end

  @impl true
  def execute(%{backend_context: native} = operation) do
    with {:ok, context} <- execution_context(native),
         {:ok, _} <-
           classify(context, CatalogBinding.classification_operation(operation, context)),
         :ok <- current_scope(context.scope),
         {:ok, deadline} <- effect_deadline(native),
         true <- is_map(native[:catalog_snapshot]) and is_function(native[:stage_catalog], 1),
         assert_live = fn -> check_live(native, context.scope, deadline) end,
         :ok <- assert_live.(),
         {:ok, source} <-
           Workshop.run(context.scope, operation.arguments, %{
             deadline: deadline,
             assert_live: assert_live,
             actor: "agent",
             session_key: context.session_id,
             run_id: context.run_id
           }),
         :ok <- publish_successor(context, operation, source) do
      {:ok,
       %{
         content: Enum.map_join(source["content"], "\n", & &1["text"]),
         structured: source
       }}
    else
      false -> failure(:invalid_context)
      {:error, reason} -> failure(reason)
    end
  end

  def execute(_), do: failure(:invalid_input)

  # Core's filesystem lease monitors this actual native effect owner. Native
  # cancellation stops it; this adapter never starts a second lifetime owner.
  @impl true
  def cancel(_), do: :ok

  defp publish_successor(context, %{arguments: %{"action" => action}} = operation, source)
       when action in @mutations do
    native = operation.backend_context

    with %{"details" => %{"change" => %{}}} <- source,
         {:ok, _} <- effect_deadline(native),
         {:ok, update} <- context.prepare_successor.(operation, native.catalog_snapshot),
         {:ok, %{status: :staged}} <- native.stage_catalog.(update) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_publication}
    end
  end

  defp publish_successor(_context, _operation, _source), do: :ok

  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "enum" => @actions},
        "name" => %{"type" => "string", "description" => "Skill name (lowercase-hyphenated)."},
        "file_path" => %{
          "type" => "string",
          "description" =>
            "SKILL.md (default) or a file under references/, templates/, scripts/, assets/."
        },
        "content" => %{
          "type" => "string",
          "description" => "create: full SKILL.md. write_file: full file content."
        },
        "old_text" => %{"type" => "string", "description" => "patch: exact text to replace once."},
        "new_text" => %{"type" => "string", "description" => "patch: replacement text."},
        "absorbed_into" => %{
          "type" => "string",
          "description" => "archive: live skill that now covers this one."
        },
        "reason" => %{
          "type" => "string",
          "description" => "One short line saying what changed and why; shown to the user."
        },
        "version" => %{
          "type" => "string",
          "description" => "view/restore: version id; restore defaults to the newest."
        }
      },
      "required" => ["action"],
      "additionalProperties" => false
    }
  end

  defp input(%{tool_name: @name, arguments: %{"action" => action} = args}) do
    with true <- is_map(args) and not is_struct(args) and Map.keys(args) -- @fields == [],
         true <- Enum.all?(args, fn {_, value} -> is_binary(value) and String.valid?(value) end),
         true <- action in @actions,
         {:ok, name} <- name(args, action),
         {:ok, file} <- file(args, action) do
      {:ok, action, name, file}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp input(_), do: {:error, :invalid_input}

  defp name(_args, "list"), do: {:ok, nil}

  defp name(args, _action) do
    name = String.trim(args["name"] || "")

    if Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,254}$/, name),
      do: {:ok, name},
      else: {:error, :invalid_name}
  end

  defp file(_args, action) when action in ["list", "archive", "restore"], do: {:ok, nil}

  defp file(args, action) do
    path = String.trim(args["file_path"] || "")

    path =
      if path == "" and action not in ["write_file", "remove_file"], do: "SKILL.md", else: path

    parts = String.split(path, "/")

    if path == "SKILL.md" or
         (path != "" and Path.type(path) == :relative and not String.contains?(path, ["\\", "\0"]) and
            hd(parts) in @support_roots and
            Enum.all?(parts, &(&1 != "" and not String.starts_with?(&1, ".")))) do
      {:ok, path}
    else
      {:error, :invalid_file}
    end
  end

  defp execution_context(context) when is_map(context) do
    if Map.keys(context) -- (@context_keys ++ @native_keys) == [],
      do: {:ok, Map.take(context, @context_keys)},
      else: {:error, :invalid_context}
  end

  defp execution_context(_), do: {:error, :invalid_context}

  defp context_valid(context) when is_map(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         valid_scope?(context.scope) and text?(context.session_id) and text?(context.run_id) and
         is_integer(context.incarnation) and context.incarnation > 0 and
         is_integer(context.catalog_revision) and context.catalog_revision > 0 and
         is_function(context.prepare_successor, 2),
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp context_valid(_), do: {:error, :invalid_context}

  defp valid_scope?(%Scope{} = scope) do
    Ecto.UUID.cast(scope.agent_id) == {:ok, scope.agent_id} and
      is_binary(scope.config_root) and Path.type(scope.config_root) == :absolute and
      scope.relative_root == Path.join(["agents", scope.agent_id, "workshop-skills"]) and
      scope.root == Path.join(scope.config_root, scope.relative_root) and
      is_integer(scope.max_skill_bytes) and scope.max_skill_bytes in 1_024..200_000
  end

  defp valid_scope?(_), do: false

  defp current_scope(scope) do
    case Workshop.capture(scope.agent_id) do
      {:ok, ^scope} -> :ok
      {:ok, _} -> {:error, :stale_snapshot}
      error -> error
    end
  end

  defp check_live(native, scope, deadline) do
    with {:ok, ^deadline} <- effect_deadline(native) do
      current_scope(scope)
    else
      {:ok, _} -> {:error, :stale_snapshot}
      error -> error
    end
  end

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
  defp encode(text), do: URI.encode(text, &URI.char_unreserved?/1)

  defp text?(value),
    do:
      is_binary(value) and byte_size(value) in 1..4096 and String.valid?(value) and
        String.trim(value) != "" and not String.contains?(value, "\0")

  defp failure(%Error{} = error), do: {:error, error}

  defp failure(reason) do
    code = error_code(reason)

    class =
      cond do
        reason in [:scope_mismatch, :stale_snapshot, :unsafe_path, :invalid_agent] ->
          :forbidden

        reason == :timeout ->
          :timeout

        reason in [
          :invalid_context,
          :invalid_input,
          :invalid_name,
          :invalid_file,
          :invalid_action
        ] ->
          :validation

        reason in [:enoent, :not_live, :version_not_found] ->
          :not_found

        reason in [:already_exists, :conflict, :resource_conflict] ->
          :resource_conflict

        code == "unknown_outcome" ->
          :unknown_outcome

        reason == :invalid_publication ->
          :malformed_result

        true ->
          :execution_failure
      end

    {:error, Error.new(class, "skill workshop failed", details: %{code: code}, cause: reason)}
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_), do: "operation_failed"
end
