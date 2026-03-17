defmodule Synapsis.Agent.Heartbeat.Templates do
  @moduledoc """
  Built-in heartbeat templates (AI-6.7).

  Seeds default heartbeat configurations on first run. All templates are
  disabled by default — users enable via settings UI.
  """

  alias Synapsis.{Repo, HeartbeatConfig}

  @templates [
    %{
      name: "morning-briefing",
      schedule: "30 7 * * 1-5",
      agent_type: :global,
      prompt:
        "Summarize overnight git activity, open PRs, and unresolved TODOs for all active projects.",
      enabled: false,
      notify_user: true,
      session_isolation: :isolated,
      keep_history: false
    },
    %{
      name: "stale-pr-check",
      schedule: "0 10 * * 1-5",
      agent_type: :global,
      prompt: "Check for PRs older than 3 days without review across all projects.",
      enabled: false,
      notify_user: true,
      session_isolation: :isolated,
      keep_history: false
    },
    %{
      name: "daily-summary",
      schedule: "0 18 * * 1-5",
      agent_type: :global,
      prompt: "Summarize today's completed work and remaining tasks across all projects.",
      enabled: false,
      notify_user: true,
      session_isolation: :isolated,
      keep_history: true
    }
  ]

  @doc """
  Seed default heartbeat templates. Idempotent — does not overwrite existing configs.
  """
  @spec seed_defaults() :: :ok
  def seed_defaults do
    Enum.each(@templates, fn template ->
      unless Repo.get_by(HeartbeatConfig, name: template.name) do
        %HeartbeatConfig{}
        |> HeartbeatConfig.changeset(template)
        |> Repo.insert()
      end
    end)

    :ok
  end

  @doc "Returns the list of default template configurations."
  @spec defaults() :: [map()]
  def defaults, do: @templates
end
