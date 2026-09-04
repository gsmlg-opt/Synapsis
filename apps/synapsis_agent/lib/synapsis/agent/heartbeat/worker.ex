defmodule Synapsis.Agent.Heartbeat.Worker do
  @moduledoc """
  Heartbeat fire path — called by `LocalScheduler` as a supervised Task.

  Execution authority is `Daemon.trigger/3` + `RunCoordinator`. This module
  awaits the run terminal, records streak outcomes, then optionally delivers
  a report without rewriting execution status.
  """

  alias Synapsis.Agent.Daemon
  alias Synapsis.Agent.Heartbeat.Delivery
  alias Synapsis.Agent.Runs
  alias Synapsis.AgentRun
  alias Synapsis.Config.Store, as: ConfigStore
  require Logger

  @await_poll_ms 100
  @default_await_ms :timer.minutes(10)

  @doc "Execute a heartbeat config map (from Config.Store)."
  @spec execute(map()) :: :ok | {:error, term()}
  def execute(config) do
    case Map.get(config, :enabled, true) do
      false ->
        Logger.info("heartbeat_disabled", name: config.name)
        :ok

      _ ->
        execute_heartbeat(config)
    end
  end

  @doc false
  def perform_by_id(heartbeat_id) when is_binary(heartbeat_id) do
    case find_config(heartbeat_id) do
      nil ->
        Logger.warning("heartbeat_config_not_found", heartbeat_id: heartbeat_id)
        {:error, :config_not_found}

      %{enabled: false} ->
        Logger.info("heartbeat_disabled", heartbeat_id: heartbeat_id)
        :ok

      config ->
        execute_heartbeat(config)
    end
  end

  defp execute_heartbeat(config) do
    Logger.info("heartbeat_executing", name: config.name, heartbeat_id: config.id)

    opts = trigger_opts(config)

    case Daemon.trigger(:heartbeat, config.id, opts) do
      {:ok, run} ->
        await_and_finish(run.id, config)

      {:error, reason} ->
        Logger.error("heartbeat_trigger_failed",
          name: config.name,
          heartbeat_id: config.id,
          error: inspect(reason)
        )

        _ = Daemon.record_heartbeat_outcome(config.id, :failed)
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("heartbeat_failed",
        name: config.name,
        heartbeat_id: config.id,
        error: Exception.message(e),
        stacktrace: Exception.format_stacktrace(__STACKTRACE__)
      )

      {:error, Exception.message(e)}
  end

  defp await_and_finish(run_id, config) do
    timeout_ms = Map.get(config, :await_ms, @default_await_ms)

    case await_terminal(run_id, timeout_ms) do
      {:ok, %AgentRun{} = run} ->
        outcome = if run.status == "completed", do: :completed, else: :failed
        _ = Daemon.record_heartbeat_outcome(config.id, outcome, finished_at: run.finished_at)

        case Delivery.deliver(run, config) do
          :ok ->
            if run.status == "completed", do: :ok, else: {:error, run.error || run.status}

          {:error, delivery_reason} ->
            Logger.warning("heartbeat_delivery_degraded",
              run_id: run.id,
              execution_status: run.status,
              reason: inspect(delivery_reason)
            )

            # Never rewrite execution outcome on delivery failure.
            if run.status == "completed", do: :ok, else: {:error, run.error || run.status}
        end

      {:error, :await_timeout} ->
        _ = Daemon.record_heartbeat_outcome(config.id, :failed)
        {:error, :await_timeout}
    end
  end

  defp await_terminal(run_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_terminal(run_id, deadline)
  end

  defp do_await_terminal(run_id, deadline) do
    case Runs.get(run_id) do
      %AgentRun{} = run ->
        if AgentRun.terminal?(run) do
          {:ok, run}
        else
          if System.monotonic_time(:millisecond) >= deadline do
            {:error, :await_timeout}
          else
            Process.sleep(@await_poll_ms)
            do_await_terminal(run_id, deadline)
          end
        end

      nil ->
        {:error, :await_timeout}
    end
  end

  defp trigger_opts(config) do
    occurrence = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    %{
      prompt: config.prompt || "",
      agent: config.agent_name || "main",
      assistant_name: config.agent_name || "main",
      heartbeat_id: config.id,
      routine_id: config.id,
      name: config.name,
      keep_history: Map.get(config, :keep_history, false),
      notify_user: Map.get(config, :notify_user, false),
      provider: Map.get(config, :provider),
      model: Map.get(config, :model),
      deadline_at: Map.get(config, :deadline_at),
      idempotency_key: Map.get(config, :idempotency_key) || "#{config.id}:#{occurrence}",
      metadata: %{
        "heartbeat_name" => config.name,
        "type" => "heartbeat"
      }
    }
  end

  defp find_config(heartbeat_id) do
    :heartbeat
    |> ConfigStore.list()
    |> Enum.map(&normalize_config/1)
    |> Enum.find(fn c -> c.id == heartbeat_id or c.name == heartbeat_id end)
  rescue
    _ -> nil
  end

  defp normalize_config(c) when is_map(c) do
    %{
      id: c["id"] || c[:id],
      name: c["name"] || c[:name],
      schedule: c["schedule"] || c[:schedule],
      enabled: Map.get(c, "enabled", Map.get(c, :enabled, true)),
      prompt: c["prompt"] || c[:prompt] || "",
      agent_name: c["agent_name"] || c[:agent_name] || "main",
      keep_history: c["keep_history"] || c[:keep_history] || false,
      notify_user: c["notify_user"] || c[:notify_user] || false
    }
  end
end
