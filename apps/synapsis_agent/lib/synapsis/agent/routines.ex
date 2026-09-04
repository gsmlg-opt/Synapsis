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

    with {:ok, routine} <- Store.put(:routine, attrs),
         :ok <- reload_scheduler(opts) do
      {:ok, routine}
    end
  end

  def create(_attrs, _opts), do: {:error, {:invalid_routine, :not_a_map}}

  @spec update(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update(id, attrs), do: update(id, attrs, [])

  @spec update(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update(id, attrs, opts) when is_binary(id) and is_map(attrs) and is_list(opts) do
    case locate(id) do
      {:ok, type, current} ->
        updated = current |> Map.merge(stringify_keys(attrs)) |> Map.put("id", id)

        with {:ok, routine} <- persist(type, updated),
             :ok <- reload_scheduler(opts) do
          {:ok, normalize(type, routine)}
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
      RunEvents.publish_routine_triggered(routine, run)
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

  defp persist(:routine, routine), do: Store.put(:routine, routine)

  defp persist(:heartbeat, routine) do
    attrs = Map.delete(routine, "kind")
    changeset = HeartbeatConfig.changeset(%HeartbeatConfig{}, attrs)

    if changeset.valid?,
      do: Store.put(:heartbeat, attrs),
      else: {:error, changeset}
  end

  defp ensure_enabled(%{"enabled" => false}), do: {:error, :disabled}
  defp ensure_enabled(_routine), do: :ok

  defp filter_name(routines, nil), do: routines
  defp filter_name(routines, name), do: Enum.filter(routines, &(&1["name"] == name))

  defp reload_scheduler(opts), do: LocalScheduler.reload(scheduler(opts))
  defp scheduler(opts), do: Keyword.get(opts, :scheduler, LocalScheduler)
end
