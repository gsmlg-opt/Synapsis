defmodule Synapsis.DataCase do
  @moduledoc "Test case for tests that require database access."
  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Changeset
      import Synapsis.DataCase
    end
  end

  # ADR-006 C4: no Ecto sandbox — the embedded Concord store is node-local; tests
  # isolate via unique ids rather than per-test DB transactions.
  setup tags do
    setup_sandbox(tags)
    :ok
  end

  @doc "Kept for ConnCase/ChannelCase compatibility — ensures the store is up."
  def setup_sandbox(_tags) do
    Synapsis.Session.Store.ensure_started()
    :ok
  end

  @doc """
  Clear a `Config.Store` type's backing file and ETS table (test isolation for
  Config.Store-backed contexts, which have no per-test transaction rollback).
  """
  def clear_config_store(type) do
    type
    |> Synapsis.Config.Store.file_path()
    |> File.rm()

    table = :"synapsis_config_#{type}"
    if :ets.info(table) != :undefined, do: :ets.delete_all_objects(table)
    :ok
  end

  @doc """
  Ensure the active memory adapter process is alive (it is a supervised singleton
  that an earlier test may have crashed past its restart budget) and start from a
  clean file store.
  """
  def reset_memory_store do
    dir = Application.get_env(:synapsis_core, :memory_dir)
    if dir, do: File.rm_rf!(dir)

    if :ets.info(:synapsis_memory_file_index) != :undefined,
      do: :ets.delete_all_objects(:synapsis_memory_file_index)

    if :ets.info(Synapsis.Memory.EventLog) != :undefined,
      do: :ets.delete_all_objects(Synapsis.Memory.EventLog)

    :ok
  end

  @doc "Delete every Concord key under a coordination prefix (test isolation)."
  def clear_coord(prefix) when is_binary(prefix) do
    case Concord.prefix_scan(prefix) do
      {:ok, pairs} -> Concord.delete_many(Enum.map(pairs, fn {k, _} -> k end))
      _ -> :ok
    end

    :ok
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
