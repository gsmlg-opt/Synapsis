defmodule SynapsisPlugin.LSP.Presets do
  @moduledoc """
  Data-driven LSP server presets for supported languages.

  Provides preset configurations for language servers, language detection
  from project files, and seeding of default configurations.
  """

  alias Synapsis.{Repo, PluginConfig}
  import Ecto.Query, only: [from: 2]

  @presets [
    %{
      name: "elixir",
      command: "elixir-ls",
      args: ["--stdio"],
      extensions: [".ex", ".exs"],
      markers: ["mix.exs"]
    },
    %{
      name: "typescript",
      command: "typescript-language-server",
      args: ["--stdio"],
      extensions: [".ts", ".tsx", ".js", ".jsx"],
      markers: ["package.json", "tsconfig.json"]
    },
    %{
      name: "go",
      command: "gopls",
      args: ["serve"],
      extensions: [".go"],
      markers: ["go.mod"]
    },
    %{
      name: "python",
      command: "pyright-langserver",
      args: ["--stdio"],
      extensions: [".py"],
      markers: ["pyproject.toml", "setup.py", "requirements.txt"]
    },
    %{
      name: "rust",
      command: "rust-analyzer",
      args: [],
      extensions: [".rs"],
      markers: ["Cargo.toml"]
    },
    %{
      name: "c_cpp",
      command: "clangd",
      args: [],
      extensions: [".c", ".cpp", ".h", ".hpp"],
      markers: ["CMakeLists.txt", "Makefile"]
    }
  ]

  @doc "Return all LSP presets."
  def all, do: @presets

  @doc "Get a preset by language name. Returns nil for unknown languages."
  def get(name) do
    Enum.find(@presets, &(&1.name == name))
  end

  @doc "Resolve `{command, args}` for a language from presets. Returns nil for unknown."
  def lsp_command(language) do
    case get(language) do
      nil -> nil
      preset -> {preset.command, preset.args}
    end
  end

  @doc "Detect languages present in a project directory using file extensions and markers."
  def detect_languages(project_path) do
    @presets
    |> Enum.filter(fn preset ->
      has_extensions?(project_path, preset.extensions) ||
        has_markers?(project_path, preset.markers)
    end)
    |> Enum.map(& &1.name)
  end

  @doc "Insert all presets into plugin_configs as type \"lsp\" (idempotent)."
  def seed_defaults do
    Enum.each(@presets, fn preset ->
      %PluginConfig{}
      |> PluginConfig.changeset(%{
        type: "lsp",
        name: preset.name,
        command: preset.command,
        args: preset.args,
        auto_start: false
      })
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:name, :scope, :project_id]
      )
    end)

    :ok
  end

  @doc "Return names of presets already configured in the database."
  def configured_names do
    Repo.all(from(p in PluginConfig, where: p.type == "lsp", select: p.name))
  end

  defp has_extensions?(project_path, extensions) do
    Enum.any?(extensions, fn ext ->
      project_path
      |> Path.join("**/*#{ext}")
      |> Path.wildcard()
      |> Enum.any?()
    end)
  end

  defp has_markers?(project_path, markers) do
    Enum.any?(markers, fn marker ->
      project_path
      |> Path.join(marker)
      |> File.exists?()
    end)
  end
end
