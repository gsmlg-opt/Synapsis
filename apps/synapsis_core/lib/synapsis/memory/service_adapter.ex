defmodule Synapsis.Memory.ServiceAdapter do
  @moduledoc """
  Memory adapter stub for an external hybrid-search memory service.

  All calls are async and timeout-bounded (default 5 s). On timeout or error
  the adapter falls back to `FileAdapter`.

  Configure the service URL:

      config :synapsis_core, :memory_service_url, "https://memory.example.com"

  Until the service is implemented, this stub always falls back to FileAdapter.
  """

  @behaviour Synapsis.Memory.Adapter

  require Logger

  @timeout 5_000

  @impl Synapsis.Memory.Adapter
  def store(attrs) do
    case service_url() do
      nil ->
        Synapsis.Memory.FileAdapter.store(attrs)

      _url ->
        with_fallback(fn -> do_store(attrs) end, fn ->
          Synapsis.Memory.FileAdapter.store(attrs)
        end)
    end
  end

  @impl Synapsis.Memory.Adapter
  def search(query, filters \\ []) do
    case service_url() do
      nil ->
        Synapsis.Memory.FileAdapter.search(query, filters)

      _url ->
        with_fallback(fn -> do_search(query, filters) end, fn ->
          Synapsis.Memory.FileAdapter.search(query, filters)
        end)
    end
  end

  @impl Synapsis.Memory.Adapter
  def get(id) do
    case service_url() do
      nil -> Synapsis.Memory.FileAdapter.get(id)
      _url -> with_fallback(fn -> do_get(id) end, fn -> Synapsis.Memory.FileAdapter.get(id) end)
    end
  end

  @impl Synapsis.Memory.Adapter
  def list(filters \\ []) do
    case service_url() do
      nil ->
        Synapsis.Memory.FileAdapter.list(filters)

      _url ->
        with_fallback(fn -> do_list(filters) end, fn ->
          Synapsis.Memory.FileAdapter.list(filters)
        end)
    end
  end

  @impl Synapsis.Memory.Adapter
  def update(id, attrs) do
    case service_url() do
      nil ->
        Synapsis.Memory.FileAdapter.update(id, attrs)

      _url ->
        with_fallback(fn -> do_update(id, attrs) end, fn ->
          Synapsis.Memory.FileAdapter.update(id, attrs)
        end)
    end
  end

  @impl Synapsis.Memory.Adapter
  def archive(id) do
    case service_url() do
      nil ->
        Synapsis.Memory.FileAdapter.archive(id)

      _url ->
        with_fallback(fn -> do_archive(id) end, fn -> Synapsis.Memory.FileAdapter.archive(id) end)
    end
  end

  @impl Synapsis.Memory.Adapter
  def touch_accessed(_ids), do: :ok

  # --- Private: HTTP stubs (TODO: implement when service is ready) ---

  defp do_store(_attrs) do
    # TODO(upstream): POST /memories
    {:error, :not_implemented}
  end

  defp do_search(_query, _filters) do
    # TODO(upstream): GET /memories/search?q=...
    []
  end

  defp do_get(_id) do
    # TODO(upstream): GET /memories/:id
    {:error, :not_found}
  end

  defp do_list(_filters) do
    # TODO(upstream): GET /memories
    []
  end

  defp do_update(_id, _attrs) do
    # TODO(upstream): PATCH /memories/:id
    {:error, :not_implemented}
  end

  defp do_archive(_id) do
    # TODO(upstream): DELETE /memories/:id
    {:error, :not_implemented}
  end

  defp service_url do
    Application.get_env(:synapsis_core, :memory_service_url)
  end

  defp with_fallback(primary, fallback) do
    task = Task.async(primary)

    case Task.yield(task, @timeout) || Task.shutdown(task) do
      {:ok, {:error, _}} ->
        Logger.debug("memory_service_error, falling back to file adapter")
        fallback.()

      {:ok, result} ->
        result

      nil ->
        Logger.warning("memory_service_timeout, falling back to file adapter")
        fallback.()
    end
  end
end
