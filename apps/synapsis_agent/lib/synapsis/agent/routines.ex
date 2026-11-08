defmodule Synapsis.Agent.Routines do
  @moduledoc """
  Stored routine lifecycle and trigger interface.

  A configuration source and UUID identify each routine. Bare UUIDs remain a
  compatibility target when unambiguous; names are mutable display labels.
  """

  alias Synapsis.Agent.{RunEvents}
  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.AgentRun
  alias Synapsis.Config.Store
  alias Synapsis.HeartbeatConfig

  @fail_closed_attempts 2
  @automation_common_fields ~w(name prompt schedule timezone enabled agent_name max_runtime_ms no_overlap)
  @automation_versioned_fields ~w(session_target delivery provider model deleteAfterRun)

  @type target :: String.t() | {String.t(), String.t()}

  @spec list() :: [map()]
  def list, do: list(nil)

  @spec list(String.t() | atom() | nil) :: [map()]
  def list(kind)
      when kind in [nil, "heartbeat", "dream", "schedule", :heartbeat, :dream, :schedule] do
    kind = if is_atom(kind) and not is_nil(kind), do: Atom.to_string(kind), else: kind

    all()
    |> Enum.filter(&(is_nil(kind) or &1["kind"] == kind))
    |> Enum.sort_by(&{&1["name"], &1["id"], &1["source"]})
  end

  def list(_kind), do: []

  @spec get(target()) :: {:ok, map()} | {:error, term()}
  def get(target) do
    with {:ok, _type, routine} <- locate(target), do: {:ok, routine}
  end

  @spec create(map()) :: {:ok, map()} | {:error, term()}
  def create(attrs), do: create(attrs, [])

  @spec create(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(attrs, opts) when is_map(attrs) and is_list(opts) do
    attrs = attrs |> stringify_keys() |> Map.drop(["id", "source", "__config_type"])
    attrs = Map.put(attrs, "id", Ecto.UUID.generate())

    with {:ok, routine} <- Store.put(:routine, attrs) do
      finalize_change(:routine, routine, opts)
    end
  end

  def create(_attrs, _opts), do: {:error, {:invalid_routine, :not_a_map}}

  @doc "Create a versioned automation with a trusted creator and separate persistence/activation observations."
  def create_automation(attrs, context, opts \\ []) when is_map(attrs) and is_map(context) do
    id = Ecto.UUID.generate()

    attrs =
      attrs
      |> stringify_keys()
      |> Map.take(
        ~w(name prompt schedule timezone enabled session_target delivery provider model agent_name deleteAfterRun max_runtime_ms no_overlap)
      )
      |> Map.merge(%{
        "id" => id,
        "kind" => "schedule",
        "tool_profile" => "native_agent",
        "automation_contract_version" => 1,
        "automation_origin" => %{
          "agent_id" => context.creator_agent_id,
          "session_id" => context.session_id
        }
      })
      |> Map.put_new("agent_name", context.requester_name)

    with {:ok, routine} <- Store.put(:routine, attrs) do
      {activation, observed} =
        case finalize_change(:routine, routine, opts) do
          {:ok, loaded} ->
            {"reloaded", loaded}

          {:error, _reason} ->
            saved =
              case Store.get(:routine, id) do
                {:ok, current} -> normalize(:routine, current)
                _ -> normalize(:routine, routine)
              end

            {"failed", saved}
        end

      {:ok,
       %{source: "routine", id: id, persisted: true, activation: activation, routine: observed}}
    end
  end

  @spec update(target(), map()) :: {:ok, map()} | {:error, term()}
  def update(target, attrs), do: update(target, attrs, [])

  @spec update(target(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update(target, attrs, opts) when is_map(attrs) and is_list(opts) do
    patch = attrs |> stringify_keys() |> Map.drop(["id", "source", "__config_type"])

    with {:ok, type, current} <- locate(target),
         :ok <- validate_update(type, current, patch),
         :ok <- before_update_persist(opts),
         {:ok, routine} <- Store.merge_existing(type, current["id"], persisted_patch(type, patch)) do
      finalize_change(type, routine, opts)
    end
  end

  def update(_target, _attrs, _opts), do: {:error, {:invalid_routine, :not_a_map}}

  @doc "Patch a creator-bound automation while retaining its original source and acknowledged outcome."
  def update_automation(target, attrs, context, opts \\ [])

  def update_automation({source, id} = target, attrs, context, opts)
      when source in ["routine", "heartbeat"] and is_binary(id) and is_map(attrs) and
             not is_struct(attrs) and is_map(context) and is_list(opts) do
    Store.with_write_lock(fn ->
      patch = stringify_keys(attrs)

      with :ok <- automation_mutation_context(context),
           true <- canonical_uuid?(id),
           {:ok, type, current} <- locate(target),
           :ok <- automation_creator(current, context),
           :ok <- automation_patch(type, current, patch),
           :ok <- validate_update(type, current, patch),
           {:ok, saved} <- Store.merge_existing(type, id, persisted_patch(type, patch)) do
        {activation, observed, cancellation} =
          if current["enabled"] != false and saved["enabled"] == false do
            routine = normalize(type, saved)
            cancellation = request_retirement(target, opts, config: routine)
            RunEvents.publish_routine_updated(routine)
            {retirement_activation(cancellation), routine, cancellation}
          else
            {activation, routine} = mutation_activation(type, saved, opts)
            {activation, routine, %{status: :not_requested, cleanup_pending: false}}
          end

        {:ok,
         %{
           source: source,
           id: id,
           persisted: true,
           activation: activation,
           routine: observed,
           cancellation: cancellation
         }}
      else
        false -> {:error, :invalid_input}
        {:error, _} = error -> error
      end
    end)
  end

  def update_automation(_target, _attrs, _context, _opts), do: {:error, :invalid_input}

  @doc "Delete a configuration and its future schedule, preserving already submitted runs."
  @spec delete(target(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete(target, opts \\ []) when is_list(opts) do
    with {:ok, type, routine} <- locate(target),
         :ok <- Store.delete(type, routine["id"]) do
      finalize_delete(type, routine, opts)
    end
  end

  @doc "Remove an exact-source configuration and request cancellation of captured work."
  def remove_automation(target, opts \\ [])

  def remove_automation({source, id} = target, opts)
      when source in ["routine", "heartbeat"] and is_binary(id) and is_list(opts) do
    Store.with_write_lock(fn ->
      with {:ok, type, routine} <- locate(target),
           :ok <- Store.delete(type, id) do
        cancellation = request_retirement(target, opts, [])
        RunEvents.publish_routine_updated(normalize(type, routine))

        {:ok,
         %{
           source: source,
           id: id,
           persisted: true,
           removed: true,
           cancellation: cancellation
         }}
      end
    end)
  end

  def remove_automation(_target, _opts), do: {:error, :invalid_input}

  @doc "Remove a creator-bound automation through the managed cancellation-request boundary."
  def remove_automation({source, id} = target, context, opts)
      when source in ["routine", "heartbeat"] and is_binary(id) and is_map(context) and
             is_list(opts) do
    Store.with_write_lock(fn ->
      with :ok <- automation_mutation_context(context),
           true <- canonical_uuid?(id),
           {:ok, _type, current} <- locate(target),
           :ok <- automation_creator(current, context),
           {:ok, receipt} <- remove_automation(target, opts) do
        {:ok, Map.put(receipt, :activation, retirement_activation(receipt.cancellation))}
      else
        false -> {:error, :invalid_input}
        {:error, _} = error -> error
      end
    end)
  end

  def remove_automation(_target, _context, _opts), do: {:error, :invalid_input}

  @doc "Commit an enabled-to-disabled transition before requesting captured-work cancellation."
  def disable_automation(target, opts \\ [])

  def disable_automation({source, id} = target, opts)
      when source in ["routine", "heartbeat"] and is_binary(id) and is_list(opts) do
    Store.with_write_lock(fn ->
      with {:ok, type, current} <- locate(target) do
        if current["enabled"] == false do
          {:ok,
           %{
             source: source,
             id: id,
             persisted: true,
             changed: false,
             routine: current,
             cancellation: %{status: :not_requested, cleanup_pending: false}
           }}
        else
          with {:ok, disabled} <- Store.merge_existing(type, id, %{"enabled" => false}) do
            routine = normalize(type, disabled)
            cancellation = request_retirement(target, opts, config: routine)
            RunEvents.publish_routine_updated(routine)

            {:ok,
             %{
               source: source,
               id: id,
               persisted: true,
               changed: true,
               routine: routine,
               cancellation: cancellation
             }}
          end
        end
      end
    end)
  end

  def disable_automation(_target, _opts), do: {:error, :invalid_input}

  @spec trigger(target(), keyword()) :: {:ok, AgentRun.t()} | {:error, term()}
  def trigger(target, opts \\ []) when is_list(opts) do
    with :ok <- reload_scheduler(opts),
         {:ok, routine} <- get(target),
         :ok <- ensure_enabled(routine),
         {:ok, %AgentRun{} = run} <- LocalScheduler.trigger(scheduler(opts), target) do
      {:ok, run}
    end
  end

  @doc "Run a due occurrence or explicitly force an immediate run, without changing trigger/2."
  @spec run(target(), :due | :force, keyword()) :: {:ok, map()} | {:error, term()}
  def run(target, mode \\ :due, opts \\ [])

  def run({source, id} = target, mode, opts)
      when source in ["routine", "heartbeat"] and is_binary(id) and mode in [:due, :force] and
             is_list(opts) do
    with :ok <- reload_scheduler(opts),
         do: LocalScheduler.run(scheduler(opts), target, mode)
  end

  def run(_target, _mode, _opts), do: {:error, :invalid_input}

  @spec trigger_kind(String.t() | atom(), String.t() | nil, keyword()) ::
          {:ok, AgentRun.t()} | {:error, term()}
  def trigger_kind(kind, name \\ nil, opts \\ [])

  def trigger_kind(kind, name, opts)
      when kind in ["heartbeat", "dream", "schedule", :heartbeat, :dream, :schedule] and
             (is_nil(name) or is_binary(name)) and is_list(opts) do
    candidates =
      kind
      |> list()
      |> Enum.filter(&(&1["enabled"] != false))
      |> filter_name(name)

    case candidates do
      [%{"source" => source, "id" => id}] -> trigger({source, id}, opts)
      [] -> {:error, :not_found}
      [_first, _second | _rest] -> {:error, :ambiguous}
    end
  end

  def trigger_kind(_kind, _name, _opts), do: {:error, :not_found}

  defp all do
    Enum.map(Store.list(:routine), &normalize(:routine, &1)) ++
      Enum.map(Store.list(:heartbeat), &normalize(:heartbeat, &1))
  end

  defp locate({source, id}) when source in ["routine", "heartbeat"] and is_binary(id) do
    type = if source == "routine", do: :routine, else: :heartbeat

    with {:ok, routine} <- Store.get(type, id), do: {:ok, type, normalize(type, routine)}
  end

  defp locate(id) when is_binary(id) do
    case {Store.get(:routine, id), Store.get(:heartbeat, id)} do
      {{:ok, _routine}, {:ok, _heartbeat}} ->
        {:error, :ambiguous}

      {{:ok, routine}, {:error, :not_found}} ->
        {:ok, :routine, normalize(:routine, routine)}

      {{:error, :not_found}, {:ok, heartbeat}} ->
        {:ok, :heartbeat, normalize(:heartbeat, heartbeat)}

      {{:error, :not_found}, {:error, reason}} ->
        {:error, reason}

      {{:error, reason}, _heartbeat} ->
        {:error, reason}

      {_routine, {:error, reason}} ->
        {:error, reason}
    end
  end

  defp locate(_target), do: {:error, :not_found}

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp normalize(:heartbeat, routine),
    do: routine |> Map.put("kind", "heartbeat") |> Map.put("source", "heartbeat")

  defp normalize(:routine, routine), do: Map.put(routine, "source", "routine")

  defp validate_update(:routine, _current, _patch), do: :ok

  defp validate_update(:heartbeat, current, patch) do
    attrs = current |> Map.merge(patch) |> Map.drop(["kind", "source", "__config_type"])
    changeset = HeartbeatConfig.changeset(%HeartbeatConfig{}, attrs)

    if changeset.valid?,
      do: :ok,
      else: {:error, changeset}
  end

  defp persisted_patch(:routine, patch), do: patch
  defp persisted_patch(:heartbeat, patch), do: Map.delete(patch, "kind")

  defp before_update_persist(opts) do
    case Keyword.get(opts, :before_update_persist) do
      nil -> :ok
      callback when is_function(callback, 0) -> callback.()
    end
  end

  defp ensure_enabled(%{"enabled" => false}), do: {:error, :disabled}
  defp ensure_enabled(_routine), do: :ok

  defp automation_mutation_context(context) do
    if not is_struct(context) and canonical_uuid?(context[:creator_agent_id]) and
         canonical_uuid?(context[:session_id]) and is_binary(context[:requester_name]) and
         Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, context.requester_name),
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp canonical_uuid?(id), do: is_binary(id) and Ecto.UUID.cast(id) == {:ok, id}

  defp automation_creator(current, context) do
    case {Map.fetch(current, "automation_contract_version"),
          Map.fetch(current, "automation_origin")} do
      {{:ok, 1}, {:ok, %{"agent_id" => agent_id, "session_id" => session_id}}} ->
        if canonical_uuid?(agent_id) and canonical_uuid?(session_id) and
             agent_id == context.creator_agent_id,
           do: :ok,
           else: {:error, :not_found}

      {:error, :error} ->
        if (current["agent_name"] || "main") == context.requester_name,
          do: :ok,
          else: {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  defp automation_patch(type, current, patch) do
    versioned? = type == :routine and current["automation_contract_version"] === 1

    allowed =
      @automation_common_fields ++ if(versioned?, do: @automation_versioned_fields, else: [])

    if Map.keys(patch) -- allowed == [] and
         Enum.all?(patch, &automation_patch_value?(type, &1)),
       do: :ok,
       else: {:error, :invalid_input}
  end

  defp automation_patch_value?(_type, {key, value})
       when key in ~w(name timezone agent_name),
       do: is_binary(value)

  defp automation_patch_value?(_type, {"prompt", value}),
    do: is_binary(value) and byte_size(value) > 0

  defp automation_patch_value?(_type, {key, value})
       when key in ~w(enabled no_overlap deleteAfterRun),
       do: is_boolean(value)

  defp automation_patch_value?(_type, {"max_runtime_ms", value}),
    do: is_integer(value) and value > 0

  defp automation_patch_value?(:routine, {"schedule", value}),
    do: is_binary(value) or (is_map(value) and not is_struct(value))

  defp automation_patch_value?(:heartbeat, {"schedule", value}), do: is_binary(value)

  defp automation_patch_value?(_type, {"session_target", value}),
    do: value in ["current", "isolated"]

  defp automation_patch_value?(_type, {key, value}) when key in ~w(provider model),
    do: is_nil(value) or is_binary(value)

  defp automation_patch_value?(_type, {"delivery", value})
       when is_map(value) and not is_struct(value) do
    value = stringify_keys(value)

    Map.keys(value) -- ["mode", "to"] == [] and
      (not Map.has_key?(value, "mode") or value["mode"] in ["announce", "none", "webhook"]) and
      (not Map.has_key?(value, "to") or is_nil(value["to"]) or is_binary(value["to"]))
  end

  defp automation_patch_value?(_type, _field), do: false

  defp retirement_activation(%{status: :cancellation_requested}), do: "retired"
  defp retirement_activation(_cancellation), do: "unknown"

  defp mutation_activation(type, routine, opts) do
    case finalize_change(type, routine, opts) do
      {:ok, loaded} ->
        {"reloaded", loaded}

      {:error, _reason} ->
        observed =
          case Store.get(type, routine["id"]) do
            {:ok, current} -> current
            _ -> routine
          end

        {"failed", normalize(type, observed)}
    end
  end

  defp filter_name(routines, nil), do: routines
  defp filter_name(routines, name), do: Enum.filter(routines, &(&1["name"] == name))

  defp request_retirement(target, opts, retirement_opts) do
    retirement_opts =
      Keyword.put(retirement_opts, :timeout_ms, Keyword.get(opts, :timeout_ms, 5_000))

    case LocalScheduler.retire(scheduler(opts), target, retirement_opts) do
      {:ok, observation} -> observation
      {:error, reason} -> %{status: :unknown_outcome, cleanup_pending: true, reason: reason}
    end
  catch
    :exit, reason -> %{status: :unknown_outcome, cleanup_pending: true, reason: reason}
  end

  defp finalize_change(type, routine, opts) do
    case reload_scheduler(opts) do
      :ok ->
        routine = normalize(type, routine)
        RunEvents.publish_routine_updated(routine)
        {:ok, routine}

      {:error, reason} ->
        fail_closed(type, routine, reason, opts)
    end
  end

  defp finalize_delete(type, routine, opts) do
    result = reload_scheduler(opts)

    if match?({:error, _reason}, result),
      do: fail_close_runtime({Atom.to_string(type), routine["id"]}, opts)

    routine = normalize(type, routine)
    RunEvents.publish_routine_updated(routine)

    case result do
      :ok -> {:ok, routine}
      {:error, reason} -> {:error, {:scheduler_reload_failed, reason}}
    end
  end

  defp fail_closed(type, routine, reload_reason, opts) do
    id = routine["id"] || routine[:id]
    fail_close_runtime({Atom.to_string(type), id}, opts)

    case persist_fail_closed(type, id, opts) do
      {:ok, disabled} ->
        RunEvents.publish_routine_updated(normalize(type, disabled))
        {:error, {:scheduler_reload_failed, reload_reason}}

      {:error, persist_reason} ->
        {:error,
         {:scheduler_reload_failed, reload_reason, {:fail_closed_persist_failed, persist_reason}}}
    end
  end

  defp fail_close_runtime(id, opts) do
    LocalScheduler.fail_close(scheduler(opts), id)
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp persist_fail_closed(type, id, opts, attempts_left \\ @fail_closed_attempts) do
    writer = Keyword.get(opts, :fail_closed_writer, &Store.merge_existing/3)
    result = protect_write(fn -> writer.(type, id, %{"enabled" => false}) end)

    case {result, attempts_left} do
      {{:ok, disabled}, _attempts_left} ->
        {:ok, disabled}

      {{:error, _reason}, attempts_left} when attempts_left > 1 ->
        persist_fail_closed(type, id, opts, attempts_left - 1)

      {{:error, reason}, _attempts_left} ->
        {:error, reason}
    end
  end

  defp protect_write(fun) do
    case fun.() do
      {:ok, disabled} -> {:ok, disabled}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_fail_closed_result, other}}
    end
  rescue
    error -> {:error, {error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp reload_scheduler(opts) do
    case LocalScheduler.reload(scheduler(opts)) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_reload_result, other}}
    end
  rescue
    error -> {:error, {error.__struct__, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp scheduler(opts), do: Keyword.get(opts, :scheduler, LocalScheduler)
end
