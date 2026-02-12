defmodule Synapsis.Session.Stream do
  @moduledoc "Manages provider HTTP streaming connections."

  def start_stream(request, provider_config, provider_name) do
    case Synapsis.Provider.Registry.module_for(provider_name) do
      {:ok, provider_module} ->
        provider_module.stream(request, provider_config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def cancel_stream(ref, provider_name) do
    case Synapsis.Provider.Registry.module_for(provider_name) do
      {:ok, provider_module} ->
        provider_module.cancel(ref)

      {:error, _} ->
        :ok
    end
  end
end
