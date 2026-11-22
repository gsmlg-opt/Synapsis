defmodule SynapsisSamgita.Inbound do
  @moduledoc "Supervised, independent outbound sockets for explicitly selected Samgita device identities."
  use GenServer

  alias Synapsis.{AgentConfigs, LocalAgentConfigs, SamgitaConfig}
  alias Synapsis.Samgita.Devices
  alias SynapsisSamgita.Inbound.Client

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def select(source_kind, source_id) do
    with %{base_url: url} when is_binary(url) <- SamgitaConfig.get(),
         {:ok, name, implementation} <- source(source_kind, source_id),
         {:ok, device} <- Devices.select(source_kind, source_id, name, implementation, url),
         {:ok, _} <- connect(device["id"]) do
      {:ok, device}
    else
      %{base_url: nil} -> {:error, :not_configured}
      error -> error
    end
  end

  def connect(id) do
    with {:ok, _} <- Devices.enable(id) do
      case DynamicSupervisor.start_child(
             SynapsisSamgita.DeviceSupervisor,
             {Client, device_id: id}
           ) do
        {:ok, _pid} -> {:ok, status(id)}
        {:error, {:already_started, _pid}} -> {:ok, status(id)}
        error -> error
      end
    end
  end

  def disconnect(id) do
    with :ok <- idle(id), {:ok, _} <- Devices.disable(id) do
      stop(id)
      {:ok, status(id)}
    end
  end

  def forget(id) do
    with :ok <- idle(id), {:ok, _} <- Devices.forget(id) do
      stop(id)
      {:ok, status(id)}
    end
  end

  def list, do: Enum.map(Devices.list(), &status(&1["id"]))

  def status(id) do
    case lookup(id) do
      nil ->
        case Devices.get(id) do
          {:ok, device} ->
            %{
              device_id: id,
              state: if(device["forgotten"], do: :forgotten, else: :disconnected),
              agent_id: device["agent_id"],
              connection_id: nil,
              generation: device["generation"],
              last_error: nil
            }

          _ ->
            %{
              device_id: id,
              state: :error,
              agent_id: nil,
              connection_id: nil,
              generation: nil,
              last_error: "not_found"
            }
        end

      pid ->
        GenServer.call(pid, :status, 5_000)
    end
  catch
    :exit, _ ->
      %{
        device_id: id,
        state: :disconnected,
        agent_id: nil,
        connection_id: nil,
        generation: nil,
        last_error: "disconnected"
      }
  end

  def api_conn(id) do
    with %{state: :connected, connection_id: connection_id, agent_id: agent_id} <- status(id),
         {:ok, device} <- Devices.get(id),
         {:ok, token} <- Devices.resolve_token(id) do
      {:ok,
       %{
         device_id: id,
         agent_id: agent_id,
         base_url: device["base_url"],
         credential: token,
         connection_id: connection_id
       }}
    else
      _ -> {:error, %{status: nil, code: "not_connected", detail: nil}}
    end
  end

  defp lookup(id) do
    case Registry.lookup(SynapsisSamgita.DeviceRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp idle(id) do
    active =
      Registry.select(SynapsisSamgita.AttemptRegistry, [{{:"$1", :"$2", id}, [], [true]}]) != []

    if active or SynapsisSamgita.Execution.active?(id), do: {:error, :attempts_active}, else: :ok
  end

  defp stop(id) do
    if pid = lookup(id),
      do: DynamicSupervisor.terminate_child(SynapsisSamgita.DeviceSupervisor, pid)

    SynapsisSamgita.Events.broadcast_device_status(status(id))
    :ok
  end

  defp source("agent", id) do
    case AgentConfigs.get(id) do
      %{name: name, enabled: true} -> {:ok, name, "synapsis"}
      _ -> {:error, :invalid_identity}
    end
  end

  defp source("local_agent", id) do
    case LocalAgentConfigs.get(id) do
      %{name: name, kind: kind} when kind in ["codex", "sigma"] -> {:ok, name, kind}
      _ -> {:error, :invalid_identity}
    end
  end

  defp source(_, _), do: {:error, :invalid_identity}

  @impl true
  def init(_opts), do: {:ok, nil, {:continue, :restore}}

  @impl true
  def handle_continue(:restore, state) do
    for device <- Devices.list(), device["enabled"] == true and device["forgotten"] != true do
      DynamicSupervisor.start_child(
        SynapsisSamgita.DeviceSupervisor,
        {Client, device_id: device["id"]}
      )
    end

    {:noreply, state}
  end
end
