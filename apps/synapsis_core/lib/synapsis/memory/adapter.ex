defmodule Synapsis.Memory.Adapter do
  @moduledoc """
  Behaviour for semantic memory storage backends.

  The file adapter (default/bootstrap) stores memories as Markdown files with
  YAML frontmatter. The service adapter forwards to an external hybrid-search
  service. Both expose the same callbacks; `Retriever` is configured to use
  whichever adapter is active.

  All implementations must be async-safe and timeout-bounded when called from
  the prompt-building path.
  """

  @type memory :: %{
          id: String.t(),
          scope: String.t(),
          scope_id: String.t(),
          kind: String.t(),
          title: String.t(),
          summary: String.t(),
          detail: map(),
          tags: [String.t()],
          importance: float(),
          confidence: float(),
          freshness: float(),
          source: String.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Store or update a memory. `attrs` must include at least :scope, :kind, :title, :summary."
  @callback store(attrs :: map()) :: {:ok, memory()} | {:error, term()}

  @doc "Keyword + tag search. Returns memories ranked by relevance."
  @callback search(query :: String.t(), filters :: keyword()) :: [memory()]

  @doc "Fetch a single memory by id."
  @callback get(id :: String.t()) :: {:ok, memory()} | {:error, :not_found}

  @doc "List all memories matching filters."
  @callback list(filters :: keyword()) :: [memory()]

  @doc "Update fields on an existing memory."
  @callback update(id :: String.t(), attrs :: map()) :: {:ok, memory()} | {:error, term()}

  @doc "Mark a memory as archived (soft delete)."
  @callback archive(id :: String.t()) :: :ok | {:error, term()}

  @doc "Touch access stats (may be a no-op for some adapters)."
  @callback touch_accessed(ids :: [String.t()]) :: :ok

  @doc "Return the active adapter module (configured or default)."
  def active do
    Application.get_env(:synapsis_core, :memory_adapter, Synapsis.Memory.FileAdapter)
  end

  @doc "Search via the active adapter, bounded by timeout."
  @spec search(String.t(), keyword(), timeout()) :: [memory()]
  def search(query, filters \\ [], timeout \\ 4_000) do
    task = Task.async(fn -> active().search(query, filters) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, results} -> results
      _ -> []
    end
  end

  @doc "Store via the active adapter."
  @spec store(map()) :: {:ok, memory()} | {:error, term()}
  def store(attrs), do: with_retry(fn -> active().store(attrs) end)

  @doc "Get via the active adapter."
  @spec get(String.t()) :: {:ok, memory()} | {:error, :not_found}
  def get(id), do: with_retry(fn -> active().get(id) end)

  @doc "List via the active adapter."
  @spec list(keyword()) :: [memory()]
  def list(filters \\ []), do: with_retry(fn -> active().list(filters) end)

  @doc "Update via the active adapter."
  @spec update(String.t(), map()) :: {:ok, memory()} | {:error, term()}
  def update(id, attrs), do: with_retry(fn -> active().update(id, attrs) end)

  @doc "Archive via the active adapter."
  @spec archive(String.t()) :: :ok | {:error, term()}
  def archive(id), do: with_retry(fn -> active().archive(id) end)

  # The adapter is a supervised singleton; if it is momentarily down, revive it
  # and retry rather than surfacing a `:noproc` exit to callers.
  defp with_retry(fun, retries \\ 5) do
    fun.()
  catch
    :exit, reason ->
      if retries > 0 and noproc?(reason) do
        revive()
        with_retry(fun, retries - 1)
      else
        :erlang.raise(:exit, reason, __STACKTRACE__)
      end
  end

  defp revive do
    Enum.each([active(), Synapsis.Memory.EventLog], fn mod ->
      if function_exported?(mod, :start_link, 1) and not is_pid(Process.whereis(mod)) do
        case mod.start_link([]) do
          {:ok, pid} -> Process.unlink(pid)
          _ -> :ok
        end
      end
    end)
  end

  defp noproc?(:noproc), do: true
  defp noproc?({:noproc, _}), do: true
  defp noproc?({{:noproc, _}, _}), do: true
  defp noproc?(_), do: false
end
