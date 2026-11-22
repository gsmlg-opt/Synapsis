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
    {:ok, config} =
      LocalAgentConfigs.create(%{name: "Codex", kind: "codex", executable: "/bin/true"})

    assert {:ok, %LocalAgentConfig{autostart: true}} =
             LocalAgentConfigs.update(config, %{autostart: true})

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

  describe "sigma" do
    @sigma %{
      name: "Sigma",
      kind: "sigma",
      url: "ws://127.0.0.1:4580/app-server",
      repository: "/home/me/repo"
    }

    test "requires a ws url and an absolute repository, not an executable" do
      assert {:ok, %LocalAgentConfig{kind: "sigma", url: "ws://127.0.0.1:4580/app-server"}} =
               LocalAgentConfigs.create(@sigma)

      assert {:error, changeset} = LocalAgentConfigs.create(%{@sigma | url: "http://x"})
      assert %{url: [_]} = errors_on(changeset)
      assert {:error, changeset} = LocalAgentConfigs.create(%{@sigma | repository: "repo"})
      assert %{repository: [_]} = errors_on(changeset)
    end

    test "a rotated token resolves, survives updates and is never inspected" do
      {:ok, config} = LocalAgentConfigs.create(@sigma)
      assert {:error, :not_configured} = LocalAgentConfigs.resolve_token(config.id)

      assert {:ok, token} = LocalAgentConfigs.rotate_token(config.id)
      assert byte_size(token) >= 32
      assert {:ok, ^token} = LocalAgentConfigs.resolve_token(config.id)

      {:ok, _} = LocalAgentConfigs.update(config, %{name: "Sigma 2", token_encrypted: "x"})
      assert {:ok, ^token} = LocalAgentConfigs.resolve_token(config.id)

      stored = LocalAgentConfigs.get(config.id)
      refute inspect(stored) =~ stored.token_encrypted
      refute inspect(stored) =~ token
    end

    test "codex agents have no token" do
      {:ok, config} =
        LocalAgentConfigs.create(%{name: "Codex", kind: "codex", executable: "/bin/true"})

      assert {:error, :unsupported_kind} = LocalAgentConfigs.rotate_token(config.id)
    end
  end
end
