defmodule Synapsis.Memory.Settings do
  @moduledoc "Memory backend configuration. Workspace Markdown is always the default."

  alias Synapsis.Config.Store
  alias Synapsis.Memory.HostAgent

  @defaults %{
    "backend" => "workspace",
    "host_agent" => %{
      "enabled" => false,
      "endpoint" => "http://127.0.0.1:4222",
      "agent_id" => "synapsis"
    }
  }

  def get do
    case Store.get(:memory, "default") do
      {:ok, entry} -> validate(Map.delete(entry, "id"))
      {:error, :not_found} -> {:ok, @defaults}
      {:error, :invalid_config} -> {:error, :invalid_config}
      _ -> {:error, :unavailable}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def save(config) do
    with {:ok, valid} <- validate(config) do
      case Store.put(:memory, Map.put(valid, "id", "default")) do
        {:ok, _} -> {:ok, valid}
        _ -> {:error, :unavailable}
      end
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def host_source do
    with {:ok, config} <- get() do
      if config["host_agent"]["enabled"],
        do: {:ok, source(config["host_agent"])},
        else: {:error, :disabled}
    end
  end

  def host_enabled?, do: match?({:ok, _}, host_source())

  defp validate(%{"backend" => "workspace", "host_agent" => host} = config)
       when is_map(host) do
    if Enum.sort(Map.keys(config)) == ~w(backend host_agent) and
         Enum.sort(Map.keys(host)) == ~w(agent_id enabled endpoint) and
         is_boolean(host["enabled"]) and HostAgent.validate_source(source(host)) == :ok,
       do: {:ok, config},
       else: {:error, :invalid_config}
  end

  defp validate(_), do: {:error, :invalid_config}

  defp source(host) do
    %{id: "backplane-host", endpoint: host["endpoint"], agent_id: host["agent_id"]}
  end
end
