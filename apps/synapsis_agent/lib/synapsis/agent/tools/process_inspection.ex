defmodule Synapsis.Agent.Tools.ProcessInspection do
  @moduledoc """
  Selected inspection of the existing native command registry.

  The native Session supplies the owner and incarnation for every call. No
  process records or output cursors are stored here. Logs use native byte
  cursors; output bytes are base64 with an additional text field when valid UTF-8.
  Polling advances only the native inspection cursor. Removing and clearing
  records affect finalized inspection, never a command's lifetime.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema, ToolCatalog, ToolEffects}
  alias Backplane.AgentRuntime.Codex.{Commands, Session}
  alias Synapsis.Agent.Tools.CatalogBinding

  @name "synapsis::process"
  @actions ~w(list inspect log poll remove clear_finished)
  @keys [:identity, :local]
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a

  def names, do: [@name]
  def permission_level(@name), do: :write

  def bundles(local, identity, authority, selection) do
    if @name in selection do
      with true <- @name in authority.grants,
           true <- available?(local) do
        descriptor = %{
          tool_name: @name,
          tool_revision: 1,
          description: description(),
          schema: schema(),
          safety: %{read_only: false, retry_safe: false, parallel_safe: false},
          backend: __MODULE__,
          backend_context: %{identity: identity, local: local}
        }

        ceiling = %{
          authority
          | grants: [@name],
            tool_revisions: Map.take(authority.tool_revisions, [@name])
        }

        case ToolCatalog.admit_batch([descriptor], authority: ceiling, mode: :strict) do
          {:ok, bundle} -> {:ok, [bundle]}
          error -> error
        end
      else
        false -> failure(:unsupported_capability, "Native command inspection is unavailable")
        error -> error
      end
    else
      {:ok, []}
    end
  end

  def classify(%{backend: __MODULE__, backend_context: context}, identity, operation) do
    with true <- context.identity === identity,
         {:ok, args, owner} <- invocation(context, operation) do
      target = [owner.owner_id, owner.incarnation, args["command_id"]]
      level = if args["action"] in ~w(list inspect log), do: :read, else: :write

      {:ok,
       %{
         action: "command.inspect." <> args["action"],
         resource: "command:inspection:" <> Jason.encode!(target),
         permission_level: level
       }}
    else
      false -> failure(:validation, "Command inspection scope changed")
      error -> error
    end
  end

  def classify(_, _, _), do: failure(:validation, "Command inspection descriptor is unavailable")

  @impl true
  def execute(%{backend_context: enriched} = operation) when is_map(enriched) do
    context = Map.take(enriched, @keys)

    with {:ok, args, owner} <- invocation(context, operation),
         :ok <- before_deadline(enriched[:effect_deadline]) do
      local = Map.put(context.local, :resource_owner, owner)

      with {:ok, value} <- dispatch(local, args),
           payload = %{"action" => args["action"], "result" => value},
           {:ok, content} <- Jason.encode(payload) do
        # One public JSON representation is shared by model text and Parts.
        {:ok, %{content: content, structured: Jason.decode!(content)}}
      else
        {:error, %Error{}} = error -> error
        _ -> failure(:malformed_result, "Native command inspection result is not portable")
      end
    else
      {:error, %Error{} = error} -> ToolEffects.reject(operation, error)
      _ -> failure(:validation, "Command inspection invocation is unavailable")
    end
  catch
    :exit, _ -> failure(:unknown_outcome, "Command inspection acknowledgement is unavailable")
  end

  def execute(_), do: failure(:validation, "Command inspection context is unavailable")

  @impl true
  # Native ToolEffects owns this caller's deadline and retirement. The native
  # registry/command processes remain owned by the original Session.
  def cancel(_operation), do: :ok

  defp invocation(context, operation) do
    with true <- Enum.sort(Map.keys(context)) == Enum.sort(@keys),
         true <- operation[:tool_name] === @name,
         :ok <-
           CatalogBinding.host(context, operation, __MODULE__, 1, @native_keys, context.identity),
         {:ok, owner} <- Session.validate(context.local.session_binding, operation),
         true <- available?(context.local),
         {:ok, args} <- InputSchema.validate(schema(), operation.arguments),
         :ok <- action_arguments(args) do
      {:ok, args, owner}
    else
      {:error, %Error{}} = error -> error
      _ -> failure(:validation, "Command inspection scope or arguments are invalid")
    end
  end

  defp available?(%{command: %{server: server}, session_registry: registry})
       when is_pid(server) and is_pid(registry),
       do: Process.alive?(server) and Process.alive?(registry)

  defp available?(_), do: false

  defp action_arguments(%{"action" => action} = args) do
    {required, optional} =
      case action do
        action when action in ~w(list clear_finished) -> {["action"], []}
        "log" -> {["action", "command_id"], ["cursor", "max_bytes"]}
        "poll" -> {["action", "command_id"], ["max_bytes"]}
        _ -> {["action", "command_id"], []}
      end

    if required -- Map.keys(args) == [] and Map.keys(args) -- (required ++ optional) == [],
      do: :ok,
      else: failure(:validation, "Command inspection arguments do not match the action")
  end

  defp dispatch(local, %{"action" => "list"}), do: Commands.list(local)

  defp dispatch(local, %{"action" => "inspect", "command_id" => id}),
    do: Commands.inspect(local, id)

  defp dispatch(local, %{"action" => action, "command_id" => id} = args)
       when action in ~w(log poll) do
    opts = [max_bytes: Map.get(args, "max_bytes", 65_536)]

    opts =
      if action == "log", do: Keyword.put(opts, :cursor, Map.get(args, "cursor", 0)), else: opts

    result =
      if action == "log", do: Commands.log(local, id, opts), else: Commands.poll(local, id, opts)

    with {:ok, %{output: bytes} = result} <- result do
      value = result |> Map.delete(:output) |> Map.put(:output_base64, Base.encode64(bytes))
      {:ok, if(String.valid?(bytes), do: Map.put(value, :output_text, bytes), else: value)}
    end
  end

  defp dispatch(local, %{"action" => "remove", "command_id" => id}) do
    with :ok <- Commands.remove(local, id), do: {:ok, %{removed: true, command_id: id}}
  end

  defp dispatch(local, %{"action" => "clear_finished"}) do
    with {:ok, count} <- Commands.clear_finished(local), do: {:ok, %{removed: count}}
  end

  defp before_deadline(nil), do: :ok

  defp before_deadline(getter) when is_function(getter, 0) do
    with {:ok, %{deadline_ms: deadline, remaining_ms: remaining, paused: false}} <- getter.(),
         true <-
           is_integer(deadline) and is_integer(remaining) and remaining > 0 and
             System.monotonic_time(:millisecond) < deadline do
      :ok
    else
      _ -> failure(:timeout, "Command inspection deadline expired")
    end
  end

  defp before_deadline(_), do: failure(:validation, "Command inspection deadline is invalid")

  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "enum" => @actions},
        "command_id" => %{"type" => "integer", "minimum" => 1},
        "cursor" => %{"type" => "integer", "minimum" => 0},
        "max_bytes" => %{"type" => "integer", "minimum" => 1, "maximum" => 65_536}
      },
      "required" => ["action"],
      "additionalProperties" => false
    }
  end

  defp description do
    "Inspect this native Session's commands. Actions: list, inspect, log, poll, remove, clear_finished. " <>
      "command_id comes from list and equals the original native command_id/running session_id; required for inspect/log/poll/remove. " <>
      "log is non-consuming with a byte cursor (default 0). poll advances an independent native inspection cursor, " <>
      "without draining write_stdin output; it can finalize a naturally completed command. max_bytes for log/poll " <>
      "defaults to 65536 and is capped at 65536. Results preserve native metadata, output_base64 and output_text " <>
      "when the chunk is valid UTF-8; cursor is the next byte offset. Finalized logs are retained by the native " <>
      "registry within its finite history lifetime, not persisted as live handles in conversation history. " <>
      "remove deletes one finalized inspection record; clear_finished deletes all finalized records for this Session. " <>
      "They leave running commands untouched. Does not start commands, write stdin or terminate processes."
  end

  defp failure(class, message), do: {:error, Error.new(class, message)}
end
