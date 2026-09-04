defmodule Synapsis.Config.Store.Server do
  @moduledoc """
  GenServer + ETS store for one config type.

  Writes serialize through the GenServer and persist to the TOML file.
  Reads bypass the GenServer via ETS directly (`:read_concurrency`).
  """

  use GenServer
  require Logger

  alias Synapsis.Config.Store

  @table_prefix :synapsis_config_

  # --- Public API (delegates from Store) ---

  # Entries are stored atom-keyed in ETS; reads expose string-keyed maps to match
  # how contexts (and the persisted TOML) address fields.
  @spec list(atom()) :: [map()]
  def list(type) do
    case :ets.info(table(type)) do
      :undefined -> []
      _ -> :ets.tab2list(table(type)) |> Enum.map(fn {_id, entry} -> stringify_keys(entry) end)
    end
  end

  @spec get(atom(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(type, id) do
    case :ets.info(table(type)) do
      :undefined ->
        {:error, :not_found}

      _ ->
        case :ets.lookup(table(type), id) do
          [{^id, entry}] -> {:ok, stringify_keys(entry)}
          [] -> {:error, :not_found}
        end
    end
  end

  @spec put(atom(), map()) :: {:ok, map()} | {:error, term()}
  def put(type, attrs) do
    GenServer.call(via(type), {:put, attrs})
  end

  @spec delete(atom(), String.t()) :: :ok | {:error, term()}
  def delete(type, id) do
    GenServer.call(via(type), {:delete, id})
  end

  @spec reload(atom()) :: :ok
  def reload(type) do
    GenServer.call(via(type), :reload)
  end

  # --- Supervisor / start ---

  def start_link(type) when is_atom(type) do
    GenServer.start_link(__MODULE__, type, name: via(type))
  end

  defp via(type), do: {:via, Registry, {Synapsis.Config.Store.Registry, type}}
  defp table(type), do: :"#{@table_prefix}#{type}"

  # --- GenServer ---

  @impl true
  def init(type) do
    tab = :ets.new(table(type), [:named_table, :set, :public, read_concurrency: true])
    load_from_disk(type, tab)
    {:ok, %{type: type, table: tab}}
  end

  @impl true
  def handle_call({:put, attrs}, _from, state) do
    with {:ok, attrs} <- validate_entry(state.type, attrs),
         id when not is_nil(id) <- id_of(attrs) do
      entry = Map.put(atomize_keys(attrs), :id, id)

      candidate_entries =
        state.table
        |> :ets.tab2list()
        |> Map.new()
        |> Map.put(id, entry)
        |> Map.values()

      case persist(state.type, candidate_entries) do
        :ok ->
          :ets.insert(state.table, {id, entry})
          # Expose string-keyed maps consistently with get/2 and list/1.
          {:reply, {:ok, stringify_keys(entry)}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      nil -> {:reply, {:error, :missing_id}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete, id}, _from, state) do
    candidate_entries =
      state.table
      |> :ets.tab2list()
      |> Enum.reject(fn {entry_id, _entry} -> entry_id == id end)
      |> Enum.map(fn {_id, entry} -> entry end)

    case persist(state.type, candidate_entries) do
      :ok ->
        :ets.delete(state.table, id)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    :ets.delete_all_objects(state.table)
    load_from_disk(state.type, state.table)
    {:reply, :ok, state}
  end

  # --- Private ---

  defp load_from_disk(type, tab) do
    path = Store.file_path(type)

    case File.read(path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, map} ->
            entries = Map.get(map, Atom.to_string(type) <> "s", [])

            Enum.each(entries, fn raw ->
              with {:ok, raw} <- validate_entry(type, raw),
                   entry = atomize_keys(raw),
                   id when not is_nil(id) <- Map.get(entry, :id) do
                :ets.insert(tab, {id, entry})
              else
                _invalid -> :ok
              end
            end)

          {:error, reason} ->
            Logger.warning("config_store_toml_parse_error",
              type: type,
              path: path,
              reason: inspect(reason)
            )
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("config_store_read_error", type: type, path: path, reason: inspect(reason))
    end
  end

  defp persist(type, entries) do
    path = Store.file_path(type)

    table_key = Atom.to_string(type) <> "s"
    content = encode_toml_array_of_tables(table_key, Enum.map(entries, &stringify_keys/1))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("config_store_write_error",
          type: type,
          path: path,
          reason: inspect(reason)
        )

        {:error, {:persist_failed, reason}}
    end
  end

  # Minimal TOML encoder for arrays of flat maps (the only shape we persist).
  # Values may be: string, integer, float, boolean, list-of-string, or nil (skipped).
  defp encode_toml_array_of_tables(key, entries) do
    Enum.map_join(entries, "\n", fn entry ->
      header = "[[#{key}]]\n"

      fields =
        Enum.flat_map(entry, fn
          {_k, nil} -> []
          {_k, v} when is_map(v) and map_size(v) == 0 -> []
          {k, v} -> ["#{k} = #{encode_toml_value(v)}\n"]
        end)

      header <> Enum.join(fields)
    end)
  end

  defp encode_toml_value(v) when is_binary(v), do: inspect(v)
  defp encode_toml_value(v) when is_boolean(v), do: to_string(v)
  defp encode_toml_value(v) when is_integer(v), do: to_string(v)
  defp encode_toml_value(v) when is_float(v), do: to_string(v)

  defp encode_toml_value(list) when is_list(list) do
    items = Enum.map_join(list, ", ", &encode_toml_value/1)
    "[#{items}]"
  end

  defp encode_toml_value(map) when is_map(map) do
    pairs = Enum.map_join(map, ", ", fn {k, v} -> "#{k} = #{encode_toml_value(v)}" end)
    "{#{pairs}}"
  end

  defp encode_toml_value(v), do: inspect(v)

  defp id_of(attrs) do
    Map.get(attrs, :id) || Map.get(attrs, "id")
  end

  defp validate_entry(:routine, attrs) when is_map(attrs) do
    with :ok <- required_string(attrs, :id),
         :ok <- required_string(attrs, :name),
         :ok <- valid_kind(attrs),
         :ok <- required_boolean(attrs, :enabled),
         :ok <- valid_schedule(attrs),
         :ok <- required_string(attrs, :prompt),
         :ok <- optional_string(attrs, :tool_profile),
         :ok <- optional_boolean(attrs, :no_overlap),
         :ok <- optional_positive_integer(attrs, :max_runtime_ms),
         :ok <- optional_datetime(attrs, :last_run_at),
         :ok <- optional_datetime(attrs, :next_run_at),
         :ok <- optional_string(attrs, :last_status),
         :ok <- optional_map(attrs, :metadata) do
      {:ok, attrs}
    else
      {:error, reason} -> {:error, {:invalid_routine, reason}}
    end
  end

  defp validate_entry(:routine, _attrs), do: {:error, {:invalid_routine, :not_a_map}}
  defp validate_entry(_type, attrs), do: {:ok, attrs}

  defp required_string(attrs, key) do
    case value(attrs, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, key}, else: :ok

      _other ->
        {:error, key}
    end
  end

  defp required_boolean(attrs, key) do
    if is_boolean(value(attrs, key)), do: :ok, else: {:error, key}
  end

  defp valid_kind(attrs) do
    if value(attrs, :kind) in ~w(heartbeat dream schedule), do: :ok, else: {:error, :kind}
  end

  defp valid_schedule(attrs) do
    case value(attrs, :schedule) do
      schedule when is_binary(schedule) ->
        case Crontab.CronExpression.Parser.parse(schedule) do
          {:ok, _expression} -> :ok
          {:error, _reason} -> {:error, :schedule}
        end

      _other ->
        {:error, :schedule}
    end
  end

  defp optional_string(attrs, key) do
    case value(attrs, key, :missing) do
      :missing -> :ok
      nil -> :ok
      value when is_binary(value) -> if String.trim(value) == "", do: {:error, key}, else: :ok
      _other -> {:error, key}
    end
  end

  defp optional_boolean(attrs, key) do
    case value(attrs, key, :missing) do
      :missing -> :ok
      value when is_boolean(value) -> :ok
      _other -> {:error, key}
    end
  end

  defp optional_positive_integer(attrs, key) do
    case value(attrs, key, :missing) do
      :missing -> :ok
      value when is_integer(value) and value > 0 -> :ok
      _other -> {:error, key}
    end
  end

  defp optional_datetime(attrs, key) do
    case value(attrs, key, :missing) do
      :missing ->
        :ok

      nil ->
        :ok

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, _datetime, _offset} -> :ok
          _invalid -> {:error, key}
        end

      _other ->
        {:error, key}
    end
  end

  defp optional_map(attrs, key) do
    case value(attrs, key, :missing) do
      :missing -> :ok
      value when is_map(value) -> :ok
      _other -> {:error, key}
    end
  end

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
