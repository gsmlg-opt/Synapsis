defmodule Synapsis.Session.Quarantine do
  @moduledoc """
  Poison-session protection (ADR-006 B1).

  Tracks per-session boot-failure counts and quarantines a session once it
  crosses a threshold, so a session whose `init`/rehydrate keeps crashing (e.g.
  corrupt Concord data) is marked **unbootable** instead of restart-looping.

  Writes serialize through this GenServer; reads bypass it via an ETS table with
  `:read_concurrency` (the OTP "GenServer owns the table, reads go direct" rule).
  """
  use GenServer

  @table :session_quarantine
  @default_threshold 3

  # ── public API ─────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Configured failure threshold before a session is quarantined."
  def threshold,
    do: Application.get_env(:synapsis_core, __MODULE__, [])[:threshold] || @default_threshold

  @doc "True if the session is quarantined (read bypasses the GenServer)."
  def quarantined?(session_id) do
    case :ets.lookup(@table, {:quarantined, session_id}) do
      [{_, true}] -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc "Current consecutive boot-failure count for a session."
  def failure_count(session_id) do
    case safe_lookup({:failures, session_id}) do
      [{_, n}] -> n
      _ -> 0
    end
  end

  @doc """
  Record a boot failure. Returns `{:quarantined, count}` once the count reaches
  the threshold, otherwise `{:ok, count}`.
  """
  def record_failure(session_id), do: GenServer.call(__MODULE__, {:record_failure, session_id})

  @doc "Clear failure state for a session (call on a successful boot)."
  def clear(session_id), do: GenServer.call(__MODULE__, {:clear, session_id})

  @doc "Force-quarantine a session (e.g. operator action)."
  def quarantine(session_id), do: GenServer.call(__MODULE__, {:quarantine, session_id})

  # ── server ──────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:record_failure, session_id}, _from, state) do
    count = failure_count(session_id) + 1
    :ets.insert(@table, {{:failures, session_id}, count})

    reply =
      if count >= threshold() do
        :ets.insert(@table, {{:quarantined, session_id}, true})
        {:quarantined, count}
      else
        {:ok, count}
      end

    {:reply, reply, state}
  end

  def handle_call({:clear, session_id}, _from, state) do
    :ets.delete(@table, {:failures, session_id})
    :ets.delete(@table, {:quarantined, session_id})
    {:reply, :ok, state}
  end

  def handle_call({:quarantine, session_id}, _from, state) do
    :ets.insert(@table, {{:quarantined, session_id}, true})
    {:reply, :ok, state}
  end

  defp safe_lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end
end
