defmodule Synapsis.Agent.Routines do
  @moduledoc """
  Stored routine lifecycle and trigger interface.

  Routine UUIDs are durable identity. Names are mutable display labels and are
  only used by compatibility callers that explicitly request name resolution.
  """

  alias Synapsis.Agent.{RunEvents}
  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.AgentRun
  alias Synapsis.Config.Store
  alias Synapsis.HeartbeatConfig

  @fail_closed_attempts 2

  @spec list() :: [map()]
  def list, do: list(nil)

  @spec list(String.t() | atom() | nil) :: [map()]
  def list(kind)
      when kind in [nil, "heartbeat", "dream", "schedule", :heartbeat, :dream, :schedule] do
    kind = if is_atom(kind) and not is_nil(kind), do: Atom.to_string(kind), else: kind

    all()
    |> Enum.filter(&(is_nil(kind) or &1["kind"] == kind))
    |> Enum.sort_by(&{&1["name"], &1["id"]})
  end

  def list(_kind), do: []

  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case locate(id) do
      {:ok, _type, routine} -> {:ok, routine}
      :error -> {:error, :not_found}
    end
  end

  @spec create(map()) :: {:ok, map()} | {:error, term()}
  def create(attrs), do: create(attrs, [])

  @spec create(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(attrs, opts) when is_map(attrs) and is_list(opts) do
    attrs = attrs |> stringify_keys() |> Map.put("id", Ecto.UUID.generate())

    with {:ok, routine} <- Store.put(:routine, attrs) do
      finalize_change(:routine, routine, opts)
    end
  end

  def create(_attrs, _opts), do: {:error, {:invalid_routine, :not_a_map}}

  @spec update(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update(id, attrs), do: update(id, attrs, [])

  @spec update(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update(id, attrs, opts) when is_binary(id) and is_map(attrs) and is_list(opts) do
    patch = attrs |> stringify_keys() |> Map.delete("id")

    case locate(id) do
      {:ok, type, current} ->
        with :ok <- validate_update(type, current, patch),
             :ok <- before_update_persist(opts),
             {:ok, routine} <- Store.merge_existing(type, id, persisted_patch(type, patch)) do
          finalize_change(type, routine, opts)
        end

      :error ->
        {:error, :not_found}
    end
  end

  def update(_id, _attrs, _opts), do: {:error, {:invalid_routine, :not_a_map}}

  @spec trigger(String.t(), keyword()) :: {:ok, AgentRun.t()} | {:error, term()}
  def trigger(id, opts \\ []) when is_binary(id) and is_list(opts) do
    with :ok <- reload_scheduler(opts),
         {:ok, routine} <- get(id),
         :ok <- ensure_enabled(routine),
         {:ok, %AgentRun{} = run} <- LocalScheduler.trigger(scheduler(opts), id) do
      {:ok, run}
    end
  end

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
      [%{"id" => id}] -> trigger(id, opts)
      [] -> {:error, :not_found}
      [_first, _second | _rest] -> {:error, :ambiguous}
    end
  end

  def trigger_kind(_kind, _name, _opts), do: {:error, :not_found}

  defp all do
    Store.list(:routine) ++
      Enum.map(Store.list(:heartbeat), &Map.put(&1, "kind", "heartbeat"))
  end

  defp locate(id) do
    case Store.get(:routine, id) do
      {:ok, routine} ->
        {:ok, :routine, routine}

      {:error, :not_found} ->
        case Store.get(:heartbeat, id) do
          {:ok, heartbeat} -> {:ok, :heartbeat, normalize(:heartbeat, heartbeat)}
          {:error, :not_found} -> :error
        end
    end
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp normalize(:heartbeat, routine), do: Map.put(routine, "kind", "heartbeat")
  defp normalize(:routine, routine), do: routine

  defp validate_update(:routine, _current, _patch), do: :ok

  defp validate_update(:heartbeat, current, patch) do
    attrs = current |> Map.merge(patch) |> Map.delete("kind")
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

  defp filter_name(routines, nil), do: routines
  defp filter_name(routines, name), do: Enum.filter(routines, &(&1["name"] == name))

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

  defp fail_closed(type, routine, reload_reason, opts) do
    id = routine["id"] || routine[:id]
    fail_close_runtime(id, opts)

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
