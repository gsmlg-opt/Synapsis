defmodule Synapsis.LSPConfigTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.LSPConfig

  describe "changeset/2" do
    test "valid with required fields" do
      changeset =
        LSPConfig.changeset(%LSPConfig{}, %{
          language: "elixir",
          command: "elixir-ls"
        })

      assert changeset.valid?
    end

    test "requires language" do
      changeset = LSPConfig.changeset(%LSPConfig{}, %{command: "gopls"})
      refute changeset.valid?
      assert %{language: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires command" do
      changeset = LSPConfig.changeset(%LSPConfig{}, %{language: "go"})
      refute changeset.valid?
      assert %{command: ["can't be blank"]} = errors_on(changeset)
    end

    test "defaults auto_start to true" do
      {:ok, config} =
        %LSPConfig{}
        |> LSPConfig.changeset(%{language: "rust", command: "rust-analyzer"})
        |> Repo.insert()

      assert config.auto_start == true
    end

    test "stores args list and settings map" do
      {:ok, config} =
        %LSPConfig{}
        |> LSPConfig.changeset(%{
          language: "typescript",
          command: "typescript-language-server",
          args: ["--stdio"],
          settings: %{"implicitProjectConfig" => %{"checkJs" => true}}
        })
        |> Repo.insert()

      assert config.args == ["--stdio"]
      assert get_in(config.settings, ["implicitProjectConfig", "checkJs"]) == true
    end

    test "enforces unique language constraint" do
      {:ok, _} =
        %LSPConfig{}
        |> LSPConfig.changeset(%{language: "python", command: "pylsp"})
        |> Repo.insert()

      assert {:error, changeset} =
               %LSPConfig{}
               |> LSPConfig.changeset(%{language: "python", command: "pyright"})
               |> Repo.insert()

      assert %{language: ["has already been taken"]} = errors_on(changeset)
    end
  end
end
