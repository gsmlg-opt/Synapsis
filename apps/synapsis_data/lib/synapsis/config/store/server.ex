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
  @directory_candidates 1_000

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

  @doc false
  def agent_directory_snapshot(requester, deadline)
      when is_binary(requester) and byte_size(requester) in 1..256 and is_integer(deadline) do
    deadline = min(deadline, System.monotonic_time(:millisecond) + 5_000)
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      GenServer.call(via(:agent), {:agent_directory_snapshot, requester, deadline}, remaining)
    else
      {:error, :timeout}
    end
  rescue
    ArgumentError -> {:error, :storage_unavailable}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :storage_unavailable}
  end

  def agent_directory_snapshot(_, _), do: {:error, :invalid_input}

  @doc false
  def routine_directory_snapshot(type, deadline, remaining_budget)
      when type in [:routine, :heartbeat] and is_integer(deadline) and
             is_integer(remaining_budget) and remaining_budget in 0..@directory_candidates do
    deadline = min(deadline, System.monotonic_time(:millisecond) + 5_000)
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      GenServer.call(
        via(type),
        {:routine_directory_snapshot, deadline, remaining_budget},
        remaining
      )
    else
      {:error, :timeout}
    end
  rescue
    ArgumentError -> {:error, :storage_unavailable}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :storage_unavailable}
  end

  def routine_directory_snapshot(_, _, _), do: {:error, :invalid_input}

  @spec get(atom(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(:memory, id), do: GenServer.call(via(:memory), {:memory_get, id})

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

  @spec merge_existing(atom(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def merge_existing(type, id, attrs) do
    GenServer.call(via(type), {:merge_existing, id, attrs})
  end

  @doc false
  def routine_schedule_write(type, id, generation, operation) when type in [:routine, :heartbeat],
    do: GenServer.call(via(type), {:routine_schedule_write, id, generation, operation})

  @spec replace_existing(atom(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def replace_existing(type, id, attrs) do
    GenServer.call(via(type), {:replace_existing, id, attrs})
  end

  @spec delete(atom(), String.t()) :: :ok | {:error, term()}
  def delete(type, id) do
    GenServer.call(via(type), {:delete, id})
  end

  @spec reload(atom()) :: :ok | {:error, term()}
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

    error =
      case load_prepared_entries(type, tab) do
        {:ok, entries} ->
          replace_entries(tab, entries)
          nil

        {:error, {:read_failed, :enoent}} ->
          nil

        {:error, reason} ->
          log_load_error(type, reason)
          config_error(reason)
      end

    {:ok, %{type: type, table: tab, load_error: error}}
  end

  @impl true
  def handle_call(
        {:agent_directory_snapshot, requester, deadline},
        {caller, _},
        %{type: :agent} = state
      ) do
    result =
      with :ok <- directory_active(caller, deadline),
           :ok <- directory_healthy(state),
           {:ok, rows} <- directory_rows(state.table, caller, deadline),
           {:ok, agents} <- directory_records(rows, caller, deadline),
           %{enabled: true} = owner <- Enum.find(agents, &(&1.name == requester)),
           :ok <- directory_active(caller, deadline) do
        {:ok,
         %{
           requester: Map.take(owner, [:id, :name]),
           agents:
             agents
             |> Enum.filter(& &1.enabled)
             |> Enum.map(&Map.delete(&1, :enabled))
         }}
      else
        nil -> {:error, :requester_unavailable}
        %{enabled: false} -> {:error, :requester_unavailable}
        {:error, _} = error -> error
      end

    {:reply, result, state}
  end

  def handle_call(
        {:routine_directory_snapshot, deadline, budget},
        {caller, _},
        %{type: type} = state
      )
      when type in [:routine, :heartbeat] do
    result =
      with :ok <- directory_active(caller, deadline),
           :ok <- directory_healthy(state),
           {:ok, rows} <- routine_directory_rows(state.table, type, caller, deadline, budget),
           {:ok, routines} <- routine_directory_records(rows, type, caller, deadline),
           :ok <- directory_active(caller, deadline) do
        {:ok, %{routines: routines, count: length(rows)}}
      end

    {:reply, result, state}
  end

  def handle_call({:memory_get, id}, _from, state) do
    result =
      if state.load_error do
        {:error, state.load_error}
      else
        case :ets.lookup(state.table, id) do
          [{^id, entry}] -> {:ok, stringify_keys(entry)}
          [] -> {:error, :not_found}
        end
      end

    {:reply, result, state}
  end

  def handle_call({:routine_schedule_write, id, generation, operation}, from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, current}] ->
        if owns_routine_schedule?(state.type, current, generation) do
          case operation do
            :delete -> handle_call({:delete, id}, from, state)
            {:merge, attrs} -> handle_call({:merge_existing, id, attrs}, from, state)
          end
        else
          {:reply, {:error, :stale_schedule}, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:put, attrs}, _from, state) do
    with {:ok, attrs} <-
           prepare_entry(state.type, attrs, current_entry(state.table, id_of(attrs))),
         {:ok, attrs} <- validate_entry(state.type, attrs),
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
          {:reply, {:ok, stringify_keys(entry)}, %{state | load_error: nil}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      nil -> {:reply, {:error, :missing_id}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:replace_existing, id, attrs}, from, state) do
    if :ets.member(state.table, id) do
      handle_call({:put, attrs |> atomize_keys() |> Map.put(:id, id)}, from, state)
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:merge_existing, id, attrs}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, current}] ->
        entry =
          current
          |> Map.merge(attrs |> atomize_keys() |> Map.delete(:id))
          |> Map.put(:id, id)

        with {:ok, entry} <- prepare_entry(state.type, entry, current),
             {:ok, entry} <- validate_entry(state.type, entry) do
          entry = atomize_keys(entry)

          candidate_entries =
            state.table
            |> :ets.tab2list()
            |> Map.new()
            |> Map.put(id, entry)
            |> Map.values()

          case persist(state.type, candidate_entries) do
            :ok ->
              :ets.insert(state.table, {id, entry})
              {:reply, {:ok, stringify_keys(entry)}, %{state | load_error: nil}}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
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
    case load_prepared_entries(state.type, state.table) do
      {:ok, entries} ->
        replace_entries(state.table, entries)
        {:reply, :ok, %{state | load_error: nil}}

      {:error, {:read_failed, :enoent}} when state.type == :memory ->
        replace_entries(state.table, [])
        {:reply, :ok, %{state | load_error: nil}}

      {:error, reason} ->
        log_load_error(state.type, reason)
        {:reply, {:error, reason}, %{state | load_error: config_error(reason)}}
    end
  end

  # --- Private ---

  defp routine_directory_rows(table, type, caller, deadline, budget) do
    with :ok <- directory_active(caller, deadline) do
      case :ets.info(table, :size) do
        :undefined ->
          {:error, :storage_unavailable}

        size when size > budget ->
          {:error, :scan_limit}

        _ ->
          with :ok <- directory_active(caller, deadline) do
            case :ets.select(table, routine_directory_projection(type), budget + 1) do
              :"$end_of_table" -> {:ok, []}
              {rows, :"$end_of_table"} when length(rows) <= budget -> {:ok, rows}
              _ -> {:error, :scan_limit}
            end
          end
      end
    end
  rescue
    ArgumentError -> {:error, :storage_unavailable}
  end

  # Only bounded public scalars leave ETS. Malformed and other-route entries
  # remain candidates, so neither can silently disappear from the inventory.
  defp routine_directory_projection(type) do
    id = {:map_get, :id, :"$2"}
    name = {:map_get, :name, :"$2"}
    schedule = {:map_get, :schedule, :"$2"}
    kind = if type == :heartbeat, do: "heartbeat", else: {:map_get, :kind, :"$2"}

    clauses =
      for enabled? <- [true, false],
          timezone? <- [true, false],
          route? <- [true, false],
          {schedule_guards, schedule_projection} <- routine_schedule_projections(type, schedule) do
        enabled = if enabled?, do: {:map_get, :enabled, :"$2"}, else: true
        timezone = if timezone?, do: {:map_get, :timezone, :"$2"}, else: "Etc/UTC"
        route = if route?, do: {:map_get, :agent_name, :"$2"}, else: "main"

        guards =
          [
            {:is_map, :"$2"},
            {:is_binary, :"$1"},
            {:==, {:byte_size, :"$1"}, 36},
            {:is_binary, id},
            {:==, {:byte_size, id}, 36},
            {:orelse, {:==, kind, "heartbeat"},
             {:orelse, {:==, kind, "dream"}, {:==, kind, "schedule"}}},
            directory_field_guard(:enabled, enabled?),
            directory_field_guard(:timezone, timezone?),
            directory_field_guard(:agent_name, route?),
            {:is_boolean, enabled}
          ] ++
            routine_directory_string_guards(name, 256) ++
            schedule_guards ++
            routine_directory_string_guards(timezone, 256) ++
            routine_directory_string_guards(route, 256)

        {{:"$1", :"$2"}, guards,
         [{{:"$1", id, name, kind, enabled, schedule_projection, timezone, route}}]}
      end

    clauses ++ [{:_, [], [:invalid_config]}]
  end

  defp routine_schedule_projections(type, schedule) do
    legacy = {routine_directory_string_guards(schedule, 1_024), schedule}

    if type == :heartbeat do
      [legacy]
    else
      kind = {:map_get, "kind", schedule}
      expr = {:map_get, "expr", schedule}
      tz = {:map_get, "tz", schedule}
      at = {:map_get, "at", schedule}
      period = {:map_get, "everyMs", schedule}
      anchor = {:map_get, "anchorMs", schedule}
      base = [{:is_map, schedule}]
      cron = base ++ [{:==, kind, "cron"}] ++ routine_directory_string_guards(expr, 1_024)

      [
        legacy,
        {cron ++ [{:not, {:is_map_key, "tz", schedule}}], %{"kind" => "cron", "expr" => expr}},
        {cron ++ routine_directory_string_guards(tz, 256),
         %{"kind" => "cron", "expr" => expr, "tz" => tz}},
        {base ++ [{:==, kind, "at"}] ++ routine_directory_string_guards(at, 128),
         %{"kind" => "at", "at" => at}},
        {base ++
           [
             {:==, kind, "every"},
             {:is_integer, period},
             {:>, period, 0},
             {:is_integer, anchor},
             {:>=, anchor, 0}
           ], %{"kind" => "every", "everyMs" => period, "anchorMs" => anchor}},
        {base ++
           [
             {:==, kind, "every"},
             {:is_integer, period},
             {:>, period, 0},
             {:not, {:is_map_key, "anchorMs", schedule}}
           ], %{"kind" => "every", "everyMs" => period}}
      ]
    end
  end

  defp routine_directory_string_guards(value, max_bytes) do
    [
      {:is_binary, value},
      {:>, {:byte_size, value}, 0},
      {:"=<", {:byte_size, value}, max_bytes}
    ]
  end

  defp routine_directory_records(rows, type, caller, deadline) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, routines} ->
      with :ok <- directory_active(caller, deadline),
           {:ok, routine} <- routine_directory_record(row, type) do
        {:cont, {:ok, [routine | routines]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp routine_directory_record({key, id, name, kind, enabled, schedule, timezone, route}, type) do
    with true <- key == id,
         {:ok, ^id} <- Ecto.UUID.cast(id),
         true <- Enum.all?([name, timezone, route], &String.valid?/1),
         :ok <- valid_directory_schedule(schedule),
         true <- Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, route) do
      {:ok,
       %{
         id: id,
         source: Atom.to_string(type),
         name: name,
         kind: kind,
         enabled: enabled,
         schedule: schedule,
         timezone: timezone,
         agent_name: route
       }}
    else
      _ -> {:error, :invalid_config}
    end
  end

  defp routine_directory_record(_, _), do: {:error, :invalid_config}

  defp valid_directory_schedule(schedule) when is_binary(schedule) do
    if String.valid?(schedule), do: :ok, else: {:error, :schedule}
  end

  defp valid_directory_schedule(schedule), do: Synapsis.RoutineSchedule.validate(schedule)

  defp directory_healthy(%{load_error: nil}), do: :ok
  defp directory_healthy(%{load_error: :unavailable}), do: {:error, :storage_unavailable}
  defp directory_healthy(_), do: {:error, :invalid_config}

  defp directory_active(caller, deadline) do
    cond do
      System.monotonic_time(:millisecond) >= deadline -> {:error, :timeout}
      not Process.alive?(caller) -> {:error, :caller_cancelled}
      true -> :ok
    end
  end

  defp directory_rows(table, caller, deadline) do
    with :ok <- directory_active(caller, deadline) do
      case :ets.info(table, :size) do
        :undefined ->
          {:error, :storage_unavailable}

        size when size > @directory_candidates ->
          {:error, :scan_limit}

        _ ->
          with :ok <- directory_active(caller, deadline) do
            case :ets.select(table, directory_projection(), @directory_candidates + 1) do
              :"$end_of_table" -> {:ok, []}
              {rows, :"$end_of_table"} when length(rows) <= @directory_candidates -> {:ok, rows}
              _ -> {:error, :scan_limit}
            end
          end
      end
    end
  rescue
    ArgumentError -> {:error, :storage_unavailable}
  end

  # Match specs run inside ETS. They return only bounded public fields, never the
  # record map containing prompts, credentials, tools or arbitrarily large config.
  # A catch-all marker ensures malformed entries cannot disappear from the scan.
  defp directory_projection do
    id = {:map_get, :id, :"$2"}
    name = {:map_get, :name, :"$2"}

    clauses =
      for enabled? <- [true, false], label? <- [true, false] do
        enabled = if enabled?, do: {:map_get, :enabled, :"$2"}, else: true
        label = if label?, do: {:map_get, :label, :"$2"}, else: nil

        guards = [
          {:is_map, :"$2"},
          {:is_binary, :"$1"},
          {:==, {:byte_size, :"$1"}, 36},
          {:is_binary, id},
          {:==, {:byte_size, id}, 36},
          {:is_binary, name},
          {:>, {:byte_size, name}, 0},
          {:"=<", {:byte_size, name}, 256},
          directory_field_guard(:enabled, enabled?),
          directory_field_guard(:label, label?),
          {:is_boolean, enabled},
          {:orelse, {:==, label, nil},
           {:andalso, {:is_binary, label}, {:"=<", {:byte_size, label}, 65_536}}}
        ]

        {{:"$1", :"$2"}, guards, [{{:"$1", id, name, enabled, label}}]}
      end

    clauses ++ [{:_, [], [:invalid_config]}]
  end

  defp directory_field_guard(key, true), do: {:is_map_key, key, :"$2"}
  defp directory_field_guard(key, false), do: {:not, {:is_map_key, key, :"$2"}}

  defp directory_records(rows, caller, deadline) do
    Enum.reduce_while(rows, {:ok, [], MapSet.new()}, fn row, {:ok, agents, names} ->
      with :ok <- directory_active(caller, deadline),
           {:ok, agent} <- directory_record(row),
           false <- MapSet.member?(names, agent.name) do
        {:cont, {:ok, [agent | agents], MapSet.put(names, agent.name)}}
      else
        true -> {:halt, {:error, :invalid_config}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, agents, _names} -> {:ok, agents}
      {:error, _} = error -> error
    end
  end

  defp directory_record({key, id, name, enabled, label}) do
    with true <- key == id,
         {:ok, ^id} <- Ecto.UUID.cast(id),
         true <- String.valid?(name) and Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, name),
         true <- is_nil(label) or String.valid?(label) do
      agent = %{id: id, name: name, enabled: enabled, configured: true}
      {:ok, if(is_nil(label), do: agent, else: Map.put(agent, :label, label))}
    else
      _ -> {:error, :invalid_config}
    end
  end

  defp directory_record(_), do: {:error, :invalid_config}

  # Reconcile external edits before exposing them to readers. Persisting the
  # normalized cadence identity also detects an edit made while ETS was absent.
  defp load_prepared_entries(type, table) do
    with {:ok, entries} <- load_entries(type),
         {:ok, prepared} <- prepare_loaded_entries(type, table, entries),
         :ok <-
           if(prepared == entries, do: :ok, else: persist(type, Enum.map(prepared, &elem(&1, 1)))) do
      {:ok, prepared}
    end
  end

  defp prepare_loaded_entries(:routine, table, entries) do
    Enum.reduce_while(entries, {:ok, []}, fn {id, entry}, {:ok, acc} ->
      current = current_entry(table, id)
      typed? = is_map(value(entry, :schedule))

      attributed? =
        is_binary(value(entry, :schedule_fingerprint)) or
          (current && is_binary(current["schedule_fingerprint"]))

      result =
        if typed? or attributed? do
          prepare_entry(:routine, entry, current)
        else
          with :ok <- Synapsis.RoutineAutomation.validate_delivery(stringify_keys(entry)),
               do: {:ok, entry}
        end

      case result do
        {:ok, prepared} ->
          prepared =
            if is_nil(value(prepared, :next_run_at)),
              do: Map.drop(prepared, [:next_run_at, "next_run_at"]),
              else: prepared

          {:cont, {:ok, [{id, atomize_keys(prepared)} | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      error -> error
    end
  end

  defp prepare_loaded_entries(_type, _table, entries), do: {:ok, entries}

  defp load_entries(type) do
    path = Store.file_path(type)

    case File.read(path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, map} ->
            entries =
              if type in [:memory, :diffs],
                do: if(map == %{}, do: [], else: [Map.put(map, "id", "default")]),
                else: Map.get(map, Atom.to_string(type) <> "s", [])

            validate_entries(entries, type)

          {:error, reason} ->
            {:error, {:parse_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp validate_entries(entries, type) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn raw, {:ok, acc} ->
      with true <- is_map(raw),
           {:ok, validated} <- validate_entry(type, raw),
           id when not is_nil(id) <- id_of(validated) do
        entry = validated |> atomize_keys() |> Map.put(:id, id)
        {:cont, {:ok, [{id, entry} | acc]}}
      else
        false -> {:halt, {:error, {:invalid_entry, :not_a_map}}}
        nil -> {:halt, {:error, {:invalid_entry, :missing_id}}}
        {:error, reason} -> {:halt, {:error, {:invalid_entry, reason}}}
      end
    end)
    |> case do
      {:ok, validated} ->
        case validate_model_identities(type, Enum.map(validated, &elem(&1, 1))) do
          :ok -> {:ok, validated}
          {:error, reason} -> {:error, {:invalid_entry, reason}}
        end

      error ->
        error
    end
  end

  defp validate_entries(_entries, _type), do: {:error, {:invalid_entry, :not_a_list}}

  defp replace_entries(table, entries) do
    :ets.delete_all_objects(table)
    if entries != [], do: :ets.insert(table, entries)
    :ok
  end

  defp log_load_error(type, {kind, reason}) when kind in [:read_failed, :parse_failed] do
    Logger.warning("config_store_#{kind}",
      type: type,
      path: Store.file_path(type),
      reason: inspect(reason)
    )
  end

  defp log_load_error(type, reason) do
    Logger.warning("config_store_validation_failed",
      type: type,
      path: Store.file_path(type),
      reason: inspect(reason)
    )
  end

  defp persist(type, entries) do
    with :ok <- validate_model_identities(type, entries), do: persist_entries(type, entries)
  end

  defp validate_model_identities(:model, entries) do
    identities = Enum.map(entries, &{value(&1, :provider_id), value(&1, :model)})

    if length(Enum.uniq(identities)) == length(identities),
      do: :ok,
      else: {:error, :duplicate_model}
  end

  defp validate_model_identities(_type, _entries), do: :ok

  defp persist_entries(type, entries) do
    path = Store.file_path(type)

    content =
      if type in [:memory, :diffs] do
        case entries do
          [] ->
            ""

          [entry] ->
            entry |> stringify_keys() |> Map.delete("id") |> encode_toml_fields([]) |> Enum.join()
        end
      else
        encode_toml_array_of_tables(
          Atom.to_string(type) <> "s",
          Enum.map(entries, &stringify_keys/1)
        )
      end

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

      # Toml 0.7 flattens inline map values inside an array of tables. Dotted
      # keys preserve nested config maps across reloads, including model choices.
      fields = encode_toml_fields(entry, [])

      header <> Enum.join(fields)
    end)
  end

  defp encode_toml_fields(map, prefix) do
    Enum.flat_map(map, fn
      {_key, nil} ->
        []

      {key, value} when is_map(value) ->
        encode_toml_fields(value, prefix ++ [to_string(key)])

      {key, value} ->
        path = Enum.map_join(prefix ++ [to_string(key)], ".", &encode_toml_string/1)
        ["#{path} = #{encode_toml_value(value)}\n"]
    end)
  end

  defp encode_toml_value(v) when is_binary(v), do: encode_toml_string(v)
  defp encode_toml_value(v) when is_boolean(v), do: to_string(v)
  defp encode_toml_value(v) when is_integer(v), do: to_string(v)
  defp encode_toml_value(v) when is_float(v), do: to_string(v)

  defp encode_toml_value(list) when is_list(list) do
    items = Enum.map_join(list, ", ", &encode_toml_value/1)
    "[#{items}]"
  end

  defp encode_toml_value(map) when is_map(map) do
    pairs =
      Enum.map_join(map, ", ", fn {k, v} ->
        "#{encode_toml_string(to_string(k))} = #{encode_toml_value(v)}"
      end)

    "{#{pairs}}"
  end

  defp encode_toml_value(v), do: inspect(v)

  defp encode_toml_string(value) do
    # JSON escapes TOML basic strings except DEL, which TOML also forbids literally.
    value |> Jason.encode!() |> String.replace(<<127>>, "\\u007F")
  end

  defp id_of(attrs) do
    Map.get(attrs, :id) || Map.get(attrs, "id")
  end

  defp config_error({:read_failed, _}), do: :unavailable
  defp config_error(_), do: :invalid_config

  # A pre-generation legacy cron may finish after its first ordinary scheduler
  # write materialized identity. Its frozen cadence still distinguishes that
  # hydration from an edited replacement schedule.
  defp owns_routine_schedule?(:routine, current, {:legacy_cadence, fingerprint}) do
    Synapsis.RoutineSchedule.fingerprint(value(current, :schedule), value(current, :timezone)) ==
      {:ok, fingerprint}
  end

  defp owns_routine_schedule?(_type, current, generation),
    do: value(current, :schedule_generation) == generation

  defp current_entry(table, id) do
    case :ets.lookup(table, id) do
      [{^id, entry}] -> stringify_keys(entry)
      [] -> nil
    end
  end

  # Creation identity and schedule ownership are assigned at the serialized
  # mutation boundary, including the first write of hand-authored schedules.
  defp prepare_entry(:routine, attrs, current) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    current = if current, do: stringify_keys(current)
    attrs = Synapsis.RoutineAutomation.prepare(attrs, current)

    with :ok <- Synapsis.RoutineAutomation.validate_delivery(attrs) do
      prepare_routine_schedule(attrs, current)
    end
  end

  defp prepare_entry(_type, attrs, _current), do: {:ok, attrs}

  defp prepare_routine_schedule(attrs, current) do
    legacy? =
      is_binary(attrs["schedule"]) and
        not Enum.any?([attrs, current || %{}], fn entry ->
          is_binary(entry["schedule_generation"]) or is_binary(entry["schedule_fingerprint"])
        end)

    if legacy? do
      {:ok, attrs}
    else
      created_at =
        (current && current["createdAtMs"]) || attrs["createdAtMs"] ||
          System.system_time(:millisecond)

      with {:ok, schedule} <- normalize_routine_cadence(attrs, current, created_at),
           {:ok, fingerprint} <- Synapsis.RoutineSchedule.fingerprint(schedule, attrs["timezone"]) do
        current_schedule =
          if current,
            do: Synapsis.RoutineSchedule.normalize(current["schedule"], anchor_ms: created_at)

        changed? =
          (not is_nil(current) and
             {current_schedule, current["timezone"]} != {{:ok, schedule}, attrs["timezone"]}) or
            (is_binary(attrs["schedule_fingerprint"]) and
               attrs["schedule_fingerprint"] != fingerprint)

        generation =
          if changed?,
            do: Ecto.UUID.generate(),
            else:
              (current && current["schedule_generation"]) || attrs["schedule_generation"] ||
                Ecto.UUID.generate()

        attrs =
          attrs
          |> Map.put("schedule", schedule)
          |> Map.put("createdAtMs", created_at)
          |> Map.put("schedule_generation", generation)
          |> Map.put("schedule_fingerprint", fingerprint)

        attrs = if changed?, do: Map.put(attrs, "next_run_at", nil), else: attrs
        {:ok, attrs}
      else
        {:error, reason} -> {:error, {:invalid_routine, reason}}
      end
    end
  end

  defp normalize_routine_cadence(
         %{"automation_contract_version" => 1} = attrs,
         current,
         created_at
       ) do
    previous = if current, do: current["schedule"], else: persisted_routine_schedule(attrs)

    Synapsis.RoutineCadence.normalize(attrs["schedule"], previous,
      anchor_ms: created_at,
      now_ms: System.system_time(:millisecond)
    )
  end

  defp normalize_routine_cadence(attrs, _current, created_at),
    do: Synapsis.RoutineSchedule.normalize(attrs["schedule"], anchor_ms: created_at)

  # A matching persisted fingerprint identifies an unchanged cold-loaded
  # snapshot. A real file cadence edit cannot borrow that previous schedule.
  defp persisted_routine_schedule(attrs) do
    with fingerprint when is_binary(fingerprint) <- attrs["schedule_fingerprint"],
         {:ok, ^fingerprint} <-
           Synapsis.RoutineSchedule.fingerprint(attrs["schedule"], attrs["timezone"]) do
      attrs["schedule"]
    else
      _ -> nil
    end
  end

  defp validate_entry(:diffs, attrs), do: Synapsis.Diffs.Config.resolve(attrs)

  defp validate_entry(:memory, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    host = attrs["host_agent"]

    valid =
      Enum.sort(Map.keys(attrs)) == ~w(backend host_agent id) and
        attrs["id"] == "default" and attrs["backend"] == "workspace" and is_map(host) and
        Enum.sort(Map.keys(host)) == ~w(agent_id enabled endpoint) and
        is_boolean(host["enabled"]) and is_binary(host["endpoint"]) and
        is_binary(host["agent_id"])

    if valid, do: {:ok, attrs}, else: {:error, :invalid_memory}
  end

  defp validate_entry(:memory, _), do: {:error, :invalid_memory}

  defp validate_entry(:model, attrs) when is_map(attrs) do
    case Synapsis.ModelConfig.changeset(%Synapsis.ModelConfig{}, attrs) do
      %{valid?: true} -> {:ok, attrs}
      changeset -> {:error, {:invalid_model, changeset.errors}}
    end
  end

  defp validate_entry(:model, _attrs), do: {:error, {:invalid_model, :not_a_map}}

  defp validate_entry(:routine, attrs) when is_map(attrs) do
    with :ok <- required_string(attrs, :id),
         :ok <- required_string(attrs, :name),
         :ok <- valid_kind(attrs),
         :ok <- required_boolean(attrs, :enabled),
         {:ok, schedule} <- Synapsis.RoutineSchedule.normalize(value(attrs, :schedule)),
         :ok <- required_string(attrs, :prompt),
         :ok <- optional_string(attrs, :tool_profile),
         :ok <- optional_boolean(attrs, :no_overlap),
         :ok <- optional_positive_integer(attrs, :max_runtime_ms),
         :ok <- optional_datetime(attrs, :last_run_at),
         :ok <- optional_datetime(attrs, :next_run_at),
         :ok <- optional_string(attrs, :last_status),
         :ok <- optional_map(attrs, :metadata) do
      normalized = attrs |> stringify_keys() |> Map.put("schedule", schedule)

      normalized =
        if is_nil(normalized["next_run_at"]),
          do: Map.delete(normalized, "next_run_at"),
          else: normalized

      {:ok, normalized}
    else
      {:error, reason} -> {:error, {:invalid_routine, reason}}
    end
  end

  defp validate_entry(:routine, _attrs), do: {:error, {:invalid_routine, :not_a_map}}

  defp validate_entry(:heartbeat, attrs) when is_map(attrs) do
    if is_map(value(attrs, :schedule)),
      do: {:error, :invalid_heartbeat_schedule},
      else: {:ok, attrs}
  end

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
