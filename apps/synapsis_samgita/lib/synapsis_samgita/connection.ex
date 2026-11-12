defmodule SynapsisSamgita.Connection do
  @moduledoc """
  The current Samgita agent connection (from `POST /api/agent/connect`) and the
  latest view of every attempt claimed during this run. Connecting is manual.
  HTTP calls run in the caller, not in this process.
  """
  use GenServer

  require Logger
  alias Synapsis.SamgitaConfig
  alias SynapsisSamgita.{API, Events}

  @initial %{state: :disconnected, agent_id: nil, connection_id: nil, expires_at: nil, last_error: nil}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def status, do: GenServer.call(__MODULE__, :status)
  def attempts, do: GenServer.call(__MODULE__, :attempts)
  def disconnect, do: GenServer.call(__MODULE__, :disconnect)

  def connect do
    with {:ok, conn} <- base_conn() do
      result = API.connect(conn)
      GenServer.call(__MODULE__, {:connected, result})
    end
  end

  @doc "API connection map for the current connection."
  def api_conn do
    case status() do
      %{state: :connected, connection_id: id} ->
        with {:ok, conn} <- base_conn(), do: {:ok, %{conn | connection_id: id}}

      _ ->
        {:error, %{status: nil, code: "not_connected", detail: nil}}
    end
  end

  defp base_conn do
    with %{base_url: url} when is_binary(url) <- SamgitaConfig.get(),
         {:ok, credential} <- SamgitaConfig.resolve_secret(:agent_credential) do
      {:ok, %{base_url: url, credential: credential, connection_id: nil}}
    else
      _ -> {:error, %{status: nil, code: "not_configured", detail: nil}}
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{status: @initial, attempts: %{}}}

  @impl true
  def handle_call(:status, _from, s), do: {:reply, s.status, s}
  def handle_call(:attempts, _from, s), do: {:reply, Map.values(s.attempts), s}

  def handle_call(:disconnect, _from, s) do
    {:reply, :ok, publish(%{s | status: @initial, attempts: %{}})}
  end

  def handle_call({:connected, {:ok, data}}, _from, s) do
    status = %{
      state: :connected,
      agent_id: data["agent_id"],
      connection_id: data["id"],
      expires_at: data["expires_at"],
      last_error: nil
    }

    Logger.info("samgita_connected", agent_id: data["agent_id"])
    s = publish(%{s | status: status})
    {:reply, {:ok, status}, s}
  end

  def handle_call({:connected, {:error, error}}, _from, s) do
    Logger.warning("samgita_connect_failed", reason: error.code)
    s = publish(%{s | status: %{@initial | state: :error, last_error: error.code}})
    {:reply, {:error, error}, s}
  end

  @impl true
  def handle_cast({:attempt_view, view}, s), do: {:noreply, put_in(s.attempts[view.id], view)}

  defp publish(s) do
    Events.broadcast_status(s.status)
    s
  end
end
