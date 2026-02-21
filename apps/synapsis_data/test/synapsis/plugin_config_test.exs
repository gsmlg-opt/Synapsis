defmodule Synapsis.PluginConfigTest do
  use Synapsis.DataCase

  alias Synapsis.{PluginConfig, Repo}

  describe "changeset/2" do
    test "valid with required fields" do
      cs = %PluginConfig{} |> PluginConfig.changeset(%{type: "mcp", name: "test-plugin"})
      assert cs.valid?
    end

    test "invalid without type" do
      cs = %PluginConfig{} |> PluginConfig.changeset(%{name: "test"})
      refute cs.valid?
      assert %{type: ["can't be blank"]} = errors_on(cs)
    end

    test "invalid without name" do
      cs = %PluginConfig{} |> PluginConfig.changeset(%{type: "mcp"})
      refute cs.valid?
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "validates type inclusion" do
      cs = %PluginConfig{} |> PluginConfig.changeset(%{type: "invalid", name: "test"})
      refute cs.valid?
      assert %{type: [_]} = errors_on(cs)
    end

    test "allows valid types" do
      for type <- ~w(mcp lsp custom) do
        cs = %PluginConfig{} |> PluginConfig.changeset(%{type: type, name: "test"})
        assert cs.valid?, "Expected type #{type} to be valid"
      end
    end

    test "validates transport inclusion" do
      cs =
        %PluginConfig{}
        |> PluginConfig.changeset(%{type: "mcp", name: "test", transport: "invalid"})

      refute cs.valid?
      assert %{transport: [_]} = errors_on(cs)
    end

    test "allows valid transports" do
      for transport <- ~w(stdio sse tcp) do
        cs =
          %PluginConfig{}
          |> PluginConfig.changeset(%{type: "mcp", name: "test", transport: transport})

        assert cs.valid?, "Expected transport #{transport} to be valid"
      end
    end

    test "validates scope inclusion" do
      cs =
        %PluginConfig{}
        |> PluginConfig.changeset(%{type: "mcp", name: "test", scope: "invalid"})

      refute cs.valid?
      assert %{scope: [_]} = errors_on(cs)
    end

    test "sets defaults" do
      cs = %PluginConfig{} |> PluginConfig.changeset(%{type: "mcp", name: "test"})
      assert get_field(cs, :transport) == "stdio"
      assert get_field(cs, :args) == []
      assert get_field(cs, :env) == %{}
      assert get_field(cs, :settings) == %{}
      assert get_field(cs, :auto_start) == false
      assert get_field(cs, :scope) == "project"
    end
  end

  describe "unique_constraint" do
    test "enforces uniqueness of name + scope + project_id with same non-nil project_id" do
      {:ok, project} =
        %Synapsis.Project{}
        |> Synapsis.Project.changeset(%{
          path: "/tmp/plugin-unique-#{:rand.uniform(100_000)}",
          slug: "plugin-unique-#{:rand.uniform(100_000)}"
        })
        |> Repo.insert()

      attrs = %{type: "mcp", name: "unique-plugin", scope: "project", project_id: project.id}

      {:ok, _} =
        %PluginConfig{}
        |> PluginConfig.changeset(attrs)
        |> Repo.insert()

      {:error, changeset} =
        %PluginConfig{}
        |> PluginConfig.changeset(attrs)
        |> Repo.insert()

      assert not changeset.valid? or changeset.errors != []
    end
  end

  describe "persistence" do
    test "inserts and retrieves config" do
      {:ok, config} =
        %PluginConfig{}
        |> PluginConfig.changeset(%{
          type: "mcp",
          name: "test-mcp",
          transport: "stdio",
          command: "npx test-server"
        })
        |> Repo.insert()

      found = Repo.get!(PluginConfig, config.id)
      assert found.type == "mcp"
      assert found.name == "test-mcp"
      assert found.command == "npx test-server"
    end

    test "stores args and settings" do
      {:ok, config} =
        %PluginConfig{}
        |> PluginConfig.changeset(%{
          type: "lsp",
          name: "test-lsp",
          command: "elixir-ls",
          args: ["--stdio"],
          settings: %{"rootPath" => "/tmp"}
        })
        |> Repo.insert()

      found = Repo.get!(PluginConfig, config.id)
      assert found.args == ["--stdio"]
      assert found.settings == %{"rootPath" => "/tmp"}
    end
  end
end
