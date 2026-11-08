defmodule Synapsis.SkillWorkshop.Scope do
  @moduledoc "A captured, persisted Agent's private workshop location and authoring limit."

  alias Synapsis.Config.Store

  @enforce_keys [:agent_id, :config_root, :relative_root, :root, :max_skill_bytes]
  defstruct @enforce_keys

  def capture(agent_id) when is_binary(agent_id) do
    with {:ok, ^agent_id} <- Ecto.UUID.cast(agent_id),
         {:ok, %{"id" => ^agent_id, "enabled" => true} = agent} <- Store.get(:agent, agent_id),
         {:ok, config} <- decode_config(Map.get(agent, "config")),
         config_root = Path.expand(Store.config_dir()),
         :ok <- existing_directory(config_root),
         relative_root = Path.join(["agents", agent_id, "workshop-skills"]) do
      {:ok,
       %__MODULE__{
         agent_id: agent_id,
         config_root: config_root,
         relative_root: relative_root,
         root: Path.join(config_root, relative_root),
         max_skill_bytes: limit(config)
       }}
    else
      {:ok, _} -> {:error, :invalid_agent}
      :error -> {:error, :invalid_agent}
      error -> error
    end
  end

  def capture(_), do: {:error, :invalid_agent}

  defp existing_directory(path) do
    case File.stat(path) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, _} -> {:error, :enotdir}
      {:error, _} = error -> error
    end
  end

  defp decode_config(nil), do: {:ok, %{}}
  defp decode_config(config) when is_map(config) and not is_struct(config), do: {:ok, config}

  defp decode_config(config) when is_binary(config) do
    case Jason.decode(config) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, :invalid_agent_config}
    end
  end

  defp decode_config(_), do: {:error, :invalid_agent_config}

  defp limit(config) do
    value =
      case config do
        %{"skills" => %{"workshop" => %{"maxSkillBytes" => maximum}}} -> maximum
        _ -> nil
      end

    case value do
      value when is_number(value) -> value |> trunc() |> max(1_024) |> min(200_000)
      _ -> 40_000
    end
  end
end
