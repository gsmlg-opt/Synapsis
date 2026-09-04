defmodule Synapsis.Session.Worker.Auditor do
  @moduledoc "Async auditor invocation for Session.Worker escalation."

  require Logger

  alias Synapsis.Session.Worker.Config

  def start_async(params, state) do
    worker_pid = self()

    Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
      auditor_request =
        Synapsis.Session.AuditorTask.prepare_escalation(
          params.session_id,
          params.monitor,
          params.agent_config
        )

      auditor_provider = auditor_request.config.provider || state.session.provider

      case Config.resolve_provider_config(auditor_provider) do
        {:ok, provider_config} ->
          invoke_auditor(auditor_request, auditor_provider, provider_config, params)

        {:error, err} ->
          Logger.warning("auditor_invocation_failed",
            session_id: params.session_id,
            reason: inspect(err)
          )
      end

      send(worker_pid, {:auditor_completed, :ok})
    end)
  end

  defp invoke_auditor(auditor_request, auditor_provider, provider_config, params) do
    provider_type = provider_config[:type] || provider_config["type"] || "anthropic"

    model =
      auditor_request.config.model || provider_config[:default_model] ||
        Synapsis.Providers.model_for_tier(auditor_provider, :fast)

    config = Map.put(provider_config, :type, provider_type)

    result =
      with {:ok, request} <-
             Synapsis.Provider.Adapter.format_request(
               [
                 %{
                   role: "user",
                   parts: [%Synapsis.Part.Text{content: auditor_request.user_message}]
                 }
               ],
               [],
               %{
                 model: model,
                 max_tokens: auditor_request.config.max_tokens,
                 system_prompt: auditor_request.system_prompt,
                 provider_type: provider_type,
                 provider_name: auditor_provider,
                 endpoint: provider_config[:base_url] || provider_config["base_url"],
                 stream: false
               }
             ) do
        Synapsis.Provider.Adapter.complete(request, config)
      end

    case result do
      {:ok, response_text} ->
        Synapsis.Session.AuditorTask.record_analysis(
          params.session_id,
          response_text,
          trigger: to_string(params.decision),
          auditor_model: model
        )

      {:error, err} ->
        Logger.warning("auditor_invocation_failed",
          session_id: params.session_id,
          reason: inspect(err)
        )
    end
  end
end
