defmodule Synapsis.Agent.TestSupport.SessionHarness do
  @moduledoc """
  Shared helpers for interactive session characterization tests.
  """

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, DeterministicTool}
  alias Synapsis.Session.DynamicSupervisor

  @doc "Build an agent + session wired to a deterministic provider (and optional tool)."
  def setup_session!(opts) do
    tmp_dir = Keyword.fetch!(opts, :tmp_dir)
    suffix = System.unique_integer([:positive, :monotonic])
    agent_name = Keyword.get(opts, :agent_name, "char_agent_#{suffix}")
    permission_mode = Keyword.get(opts, :permission_mode, "yolo")
    scenario = Keyword.get(opts, :scenario, :success)
    tool_behavior = Keyword.get(opts, :tool_behavior)
    text = Keyword.get(opts, :text, "characterization complete")

    {:ok, counter} =
      Agent.start_link(fn -> %{provider_requests: [], tool_executions: 0} end)

    tool_name =
      if tool_behavior do
        name = Keyword.get(opts, :tool_name, "char_tool_#{suffix}")
        DeterministicTool.register(name, tool_behavior, Keyword.get(opts, :tool_opts, []))
        name
      end

    provider_opts =
      [
        scenario: scenario,
        counter: counter,
        text: text
      ]
      |> maybe_put(:tool_name, tool_name)
      |> maybe_put(:tool_call_id, Keyword.get(opts, :tool_call_id))
      |> maybe_put(:tool_args, Keyword.get(opts, :tool_args, %{"value" => "verified"}))
      |> maybe_put(:stream_chunks, Keyword.get(opts, :stream_chunks))

    provider = DeterministicProvider.start!(provider_opts)

    tools = if is_binary(tool_name), do: [tool_name], else: []

    {:ok, agent_config} =
      Synapsis.AgentConfigs.create(%{
        name: agent_name,
        label: "Characterization",
        provider: provider.name,
        model: "characterization-model",
        tools: tools,
        permission_mode: permission_mode,
        config: %{"workspace_path" => tmp_dir}
      })

    {:ok, session} =
      Synapsis.Sessions.create(agent_name, %{
        agent: agent_name,
        provider: provider.name,
        model: "characterization-model"
      })

    %{
      session: session,
      agent_config: agent_config,
      agent_name: agent_name,
      provider: provider,
      tool_name: tool_name,
      counter: counter,
      tmp_dir: tmp_dir
    }
  end

  def cleanup!(harness) do
    _ = DynamicSupervisor.stop_session(harness.session.id)
    _ = Synapsis.Sessions.delete(harness.session.id)
    _ = Synapsis.AgentConfigs.delete(harness.agent_config)
    _ = DeterministicProvider.stop(harness.provider)

    if harness.tool_name do
      DeterministicTool.unregister(harness.tool_name)
    end

    if Process.alive?(harness.counter) do
      Agent.stop(harness.counter)
    end

    :ok
  end

  def subscribe!(session_id) do
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session_id}")
  end

  def ensure_running!(session_id) do
    :ok = Synapsis.Sessions.ensure_running(session_id)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
