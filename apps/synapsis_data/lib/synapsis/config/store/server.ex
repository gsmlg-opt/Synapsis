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

  @spec delete(atom(), String.t()) :: :ok
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
    id = id_of(attrs)

    if is_nil(id) do
      {:reply, {:error, :missing_id}, state}
    else
      entry = Map.put(atomize_keys(attrs), :id, id)
      :ets.insert(state.table, {id, entry})
      persist(state.type)
      # Expose string-keyed maps consistently with get/2 and list/1.
      {:reply, {:ok, stringify_keys(entry)}, state}
    end
  end

  def handle_call({:delete, id}, _from, state) do
    :ets.delete(state.table, id)
    persist(state.type)
    {:reply, :ok, state}
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
              entry = atomize_keys(raw)
              id = Map.get(entry, :id)

              if id do
                :ets.insert(tab, {id, entry})
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

  defp persist(type) do
    path = Store.file_path(type)
    File.mkdir_p!(Path.dirname(path))

    entries =
      :ets.tab2list(table(type))
      |> Enum.map(fn {_id, entry} -> stringify_keys(entry) end)

    table_key = Atom.to_string(type) <> "s"
    content = encode_toml_array_of_tables(table_key, entries)

    case File.write(path, content) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("config_store_write_error",
          type: type,
          path: path,
          reason: inspect(reason)
        )
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
