defmodule Synapsis.Session.Worker.BootTest do
  use ExUnit.Case, async: false

  alias Synapsis.{AgentConfigs, Config.Store, Session}
  alias Synapsis.Session.Worker.Boot

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    original_config_dir = System.get_env("SYNAPSIS_CONFIG_DIR")
    config_dir = Path.join(tmp_dir, "config")
    System.put_env("SYNAPSIS_CONFIG_DIR", config_dir)
    Store.reload(:agent)
    Synapsis.Session.Store.ensure_started()

    on_exit(fn ->
      if original_config_dir do
        System.put_env("SYNAPSIS_CONFIG_DIR", original_config_dir)
      else
        System.delete_env("SYNAPSIS_CONFIG_DIR")
      end

      Store.reload(:agent)
    end)

    :ok
  end

  @tag :tmp_dir
  test "creates missing agent workspace path before boot uses it", %{tmp_dir: tmp_dir} do
    workspace_path = Path.join(tmp_dir, "agents/main")

    refute File.exists?(workspace_path)
    assert {:ok, ^workspace_path} = Boot.ensure_workspace_path(workspace_path)
    assert File.dir?(workspace_path)
  end

  @tag :tmp_dir
  test "reports workspace path creation failures", %{tmp_dir: tmp_dir} do
    parent_file = Path.join(tmp_dir, "not-a-directory")
    File.write!(parent_file, "file")
    workspace_path = Path.join(parent_file, "main")

    assert {:error, {:workspace_unavailable, ^workspace_path, _reason}} =
             Boot.ensure_workspace_path(workspace_path)
  end

  test "load_and_boot refreshes stale session metadata to agent default model", %{
    tmp_dir: tmp_dir
  } do
    agent_name = "agent-#{System.unique_integer([:positive])}"
    workspace_path = Path.join(tmp_dir, "workspace")

    {:ok, _agent} =
      AgentConfigs.create(%{
        name: agent_name,
        provider: "anthropic",
        model: "new-default-model",
        config: %{"workspace_path" => workspace_path}
      })

    session =
      persist_session(%{
        agent: agent_name,
        provider: "anthropic",
        model: "old-stale-model"
      })

    assert {booted_session, agent, _provider_config, _graph, engine_state, engine_ctx,
            ^workspace_path} = Boot.load_and_boot(session.id)

    assert booted_session.model == "new-default-model"
    assert agent.model == "new-default-model"
    assert engine_state.agent_config.model == "new-default-model"
    assert engine_ctx.model == "new-default-model"

    assert {:ok, meta} = Synapsis.Session.Store.get_meta(session.id)
    assert Session.from_meta(meta).model == "new-default-model"
  end

  defp persist_session(attrs) do
    session =
      %Session{}
      |> Session.changeset(
        Map.merge(%{provider: "anthropic", model: "test-model", agent: "main"}, attrs)
      )
      |> Ecto.Changeset.apply_changes()
      |> Map.put(:id, Ecto.UUID.generate())

    :ok = Synapsis.Session.Store.put_meta(session.id, Session.to_meta(session))
    session
  end
end
