defmodule Synapsis.LocalAgentConfigsTest do
  use Synapsis.DataCase

  alias Synapsis.{LocalAgentConfig, LocalAgentConfigs}

  setup do
    clear_config_store(:local_agent)
    :ok
  end

  test "create/1 round-trips with codex defaults" do
    assert {:ok, %LocalAgentConfig{id: id}} =
             LocalAgentConfigs.create(%{name: "Codex", kind: "codex", executable: "/bin/true"})

    assert %LocalAgentConfig{
             name: "Codex",
             kind: "codex",
             executable: "/bin/true",
             args: ["app-server", "--listen", "stdio://"],
             autostart: false,
             codex_home: codex_home
           } = LocalAgentConfigs.get(id)

    assert codex_home == Path.expand("~/.codex")
    assert [%LocalAgentConfig{id: ^id}] = LocalAgentConfigs.list()
  end

  test "create/1 rejects unknown kinds" do
    assert {:error, %Ecto.Changeset{}} =
             LocalAgentConfigs.create(%{name: "X", kind: "nope", executable: "/bin/true"})
  end

  test "update/2 and delete/1" do
    {:ok, config} = LocalAgentConfigs.create(%{name: "Codex", kind: "codex", executable: "/bin/true"})
    assert {:ok, %LocalAgentConfig{autostart: true}} = LocalAgentConfigs.update(config, %{autostart: true})
    assert {:ok, _} = LocalAgentConfigs.delete(config)
    assert LocalAgentConfigs.get(config.id) == nil
  end

  test "ensure_default_codex/0 is idempotent" do
    if System.find_executable("codex") do
      LocalAgentConfigs.ensure_default_codex()
      LocalAgentConfigs.ensure_default_codex()
      assert [%LocalAgentConfig{kind: "codex", name: "Codex"}] = LocalAgentConfigs.list()
    else
      assert :ok = LocalAgentConfigs.ensure_default_codex()
      assert [] = LocalAgentConfigs.list()
    end
  end
end
