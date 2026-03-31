defmodule Synapsis.Session.Stream do
  @moduledoc "Manages provider HTTP streaming connections."

  require Logger

  def start_stream(request, provider_config, provider_name) do
    case Synapsis.Provider.Registry.module_for(provider_name) do
      {:ok, provider_module} ->
        try do
          provider_module.stream(request, provider_config)
        rescue
          e ->
            Logger.warning("provider_stream_crash",
              provider: provider_name,
              error: Exception.message(e)
            )

            {:error, "Provider stream failed"}
        catch
          kind, reason ->
            Logger.warning("provider_stream_throw",
              provider: provider_name,
              kind: kind,
              error: inspect(reason)
            )

            {:error, "Provider stream failed"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def cancel_stream(ref, provider_name) do
    case Synapsis.Provider.Registry.module_for(provider_name) do
      {:ok, provider_module} ->
        try do
          provider_module.cancel(ref)
        rescue
          e ->
            Logger.warning("provider_cancel_crash",
              provider: provider_name,
              error: Exception.message(e)
            )

            :ok
        end

      {:error, _} ->
        :ok
    end
  end
end
