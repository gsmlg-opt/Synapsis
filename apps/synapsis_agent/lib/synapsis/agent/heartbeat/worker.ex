defmodule Synapsis.Agent.Heartbeat.Worker do
  @moduledoc """
  Compatibility adapter from stored heartbeat configs to the daemon run path.

  Session creation, timeout, cancellation, persistence, and lifecycle events are
  owned by `Synapsis.Agent.Daemon`; this module does not run a second executor.
  """

  alias Synapsis.Agent.Daemon
  require Logger

  @doc "Submit a heartbeat config through the daemon."
  @spec execute(map(), GenServer.server()) ::
          {:ok, Synapsis.AgentRun.t()} | {:error, term()} | :ok
  def execute(config, daemon \\ Daemon) do
    if value(config, :enabled, true) == false do
      Logger.info("heartbeat_disabled", name: value(config, :name))
      :ok
    else
      Daemon.trigger(daemon, :heartbeat, trigger_options(config))
    end
  end

  @doc false
  def perform_by_id(heartbeat_id) do
    case Synapsis.Heartbeats.get(heartbeat_id) do
      nil ->
        Logger.warning("heartbeat_config_not_found", heartbeat_id: heartbeat_id)
        {:error, :config_not_found}

      config ->
        execute(config)
    end
  end

  defp trigger_options(config) do
    id = value(config, :id)

    %{
      heartbeat_id: id,
      routine_id: id,
      prompt: value(config, :prompt),
      assistant_name: value(config, :agent_name, "main") || "main",
      tool_profile: value(config, :tool_profile, "assistant_basic") || "assistant_basic",
      no_overlap: value(config, :no_overlap, true) != false,
      max_runtime_ms: value(config, :max_runtime_ms, :timer.minutes(2)),
      metadata: %{"heartbeat_name" => value(config, :name)}
    }
  end

  defp value(config, key, default \\ nil) do
    Map.get(config, key, Map.get(config, Atom.to_string(key), default))
  end
end
