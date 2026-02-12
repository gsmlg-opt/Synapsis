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
    case to_string(provider_name) do
      "anthropic" -> {:ok, Synapsis.Provider.Anthropic}
      "openai" -> {:ok, Synapsis.Provider.OpenAICompat}
      "google" -> {:ok, Synapsis.Provider.Google}
      "local" -> {:ok, Synapsis.Provider.OpenAICompat}
      "openrouter" -> {:ok, Synapsis.Provider.OpenAICompat}
      _ -> {:error, :unknown_provider}
    end
  end

  @impl true
  def init(:ok) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, table}
  end
end
