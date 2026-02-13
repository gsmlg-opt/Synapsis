defmodule Synapsis.Provider.Registry do
  @moduledoc "ETS-backed provider configuration registry."
  use GenServer

  @table :synapsis_providers

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def register(provider_name, config) do
    :ets.insert(@table, {provider_name, config})
    :ok
  end

  def unregister(provider_name) do
    :ets.delete(@table, provider_name)
    :ok
  end

  def get(provider_name) do
    case :ets.lookup(@table, provider_name) do
      [{^provider_name, config}] -> {:ok, config}
      [] -> {:error, :not_found}
    end
  end

  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {name, config} -> {name, config} end)
  end

  def module_for(provider_name) do
    # Check ETS config for a type field first
    type =
      case get(provider_name) do
        {:ok, %{type: t}} -> t
        _ -> nil
      end

    resolve_module(type || to_string(provider_name))
  end

  defp resolve_module("anthropic"), do: {:ok, Synapsis.Provider.Anthropic}
  defp resolve_module("openai"), do: {:ok, Synapsis.Provider.OpenAICompat}
  defp resolve_module("openai_compat"), do: {:ok, Synapsis.Provider.OpenAICompat}
  defp resolve_module("google"), do: {:ok, Synapsis.Provider.Google}
  defp resolve_module("local"), do: {:ok, Synapsis.Provider.OpenAICompat}
  defp resolve_module("openrouter"), do: {:ok, Synapsis.Provider.OpenAICompat}
  defp resolve_module(_), do: {:error, :unknown_provider}

  @impl true
  def init(:ok) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, table}
  end
end
