defmodule Synapsis.Session.Worker.Auditor do
  @moduledoc "Async auditor invocation for Session.Worker escalation."

  require Logger

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

      provider_config =
        case Synapsis.Provider.Registry.get(auditor_provider) do
          {:ok, cfg} -> cfg
          {:error, _} -> state.provider_config
        end

      provider_type = provider_config[:type] || provider_config["type"] || "anthropic"

      request = %{
        model:
          auditor_request.config.model || provider_config[:default_model] ||
            Synapsis.Providers.model_for_tier(auditor_provider, :fast),
        max_tokens: auditor_request.config.max_tokens || 1024,
        system: auditor_request.system_prompt,
        messages: [%{role: "user", content: auditor_request.user_message}]
      }

      config = Map.put(provider_config, :type, provider_type)

      case Synapsis.Provider.Adapter.complete(request, config) do
        {:ok, response_text} ->
          Synapsis.Session.AuditorTask.record_analysis(
            params.session_id,
            response_text,
            trigger: to_string(params.decision),
            auditor_model: request.model
          )

        {:error, err} ->
          Logger.warning("auditor_invocation_failed",
            session_id: params.session_id,
            reason: inspect(err)
          )
      end

      send(worker_pid, {:auditor_completed, :ok})
    end)
  end
end
