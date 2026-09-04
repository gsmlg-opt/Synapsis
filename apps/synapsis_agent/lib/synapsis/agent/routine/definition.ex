defmodule Synapsis.Agent.Routine.Definition do
  @moduledoc """
  Normalized routine definition (PRD §8.1).

  Heartbeat TOML configs adapt into this shape without requiring file migration.
  """

  @enforce_keys [:id, :name, :kind, :schedule]
  defstruct [
    :id,
    :name,
    :kind,
    :schedule,
    :prompt,
    scope: :global,
    project_ref: nil,
    enabled: true,
    timezone: "Etc/UTC",
    tool_profile: "heartbeat",
    capability_overrides: %{},
    no_overlap: true,
    max_runtime_ms: nil,
    misfire_policy: :skip,
    retry_policy: %{max_attempts: 3, base_ms: 60_000, max_ms: 3_600_000},
    notify_user: false,
    keep_history: false,
    agent_name: "main",
    provider: nil,
    model: nil,
    metadata: %{}
  ]

  @type misfire_policy :: :skip | :run_once
  @type kind :: :heartbeat | :dream | :schedule

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          kind: kind(),
          scope: :global | :project,
          project_ref: String.t() | nil,
          enabled: boolean(),
          schedule: String.t(),
          timezone: String.t(),
          prompt: String.t() | nil,
          tool_profile: String.t(),
          capability_overrides: map(),
          no_overlap: boolean(),
          max_runtime_ms: pos_integer() | nil,
          misfire_policy: misfire_policy(),
          retry_policy: map(),
          notify_user: boolean(),
          keep_history: boolean(),
          agent_name: String.t(),
          provider: String.t() | nil,
          model: String.t() | nil,
          metadata: map()
        }

  @doc "Adapt a heartbeat Config.Store / legacy map into a Definition."
  @spec from_heartbeat(map()) :: {:ok, t()} | {:error, term()}
  def from_heartbeat(map) when is_map(map) do
    id = get(map, :id) || get(map, "id")
    name = get(map, :name) || get(map, "name")
    schedule = get(map, :schedule) || get(map, "schedule")

    cond do
      not is_binary(id) or id == "" ->
        {:error, :missing_id}

      not is_binary(name) or name == "" ->
        {:error, :missing_name}

      not is_binary(schedule) or schedule == "" ->
        {:error, :missing_schedule}

      true ->
        {:ok,
         %__MODULE__{
           id: id,
           name: name,
           kind: :heartbeat,
           scope: :global,
           enabled: truthy?(get(map, :enabled, get(map, "enabled", true))),
           schedule: schedule,
           timezone: get(map, :timezone) || get(map, "timezone") || "Etc/UTC",
           prompt: get(map, :prompt) || get(map, "prompt") || "",
           tool_profile: get(map, :tool_profile) || get(map, "tool_profile") || "heartbeat",
           no_overlap: truthy?(get(map, :no_overlap, get(map, "no_overlap", true))),
           max_runtime_ms: get(map, :max_runtime_ms) || get(map, "max_runtime_ms"),
           misfire_policy: parse_misfire(get(map, :misfire_policy) || get(map, "misfire_policy")),
           retry_policy: parse_retry(get(map, :retry_policy) || get(map, "retry_policy")),
           notify_user: truthy?(get(map, :notify_user, get(map, "notify_user", false))),
           keep_history: truthy?(get(map, :keep_history, get(map, "keep_history", false))),
           agent_name: get(map, :agent_name) || get(map, "agent_name") || "main",
           provider: get(map, :provider) || get(map, "provider"),
           model: get(map, :model) || get(map, "model"),
           metadata: get(map, :metadata) || get(map, "metadata") || %{}
         }}
    end
  end

  @doc "Load enabled heartbeat definitions from Config.Store."
  @spec load_heartbeats() :: {:ok, [t()]} | {:error, term()}
  def load_heartbeats do
    defs =
      :heartbeat
      |> Synapsis.Config.Store.list()
      |> Enum.map(&from_heartbeat/1)
      |> Enum.flat_map(fn
        {:ok, %__MODULE__{enabled: true} = d} -> [d]
        {:ok, _} -> []
        {:error, _} -> []
      end)

    {:ok, defs}
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, inspect({kind, reason})}
  end

  @doc "Legacy Worker-shaped map for heartbeat execution helpers."
  @spec to_heartbeat_config(t()) :: map()
  def to_heartbeat_config(%__MODULE__{} = d) do
    %{
      id: d.id,
      name: d.name,
      schedule: d.schedule,
      enabled: d.enabled,
      prompt: d.prompt || "",
      agent_name: d.agent_name,
      keep_history: d.keep_history,
      notify_user: d.notify_user,
      provider: d.provider,
      model: d.model,
      tool_profile: d.tool_profile
    }
  end

  defp get(map, key, default \\ nil) do
    Map.get(map, key, default)
  end

  defp truthy?(false), do: false
  defp truthy?("false"), do: false
  defp truthy?("0"), do: false
  defp truthy?(0), do: false
  defp truthy?(nil), do: false
  defp truthy?(_), do: true

  defp parse_misfire(:run_once), do: :run_once
  defp parse_misfire("run_once"), do: :run_once
  defp parse_misfire(_), do: :skip

  defp parse_retry(%{} = policy) do
    %{
      max_attempts: policy[:max_attempts] || policy["max_attempts"] || 3,
      base_ms: policy[:base_ms] || policy["base_ms"] || 60_000,
      max_ms: policy[:max_ms] || policy["max_ms"] || 3_600_000
    }
  end

  defp parse_retry(_), do: %{max_attempts: 3, base_ms: 60_000, max_ms: 3_600_000}
end
